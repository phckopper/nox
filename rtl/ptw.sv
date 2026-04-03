/**
 * File   : ptw.sv
 * Date   : 2026-04-01
 *
 * Sv39 hardware page-table walker (PTW).
 *
 * Walks up to 3 levels of the Sv39 page table on a TLB miss.
 * Uses the core-bus interface (s_cb_mosi_t / s_cb_miso_t) to load PTEs.
 *
 * State machine:
 *   IDLE   → request arrives → L2_AR
 *   L2_AR  → issue read for level-2 PTE (root)
 *   L2_R   → wait for response; decode PTE
 *   L1_AR  → issue read for level-1 PTE
 *   L1_R   → wait; decode PTE
 *   L0_AR  → issue read for level-0 PTE
 *   L0_R   → wait; decode PTE
 *   DONE   → pulse tlb_refill, return to IDLE
 *   FAULT  → pulse mmu_fault, return to IDLE
 *
 * A/D bits: checked; if A=0 (or D=0 for stores) a page fault is raised.
 * OS is responsible for setting A/D before exposing the mapping.
 *
 * All permission checks are done on the raw read data in _R states so that
 * registered PTE fields don't introduce a one-cycle lag.
 */
module ptw
  import nox_utils_pkg::*;
  import mmu_pkg::*;
