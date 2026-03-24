/**
 * File   : muldiv_unit.sv
 * Brief  : RV32M multiply / divide execution unit.
 *
 * MUL variants  (funct3[2]=0) — 1 stall cycle (inputs registered, product
 *   computed reg-to-reg the following cycle so the multiplier path is a
 *   dedicated register-to-register timing arc, not part of the main ALU).
 *
 * DIV variants  (funct3[2]=1) — 32 stall cycles (restoring shift-subtract).
 *   Operands are pre-abs-valued and sign flags captured at start so the
 *   inner loop is a pure unsigned comparison + subtract, friendly to timing.
 *
 * Interface contract:
 *   valid_i  — pulse one cycle to start; op/a/b sampled that same cycle.
 *   freeze_i — lsu_bp: hold all state (divider counter frozen).
 *   stall_o  — high while unit is busy (MD_MUL or MD_DIV state).
 *   result_valid_o — 1-cycle pulse when result is ready; stall_o is 0.
 *   result_o — valid when result_valid_o.
 *
 * RISC-V spec corner cases handled:
 *   Divide by zero  → quotient = -1 (FFFF_FFFF), remainder = dividend
 *   Signed overflow  → INT_MIN / -1: quotient = INT_MIN, remainder = 0
 */
module muldiv_unit
  import nox_utils_pkg::*;
