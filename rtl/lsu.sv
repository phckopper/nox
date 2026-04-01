/**
 * File              : lsu.sv
 * License           : MIT license <Check LICENSE>
 * Author            : Anderson Ignacio da Silva (aignacio) <anderson@aignacio.com>
 * Date              : 04.12.2021
 * Last Modified Date: 21.03.2022
 *
 * P11 (2026-03-24): Added RV32A atomic extension support.
 *   - LR.W: handled as LSU_LOAD with amo_op=AMO_LR; LSU sets reservation on completion.
 *   - SC.W / AMO*: handled by an AMO state machine (LSU_AMO path).
 *     SC.W checks the reservation register; on success issues a store and returns 0;
 *     on fail returns 1 immediately (no memory access).
 *     AMO* does a read-modify-write: load old value, apply operation, store result,
 *     return old value to writeback.
 *   - Reservation is invalidated by any SC.W attempt and by any store to the
 *     reserved word address (conservative for single-hart correctness).
 */
module lsu
  import amba_axi_pkg::*;
  import amba_ahb_pkg::*;
  import nox_utils_pkg::*;
#(
  parameter int SUPPORT_DEBUG         = 1,
  parameter int TRAP_ON_MIS_LSU_ADDR  = 0,
  parameter int TRAP_ON_LSU_ERROR     = 0
)(
  input                     clk,
  input                     rst,
  // From EXE stg
  input   s_lsu_op_t        lsu_i,
  // To EXE stg
  output  logic             lsu_bp_o,
  output  pc_t              lsu_pc_o,
  // To write-back datapath
  output  logic             lsu_bp_data_o,
  output  s_lsu_op_t        wb_lsu_o,
  output  rdata_t           lsu_data_o,
  // Core data bus I/F
  output  s_cb_mosi_t       data_cb_mosi_o,
  input   s_cb_miso_t       data_cb_miso_i,
  output  s_trap_lsu_info_t lsu_trap_o
);
  // ── Normal load/store pipeline registers ──────────────────────────────────
  s_lsu_op_t lsu_ff, next_lsu;

  logic       bp_addr, bp_data;
  logic       ap_txn, ap_rd_txn, ap_wr_txn;
  logic       dp_txn, dp_rd_txn, dp_wr_txn;
  logic       dp_done_ff, next_dp_done;
  logic       lock_ff, next_lock;
  logic       unaligned_lsu;

  cb_addr_t   locked_addr_ff, next_locked_addr;
  cb_addr_t   lsu_req_addr;

  // ── P11: AMO state machine ─────────────────────────────────────────────────
  typedef enum logic [1:0] {
    AMO_IDLE = 2'b00,
    AMO_RD   = 2'b01,   // Issued read, waiting for rvalid
    AMO_WR   = 2'b10    // Issued write, waiting for wr_resp_valid
  } amo_state_t;

  amo_state_t amo_state_ff,   next_amo_state;
  rdata_t     amo_loaded_ff,  next_amo_loaded;  // old value returned to rd
  rdata_t     amo_result_ff,  next_amo_result;  // computed value stored back
  lsu_addr_t  amo_addr_ff,    next_amo_addr;    // AMO word address
  rdata_t     amo_wdata_ff,   next_amo_wdata;   // rs2 operand (AMO source)
  amo_op_t    amo_op_ff,      next_amo_op;      // which AMO
  logic       amo_rd_sent_ff, next_amo_rd_sent; // rd addr phase accepted
  logic       amo_wr_addr_sent_ff, next_amo_wr_addr_sent;
  logic       amo_wr_data_sent_ff, next_amo_wr_data_sent;

  // P11: LR/SC reservation register (per-hart; only one hart in NOX)
  logic       lr_reserved_ff, next_lr_reserved;
  lsu_addr_t  lr_addr_ff,     next_lr_addr;

  // P11: sc_success_ff — 1 when the current lsu_ff is an SC.W that succeeded
  // (used to pick lsu_data_o = 0 vs 1 and to skip the AMO state machine).
  // sc_fail_ff  — 1 when the current lsu_ff is an SC.W that failed.
  logic       sc_success_ff, next_sc_success;

  // bp_amo: additional stall from the AMO state machine
  logic       bp_amo;

  // ── Byte-strobe helper ────────────────────────────────────────────────────
  function automatic cb_strb_t mask_strobe(lsu_w_t size, logic [2:0] shift_left);
    cb_strb_t mask;
    case (size)
      RV_LSU_B:  mask = cb_strb_t'(8'b0000_0001);
      RV_LSU_H:  mask = cb_strb_t'(8'b0000_0011);
      RV_LSU_BU: mask = cb_strb_t'(8'b0000_0001);
      RV_LSU_HU: mask = cb_strb_t'(8'b0000_0011);
      RV_LSU_W:  mask = cb_strb_t'(8'b0000_1111);
      RV_LSU_WU: mask = cb_strb_t'(8'b0000_1111);
      RV_LSU_D:  mask = cb_strb_t'(8'b1111_1111);
      default:   mask = cb_strb_t'(8'b1111_1111);
    endcase

    for (int i=0;i<`XLEN/8;i++) begin
      if (i[2:0] == shift_left) begin
        return mask;
      end
      else begin
        mask = {mask[6:0],1'b0};
      end
    end

    return mask;
  endfunction

  // ── AXI transfer size helper ──────────────────────────────────────────────
  function automatic cb_size_t lsu_cb_size(lsu_w_t w);
    case (w)
      RV_LSU_B,  RV_LSU_BU: return CB_BYTE;
      RV_LSU_H,  RV_LSU_HU: return CB_HALF_WORD;
      RV_LSU_W,  RV_LSU_WU: return CB_WORD;
      RV_LSU_D:              return CB_DWORD;
      default:               return CB_DWORD;
    endcase
  endfunction

  // ── P11: AMO ALU — compute store-back value ───────────────────────────────
  function automatic rdata_t amo_compute(amo_op_t op, rdata_t loaded, rdata_t src);
    case (op)
      AMO_SWAP: return src;
      AMO_ADD:  return loaded + src;
      AMO_XOR:  return loaded ^ src;
      AMO_AND:  return loaded & src;
      AMO_OR:   return loaded | src;
      AMO_MIN:  return ($signed(loaded) < $signed(src)) ? loaded : src;
      AMO_MAX:  return ($signed(loaded) > $signed(src)) ? loaded : src;
      AMO_MINU: return (loaded < src) ? loaded : src;
      AMO_MAXU: return (loaded > src) ? loaded : src;
      default:  return loaded; // LR/SC shouldn't reach here
    endcase
  endfunction

  // ── Main combinational logic ───────────────────────────────────────────────
  always_comb begin
    next_dp_done = dp_done_ff;

    // Default: idle bus
    data_cb_mosi_o = s_cb_mosi_t'('0);
    data_cb_mosi_o.rd_ready      = 'b1;
    data_cb_mosi_o.wr_resp_ready = 'b1;

    lsu_bp_o    = 'b0;
    bp_amo      = 'b0;

    // P11: Exclude LSU_AMO from the normal address/data phase logic.
    // The AMO state machine drives the bus directly when active.
    ap_txn     = (lsu_i.op_typ  != NO_LSU)    && (lsu_i.op_typ  != LSU_AMO);
    ap_rd_txn  = (lsu_i.op_typ  == LSU_LOAD);
    ap_wr_txn  = (lsu_i.op_typ  == LSU_STORE);

    dp_txn     = (lsu_ff.op_typ != NO_LSU)    && (lsu_ff.op_typ != LSU_AMO);
    dp_rd_txn  = (lsu_ff.op_typ == LSU_LOAD);
    dp_wr_txn  = (lsu_ff.op_typ == LSU_STORE);

    // ── Data phase ────────────────────────────────────────────────────────────
    bp_data = 'b0;
    if (dp_txn) begin
      if (~dp_done_ff)
        bp_data = dp_rd_txn ? ~data_cb_miso_i.rd_valid : ~data_cb_miso_i.wr_data_ready;
      if (dp_wr_txn) begin
        data_cb_mosi_o.wr_strobe = mask_strobe(lsu_ff.width, lsu_ff.addr[2:0]);
        for (int i=0;i<`XLEN/8;i++) begin
          if (lsu_ff.addr[2:0]==i[2:0]) begin
            data_cb_mosi_o.wr_data = lsu_ff.wdata << (8*i);
          end
          data_cb_mosi_o.wr_data[(i*8)+:8] = data_cb_mosi_o.wr_strobe[i] ?
                                             data_cb_mosi_o.wr_data[(i*8)+:8] : 8'h0;
        end
        data_cb_mosi_o.wr_data_valid = ~dp_done_ff;
      end
      next_dp_done = ~bp_data;
    end

    // ── Address phase ─────────────────────────────────────────────────────────
    if (lock_ff) begin
      lsu_req_addr = locked_addr_ff;
    end
    else begin
      lsu_req_addr = lsu_i.addr;
    end

    bp_addr = 'b0;
    if (ap_txn) begin
        bp_addr = ap_rd_txn ? ~data_cb_miso_i.rd_addr_ready : ~data_cb_miso_i.wr_addr_ready;
      if (ap_wr_txn) begin
        data_cb_mosi_o.wr_addr       = lsu_req_addr;
        data_cb_mosi_o.wr_size       = lsu_cb_size(lsu_i.width);
        data_cb_mosi_o.wr_addr_valid = ~bp_data;
      end
      else begin
        data_cb_mosi_o.rd_addr       = lsu_req_addr;
        data_cb_mosi_o.rd_size       = lsu_cb_size(lsu_i.width);
        data_cb_mosi_o.rd_addr_valid = ~bp_data;
      end
    end

    next_lock = lock_ff;
    next_locked_addr = locked_addr_ff;

    if (ap_txn) begin
      next_lock = ap_rd_txn ? (data_cb_mosi_o.rd_addr_valid && ~data_cb_miso_i.rd_addr_ready) :
                              (data_cb_mosi_o.wr_addr_valid && ~data_cb_miso_i.wr_addr_ready);
    end

    next_locked_addr = lock_ff ? locked_addr_ff : lsu_req_addr;

    // ── P11: AMO state machine ─────────────────────────────────────────────────
    // Defaults for AMO registers
    next_amo_state        = amo_state_ff;
    next_amo_loaded       = amo_loaded_ff;
    next_amo_result       = amo_result_ff;
    next_amo_addr         = amo_addr_ff;
    next_amo_wdata        = amo_wdata_ff;
    next_amo_op           = amo_op_ff;
    next_amo_rd_sent      = amo_rd_sent_ff;
    next_amo_wr_addr_sent = amo_wr_addr_sent_ff;
    next_amo_wr_data_sent = amo_wr_data_sent_ff;
    next_lr_reserved      = lr_reserved_ff;
    next_lr_addr          = lr_addr_ff;
    next_sc_success       = 1'b0;

    case (amo_state_ff)
      AMO_IDLE: begin
        if (lsu_i.op_typ == LSU_AMO) begin
          // Capture operands for the state machine
          next_amo_addr  = {lsu_i.addr[63:3], 3'b0};  // dword-align
          next_amo_wdata = lsu_i.wdata;
          next_amo_op    = lsu_i.amo_op;

          if (lsu_i.amo_op == AMO_SC) begin
            // Invalidate reservation unconditionally on any SC attempt
            next_lr_reserved = 1'b0;
            if (lr_reserved_ff && (lr_addr_ff == {lsu_i.addr[63:3], 3'b0})) begin
              // SC success: skip the load phase, go straight to write
              next_sc_success  = 1'b1;
              next_amo_loaded  = rdata_t'(0);   // SC success result = 0
              next_amo_result  = lsu_i.wdata;  // store rs2 to memory
              next_amo_state   = AMO_WR;
              next_amo_wr_addr_sent = 1'b0;
              next_amo_wr_data_sent = 1'b0;
              bp_amo = 1'b1;
            end
            // SC fail: no memory op needed, lsu_data_o will return 1 (see below).
            // bp_amo stays 0 → pipeline advances; lsu_ff = LSU_AMO/AMO_SC w/ sc_success=0.
          end else begin
            // AMO*: issue a read first
            bp_amo         = 1'b1;
            next_amo_state = AMO_RD;
            next_amo_rd_sent = 1'b0;
          end
        end
      end

      AMO_RD: begin
        bp_amo = 1'b1;
        // Drive read address (keep valid until accepted)
        data_cb_mosi_o.rd_addr       = amo_addr_ff;
        data_cb_mosi_o.rd_size       = lsu_cb_size(lsu_ff.width);
        data_cb_mosi_o.rd_addr_valid = ~amo_rd_sent_ff;

        if (~amo_rd_sent_ff && data_cb_miso_i.rd_addr_ready)
          next_amo_rd_sent = 1'b1;

        if (data_cb_miso_i.rd_valid) begin
          // Read data arrived: compute store-back value
          next_amo_loaded       = data_cb_miso_i.rd_data;
          next_amo_result       = amo_compute(amo_op_ff, data_cb_miso_i.rd_data, amo_wdata_ff);
          next_amo_state        = AMO_WR;
          next_amo_rd_sent      = 1'b0;
          next_amo_wr_addr_sent = 1'b0;
          next_amo_wr_data_sent = 1'b0;
        end
      end

      AMO_WR: begin
        bp_amo = 1'b1;
        // Preserve sc_success_ff throughout AMO_WR so that WB can read it once
        // lsu_ff is updated to the SC.W/AMO instruction after the stall releases.
        next_sc_success = sc_success_ff;
        // Drive write address and data (keep valid until each is accepted)
        data_cb_mosi_o.wr_addr       = amo_addr_ff;
        data_cb_mosi_o.wr_size       = lsu_cb_size(lsu_ff.width);
        data_cb_mosi_o.wr_addr_valid = ~amo_wr_addr_sent_ff;
        data_cb_mosi_o.wr_data       = amo_result_ff;
        data_cb_mosi_o.wr_strobe     = mask_strobe(lsu_ff.width, 3'b0);
        data_cb_mosi_o.wr_data_valid = ~amo_wr_data_sent_ff;

        if (~amo_wr_addr_sent_ff && data_cb_miso_i.wr_addr_ready)
          next_amo_wr_addr_sent = 1'b1;
        if (~amo_wr_data_sent_ff && data_cb_miso_i.wr_data_ready)
          next_amo_wr_data_sent = 1'b1;

        if (data_cb_miso_i.wr_resp_valid) begin
          // Write acknowledged: release stall, return to IDLE.
          // Keep sc_success_ff=1 one more cycle so it's still set when lsu_ff
          // is updated to the SC.W instruction and WB reads lsu_data_o.
          bp_amo         = 1'b0;
          next_amo_state = AMO_IDLE;
          next_amo_wr_addr_sent = 1'b0;
          next_amo_wr_data_sent = 1'b0;
        end
      end

      default: next_amo_state = AMO_IDLE;
    endcase

    // ── P11: LR.W — set reservation when load completes ───────────────────────
    // lsu_ff.amo_op == AMO_LR indicates this is an LR.W in the data phase.
    if (dp_txn && dp_rd_txn && ~dp_done_ff &&
        data_cb_miso_i.rd_valid && lsu_ff.amo_op == AMO_LR) begin
      next_lr_reserved = 1'b1;
      next_lr_addr     = {lsu_ff.addr[63:3], 3'b0};
    end

    // Invalidate reservation on any regular STORE to the reserved address
    if (lsu_ff.op_typ == LSU_STORE &&
        ({lsu_ff.addr[63:3], 3'b0} == lr_addr_ff)) begin
      next_lr_reserved = 1'b0;
    end

    // ── Combined backpressure ──────────────────────────────────────────────────
    lsu_bp_o = bp_addr || bp_data || bp_amo;
    lsu_bp_data_o = bp_data;

    next_lsu = lsu_ff;

    if (~lsu_bp_o) begin
      next_lsu = lsu_i;
      next_lsu.addr = lock_ff ? locked_addr_ff : lsu_i.addr;
      next_dp_done = 'b0;
    end

    // ── Outputs to writeback ───────────────────────────────────────────────────
    wb_lsu_o = lsu_ff;
    lsu_pc_o = lsu_ff.pc_addr;

    // lsu_data_o mux:
    //   - Normal load / LR.W → AXI read data (fmt_load in WB handles alignment)
    //   - AMO* (lsu_ff=LSU_AMO, not SC) → old loaded value
    //   - SC.W success → 0   (sc_success_ff set when SC succeeded)
    //   - SC.W fail    → 1   (sc_success_ff=0, amo_op=AMO_SC)
    lsu_data_o = data_cb_miso_i.rd_data;
    if (lsu_ff.op_typ == LSU_AMO) begin
      if (lsu_ff.amo_op == AMO_SC) begin
        lsu_data_o = sc_success_ff ? rdata_t'(0) : rdata_t'(1);
      end else begin
        lsu_data_o = amo_loaded_ff;
      end
    end
  end

  always_comb begin : trap_lsu
    lsu_trap_o = s_trap_lsu_info_t'('0);

    unaligned_lsu = 'b0;

    case (lsu_i.width)
      RV_LSU_B:  unaligned_lsu = 'b0;
      RV_LSU_H:  unaligned_lsu = (lsu_req_addr[0]   != 1'b0);
      RV_LSU_BU: unaligned_lsu = 'b0;
      RV_LSU_HU: unaligned_lsu = (lsu_req_addr[0]   != 1'b0);
      RV_LSU_W:  unaligned_lsu = (lsu_req_addr[1:0] != 2'd0);
      RV_LSU_WU: unaligned_lsu = (lsu_req_addr[1:0] != 2'd0);
      RV_LSU_D:  unaligned_lsu = (lsu_req_addr[2:0] != 3'd0);
      default:   unaligned_lsu = 'b0;
    endcase

    if ((lsu_i.op_typ != NO_LSU) && (lsu_i.op_typ != LSU_AMO) && unaligned_lsu) begin
      if ((lsu_i.op_typ == LSU_LOAD) && data_cb_mosi_o.rd_addr_valid)
        lsu_trap_o.ld_mis.active = (TRAP_ON_MIS_LSU_ADDR == 'b1);

      if ((lsu_i.op_typ == LSU_STORE) && data_cb_mosi_o.wr_addr_valid)
        lsu_trap_o.st_mis.active = (TRAP_ON_MIS_LSU_ADDR == 'b1);
    end

    if (data_cb_miso_i.wr_resp_valid && (data_cb_miso_i.wr_resp_error != CB_OKAY)) begin
      lsu_trap_o.st.active = (TRAP_ON_LSU_ERROR == 'b1);
    end

    if (data_cb_miso_i.rd_valid && (data_cb_miso_i.rd_resp != CB_OKAY)) begin
      lsu_trap_o.ld.active = (TRAP_ON_LSU_ERROR == 'b1);
    end
  end : trap_lsu

  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      lsu_ff               <= s_lsu_op_t'('0);
      dp_done_ff           <= 'b0;
      lock_ff              <= 'b0;
      locked_addr_ff       <= '0;
      // P11: AMO state
      amo_state_ff         <= AMO_IDLE;
      amo_loaded_ff        <= '0;
      amo_result_ff        <= '0;
      amo_addr_ff          <= '0;
      amo_wdata_ff         <= '0;
      amo_op_ff            <= amo_op_t'('0);
      amo_rd_sent_ff       <= 1'b0;
      amo_wr_addr_sent_ff  <= 1'b0;
      amo_wr_data_sent_ff  <= 1'b0;
      lr_reserved_ff       <= 1'b0;
      lr_addr_ff           <= '0;
      sc_success_ff        <= 1'b0;
    end
    else begin
      lsu_ff               <= next_lsu;
      dp_done_ff           <= next_dp_done;
      lock_ff              <= next_lock;
      locked_addr_ff       <= next_locked_addr;
      amo_state_ff         <= next_amo_state;
      amo_loaded_ff        <= next_amo_loaded;
      amo_result_ff        <= next_amo_result;
      amo_addr_ff          <= next_amo_addr;
      amo_wdata_ff         <= next_amo_wdata;
      amo_op_ff            <= next_amo_op;
      amo_rd_sent_ff       <= next_amo_rd_sent;
      amo_wr_addr_sent_ff  <= next_amo_wr_addr_sent;
      amo_wr_data_sent_ff  <= next_amo_wr_data_sent;
      lr_reserved_ff       <= next_lr_reserved;
      lr_addr_ff           <= next_lr_addr;
      sc_success_ff        <= next_sc_success;
    end
  end

endmodule