#()(
  input  logic              clk,
  input  logic              rst,

  // Walk request (from MMU on TLB miss)
  input  logic              walk_req_i,
  input  logic [63:0]       va_i,
  input  mmu_access_t       access_i,    // FETCH / LOAD / STORE
  input  logic [15:0]       asid_i,
  input  logic [43:0]       satp_ppn_i,  // root PPN from satp
  input  logic [1:0]        priv_i,
  input  logic              mxr_i,
  input  logic              sum_i,

  // PTW → memory bus
  output s_cb_mosi_t        ptw_cb_mosi_o,
  input  s_cb_miso_t        ptw_cb_miso_i,

  // PTW is busy (MMU must stall pipeline)
  output logic              busy_o,

  // TLB refill on success (1-cycle pulse)
  output logic              tlb_refill_valid_o,
  output sv39_tlb_entry_t   tlb_refill_entry_o,

  // Fault (1-cycle pulse)
  output mmu_fault_t        mmu_fault_o,
  output logic              mmu_fault_valid_o
);

  typedef enum logic [3:0] {
    IDLE  = 4'd0,
    L2_AR = 4'd1,
    L2_R  = 4'd2,
    L1_AR = 4'd3,
    L1_R  = 4'd4,
    L0_AR = 4'd5,
    L0_R  = 4'd6,
    DONE  = 4'd7,
    FAULT = 4'd8
  } ptw_state_t;

  ptw_state_t   state_ff;
  logic [63:0]  va_ff;
  mmu_access_t  access_ff;
  logic [15:0]  asid_ff;
  logic [43:0]  satp_ppn_ff;
  logic [1:0]   priv_ff;
  logic         mxr_ff, sum_ff;

  // Leaf PTE captured on walk completion
  logic [63:0]       pte_ff;
  sv39_page_size_t   pgsz_ff;

  // Working PPN (root or intermediate pointer)
  logic [43:0]  next_ppn_ff;

  // VPN fields from registered VA
  wire [8:0] vpn2 = va_ff[38:30];
  wire [8:0] vpn1 = va_ff[29:21];
  wire [8:0] vpn0 = va_ff[20:12];

  // PTE read addresses (combinational)
  wire [63:0] pte_addr_l2 = {8'h0, satp_ppn_ff, 12'h0} + {52'h0, vpn2, 3'h0};
  wire [63:0] pte_addr_l1 = {8'h0, next_ppn_ff, 12'h0} + {52'h0, vpn1, 3'h0};
  wire [63:0] pte_addr_l0 = {8'h0, next_ppn_ff, 12'h0} + {52'h0, vpn0, 3'h0};

  // ---- Inline permission check for a given PTE data word ----
  // Checks R/W/X/U bits plus A/D against priv, access, mxr, sum.
  // Used combinationally inside _R states directly on rd_data.
  function automatic logic pte_perm_ok(
    input logic [63:0] pte,
    input mmu_access_t acc,
    input logic [1:0]  priv,
    input logic        mxr,
    input logic        sum
  );
    logic ok;
    logic pv, pr, pw, px, pu, pa, pd;
    pv = pte[`SV39_PTE_V];
    pr = pte[`SV39_PTE_R];
    pw = pte[`SV39_PTE_W];
    px = pte[`SV39_PTE_X];
    pu = pte[`SV39_PTE_U];
    pa = pte[`SV39_PTE_A];
    pd = pte[`SV39_PTE_D];
    ok = 1'b1;
    if (!pv) ok = 1'b0;
    if (!pa) ok = 1'b0;
    if (acc == MMU_STORE && !pd) ok = 1'b0;
    unique case (acc)
      MMU_FETCH: begin
        if (!px)                  ok = 1'b0;
        if (priv == `RV_PRIV_U && !pu) ok = 1'b0;
        if (priv == `RV_PRIV_S &&  pu) ok = 1'b0;
      end
      MMU_LOAD: begin
        if (!pr && !(mxr && px))  ok = 1'b0;
        if (priv == `RV_PRIV_U && !pu) ok = 1'b0;
        if (priv == `RV_PRIV_S && pu && !sum) ok = 1'b0;
      end
      MMU_STORE: begin
        if (!pw)                  ok = 1'b0;
        if (priv == `RV_PRIV_U && !pu) ok = 1'b0;
        if (priv == `RV_PRIV_S && pu && !sum) ok = 1'b0;
      end
      default: ok = 1'b0;
    endcase
    return ok;
  endfunction

  // ---- Bus output (combinational) ----
  always_comb begin
    ptw_cb_mosi_o                = '0;
    ptw_cb_mosi_o.rd_size        = CB_DWORD;
    ptw_cb_mosi_o.rd_ready       = 1'b1;
    unique case (state_ff)
      L2_AR: begin
        ptw_cb_mosi_o.rd_addr_valid = 1'b1;
        ptw_cb_mosi_o.rd_addr       = pte_addr_l2;
      end
      L1_AR: begin
        ptw_cb_mosi_o.rd_addr_valid = 1'b1;
        ptw_cb_mosi_o.rd_addr       = pte_addr_l1;
      end
      L0_AR: begin
        ptw_cb_mosi_o.rd_addr_valid = 1'b1;
        ptw_cb_mosi_o.rd_addr       = pte_addr_l0;
      end
      default: ;
    endcase
  end

  assign busy_o = (state_ff != IDLE) && (state_ff != DONE) && (state_ff != FAULT);

  // ---- TLB refill (combinational, valid in DONE state) ----
  always_comb begin
    tlb_refill_valid_o           = (state_ff == DONE);
    tlb_refill_entry_o           = '0;
    tlb_refill_entry_o.valid     = 1'b1;
    tlb_refill_entry_o.global_p  = pte_ff[`SV39_PTE_G];
    tlb_refill_entry_o.asid      = asid_ff;
    tlb_refill_entry_o.vpn       = va_ff[38:12];
    tlb_refill_entry_o.ppn       = pte_ff[`SV39_PTE_PPN];
    tlb_refill_entry_o.pgsz      = pgsz_ff;
    tlb_refill_entry_o.r         = pte_ff[`SV39_PTE_R];
    tlb_refill_entry_o.w         = pte_ff[`SV39_PTE_W];
    tlb_refill_entry_o.x         = pte_ff[`SV39_PTE_X];
    tlb_refill_entry_o.u         = pte_ff[`SV39_PTE_U];
  end

  // ---- Fault (combinational, valid in FAULT state) ----
  always_comb begin
    mmu_fault_valid_o    = (state_ff == FAULT);
    mmu_fault_o          = '0;
    mmu_fault_o.va       = va_ff;
    unique case (access_ff)
      MMU_FETCH: mmu_fault_o.instr_pf = 1'b1;
      MMU_LOAD:  mmu_fault_o.load_pf  = 1'b1;
      MMU_STORE: mmu_fault_o.store_pf = 1'b1;
      default: ;
    endcase
  end

  // ---- State machine ----
  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      state_ff      <= IDLE;
      va_ff         <= '0;
      access_ff     <= MMU_LOAD;
      asid_ff       <= '0;
      satp_ppn_ff   <= '0;
      priv_ff       <= `RV_PRIV_M;
      mxr_ff        <= '0;
      sum_ff        <= '0;
      pte_ff        <= '0;
      next_ppn_ff   <= '0;
      pgsz_ff       <= PAGE_4K;
    end
    else begin
      unique case (state_ff)

        IDLE: begin
          if (walk_req_i) begin
            va_ff       <= va_i;
            access_ff   <= access_i;
            asid_ff     <= asid_i;
            satp_ppn_ff <= satp_ppn_i;
            priv_ff     <= priv_i;
            mxr_ff      <= mxr_i;
            sum_ff      <= sum_i;
            pgsz_ff     <= PAGE_4K;
            state_ff    <= L2_AR;
          end
        end

        L2_AR: if (ptw_cb_miso_i.rd_addr_ready) state_ff <= L2_R;

        L2_R: begin
          if (ptw_cb_miso_i.rd_valid) begin
            logic [63:0] d;
            d = ptw_cb_miso_i.rd_data;
            pte_ff <= d;
            if (!d[`SV39_PTE_V] || (d[`SV39_PTE_W] && !d[`SV39_PTE_R])) begin
              state_ff <= FAULT;
            end
            else if (d[`SV39_PTE_R] || d[`SV39_PTE_X]) begin
              // 1G superpage leaf
              pgsz_ff     <= PAGE_1G;
              next_ppn_ff <= d[`SV39_PTE_PPN];
              // misaligned superpage: PPN[1] and PPN[0] must be 0
              if (d[`SV39_PTE_PPN1] != 9'h0 || d[`SV39_PTE_PPN0] != 9'h0 ||
                  !pte_perm_ok(d, access_ff, priv_ff, mxr_ff, sum_ff))
                state_ff <= FAULT;
              else
                state_ff <= DONE;
            end
            else begin
              next_ppn_ff <= d[`SV39_PTE_PPN];
              state_ff    <= L1_AR;
            end
          end
        end

        L1_AR: if (ptw_cb_miso_i.rd_addr_ready) state_ff <= L1_R;

        L1_R: begin
          if (ptw_cb_miso_i.rd_valid) begin
            logic [63:0] d;
            d = ptw_cb_miso_i.rd_data;
            pte_ff <= d;
            if (!d[`SV39_PTE_V] || (d[`SV39_PTE_W] && !d[`SV39_PTE_R])) begin
              state_ff <= FAULT;
            end
            else if (d[`SV39_PTE_R] || d[`SV39_PTE_X]) begin
              // 2M superpage leaf
              pgsz_ff     <= PAGE_2M;
              next_ppn_ff <= d[`SV39_PTE_PPN];
              if (d[`SV39_PTE_PPN0] != 9'h0 ||
                  !pte_perm_ok(d, access_ff, priv_ff, mxr_ff, sum_ff))
                state_ff <= FAULT;
              else
                state_ff <= DONE;
            end
            else begin
              next_ppn_ff <= d[`SV39_PTE_PPN];
              state_ff    <= L0_AR;
            end
          end
        end

        L0_AR: if (ptw_cb_miso_i.rd_addr_ready) state_ff <= L0_R;

        L0_R: begin
          if (ptw_cb_miso_i.rd_valid) begin
            logic [63:0] d;
            d = ptw_cb_miso_i.rd_data;
            pte_ff <= d;
            if (!d[`SV39_PTE_V] || (d[`SV39_PTE_W] && !d[`SV39_PTE_R]) ||
                !(d[`SV39_PTE_R] || d[`SV39_PTE_X])) begin
              // invalid, W-without-R, or non-leaf at L0
              state_ff <= FAULT;
            end
            else if (!pte_perm_ok(d, access_ff, priv_ff, mxr_ff, sum_ff)) begin
              state_ff <= FAULT;
            end
            else begin
              pgsz_ff     <= PAGE_4K;
              next_ppn_ff <= d[`SV39_PTE_PPN];
              state_ff    <= DONE;
            end
          end
        end

        DONE:  state_ff <= IDLE;
        FAULT: state_ff <= IDLE;
        default: state_ff <= IDLE;

      endcase
    end
  end

endmodule
