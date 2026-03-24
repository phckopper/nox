/**
 * File   : branch_predictor.sv
 * Brief  : Bimodal branch predictor — BTB (Branch Target Buffer) +
 *          BHT (Branch History Table, 2-bit saturating counters) +
 *          RAS (Return Address Stack).
 *
 * The predictor is queried combinationally every cycle with the current
 * fetch address.  It predicts taken/not-taken and supplies the target
 * address so fetch can redirect the PC one cycle earlier than waiting
 * for execute to resolve the branch.
 *
 * BTB:  64 entries (P3: was 16), direct-mapped.  Index = PC[7:2], tag = PC[31:8].
 *       On a hit the entry holds the target address seen last time this
 *       branch (or a branch aliasing into this entry) was executed.
 *       Each entry also carries an `is_return` flag set when execute
 *       identifies a JALR return (rs1=x1) at that PC.
 *
 * BHT:  64 entries of 2-bit saturating counters, indexed by PC[7:2].
 *       MSB == 1  →  predict taken.
 *       Initial state: weakly not-taken (2'b01) so loops warm up quickly
 *       without causing mispredictions on cold non-loop branches.
 *
 * RAS:  4-entry return-address stack (P2).
 *       Push: when execute resolves a JAL with rd=x1 (function call).
 *             The pushed address is the call's return address (call_pc + 4).
 *       Pop:  decrements the pointer when execute resolves a JALR with
 *             rs1=x1 (function return).
 *       Peek: the stack top is provided combinationally to override the
 *             BTB target when the queried PC is marked as a return.
 *       The `is_return` BTB flag gates the RAS prediction so only confirmed
 *       return instructions use the RAS, avoiding false positives.
 *
 * Misprediction recovery is handled by the existing execute→fetch
 * redirect mechanism (fetch_req_i / F_CLR state); no extra logic is
 * needed here.
 */
module branch_predictor
  import nox_utils_pkg::*;