(
  input  logic        clk,
  input  logic        rst,
  // Control
  input  logic        valid_i,         // start a new operation
  input  logic        freeze_i,        // lsu_bp: freeze divider state
  // Operation
  input  logic [2:0]  op_i,            // funct3: 000=MUL 001=MULH 010=MULHSU
                                        //         011=MULHU 100=DIV 101=DIVU
                                        //         110=REM  111=REMU
  input  logic [31:0] a_i,             // operand A (forwarded)
  input  logic [31:0] b_i,             // operand B (forwarded)
  // Status / result
  output logic        stall_o,         // unit is computing
  output logic        result_valid_o,  // result ready (1 cycle, ~stall_o)
  output logic [31:0] result_o
);
  // ── State ───────────────────────────────────────────────────────────
  typedef enum logic [1:0] {
    MD_IDLE,
    MD_MUL,   // 1-cycle wait; multiply computed from registered ops
    MD_DIV,   // 32-cycle shift-subtract loop
    MD_DONE   // result available; held if freeze_i
  } state_t;

  state_t state_ff, next_state;

  // ── Registered operands ─────────────────────────────────────────────
  logic [31:0] op1_ff;   // a_i saved at start (also orig dividend for div-by-zero rem)
  logic [31:0] op2_ff;   // b_i (mul) or abs(b) divisor (div)
  logic [2:0]  f3_ff;    // funct3 saved at start

  // ── Divide-specific state ────────────────────────────────────────────
  logic [4:0]  div_cnt_ff;    // iteration counter 31→0
  logic [31:0] div_rem_ff;    // partial remainder
  logic [31:0] div_quot_ff;   // accumulating quotient
  logic [31:0] div_divd_ff;   // dividend shift register (MSB→LSB)
  logic        div_neg_q_ff;  // negate quotient at end (signed div)
  logic        div_neg_r_ff;  // negate remainder at end (signed rem)
  logic        div_zero_ff;   // divide-by-zero special case
  logic        div_ovf_ff;    // INT_MIN/-1 overflow special case

  // ── Combinational helpers at operation start ─────────────────────────
  logic        neg_a, neg_b;
  logic [31:0] abs_a, abs_b;

  always_comb begin
    neg_a = ~op_i[0] & a_i[31];   // signed operation and a is negative
    neg_b = ~op_i[0] & b_i[31];   // signed operation and b is negative
    abs_a = neg_a ? (-a_i) : a_i;
    abs_b = neg_b ? (-b_i) : b_i;
  end

  // ── Multiply: 33×33 signed product (registered-operand reg-to-reg arc)
  // Operand sign extension:
  //   f3=011 (MULHU) : a unsigned → zero-extend
  //   f3=010 (MULHSU): a signed, b unsigned
  //   f3=001 (MULH)  : both signed
  //   f3=000 (MUL)   : lower 32 bits — sign irrelevant
  logic [32:0] mul_a33, mul_b33;
  logic signed [65:0] mul_prod;
  logic [31:0] mul_result;

  always_comb begin
    // a: unsigned only for MULHU (f3=011, both bits set)
    mul_a33 = (&f3_ff[1:0]) ? {1'b0, op1_ff} : {op1_ff[31], op1_ff};
    // b: unsigned when f3[1]=1 (MULHSU=010 and MULHU=011)
    mul_b33 = f3_ff[1] ? {1'b0, op2_ff} : {op2_ff[31], op2_ff};
    mul_prod   = $signed(mul_a33) * $signed(mul_b33);
    // MUL (000) returns lower 32; all other variants return upper 32
    mul_result = (f3_ff == 3'b000) ? mul_prod[31:0] : mul_prod[63:32];
  end

  // ── Divide iteration (combinational from registered state) ───────────
  logic [31:0] div_rem_sh;   // remainder shifted left + new dividend bit
  logic        div_q_bit;    // quotient bit this iteration
  logic [31:0] div_rem_new;  // updated remainder

  always_comb begin
    div_rem_sh  = {div_rem_ff[30:0], div_divd_ff[31]};   // shift in MSB
    div_q_bit   = (div_rem_sh >= op2_ff);                 // unsigned compare
    div_rem_new = div_q_bit ? (div_rem_sh - op2_ff) : div_rem_sh;
  end

  // ── Next state ───────────────────────────────────────────────────────
  always_comb begin
    next_state = state_ff;
    case (state_ff)
      MD_IDLE: if (valid_i) next_state = op_i[2] ? MD_DIV : MD_MUL;
      MD_MUL:  if (~freeze_i) next_state = MD_DONE;
      MD_DIV:  if (~freeze_i && (div_cnt_ff == 5'd0)) next_state = MD_DONE;
      MD_DONE: if (~freeze_i) next_state = MD_IDLE;
      default: next_state = MD_IDLE;
    endcase
  end

  // ── Output ───────────────────────────────────────────────────────────
  always_comb begin
    stall_o        = (state_ff == MD_MUL) || (state_ff == MD_DIV);
    result_valid_o = (state_ff == MD_DONE) && ~freeze_i;
    result_o       = '0;

    if (state_ff == MD_DONE) begin
      if (f3_ff[2]) begin
        // DIV/DIVU/REM/REMU
        if (div_zero_ff) begin
          // Divide by zero: quotient = -1 (all 1s), remainder = dividend
          result_o = f3_ff[1] ? op1_ff : 32'hFFFF_FFFF;
        end else if (div_ovf_ff) begin
          // Signed overflow (INT_MIN / -1): quotient = INT_MIN, remainder = 0
          result_o = f3_ff[1] ? 32'b0 : 32'h8000_0000;
        end else if (f3_ff[1]) begin
          // REM/REMU: return remainder, optionally negated
          result_o = div_neg_r_ff ? (-div_rem_ff) : div_rem_ff;
        end else begin
          // DIV/DIVU: return quotient, optionally negated
          result_o = div_neg_q_ff ? (-div_quot_ff) : div_quot_ff;
        end
      end else begin
        // MUL/MULH/MULHSU/MULHU
        result_o = mul_result;
      end
    end
  end

  // ── Sequential ───────────────────────────────────────────────────────
  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      state_ff    <= MD_IDLE;
      op1_ff      <= '0;
      op2_ff      <= '0;
      f3_ff       <= '0;
      div_cnt_ff  <= '0;
      div_rem_ff  <= '0;
      div_quot_ff <= '0;
      div_divd_ff <= '0;
      div_neg_q_ff <= 1'b0;
      div_neg_r_ff <= 1'b0;
      div_zero_ff  <= 1'b0;
      div_ovf_ff   <= 1'b0;
    end
    else begin
      state_ff <= next_state;

      // ── Capture inputs when starting a new operation ─────────────────
      if (valid_i && (state_ff == MD_IDLE)) begin
        f3_ff  <= op_i;
        op1_ff <= a_i;     // saved for div-by-zero remainder result
        if (op_i[2]) begin
          // Division — pre-compute absolute values and sign flags
          op2_ff       <= abs_b;
          div_divd_ff  <= abs_a;
          div_rem_ff   <= 32'b0;
          div_quot_ff  <= 32'b0;
          div_cnt_ff   <= 5'd31;
          div_neg_q_ff <= neg_a ^ neg_b;
          div_neg_r_ff <= neg_a;
          div_zero_ff  <= (b_i == 32'b0);
          // Signed overflow: INT_MIN / -1 (a=0x80000000, b=0xFFFFFFFF)
          div_ovf_ff   <= ~op_i[0] && (a_i == 32'h8000_0000) && (&b_i);
        end else begin
          // Multiply — save b; product computed next cycle from registered ops
          op2_ff <= b_i;
        end
      end

      // ── Divide iteration ─────────────────────────────────────────────
      if ((state_ff == MD_DIV) && ~freeze_i) begin
        div_rem_ff  <= div_rem_new;
        div_quot_ff <= {div_quot_ff[30:0], div_q_bit};
        div_divd_ff <= {div_divd_ff[30:0], 1'b0};  // shift left
        div_cnt_ff  <= div_cnt_ff - 5'd1;
      end
    end
  end

endmodule
