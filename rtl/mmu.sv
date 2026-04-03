/**
 * File   : mmu.sv
 * Date   : 2026-04-01
 *
 * Sv39 MMU wrapper.
 *
 * Sits as a shim between the fetch/LSU bus outputs and the cb_to_axi converters.
 * Contains an I-TLB (32 entries), D-TLB (64 entries), and a shared PTW.
 *
 * Bypass mode: when satp.MODE ≠ Sv39 or privilege = M-mode, addresses pass
 * through untranslated.
 *
 * PTW arbitration: D-TLB miss has priority over I-TLB miss. The PTW
 * always uses the data bus read channels (separate from write channels,
 * so concurrent stores are safe).
 *
 * Page-fault drain:
 *   D-TLB fault → kill_lsu_o (forces LSU to NO_LSU) + mmu_fault_valid_o
 *   I-TLB fault → rd_addr_ready=0 to fetch + mmu_fault_valid_o (no kill needed)
 *
 * csr.sv adds instr_pf / load_pf / store_pf to traps_can_happen_wo_exec.
 * wb.sv suppresses we_rd when mmu_fault_valid fires.
 */
module mmu
  import nox_utils_pkg::*;
  import mmu_pkg::*;
(
  input  logic            clk,
  input  logic            rst,

  // Translation control (from CSR)
  input  logic [63:0]     satp_i,
  input  logic [1:0]      priv_i,
  input  logic            mxr_i,
  input  logic            sum_i,

  // SFENCE.VMA invalidation
  input  logic            sfence_i,
  input  logic [63:0]     sfence_vaddr_i,
  input  logic [63:0]     sfence_asid_i,
  input  logic            sfence_rs1_x0_i,
  input  logic            sfence_rs2_x0_i,

  // Fetch path (I-TLB)
  input  s_cb_mosi_t      fetch_mosi_i,    // from fetch (rd_addr = VA)
  output s_cb_miso_t      fetch_miso_o,    // to fetch (stall via rd_addr_ready)
  output s_cb_mosi_t      instr_mosi_o,    // to instr bus (rd_addr = PA)
  input  s_cb_miso_t      instr_miso_i,    // from instr bus

  // Data path (D-TLB)
  input  s_cb_mosi_t      lsu_mosi_i,      // from LSU (rd_addr/wr_addr = VA)
  output s_cb_miso_t      lsu_miso_o,      // to LSU (stall)
  output s_cb_mosi_t      data_mosi_o,     // to data bus (PA, or PTW reads)
  input  s_cb_miso_t      data_miso_i,     // from data bus

  // Kill LSU (on D-TLB page fault, clears lsu_ff and drops lsu_bp)
  output logic            kill_lsu_o,

  // Page fault (1-cycle pulse to execute/CSR)
  output mmu_fault_t      mmu_fault_o,
  output logic            mmu_fault_valid_o
);

  // ---- Bypass: satp.MODE != Sv39 or priv = M ----
  logic mmu_active;
  assign mmu_active = (satp_i[`SATP_MODE_F] == `SATP_MODE_SV39) &&
                      (priv_i != `RV_PRIV_M);

  // ---- ASID from satp ----
  logic [15:0] satp_asid;
  assign satp_asid = satp_i[`SATP_ASID_F];

  // ---- PTW ----
  // Walk request mux: D-TLB takes priority
  logic         ptw_walk_req;
  logic [63:0]  ptw_va;
  mmu_access_t  ptw_access;

  logic         ptw_busy;
  logic         ptw_refill_valid;
  sv39_tlb_entry_t ptw_refill_entry;
  mmu_fault_t   ptw_fault;
  logic         ptw_fault_valid;

  s_cb_mosi_t   ptw_cb_mosi;
  s_cb_miso_t   ptw_cb_miso;

  ptw u_ptw (
    .clk              (clk),
    .rst              (rst),
    .walk_req_i       (ptw_walk_req),
    .va_i             (ptw_va),
    .access_i         (ptw_access),
    .asid_i           (satp_asid),
    .satp_ppn_i       (satp_i[`SATP_PPN_F]),
    .priv_i           (priv_i),
    .mxr_i            (mxr_i),
    .sum_i            (sum_i),
    .ptw_cb_mosi_o    (ptw_cb_mosi),
    .ptw_cb_miso_i    (ptw_cb_miso),
    .busy_o           (ptw_busy),
    .tlb_refill_valid_o (ptw_refill_valid),
    .tlb_refill_entry_o (ptw_refill_entry),
    .mmu_fault_o      (ptw_fault),
    .mmu_fault_valid_o (ptw_fault_valid)
  );

  // ---- I-TLB ----
  logic        itlb_hit, itlb_pf;
  logic [55:0] itlb_pa;
  logic        itlb_refill_valid;
  sv39_tlb_entry_t itlb_refill_entry;

  tlb #(.ENTRIES(32)) u_itlb (
    .clk              (clk),
    .rst              (rst),
    .va_i             (fetch_mosi_i.rd_addr),
    .asid_i           (satp_asid),
    .access_i         (MMU_FETCH),
    .priv_i           (priv_i),
    .mxr_i            (mxr_i),
    .sum_i            (sum_i),
    .hit_o            (itlb_hit),
    .pa_o             (itlb_pa),
    .perm_fault_o     (itlb_pf),
    .refill_valid_i   (itlb_refill_valid),
    .refill_entry_i   (itlb_refill_entry),
    .sfence_i         (sfence_i),
    .sfence_vaddr_i   (sfence_vaddr_i),
    .sfence_asid_i    (sfence_asid_i),
    .sfence_rs1_x0_i  (sfence_rs1_x0_i),
    .sfence_rs2_x0_i  (sfence_rs2_x0_i)
  );

  // ---- D-TLB ----
  logic        dtlb_hit, dtlb_pf;
  logic [55:0] dtlb_pa;
  mmu_access_t dtlb_access;
  logic [63:0] dtlb_va;

  // For D-TLB, access type depends on whether it's a read or write
  assign dtlb_access = lsu_mosi_i.wr_addr_valid ? MMU_STORE :
                       lsu_mosi_i.rd_addr_valid  ? MMU_LOAD  : MMU_LOAD;
  assign dtlb_va     = lsu_mosi_i.wr_addr_valid  ? lsu_mosi_i.wr_addr : lsu_mosi_i.rd_addr;

  logic        dtlb_refill_valid;
  sv39_tlb_entry_t dtlb_refill_entry;

  tlb #(.ENTRIES(64)) u_dtlb (
    .clk              (clk),
    .rst              (rst),
    .va_i             (dtlb_va),
    .asid_i           (satp_asid),
    .access_i         (dtlb_access),
    .priv_i           (priv_i),
    .mxr_i            (mxr_i),
    .sum_i            (sum_i),
    .hit_o            (dtlb_hit),
    .pa_o             (dtlb_pa),
    .perm_fault_o     (dtlb_pf),
    .refill_valid_i   (dtlb_refill_valid),
    .refill_entry_i   (dtlb_refill_entry),
    .sfence_i         (sfence_i),
    .sfence_vaddr_i   (sfence_vaddr_i),
    .sfence_asid_i    (sfence_asid_i),
    .sfence_rs1_x0_i  (sfence_rs1_x0_i),
    .sfence_rs2_x0_i  (sfence_rs2_x0_i)
  );

  // ---- MMU state machine ----
  typedef enum logic [2:0] {
    S_IDLE    = 3'd0,  // bypass or TLBs idle
    S_D_PTW   = 3'd1,  // D-TLB miss, PTW walking
    S_I_PTW   = 3'd2,  // I-TLB miss, PTW walking
    S_D_FAULT = 3'd3,  // 1-cycle: kill_lsu + fire data PF
    S_I_FAULT = 3'd4   // 1-cycle: fire instr PF, hold fetch stalled
  } mmu_state_t;

  mmu_state_t   state_ff;
  logic [63:0]  fault_va_ff;    // VA being walked (for fault reporting)
  mmu_access_t  fault_acc_ff;   // access type being walked

  // Qualified request signals (only when mmu_active)
  logic d_req, i_req;
  assign d_req = mmu_active && (lsu_mosi_i.rd_addr_valid || lsu_mosi_i.wr_addr_valid);
  assign i_req = mmu_active && fetch_mosi_i.rd_addr_valid;

  // TLB refill routing: route to the TLB that requested the walk
  assign itlb_refill_valid = ptw_refill_valid && (state_ff == S_I_PTW);
  assign itlb_refill_entry = ptw_refill_entry;
  assign dtlb_refill_valid = ptw_refill_valid && (state_ff == S_D_PTW);
  assign dtlb_refill_entry = ptw_refill_entry;

  // PTW walk request: registered via state machine
  // The PTW starts when we enter D_PTW/I_PTW; busy_o stays high until done
  assign ptw_walk_req = (state_ff == S_IDLE) && (
                          (d_req && !dtlb_hit && !dtlb_pf) ||
                          (!d_req && i_req && !itlb_hit && !itlb_pf));
  assign ptw_va       = (d_req && !dtlb_hit && !dtlb_pf) ? dtlb_va :
                                                             fetch_mosi_i.rd_addr;
  assign ptw_access   = (d_req && !dtlb_hit && !dtlb_pf) ? dtlb_access : MMU_FETCH;

  // PTW data bus: mux PTW reads onto data bus during walks
  logic ptw_owns_bus;
  assign ptw_owns_bus = (state_ff == S_D_PTW) || (state_ff == S_I_PTW);

  // ---- Bus mux: PTW vs. translated LSU ----
  // Data bus output
  always_comb begin
    if (!mmu_active) begin
      // Bypass: LSU drives data bus directly
      data_mosi_o = lsu_mosi_i;
    end
    else if (ptw_owns_bus) begin
      // PTW drives read channels; allow LSU write channels through unchanged
      data_mosi_o          = '0;
      data_mosi_o.rd_addr       = ptw_cb_mosi.rd_addr;
      data_mosi_o.rd_addr_valid = ptw_cb_mosi.rd_addr_valid;
      data_mosi_o.rd_size       = ptw_cb_mosi.rd_size;
      data_mosi_o.rd_ready      = ptw_cb_mosi.rd_ready;
      // Still allow LSU write channels (store write data can proceed)
      data_mosi_o.wr_addr       = dtlb_hit ? {8'h0, dtlb_pa} : '0;
      data_mosi_o.wr_addr_valid = 1'b0;  // block write addr during PTW
      data_mosi_o.wr_size       = lsu_mosi_i.wr_size;
      data_mosi_o.wr_data       = lsu_mosi_i.wr_data;
      data_mosi_o.wr_strobe     = lsu_mosi_i.wr_strobe;
      data_mosi_o.wr_data_valid = 1'b0;  // block write data during PTW
      data_mosi_o.wr_resp_ready = lsu_mosi_i.wr_resp_ready;
    end
    else begin
      // Normal translated access
      data_mosi_o = lsu_mosi_i;
      // Substitute translated PA
      if (dtlb_hit) begin
        data_mosi_o.rd_addr = {8'h0, dtlb_pa};
        data_mosi_o.wr_addr = {8'h0, dtlb_pa};
      end
      // On D-TLB miss or fault in IDLE: hold read addr valid off to stall
      if (!dtlb_hit) begin
        data_mosi_o.rd_addr_valid = 1'b0;
        data_mosi_o.wr_addr_valid = 1'b0;
      end
    end
  end

  // PTW miso: connect data bus read response to PTW
  assign ptw_cb_miso.rd_addr_ready = ptw_owns_bus ? data_miso_i.rd_addr_ready : 1'b0;
  assign ptw_cb_miso.rd_valid      = ptw_owns_bus ? data_miso_i.rd_valid       : 1'b0;
  assign ptw_cb_miso.rd_data       = data_miso_i.rd_data;
  assign ptw_cb_miso.rd_resp       = data_miso_i.rd_resp;
  // PTW doesn't use write channels
  assign ptw_cb_miso.wr_addr_ready = 1'b0;
  assign ptw_cb_miso.wr_data_ready = 1'b0;
  assign ptw_cb_miso.wr_resp_valid = 1'b0;
  assign ptw_cb_miso.wr_resp_error = cb_error_t'('0);

  // ---- Fetch path bus output ----
  //
  // Only forward the fetch request to the instruction bus when:
  //   - MMU is in bypass mode (mmu_active=0), OR
  //   - I-TLB hits (can substitute translated PA).
  // When stalling (TLB miss / PTW / fault), suppress rd_addr_valid so that
  // cb_to_axi does NOT issue a spurious AXI read.  If it did, the response
  // would arrive while fetch_miso_o.rd_addr_ready is still 0, causing
  // cb_to_axi to fire rd_valid once with no consumer; when the PTW later
  // unblocks the fetch the expected data beat would already be gone, leaving
  // the fetch pipeline permanently stalled waiting for rd_valid.
  always_comb begin
    instr_mosi_o = fetch_mosi_i;
    if (mmu_active) begin
      if (itlb_hit && state_ff == S_IDLE) begin
        instr_mosi_o.rd_addr = {8'h0, itlb_pa};
      end else begin
        // TLB miss, PTW in progress, or any non-IDLE state: suppress address-phase
        // so cb_to_axi does NOT issue a read while fetch's addr_ready is held at 0.
        // Without this guard, an I-TLB hit during D-TLB PTW would let AXI accept
        // an address without fetch's ot_cnt incrementing; the response would then
        // decrement ot_cnt below zero, wrapping to 7 (3-bit underflow).
        instr_mosi_o.rd_addr_valid = 1'b0;
      end
    end
  end

  // ---- LSU miso: stall control ----
  always_comb begin
    lsu_miso_o = data_miso_i;  // default: passthrough
    if (mmu_active) begin
      // During PTW for D-TLB: stall LSU
      if (state_ff == S_D_PTW) begin
        lsu_miso_o.rd_addr_ready = 1'b0;
        lsu_miso_o.wr_addr_ready = 1'b0;
      end
      // During PTW for I-TLB: stall LSU reads (writes can proceed if bus allows)
      else if (state_ff == S_I_PTW) begin
        lsu_miso_o.rd_addr_ready = 1'b0;
      end
      // During fault: keep stalling
      else if (state_ff == S_D_FAULT || state_ff == S_I_FAULT) begin
        lsu_miso_o.rd_addr_ready = 1'b0;
        lsu_miso_o.wr_addr_ready = 1'b0;
      end
      // In IDLE: stall on miss
      else if (!dtlb_hit && d_req) begin
        lsu_miso_o.rd_addr_ready = 1'b0;
        lsu_miso_o.wr_addr_ready = 1'b0;
      end
    end
  end

  // ---- Fetch miso: stall control ----
  always_comb begin
    fetch_miso_o = instr_miso_i;  // default: passthrough
    if (mmu_active) begin
      // Stall fetch during any PTW or fault, or on I-TLB miss
      if (state_ff != S_IDLE || (i_req && !itlb_hit)) begin
        fetch_miso_o.rd_addr_ready = 1'b0;
      end
      // On I-TLB fault in IDLE: still stall
      if (state_ff == S_I_FAULT) begin
        fetch_miso_o.rd_addr_ready = 1'b0;
      end
    end
  end

  // ---- Kill LSU and page fault outputs ----
  assign kill_lsu_o        = (state_ff == S_D_FAULT);

  always_comb begin
    mmu_fault_valid_o    = 1'b0;
    mmu_fault_o          = '0;
    mmu_fault_o.va       = fault_va_ff;
    if (state_ff == S_D_FAULT) begin
      mmu_fault_valid_o  = 1'b1;
      unique case (fault_acc_ff)
        MMU_LOAD:  mmu_fault_o.load_pf  = 1'b1;
        MMU_STORE: mmu_fault_o.store_pf = 1'b1;
        default:   mmu_fault_o.load_pf  = 1'b1;
      endcase
    end
    else if (state_ff == S_I_FAULT) begin
      mmu_fault_valid_o  = 1'b1;
      mmu_fault_o.instr_pf = 1'b1;
    end
  end

  // ---- State machine ----
  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      state_ff     <= S_IDLE;
      fault_va_ff  <= '0;
      fault_acc_ff <= MMU_LOAD;
    end
    else begin
      unique case (state_ff)

        S_IDLE: begin
          if (mmu_active) begin
`ifdef SIMULATION
            if (i_req && !itlb_hit && !itlb_pf)
              $display("[MMU] @%0t I-TLB miss va=%h priv=%0b", $time, fetch_mosi_i.rd_addr, priv_i);
`endif
            // D-TLB: highest priority
            if (d_req) begin
              if (!dtlb_hit && !dtlb_pf) begin
                // Miss: start PTW for D
                fault_va_ff  <= dtlb_va;
                fault_acc_ff <= dtlb_access;
                state_ff     <= S_D_PTW;
`ifdef SIMULATION
                $display("[MMU] @%0t D-TLB miss PTW start va=%h access=%0b wr_v=%b rd_v=%b priv=%0b",
                         $time, dtlb_va, dtlb_access, lsu_mosi_i.wr_addr_valid, lsu_mosi_i.rd_addr_valid, priv_i);
`endif
              end
              else if (dtlb_hit && dtlb_pf) begin
                // Permission fault
                fault_va_ff  <= dtlb_va;
                fault_acc_ff <= dtlb_access;
                state_ff     <= S_D_FAULT;
`ifdef SIMULATION
                $display("[MMU] @%0t D-TLB fault va=%h priv=%0b", $time, dtlb_va, priv_i);
`endif
              end
              // else: dtlb_hit && !dtlb_pf → pass through (stay IDLE)
            end
            // I-TLB: only when no D request
            else if (i_req) begin
              if (!itlb_hit && !itlb_pf) begin
                // Miss: start PTW for I
                fault_va_ff  <= fetch_mosi_i.rd_addr;
                fault_acc_ff <= MMU_FETCH;
                state_ff     <= S_I_PTW;
              end
              else if (itlb_hit && itlb_pf) begin
                fault_va_ff  <= fetch_mosi_i.rd_addr;
                fault_acc_ff <= MMU_FETCH;
                state_ff     <= S_I_FAULT;
              end
              // else: hit && !pf → pass through
            end
          end
        end

        S_D_PTW: begin
          if (ptw_refill_valid) begin
            // PTW succeeded: TLB refilled. Go to IDLE; D-TLB will hit next cycle.
            state_ff <= S_IDLE;
`ifdef SIMULATION
            $display("[MMU] @%0t D-TLB PTW refill done va=%h", $time, fault_va_ff);
`endif
          end
          else if (ptw_fault_valid) begin
            // PTW fault
            fault_va_ff  <= ptw_fault.va;
            state_ff     <= S_D_FAULT;
`ifdef SIMULATION
            $display("[MMU] @%0t D-TLB PTW fault va=%h", $time, ptw_fault.va);
`endif
          end
        end

        S_I_PTW: begin
          if (ptw_refill_valid) begin
            state_ff <= S_IDLE;
`ifdef SIMULATION
            $display("[MMU] @%0t I-TLB PTW refill done va=%h", $time, fault_va_ff);
`endif
          end
          else if (ptw_fault_valid) begin
            fault_va_ff  <= ptw_fault.va;
            state_ff     <= S_I_FAULT;
`ifdef SIMULATION
            $display("[MMU] @%0t I-TLB PTW fault va=%h", $time, ptw_fault.va);
`endif
          end
        end

        S_D_FAULT: begin state_ff <= S_IDLE; `ifdef SIMULATION $display("[MMU] @%0t D-TLB fault resolved", $time); `endif end
        S_I_FAULT: begin state_ff <= S_IDLE; `ifdef SIMULATION $display("[MMU] @%0t I-TLB fault resolved", $time); `endif end
        default:   state_ff <= S_IDLE;

      endcase
    end
  end

endmodule
