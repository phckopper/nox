/**
 * File              : execute.sv
 * License           : MIT license <Check LICENSE>
 * Author            : Anderson Ignacio da Silva (aignacio) <anderson@aignacio.com>
 * Date              : 21.11.2021
 * Last Modified Date: 22.05.2022
 */
module execute
  import amba_axi_pkg::*;
  import amba_ahb_pkg::*;
  import nox_utils_pkg::*;
#(
  parameter int SUPPORT_DEBUG     = 1,
  parameter int MTVEC_DEFAULT_VAL = 'h1000, // 4KB
  parameter int unsigned M_HART_ID = `M_HART_ID
)(
  input                     clk,
  input                     rst,
  // Control signals
  input   rdata_t           wb_value_i,
  input   rdata_t           wb_load_i,
  input                     lock_wb_i,
  // From DEC stg I/F
  input   s_id_ex_t         id_ex_i,
  input   rdata_t           rs1_data_i,
  input   rdata_t           rs2_data_i,
  input   valid_t           id_valid_i,
  output  ready_t           id_ready_o,
  // To MEM/WB stg I/F
  output  s_ex_mem_wb_t     ex_mem_wb_o,
  output  s_lsu_op_t        lsu_o,
  input                     lsu_bp_i,
  input   pc_t              lsu_pc_i,
  // IRQs
  input   s_irq_t           irq_i,
  // To FETCH stg
  output  logic             fetch_req_o,
  output  pc_t              fetch_addr_o,
  // To DECODE stg — PC tracking update on correct prediction (no flush)
  output  logic             decode_pc_update_o,
  output  pc_t              decode_pc_update_addr_o,
  // Branch predictor update
  output  logic             bp_update_o,
  output  pc_t              bp_update_pc_o,
  output  logic             bp_update_taken_o,
  output  pc_t              bp_update_target_o,
  // Trap signals
  input   s_trap_info_t     fetch_trap_i,
  input   s_trap_lsu_info_t lsu_trap_i
);
  typedef enum logic {
    NO_FWD,
    FWD_REG
  } fwd_mux_t;

  s_ex_mem_wb_t ex_mem_wb_ff, next_ex_mem_wb;
  alu_t         op1, op2, res;
  fwd_mux_t     rs1_fwd, rs2_fwd;
  logic         fwd_wdata;
  logic         jump_or_branch;
  s_branch_t    branch_ff, next_branch;
  s_jump_t      jump_ff, next_jump;
  // PC of the branch/jump instruction held in branch_ff / jump_ff
  pc_t          branch_pc_ff, next_branch_pc;
  pc_t          jump_pc_ff, next_jump_pc;
  // BP state carried alongside branch_ff / jump_ff
  logic         bp_taken_for_branch_ff, next_bp_taken_for_branch;
  logic         bp_taken_for_jump_ff, next_bp_taken_for_jump;
  logic         is_jal_for_jump_ff, next_is_jal_for_jump;
  // Correct-prediction wires (combinational, used in both alu_proc and fetch_req)
  logic         correct_branch_pred;
  logic         correct_jump_pred;
  logic         no_jump_guard;
  rdata_t       csr_rdata;
  s_trap_info_t trap_out;
  logic         will_jump_next_clk;
  logic         eval_trap;
  logic         load_use_hazard;
  s_trap_info_t instr_addr_misaligned;

  // A correct prediction means the BP already redirected fetch to the right
  // target, so execute must NOT fire fetch_req_o again (that would flush the
  // already-correct in-flight fetches and re-fetch redundantly).
  assign correct_branch_pred = branch_ff.b_act && branch_ff.take_branch &&
                               bp_taken_for_branch_ff;
  // Only suppress for JAL (deterministic target = pc+imm); JALR may have a
  // varying target (rs1+imm) so we always let execute redirect for JALR.
  assign correct_jump_pred   = jump_ff.j_act && bp_taken_for_jump_ff &&
                               is_jal_for_jump_ff;

  function automatic branch_dec(branch_t op, rdata_t rs1, rdata_t rs2);
    logic         take_branch;
    case (op)
      RV_B_BEQ:   take_branch = (rs1 == rs2);
      RV_B_BNE:   take_branch = (rs1 != rs2);
      RV_B_BLT:   take_branch = (signed'(rs1) < signed'(rs2));
      RV_B_BGE:   take_branch = (signed'(rs1) >= signed'(rs2));
      RV_B_BLTU:  take_branch = (rs1 < rs2);
      RV_B_BGEU:  take_branch = (rs1 >= rs2);
      default:    take_branch = 'b0;
    endcase
    return take_branch;
  endfunction

  always_comb begin : fwd_mux
    rs1_fwd = NO_FWD;
    rs2_fwd = NO_FWD;

    if ((ex_mem_wb_ff.rd_addr != 'h0) && (ex_mem_wb_ff.we_rd)) begin
      if ((id_ex_i.rs1_op == REG_RF) && (id_ex_i.rs1_addr == ex_mem_wb_ff.rd_addr)) begin
        rs1_fwd = FWD_REG;
      end

      if ((id_ex_i.rs2_op == REG_RF) && (id_ex_i.rs2_addr == ex_mem_wb_ff.rd_addr)) begin
        rs2_fwd = FWD_REG;
      end
    end

    // Load-use hazard: load in WB stage, dependent instruction in EX.
    // Stall for 1 cycle so the loaded value is read from the register file
    // (via bkp_load_ff write-through) rather than forwarded combinationally
    // from AXI rdata, eliminating the in2out timing violation.
    load_use_hazard = (ex_mem_wb_ff.lsu == LSU_LOAD) &&
                      ~lsu_bp_i &&
                      (rs1_fwd == FWD_REG || rs2_fwd == FWD_REG);
  end : fwd_mux

  always_comb begin : alu_proc
    op1 = alu_t'('0);
    op2 = alu_t'('0);
    res = alu_t'('0);
    id_ready_o = 'b1;

    next_ex_mem_wb = ex_mem_wb_ff;

    // Mux Src A (forwarding has highest priority)
    if (rs1_fwd == FWD_REG) begin
      op1 = alu_t'(wb_value_i);
    end else begin
      case (id_ex_i.rs1_op)
        REG_RF:   op1 = alu_t'(rs1_data_i);
        IMM:      op1 = alu_t'(id_ex_i.imm);
        ZERO:     op1 = alu_t'('0);
        PC:       op1 = alu_t'(id_ex_i.pc_dec);
        default:  op1 = alu_t'('0);
      endcase
    end

    // Mux Src B (forwarding has highest priority)
    if (rs2_fwd == FWD_REG) begin
      op2 = alu_t'(wb_value_i);
    end else begin
      case (id_ex_i.rs2_op)
        REG_RF:   op2 = alu_t'(rs2_data_i);
        IMM:      op2 = alu_t'(id_ex_i.imm);
        ZERO:     op2 = alu_t'('0);
        PC:       op2 = alu_t'(id_ex_i.pc_dec);
        default:  op2 = alu_t'('0);
      endcase
    end

    // ALU compute
    case (id_ex_i.f3)
      RV_F3_ADD_SUB:  res = (id_ex_i.f7 == RV_F7_1) ? op1 - op2 : op1 + op2;
      RV_F3_SLT:      res = (signed'(op1) < signed'(op2)) ? 'd1 : 'd0;
      RV_F3_SLTU:     res = (op1 < op2) ? 'd1 : 'd0;
      RV_F3_XOR:      res = (op1 ^ op2);
      RV_F3_OR:       res = (op1 | op2);
      RV_F3_AND:      res = (op1 & op2);
      RV_F3_SLL:      res = op1 << op2[4:0];
      RV_F3_SRL_SRA:  res = (id_ex_i.rshift == RV_SRA) ? signed'((signed'(op1) >>> op2[4:0])) : (op1 >> op2[4:0]);
      default:        res = 'd0;
    endcase

    next_ex_mem_wb.result  = (id_ex_i.jump) ? alu_t'(id_ex_i.pc_dec+'d4) : res;
    next_ex_mem_wb.rd_addr = id_ex_i.rd_addr;
    next_ex_mem_wb.we_rd   = id_ex_i.we_rd;
    next_ex_mem_wb.lsu     = id_ex_i.lsu;

    if (lsu_bp_i) begin
      next_ex_mem_wb = ex_mem_wb_ff;
      id_ready_o = 'b0;
    end

    if (load_use_hazard) begin
      // Stall: squash this instruction's WB write and clear the load flag
      // so the hazard does not re-trigger next cycle.
      next_ex_mem_wb.we_rd = 'b0;
      next_ex_mem_wb.lsu   = NO_LSU;
      id_ready_o           = 'b0;
    end

    // Suppress we_rd for instructions on the wrong speculative path:
    // Case 1: a taken branch/jump resolved — the following fall-through
    //         instruction is wrong-path, UNLESS BP correctly predicted it.
    // Case 2: branch was predicted taken but actually not-taken — the
    //         instruction from the speculative target path must be squashed.
    if ((jump_or_branch && ~correct_branch_pred && ~correct_jump_pred) ||
        (branch_ff.b_act && ~branch_ff.take_branch && bp_taken_for_branch_ff)) begin
      next_ex_mem_wb.we_rd = 'b0;
    end

    if (id_ex_i.csr.op != RV_CSR_NONE) begin
      next_ex_mem_wb.result = csr_rdata;
    end

    ex_mem_wb_o = ex_mem_wb_ff;
    // If we are in a trap, stop RegFile impact
    // of the pending instruction that is saved
    // in the MEPC
    if (trap_out.active) begin
      ex_mem_wb_o.we_rd = 'b0;
    end
  end : alu_proc

  always_comb begin : jump_lsu_mgmt
    instr_addr_misaligned = s_trap_info_t'('0);

    jump_or_branch = ((branch_ff.b_act && branch_ff.take_branch) || jump_ff.j_act);

    // Allow processing of the next branch/jump even when jump_or_branch=1, as
    // long as the previous branch/jump was correctly predicted (pipeline was
    // never flushed, so the current instruction is on the right path).
    no_jump_guard = ~jump_or_branch || correct_jump_pred || correct_branch_pred;

    next_branch.b_act   = id_ex_i.branch && ~lsu_bp_i && ~load_use_hazard;
    next_branch.b_addr  = id_ex_i.pc_dec + id_ex_i.imm;
    next_branch.take_branch  = no_jump_guard &&
                               branch_dec(branch_t'(id_ex_i.f3), op1, op2);

    next_jump.j_act  = no_jump_guard && id_ex_i.jump && ~lsu_bp_i && ~load_use_hazard;
    next_jump.j_addr = {res[31:1], 1'b0};

    // Track the instruction PC so the predictor update carries the right address.
    next_branch_pc = next_branch.b_act ? id_ex_i.pc_dec : branch_pc_ff;
    next_jump_pc   = next_jump.j_act   ? id_ex_i.pc_dec : jump_pc_ff;

    // Track BP state so execute can detect correct predictions and suppress
    // the redundant fetch_req_o / FIFO flush that would otherwise occur.
    next_bp_taken_for_branch = next_branch.b_act ? id_ex_i.bp_taken : bp_taken_for_branch_ff;
    next_bp_taken_for_jump   = next_jump.j_act   ? id_ex_i.bp_taken : bp_taken_for_jump_ff;
    next_is_jal_for_jump     = next_jump.j_act   ? (id_ex_i.rs1_op == PC) : is_jal_for_jump_ff;

    fwd_wdata = (id_ex_i.lsu == LSU_STORE) &&
                (ex_mem_wb_ff.we_rd) &&
                (ex_mem_wb_ff.rd_addr == id_ex_i.rs2_addr) &&
                (ex_mem_wb_ff.rd_addr != raddr_t'('h0));

    lsu_o.op_typ  = load_use_hazard ? NO_LSU : id_ex_i.lsu;
    lsu_o.width   = id_ex_i.lsu_w;
    lsu_o.addr    = res;
    lsu_o.wdata   = rs2_data_i;
    lsu_o.pc_addr = id_ex_i.pc_dec;
    if (fwd_wdata) begin
      // Lock means that we had a load but we had
      // to stall due to bp from the bus, thus we need
      // to use a store value of the load
      lsu_o.wdata  = (lock_wb_i) ? wb_load_i : wb_value_i;
    end
    will_jump_next_clk = next_branch.b_act || next_jump.j_act;

    if (will_jump_next_clk && next_jump.j_act) begin
      instr_addr_misaligned.active = next_jump.j_addr[1];
      instr_addr_misaligned.mtval  = next_jump.j_addr;
    end
    if (will_jump_next_clk && next_branch.b_act) begin
      instr_addr_misaligned.active = next_branch.b_addr[1] || next_branch.b_addr[0];
      instr_addr_misaligned.mtval  = next_branch.b_addr;
    end
  end : jump_lsu_mgmt

  // Branch predictor update — fires for every resolved branch (taken or
  // not-taken) and every unconditional jump.  Jumps are always "taken".
  always_comb begin : bp_update_proc
    bp_update_o        = branch_ff.b_act || jump_ff.j_act;
    bp_update_taken_o  = branch_ff.b_act ? branch_ff.take_branch : 1'b1;
    bp_update_target_o = branch_ff.b_act ? branch_ff.b_addr      : jump_ff.j_addr;
    bp_update_pc_o     = branch_ff.b_act ? branch_pc_ff          : jump_pc_ff;
  end : bp_update_proc

  always_comb begin : fetch_req
    fetch_req_o             = '0;
    fetch_addr_o            = '0;
    decode_pc_update_o      = 1'b0;
    decode_pc_update_addr_o = pc_t'('0);

    // Branch cases:
    //  taken  + not-predicted  → redirect to target (same as before)
    //  taken  + correct-pred   → SUPPRESS (fetch already at target)
    //  taken  + wrong-target   → redirect (handled conservatively: only suppress
    //                            when taken AND predicted, target verified via BTB)
    //  not-taken + predicted   → MISPREDICTION: redirect to fall-through PC+4
    //  not-taken + unpredicted → no redirect needed (sequential fetch continues)
    //
    // Jump (JAL only) cases:
    //  j_act + correct-pred  → SUPPRESS
    //  j_act + not-predicted → redirect as before
    //  j_act + JALR          → always redirect (target may vary per call-site)
    if (branch_ff.b_act) begin
      if (branch_ff.take_branch && ~correct_branch_pred) begin
        // Taken but not correctly predicted: redirect to actual target
        fetch_req_o  = 1'b1;
        fetch_addr_o = branch_ff.b_addr;
      end else if (~branch_ff.take_branch && bp_taken_for_branch_ff) begin
        // Not taken but BP predicted taken: flush speculative target fetches
        fetch_req_o  = 1'b1;
        fetch_addr_o = branch_pc_ff + 4;  // fall-through
      end
    end
    if (jump_ff.j_act && ~correct_jump_pred) begin
      fetch_req_o  = 1'b1;
      fetch_addr_o = jump_ff.j_addr;
    end

    if (trap_out.active) begin
      fetch_req_o  = 'b1;
      fetch_addr_o = trap_out.pc_addr;
    end

    // When a JAL/taken-branch is correctly predicted, fetch_req_o stays 0
    // (no flush needed) but decode never sees jump_i=1, so pc_dec is not
    // updated to the actual target.  Fire a dedicated PC-update pulse so
    // decode can fix up pc_dec without flushing the pipeline.
    if (next_jump.j_act && id_ex_i.bp_taken && (id_ex_i.rs1_op == PC)) begin
      // Correctly-predicted JAL: target was pc+imm (deterministic)
      decode_pc_update_o      = 1'b1;
      decode_pc_update_addr_o = next_jump.j_addr;
    end else if (next_branch.b_act && next_branch.take_branch && id_ex_i.bp_taken) begin
      // Correctly-predicted taken branch
      decode_pc_update_o      = 1'b1;
      decode_pc_update_addr_o = next_branch.b_addr;
    end

    eval_trap = id_ready_o &&
                id_valid_i &&
                ~fetch_req_o &&
                (lsu_o.op_typ == NO_LSU);
  end : fetch_req

  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      ex_mem_wb_ff         <= `OP_RST_L;
      branch_ff            <= s_branch_t'('h0);
      jump_ff              <= s_jump_t'('h0);
      branch_pc_ff         <= pc_t'('0);
      jump_pc_ff           <= pc_t'('0);
      bp_taken_for_branch_ff <= 1'b0;
      bp_taken_for_jump_ff   <= 1'b0;
      is_jal_for_jump_ff     <= 1'b0;
    end
    else begin
      ex_mem_wb_ff         <= next_ex_mem_wb;
      branch_ff            <= next_branch;
      jump_ff              <= next_jump;
      branch_pc_ff         <= next_branch_pc;
      jump_pc_ff           <= next_jump_pc;
      bp_taken_for_branch_ff <= next_bp_taken_for_branch;
      bp_taken_for_jump_ff   <= next_bp_taken_for_jump;
      is_jal_for_jump_ff     <= next_is_jal_for_jump;
    end
  end

  csr #(
    .SUPPORT_DEBUG      (SUPPORT_DEBUG),
    .MTVEC_DEFAULT_VAL  (MTVEC_DEFAULT_VAL),
    .M_HART_ID          (M_HART_ID)
  ) u_csr (
    .clk                (clk),
    .rst                (rst),
    .stall_i            (lsu_bp_i),
    .csr_i              (id_ex_i.csr),
    .rs1_data_i         (op1),
    .imm_i              (id_ex_i.imm),
    .csr_rd_o           (csr_rdata),
    .pc_addr_i          (id_ex_i.pc_dec),
    .pc_lsu_i           (lsu_pc_i),
    .irq_i              (irq_i),
    .will_jump_i        (will_jump_next_clk),
    .eval_trap_i        (eval_trap),
    .dec_trap_i         (id_ex_i.trap),
    .instr_addr_mis_i   (instr_addr_misaligned),
    .fetch_trap_i       (fetch_trap_i),
    .ecall_i            (id_ex_i.ecall),
    .ebreak_i           (id_ex_i.ebreak),
    .mret_i             (id_ex_i.mret),
    .wfi_i              (id_ex_i.wfi),
    .lsu_trap_i         (lsu_trap_i),
    .trap_o             (trap_out)
  );
endmodule
