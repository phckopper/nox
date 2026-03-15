/**
 * File   : branch_predictor.sv
 * Brief  : Bimodal branch predictor — BTB (Branch Target Buffer) +
 *          BHT (Branch History Table, 2-bit saturating counters).
 *
 * The predictor is queried combinationally every cycle with the current
 * fetch address.  It predicts taken/not-taken and supplies the target
 * address so fetch can redirect the PC one cycle earlier than waiting
 * for execute to resolve the branch.
 *
 * BTB:  16 entries, direct-mapped.  Index = PC[5:2], tag = PC[31:6].
 *       On a hit the entry holds the target address seen last time this
 *       branch (or a branch aliasing into this entry) was executed.
 *
 * BHT:  64 entries of 2-bit saturating counters, indexed by PC[7:2].
 *       MSB == 1  →  predict taken.
 *       Initial state: weakly not-taken (2'b01) so loops warm up quickly
 *       without causing mispredictions on cold non-loop branches.
 *
 * Misprediction recovery is handled by the existing execute→fetch
 * redirect mechanism (fetch_req_i / F_CLR state); no extra logic is
 * needed here.
 *
 * Future work: add GHR for gshare indexing, add RAS for returns.
 */
module branch_predictor
  import nox_utils_pkg::*;
#(
  parameter int BTB_ENTRIES = 16,   // must be a power of two
  parameter int BHT_ENTRIES = 64    // must be a power of two
)(
  input  logic  clk,
  input  logic  rst,

  // ── Query port (combinational) ───────────────────────────────────────
  // Driven every cycle by fetch with the current fetch address.
  input  pc_t   fetch_pc_i,
  output logic  predict_taken_o,   // 1 → redirect fetch to predict_target_o
  output pc_t   predict_target_o,  // predicted branch target

  // ── Update port (from execute, registered) ───────────────────────────
  // Asserted for one cycle when a branch or jump retires from execute.
  input  logic  update_i,
  input  pc_t   update_pc_i,       // PC of the resolved branch/jump
  input  logic  update_taken_i,    // 1 = branch was taken
  input  pc_t   update_target_i    // resolved target address
);

  // ── Local parameters ─────────────────────────────────────────────────
  localparam int BTB_IDX_W = $clog2(BTB_ENTRIES);       // 4
  localparam int BTB_TAG_W = 32 - BTB_IDX_W - 2;        // 26

  // ── BTB storage ──────────────────────────────────────────────────────
  typedef struct packed {
    logic              valid;
    logic [BTB_TAG_W-1:0] tag;
    pc_t               target;
  } btb_entry_t;

  btb_entry_t btb_ff [BTB_ENTRIES];

  // ── BHT storage ──────────────────────────────────────────────────────
  localparam int BHT_IDX_W = $clog2(BHT_ENTRIES);       // 6

  logic [1:0] bht_ff [BHT_ENTRIES];

  // ── Query combinational ──────────────────────────────────────────────
  logic [BTB_IDX_W-1:0] btb_q_idx;
  logic [BTB_TAG_W-1:0] btb_q_tag;
  logic                 btb_hit;
  logic [BHT_IDX_W-1:0] bht_q_idx;

  assign btb_q_idx = fetch_pc_i[BTB_IDX_W+1:2];
  assign btb_q_tag = fetch_pc_i[31:BTB_IDX_W+2];
  assign bht_q_idx = fetch_pc_i[BHT_IDX_W+1:2];

  assign btb_hit = btb_ff[btb_q_idx].valid &&
                   (btb_ff[btb_q_idx].tag == btb_q_tag);

  // predict_taken only when both BTB hits (we know it IS a branch) and
  // the BHT says taken (MSB of the 2-bit counter).
  assign predict_taken_o  = btb_hit && bht_ff[bht_q_idx][1];
  assign predict_target_o = btb_ff[btb_q_idx].target;

  // ── Update sequential ────────────────────────────────────────────────
  logic [BTB_IDX_W-1:0] btb_u_idx;
  logic [BHT_IDX_W-1:0] bht_u_idx;

  assign btb_u_idx = update_pc_i[BTB_IDX_W+1:2];
  assign bht_u_idx = update_pc_i[BHT_IDX_W+1:2];

  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      for (int i = 0; i < BTB_ENTRIES; i++) btb_ff[i] <= '0;
      for (int i = 0; i < BHT_ENTRIES; i++) bht_ff[i] <= 2'b01;  // weakly not-taken
    end
    else if (update_i) begin
      // BTB: install / update entry for this branch PC
      btb_ff[btb_u_idx].valid  <= 1'b1;
      btb_ff[btb_u_idx].tag    <= update_pc_i[31:BTB_IDX_W+2];
      btb_ff[btb_u_idx].target <= update_target_i;

      // BHT: 2-bit saturating counter update
      if (update_taken_i) begin
        if (bht_ff[bht_u_idx] != 2'b11)
          bht_ff[bht_u_idx] <= bht_ff[bht_u_idx] + 1'b1;
      end else begin
        if (bht_ff[bht_u_idx] != 2'b00)
          bht_ff[bht_u_idx] <= bht_ff[bht_u_idx] - 1'b1;
      end
    end
  end

endmodule