#(
  parameter int BTB_ENTRIES = 64,   // P3: was 16; must be a power of two
  parameter int BHT_ENTRIES = 64,   // must be a power of two
  parameter int RAS_ENTRIES = 4     // P2: return address stack depth
)(
  input  logic  clk,
  input  logic  rst,

  // ── Query port (combinational) ───────────────────────────────────────
  // Driven every cycle by fetch with the current fetch address.
  input  pc_t   fetch_pc_i,
  output logic  predict_taken_o,   // 1 → redirect fetch to predict_target_o
  output pc_t   predict_target_o,  // predicted branch/return target

  // ── Update port (from execute, registered) ───────────────────────────
  // Asserted for one cycle when a branch or jump retires from execute.
  input  logic  update_i,
  input  pc_t   update_pc_i,       // PC of the resolved branch/jump
  input  logic  update_taken_i,    // 1 = branch was taken
  input  pc_t   update_target_i,   // resolved target address

  // ── RAS control (from execute, P2) ──────────────────────────────────
  // is_call_i:      JAL with rd=x1 resolved — push call_ret_addr_i.
  // is_return_i:    JALR with rs1=x1 resolved — pop RAS, mark PC as return.
  input  logic  is_call_i,
  input  pc_t   call_ret_addr_i,
  input  logic  is_return_i
);

  // ── Local parameters ─────────────────────────────────────────────────
  localparam int BTB_IDX_W = $clog2(BTB_ENTRIES);       // 6
  localparam int BTB_TAG_W = 32 - BTB_IDX_W - 2;        // 24
  localparam int RAS_IDX_W = $clog2(RAS_ENTRIES);       // 2
  localparam int RAS_PTR_W = RAS_IDX_W + 1;             // 3 (0..RAS_ENTRIES)

  // ── BTB storage ──────────────────────────────────────────────────────
  typedef struct packed {
    logic                 valid;
    logic                 is_return;  // P2: this PC is a JALR return instruction
    logic [BTB_TAG_W-1:0] tag;
    pc_t                  target;
  } btb_entry_t;

  btb_entry_t btb_ff [BTB_ENTRIES];

  // ── BHT storage ──────────────────────────────────────────────────────
  localparam int BHT_IDX_W = $clog2(BHT_ENTRIES);       // 6

  logic [1:0] bht_ff [BHT_ENTRIES];

  // ── RAS storage (P2) ─────────────────────────────────────────────────
  pc_t                  ras_ff [RAS_ENTRIES];
  logic [RAS_PTR_W-1:0] ras_ptr_ff;   // 0 = empty, RAS_ENTRIES = full

  // ── Query combinational ──────────────────────────────────────────────
  logic [BTB_IDX_W-1:0] btb_q_idx;
  logic [BTB_TAG_W-1:0] btb_q_tag;
  logic                 btb_hit;
  logic [BHT_IDX_W-1:0] bht_q_idx;
  logic                 ras_predict;
  logic [RAS_IDX_W-1:0] ras_top_idx;  // index of current RAS top entry

  assign btb_q_idx  = fetch_pc_i[BTB_IDX_W+1:2];
  assign btb_q_tag  = fetch_pc_i[31:BTB_IDX_W+2];
  assign bht_q_idx  = fetch_pc_i[BHT_IDX_W+1:2];

  assign btb_hit    = btb_ff[btb_q_idx].valid &&
                      (btb_ff[btb_q_idx].tag == btb_q_tag);

  // RAS prediction: fire when BTB confirms this PC is a return AND the
  // stack is non-empty.  Takes priority over normal BHT prediction.
  assign ras_predict = btb_hit && btb_ff[btb_q_idx].is_return && (ras_ptr_ff > '0);
  assign ras_top_idx = RAS_IDX_W'(ras_ptr_ff - RAS_PTR_W'(1));

  // Normal BTB+BHT prediction (only when not a return).
  assign predict_taken_o  = ras_predict ||
                            (btb_hit && bht_ff[bht_q_idx][1] &&
                             ~btb_ff[btb_q_idx].is_return);

  // Return: use RAS top; otherwise use BTB target.
  assign predict_target_o = ras_predict
                            ? ras_ff[ras_top_idx]
                            : btb_ff[btb_q_idx].target;

  // ── Update sequential ────────────────────────────────────────────────
  logic [BTB_IDX_W-1:0] btb_u_idx;
  logic [BHT_IDX_W-1:0] bht_u_idx;

  assign btb_u_idx = update_pc_i[BTB_IDX_W+1:2];
  assign bht_u_idx = update_pc_i[BHT_IDX_W+1:2];

  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      for (int i = 0; i < BTB_ENTRIES; i++) btb_ff[i] <= '0;
      for (int i = 0; i < BHT_ENTRIES; i++) bht_ff[i] <= 2'b01;  // weakly not-taken
      for (int i = 0; i < RAS_ENTRIES; i++) ras_ff[i] <= '0;
      ras_ptr_ff <= '0;
    end
    else begin
      // ── RAS push/pop ──────────────────────────────────────────────
      if (update_i) begin
        if (is_call_i) begin
          // Push return address; ignore overflow (saturate at RAS_ENTRIES)
          if (ras_ptr_ff < RAS_PTR_W'(RAS_ENTRIES)) begin
            ras_ff[ras_ptr_ff[RAS_IDX_W-1:0]] <= call_ret_addr_i;
            ras_ptr_ff                         <= ras_ptr_ff + 1'b1;
          end
        end else if (is_return_i && ras_ptr_ff > '0) begin
          ras_ptr_ff <= ras_ptr_ff - 1'b1;
        end
      end

      // ── BTB / BHT update ──────────────────────────────────────────
      if (update_i) begin
        // Install / update BTB entry; mark as_return if JALR return
        btb_ff[btb_u_idx].valid     <= 1'b1;
        btb_ff[btb_u_idx].is_return <= is_return_i;
        btb_ff[btb_u_idx].tag       <= update_pc_i[31:BTB_IDX_W+2];
        btb_ff[btb_u_idx].target    <= update_target_i;

        // 2-bit saturating counter
        if (update_taken_i) begin
          if (bht_ff[bht_u_idx] != 2'b11)
            bht_ff[bht_u_idx] <= bht_ff[bht_u_idx] + 1'b1;
        end else begin
          if (bht_ff[bht_u_idx] != 2'b00)
            bht_ff[bht_u_idx] <= bht_ff[bht_u_idx] - 1'b1;
        end
      end
    end
  end

endmodule
