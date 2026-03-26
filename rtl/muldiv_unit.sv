/**
 * File   : muldiv_unit.sv
 * Brief  : RV64M multiply / divide execution unit.
 *
 * MUL variants  (funct3[2]=0) — 1 stall cycle (inputs registered, product
 *   computed reg-to-reg the following cycle so the multiplier path is a
 *   dedicated register-to-register timing arc, not part of the main ALU).
 *
 * DIV variants  (funct3[2]=1) — 64 stall cycles (restoring shift-subtract).
 *   Operands are pre-abs-valued and sign flags captured at start so the
 *   inner loop is a pure unsigned comparison + subtract, friendly to timing.
 *
 * word_op_i — When set, operates on the lower 32 bits only (MULW/DIVW/REMW).
 *   Inputs are sign- or zero-extended to 64 bits internally; result is
 *   sign-extended from 32 to 64 bits.
 *
 * Interface contract:
 *   valid_i  — pulse one cycle to start; op/a/b sampled that same cycle.
 *   freeze_i — lsu_bp: hold all state (divider counter frozen).
 *   stall_o  — high while unit is busy (MD_MUL or MD_DIV state).
 *   result_valid_o — 1-cycle pulse when result is ready; stall_o is 0.
 *   result_o — valid when result_valid_o.
 *
 * RISC-V spec corner cases handled:
 *   Divide by zero  → quotient = -1 (all 1s), remainder = dividend
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
  input  logic [63:0] a_i,             // operand A (forwarded)
  input  logic [63:0] b_i,             // operand B (forwarded)
  input  logic        word_op_i,       // RV64: *W instructions (32-bit operation)
  // Status / result
  output logic        stall_o,         // unit is computing
  output logic        result_valid_o,  // result ready (1 cycle, ~stall_o)
  output logic [63:0] result_o
);
  // ── State ───────────────────────────────────────────────────────────
  typedef enum logic [1:0] {
    MD_IDLE,
    MD_MUL,   // 1-cycle wait; multiply computed from registered ops
    MD_DIV,   // 64-cycle shift-subtract loop (32 for word ops)
    MD_DONE   // result available; held if freeze_i
  } state_t;

  state_t state_ff, next_state;

  // ── Registered operands ─────────────────────────────────────────────
  logic [63:0] op1_ff;   // a_i saved at start (also orig dividend for div-by-zero rem)
  logic [63:0] op2_ff;   // b_i (mul) or abs(b) divisor (div)
  logic [2:0]  f3_ff;    // funct3 saved at start
  logic        word_ff;  // word_op saved at start

  // ── Divide-specific state ────────────────────────────────────────────
  logic [5:0]  div_cnt_ff;    // iteration counter 63→0 (or 31→0 for word)
  logic [63:0] div_rem_ff;    // partial remainder
  logic [63:0] div_quot_ff;   // accumulating quotient
  logic [63:0] div_divd_ff;   // dividend shift register (MSB→LSB)
  logic        div_neg_q_ff;  // negate quotient at end (signed div)
  logic        div_neg_r_ff;  // negate remainder at end (signed rem)
  logic        div_zero_ff;   // divide-by-zero special case
  logic        div_ovf_ff;    // INT_MIN/-1 overflow special case

  // ── Effective operands (narrowed for *W instructions) ──────────────
  logic [63:0] eff_a, eff_b;
  always_comb begin
    if (word_op_i) begin
      // *W: sign-extend lower 32 bits to 64 (for signed ops) or zero-extend (unsigned)
      if (~op_i[0] && (op_i[2] || op_i[1:0] != 2'b11)) begin
        // Signed: DIV, REM, MUL, MULH, MULHSU
        eff_a = {{32{a_i[31]}}, a_i[31:0]};
        eff_b = {{32{b_i[31]}}, b_i[31:0]};
      end else begin
        // Unsigned: DIVU, REMU, MULHU
        eff_a = {32'b0, a_i[31:0]};
        eff_b = {32'b0, b_i[31:0]};
      end
    end else begin
      eff_a = a_i;
      eff_b = b_i;
    end
  end

  // ── Combinational helpers at operation start ─────────────────────────
  logic        neg_a, neg_b;
  logic [63:0] abs_a, abs_b;

  always_comb begin
    neg_a = ~op_i[0] & eff_a[63];   // signed operation and a is negative
    neg_b = ~op_i[0] & eff_b[63];   // signed operation and b is negative
    abs_a = neg_a ? (-eff_a) : eff_a;
    abs_b = neg_b ? (-eff_b) : eff_b;
  end

  // ── Multiply: 65×65 signed product (registered-operand reg-to-reg arc)
  logic [64:0] mul_a65, mul_b65;
  logic signed [129:0] mul_prod;
  logic [63:0] mul_result;

  always_comb begin
    // a: unsigned only for MULHU (f3=011, both bits set)
    mul_a65 = (&f3_ff[1:0]) ? {1'b0, op1_ff} : {op1_ff[63], op1_ff};
    // b: unsigned when f3[1]=1 (MULHSU=010 and MULHU=011)
    mul_b65 = f3_ff[1] ? {1'b0, op2_ff} : {op2_ff[63], op2_ff};
    mul_prod   = $signed(mul_a65) * $signed(mul_b65);
    // MUL (000) returns lower 64; all other variants return upper 64
    mul_result = (f3_ff == 3'b000) ? mul_prod[63:0] : mul_prod[127:64];
  end

  // ── Divide iteration (combinational from registered state) ───────────
  logic [63:0] div_rem_sh;   // remainder shifted left + new dividend bit
  logic        div_q_bit;    // quotient bit this iteration
  logic [63:0] div_rem_new;  // updated remainder

  always_comb begin
    div_rem_sh  = {div_rem_ff[62:0], div_divd_ff[63]};   // shift in MSB
    div_q_bit   = (div_rem_sh >= op2_ff);                  // unsigned compare
    div_rem_new = div_q_bit ? (div_rem_sh - op2_ff) : div_rem_sh;
  end

  // ── Next state ───────────────────────────────────────────────────────
  always_comb begin
    next_state = state_ff;
    case (state_ff)
      MD_IDLE: if (valid_i) next_state = op_i[2] ? MD_DIV : MD_MUL;
      MD_MUL:  if (~freeze_i) next_state = MD_DONE;
      MD_DIV:  if (~freeze_i && (div_cnt_ff == 6'd0)) next_state = MD_DONE;
      MD_DONE: if (~freeze_i) next_state = MD_IDLE;
      default: next_state = MD_IDLE;
    endcase
  end

  // ── Output ───────────────────────────────────────────────────────────
  logic [63:0] raw_result;

  always_comb begin
    stall_o        = (state_ff == MD_MUL) || (state_ff == MD_DIV);
    result_valid_o = (state_ff == MD_DONE) && ~freeze_i;
    raw_result     = '0;

    if (state_ff == MD_DONE) begin
      if (f3_ff[2]) begin
        // DIV/DIVU/REM/REMU
        if (div_zero_ff) begin
          // Divide by zero: quotient = -1 (all 1s), remainder = dividend
          raw_result = f3_ff[1] ? op1_ff : {64{1'b1}};
        end else if (div_ovf_ff) begin
          // Signed overflow (INT_MIN / -1): quotient = INT_MIN, remainder = 0
          raw_result = f3_ff[1] ? 64'b0 : {1'b1, 63'b0};
        end else if (f3_ff[1]) begin
          // REM/REMU: return remainder, optionally negated
          raw_result = div_neg_r_ff ? (-div_rem_ff) : div_rem_ff;
        end else begin
          // DIV/DIVU: return quotient, optionally negated
          raw_result = div_neg_q_ff ? (-div_quot_ff) : div_quot_ff;
        end
      end else begin
        // MUL/MULH/MULHSU/MULHU
        raw_result = mul_result;
      end
    end

    // RV64: *W instructions sign-extend 32-bit result to 64
    if (word_ff)
      result_o = {{32{raw_result[31]}}, raw_result[31:0]};
    else
      result_o = raw_result;
  end

  // ── Sequential ───────────────────────────────────────────────────────
  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      state_ff    <= MD_IDLE;
      op1_ff      <= '0;
      op2_ff      <= '0;
      f3_ff       <= '0;
      word_ff     <= 1'b0;
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
        f3_ff   <= op_i;
        word_ff <= word_op_i;
        op1_ff  <= eff_a;     // saved for div-by-zero remainder result
        if (op_i[2]) begin
          // Division — pre-compute absolute values and sign flags
          op2_ff       <= abs_b;
          div_divd_ff  <= abs_a;
          div_rem_ff   <= 64'b0;
          div_quot_ff  <= 64'b0;
          div_cnt_ff   <= word_op_i ? 6'd31 : 6'd63;
          div_neg_q_ff <= neg_a ^ neg_b;
          div_neg_r_ff <= neg_a;
          div_zero_ff  <= (eff_b == 64'b0);
          // Signed overflow: INT_MIN / -1
          if (word_op_i)
            div_ovf_ff <= ~op_i[0] && (eff_a == 64'hFFFF_FFFF_8000_0000) && (eff_b == {64{1'b1}});
          else
            div_ovf_ff <= ~op_i[0] && (eff_a == {1'b1, 63'b0}) && (eff_b == {64{1'b1}});
        end else begin
          // Multiply — save b; product computed next cycle from registered ops
          op2_ff <= eff_b;
        end
      end

      // ── Divide iteration ─────────────────────────────────────────────
      if ((state_ff == MD_DIV) && ~freeze_i) begin
        div_rem_ff  <= div_rem_new;
        div_quot_ff <= {div_quot_ff[62:0], div_q_bit};
        div_divd_ff <= {div_divd_ff[62:0], 1'b0};  // shift left
        div_cnt_ff  <= div_cnt_ff - 6'd1;
      end
    end
  end

endmodule
