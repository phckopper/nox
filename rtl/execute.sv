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
  // P2: RAS call/return signals (routed through fetch to branch_predictor)
  output  logic             bp_is_call_o,
  output  pc_t              bp_call_ret_addr_o,
  output  logic             bp_is_return_o,
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
  // P2: call/return register operand addresses
  raddr_t       rd_addr_for_jump_ff,  next_rd_addr_for_jump;
  raddr_t       rs1_addr_for_jump_ff, next_rs1_addr_for_jump;
  // Pre-registered flag: did the resolved JALR address match the BTB/RAS prediction?
  // Computed when next_jump.j_act fires (non-critical path), then stored so that
  // correct_jump_pred no longer needs the slow 32-bit combinational equality from
  // jump_ff.j_addr, eliminating the reg2reg / reg2out timing violations.
  logic         j_addr_matched_pred_ff, next_j_addr_matched_pred;
  // Correct-prediction wires (combinational, used in both alu_proc and fetch_req)
  logic         correct_branch_pred;
  logic         correct_jump_pred;
  logic         no_jump_guard;
  rdata_t       csr_rdata;
  s_trap_info_t trap_out;
  logic         will_jump_next_clk;
  logic         eval_trap;
  logic         load_use_hazard;
  logic         mispred_not_taken;
  logic         wrong_path;
  s_trap_info_t instr_addr_misaligned;

  // P7: MulDiv unit interface
  logic         muldiv_valid;        // start pulse to unit
  logic         muldiv_stall;        // unit is computing (stall pipeline)
  logic         muldiv_result_valid; // unit done: result ready this cycle
  rdata_t       muldiv_result;       // result from unit

  // A correct prediction means the BP already redirected fetch to the right
  // target, so execute must NOT fire fetch_req_o again (that would flush the
  // already-correct in-flight fetches and re-fetch redundantly).
  assign correct_branch_pred = branch_ff.b_act && branch_ff.take_branch &&
                               bp_taken_for_branch_ff;
  // Suppress for JAL (deterministic target = pc+imm) OR for correctly-
  // predicted JALR: when the BTB/RAS predicted the exact same target that
  // execute resolved, the pipeline is already on the right path.
  assign correct_jump_pred   = jump_ff.j_act && bp_taken_for_jump_ff &&
                               (is_jal_for_jump_ff || j_addr_matched_pred_ff);

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
    // LSU_AMO result is available when lsu_bp drops (state machine completes), same
    // timing as LSU_LOAD, so treat it identically for the load-use hazard check.
    load_use_hazard = (ex_mem_wb_ff.lsu == LSU_LOAD || ex_mem_wb_ff.lsu == LSU_AMO) &&
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

    // ALU compute — base RV32IM + Zba / Zbb-subset / Zicond extensions
    case (id_ex_i.f3)
      // funct3=000: ADD, SUB — no extension uses this funct3
      RV_F3_ADD_SUB:  res = (id_ex_i.f7 == RV_F7_1) ? op1 - op2 : op1 + op2;

      // funct3=001 (SLL/SLLI): also sext.b (funct7=0110000,shamt=00100)
      //                         and sext.h (funct7=0110000,shamt=00101) [Zbb]
      //                         clz (funct7=0110000,shamt=00000)        [Zbb]
      //                         ctz (funct7=0110000,shamt=00001)        [Zbb]
      //                         cpop (funct7=0110000,shamt=00010)       [Zbb]
      //                         rol (funct7=0110000) OP binary          [Zbb]
      RV_F3_SLL: begin
        if (id_ex_i.funct7_raw == 7'b011_0000 && id_ex_i.imm[4:0] == 5'b0_0100) begin
          res = {{24{op1[7]}},  op1[7:0]};       // sext.b
        end else if (id_ex_i.funct7_raw == 7'b011_0000 && id_ex_i.imm[4:0] == 5'b0_0101) begin
          res = {{16{op1[15]}}, op1[15:0]};      // sext.h
        end else if (id_ex_i.funct7_raw == 7'b011_0000 && id_ex_i.imm[4:0] == 5'b0_0000) begin
          // clz: count leading zeros
          begin
            logic [5:0] clz_n;
            clz_n = 6'd32;
            for (int ci = 31; ci >= 0; ci--) begin
              if (op1[ci] && (clz_n == 6'd32)) clz_n = 6'(31 - ci);
            end
            res = alu_t'(clz_n);
          end
        end else if (id_ex_i.funct7_raw == 7'b011_0000 && id_ex_i.imm[4:0] == 5'b0_0001) begin
          // ctz: count trailing zeros
          begin
            logic [5:0] ctz_n;
            ctz_n = 6'd32;
            for (int ci = 0; ci <= 31; ci++) begin
              if (op1[ci] && (ctz_n == 6'd32)) ctz_n = 6'(ci);
            end
            res = alu_t'(ctz_n);
          end
        end else if (id_ex_i.funct7_raw == 7'b011_0000 && id_ex_i.imm[4:0] == 5'b0_0010) begin
          // cpop: population count
          begin
            logic [5:0] pop_n;
            pop_n = 6'd0;
            for (int ci = 0; ci <= 31; ci++) begin
              if (op1[ci]) pop_n = pop_n + 6'd1;
            end
            res = alu_t'(pop_n);
          end
        end else if (id_ex_i.funct7_raw == 7'b011_0000) begin
          // rol: rotate left (OP binary, op2 is rs2)
          res = (op2[4:0] == 5'b0) ? op1 :
                ((op1 << op2[4:0]) | (op1 >> (6'd32 - {1'b0, op2[4:0]})));
        end else begin
          res = op1 << op2[4:0];                 // SLL / SLLI
        end
      end

      // funct3=010 (SLT): also sh1add (funct7=0010000)  [Zba]
      RV_F3_SLT: begin
        if (id_ex_i.funct7_raw == 7'b001_0000)
          res = (op1 << 1) + op2;                // sh1add
        else
          res = (signed'(op1) < signed'(op2)) ? 'd1 : 'd0;  // SLT
      end

      // funct3=011 (SLTU): no extension uses this funct3
      RV_F3_SLTU:  res = (op1 < op2) ? 'd1 : 'd0;

      // funct3=100 (XOR): sh2add (0010000), min (0000101), xnor (0100000),
      //                    zext.h (0000100)  [Zba/Zbb]
      RV_F3_XOR: begin
        case (id_ex_i.funct7_raw)
          7'b001_0000: res = (op1 << 2) + op2;              // sh2add  [Zba]
          7'b000_0101: res = ($signed(op1) < $signed(op2)) ? op1 : op2; // min [Zbb]
          7'b010_0000: res = ~(op1 ^ op2);                  // xnor   [Zbb]
          7'b000_0100: res = {16'b0, op1[15:0]};            // zext.h [Zbb]
          default:     res = op1 ^ op2;                     // XOR
        endcase
      end

      // funct3=101 (SRL/SRA): minu (0000101), czero.eqz (0000111) [Zbb/Zicond]
      //                        ror/rori (0110000) [Zbb]
      //                        orc.b (0010100,shamt=00111) [Zbb]
      //                        rev8 (0110101,shamt=11000)  [Zbb]
      RV_F3_SRL_SRA: begin
        case (id_ex_i.funct7_raw)
          7'b000_0101: res = (op1 < op2) ? op1 : op2;       // minu   [Zbb]
          7'b000_0111: res = (op2 == '0) ? '0 : op1;        // czero.eqz [Zicond]
          7'b011_0000: begin
            // ror / rori: rotate right; op2[4:0] is the shift amount
            res = (op2[4:0] == 5'b0) ? op1 :
                  ((op1 >> op2[4:0]) | (op1 << (6'd32 - {1'b0, op2[4:0]})));
          end
          7'b010_1000: begin
            // orc.b (funct7=0x28, shamt=0x07): OR-combine bytes
            // Each byte becomes 0xFF if any bit set, else 0x00
            res = { {8{|op1[31:24]}}, {8{|op1[23:16]}},
                    {8{|op1[15:8]}},  {8{|op1[7:0]}}  };
          end
          7'b011_0101: begin
            // rev8 (funct7=0x35, shamt=0x18): byte-reverse (endian swap)
            res = {op1[7:0], op1[15:8], op1[23:16], op1[31:24]};
          end
          default:     res = (id_ex_i.rshift == RV_SRA) ?
                             signed'((signed'(op1) >>> op2[4:0])) :
                             (op1 >> op2[4:0]);              // SRL/SRA
        endcase
      end

      // funct3=110 (OR): sh3add (0010000), max (0000101), orn (0100000)  [Zba/Zbb]
      RV_F3_OR: begin
        case (id_ex_i.funct7_raw)
          7'b001_0000: res = (op1 << 3) + op2;              // sh3add  [Zba]
          7'b000_0101: res = ($signed(op1) > $signed(op2)) ? op1 : op2; // max [Zbb]
          7'b010_0000: res = op1 | ~op2;                    // orn     [Zbb]
          default:     res = op1 | op2;                     // OR
        endcase
      end

      // funct3=111 (AND): maxu (0000101), andn (0100000), czero.nez (0000111)  [Zbb/Zicond]
      RV_F3_AND: begin
        case (id_ex_i.funct7_raw)
          7'b000_0101: res = (op1 > op2) ? op1 : op2;       // maxu   [Zbb]
          7'b010_0000: res = op1 & ~op2;                    // andn   [Zbb]
          7'b000_0111: res = (op2 != '0) ? '0 : op1;        // czero.nez [Zicond]
          default:     res = op1 & op2;                     // AND
        endcase
      end

      default: res = 'd0;
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

    // P7: MulDiv stall/result injection.
    // muldiv_valid: unit is idle and we have a fresh muldiv instruction.
    // muldiv_stall: unit is still computing (cycles 1+).
    // Both suppress WB and stall decode; they are mutually exclusive.
    // muldiv_result_valid: computation done — inject result into WB.
    // (lsu_bp_i cannot be 1 simultaneously with muldiv_result_valid because
    //  result_valid_o is gated by ~freeze_i = ~lsu_bp_i inside muldiv_unit.)
    muldiv_valid = id_ex_i.is_muldiv && ~muldiv_stall && ~muldiv_result_valid
                  && ~load_use_hazard && ~lsu_bp_i && ~wrong_path;

    if (muldiv_valid || muldiv_stall) begin
      next_ex_mem_wb.we_rd = 1'b0;
      next_ex_mem_wb.lsu   = NO_LSU;
      id_ready_o           = 1'b0;
    end

    if (muldiv_result_valid) begin
      // id_ex_i still holds the muldiv instruction (decode was stalled)
      next_ex_mem_wb.result  = muldiv_result;
      next_ex_mem_wb.rd_addr = id_ex_i.rd_addr;
      next_ex_mem_wb.we_rd   = id_ex_i.we_rd;
      next_ex_mem_wb.lsu     = NO_LSU;
      // id_ready_o stays 1: release stall so decode advances this cycle
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

    // When recovering from a not-taken branch misprediction (branch was
    // predicted taken but actually not taken), the instruction currently in
    // execute arrived from the wrong speculative path.  We must squash its
    // branch/jump so it cannot register stale control-flow data into
    // branch_ff/jump_ff, which would fire a spurious fetch redirect next cycle.
    mispred_not_taken = branch_ff.b_act && ~branch_ff.take_branch &&
                        bp_taken_for_branch_ff;

    // Instruction currently in execute is on the wrong speculative path when:
    // Case 1: a taken branch/jump just resolved and BP did not correctly predict it
    // Case 2: BP predicted taken but branch is actually not-taken (mispred_not_taken)
    // Wrong-path STOREs must be suppressed to prevent memory corruption.
    wrong_path        = (jump_or_branch && ~correct_branch_pred && ~correct_jump_pred) ||
                        mispred_not_taken;

    next_branch.b_act   = id_ex_i.branch && ~lsu_bp_i && ~load_use_hazard &&
                          ~wrong_path;
    next_branch.b_addr  = id_ex_i.pc_dec + id_ex_i.imm;
    next_branch.take_branch  = no_jump_guard &&
                               branch_dec(branch_t'(id_ex_i.f3), op1, op2);

    next_jump.j_act  = no_jump_guard && id_ex_i.jump && ~lsu_bp_i &&
                       ~load_use_hazard && ~wrong_path;
    next_jump.j_addr = {res[31:1], 1'b0};

    // Track the instruction PC so the predictor update carries the right address.
    next_branch_pc = next_branch.b_act ? id_ex_i.pc_dec : branch_pc_ff;
    next_jump_pc   = next_jump.j_act   ? id_ex_i.pc_dec : jump_pc_ff;

    // Track BP state so execute can detect correct predictions and suppress
    // the redundant fetch_req_o / FIFO flush that would otherwise occur.
    next_bp_taken_for_branch       = next_branch.b_act ? id_ex_i.bp_taken         : bp_taken_for_branch_ff;
    next_bp_taken_for_jump         = next_jump.j_act   ? id_ex_i.bp_taken         : bp_taken_for_jump_ff;
    next_is_jal_for_jump           = next_jump.j_act   ? (id_ex_i.rs1_op == PC)   : is_jal_for_jump_ff;
    // P2: register addresses for call/return detection
    next_rd_addr_for_jump    = next_jump.j_act ? id_ex_i.rd_addr  : rd_addr_for_jump_ff;
    next_rs1_addr_for_jump   = next_jump.j_act ? id_ex_i.rs1_addr : rs1_addr_for_jump_ff;
    // Pre-register JALR address match: compare when the jump fires (non-critical
    // path from id_ex_ff), not combinationally from the registered jump_ff address.
    next_j_addr_matched_pred = next_jump.j_act ?
                               (next_jump.j_addr == id_ex_i.bp_predict_target) :
                               j_addr_matched_pred_ff;

    // fwd_wdata: forward the WB result to rs2 when STORE/AMO needs updated data
    // (LSU_AMO uses rs2 as the AMO operand — same forwarding need as STORE)
    fwd_wdata = (id_ex_i.lsu == LSU_STORE || id_ex_i.lsu == LSU_AMO) &&
                (ex_mem_wb_ff.we_rd) &&
                (ex_mem_wb_ff.rd_addr == id_ex_i.rs2_addr) &&
                (ex_mem_wb_ff.rd_addr != raddr_t'('h0));

    lsu_o.op_typ  = (load_use_hazard || wrong_path) ? NO_LSU : id_ex_i.lsu;
    lsu_o.width   = id_ex_i.lsu_w;
    lsu_o.addr    = res;
    lsu_o.wdata   = rs2_data_i;
    lsu_o.pc_addr = id_ex_i.pc_dec;
    lsu_o.amo_op  = id_ex_i.amo_op;
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

    // P2: RAS push on JAL call (rd=x1), pop on JALR return (rs1=x1)
    bp_is_call_o       = jump_ff.j_act &&  is_jal_for_jump_ff &&
                         (rd_addr_for_jump_ff  == raddr_t'(5'd1));
    bp_call_ret_addr_o = jump_pc_ff + 'd4;
    bp_is_return_o     = jump_ff.j_act && ~is_jal_for_jump_ff &&
                         (rs1_addr_for_jump_ff == raddr_t'(5'd1));
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
    end else if (next_jump.j_act && id_ex_i.bp_taken && (id_ex_i.rs1_op != PC) &&
                 (next_jump.j_addr == id_ex_i.bp_predict_target)) begin
      // Correctly-predicted JALR (BTB/RAS matched actual target)
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
      ex_mem_wb_ff                 <= `OP_RST_L;
      branch_ff                    <= s_branch_t'('h0);
      jump_ff                      <= s_jump_t'('h0);
      branch_pc_ff                 <= pc_t'('0);
      jump_pc_ff                   <= pc_t'('0);
      bp_taken_for_branch_ff       <= 1'b0;
      bp_taken_for_jump_ff         <= 1'b0;
      is_jal_for_jump_ff           <= 1'b0;
      j_addr_matched_pred_ff       <= 1'b0;
      rd_addr_for_jump_ff          <= raddr_t'('0);
      rs1_addr_for_jump_ff         <= raddr_t'('0);
    end
    else begin
      ex_mem_wb_ff                 <= next_ex_mem_wb;
      branch_ff                    <= next_branch;
      jump_ff                      <= next_jump;
      branch_pc_ff                 <= next_branch_pc;
      jump_pc_ff                   <= next_jump_pc;
      bp_taken_for_branch_ff       <= next_bp_taken_for_branch;
      bp_taken_for_jump_ff         <= next_bp_taken_for_jump;
      is_jal_for_jump_ff           <= next_is_jal_for_jump;
      j_addr_matched_pred_ff       <= next_j_addr_matched_pred;
      rd_addr_for_jump_ff          <= next_rd_addr_for_jump;
      rs1_addr_for_jump_ff         <= next_rs1_addr_for_jump;
    end
  end

`ifdef SIMULATION
  // ── Performance counters ──────────────────────────────────────────────
  // Printed in a `final` block at simulation end ($finish).
  //
  // Stall taxonomy (mutually exclusive priority for display, not hardware):
  //   lsu_bp_i        — AXI back-pressure (load/store/AMO waiting for memory)
  //   load_use_hazard — 1-cycle stall after load when next instr reads rd
  //   muldiv_stall    — multi-cycle stall inside the MulDiv unit
  //   fetch_bubble    — execute ready but decode has no valid instruction
  //                     (pipeline draining after redirect, or fetch latency)
  //
  // Redirect taxonomy (per-event counters):
  //   branch_mispredict — branch resolved taken-but-unpredicted OR
  //                       predicted-taken-but-not-taken
  //   jal_btb_miss      — JAL not in BTB (cold miss or capacity eviction)
  //   jalr_redirect     — JALR target not predicted (RAS miss or non-return)
  //
  // Prediction success (per-event counters):
  //   correct_branch    — branch resolved and prediction was correct
  //   correct_jal       — JAL resolved with correct BTB prediction
  //   correct_jalr      — JALR resolved with correct RAS/BTB prediction

  longint unsigned perf_cycles                    = 0;
  longint unsigned perf_instrs_issued             = 0; // instr enters execute (incl. wrong-path)
  longint unsigned perf_lsu_stall                 = 0; // AXI back-pressure cycles
  longint unsigned perf_load_use                  = 0; // load-use hazard cycles
  longint unsigned perf_muldiv_stall              = 0; // MulDiv unit stall cycles
  longint unsigned perf_fetch_bubble              = 0; // execute ready, decode empty
  // Branch misprediction breakdown:
  //   taken_miss    = branch was taken but BHT/BTB predicted not-taken
  //   not_taken_miss = branch was not taken but BHT predicted taken (BTB present)
  longint unsigned perf_branch_taken_miss         = 0;
  longint unsigned perf_branch_not_taken_miss     = 0;
  longint unsigned perf_jal_btb_miss              = 0; // JAL BTB miss events
  longint unsigned perf_jalr_redirect             = 0; // JALR redirect events
  longint unsigned perf_branch_taken              = 0; // resolved taken branches
  longint unsigned perf_branch_not_taken          = 0; // resolved not-taken branches
  longint unsigned perf_jal_total                 = 0; // all resolved JALs
  longint unsigned perf_jalr_total                = 0; // all resolved JALRs
  longint unsigned perf_correct_jal               = 0; // JAL correctly predicted (BTB hit)
  longint unsigned perf_correct_jalr              = 0; // JALR correctly predicted (RAS/BTB hit)

  always_ff @(posedge clk) begin
    if (rst) begin  // rst=1 = normal operation (active-low reset)
      perf_cycles <= perf_cycles + 1;

      // Instructions entering execute (decode advances)
      if (id_valid_i && id_ready_o)
        perf_instrs_issued <= perf_instrs_issued + 1;

      // Stall cycles — mutually exclusive priority: lsu_bp > load_use > muldiv
      if (lsu_bp_i)
        perf_lsu_stall    <= perf_lsu_stall    + 1;
      else if (load_use_hazard)
        perf_load_use     <= perf_load_use     + 1;
      else if (muldiv_stall)
        perf_muldiv_stall <= perf_muldiv_stall + 1;
      else if (id_ready_o && ~id_valid_i)
        perf_fetch_bubble <= perf_fetch_bubble + 1;

      // Branch events — split taken vs not-taken, and by mispredict type
      if (branch_ff.b_act) begin
        if (branch_ff.take_branch) begin
          perf_branch_taken <= perf_branch_taken + 1;
          // Taken but predicted not-taken (BTB miss or BHT counter < 2)
          if (~correct_branch_pred)
            perf_branch_taken_miss <= perf_branch_taken_miss + 1;
        end else begin
          perf_branch_not_taken <= perf_branch_not_taken + 1;
          // Not-taken but predicted taken (BHT counter >= 2 + BTB present)
          if (bp_taken_for_branch_ff)
            perf_branch_not_taken_miss <= perf_branch_not_taken_miss + 1;
        end
      end

      // Jump events
      if (jump_ff.j_act) begin
        if (is_jal_for_jump_ff) begin
          perf_jal_total <= perf_jal_total + 1;
          if (~correct_jump_pred)
            perf_jal_btb_miss  <= perf_jal_btb_miss  + 1;
          else
            perf_correct_jal   <= perf_correct_jal   + 1;
        end else begin
          perf_jalr_total <= perf_jalr_total + 1;
          if (~correct_jump_pred)
            perf_jalr_redirect <= perf_jalr_redirect + 1;
          else
            perf_correct_jalr  <= perf_correct_jalr  + 1;
        end
      end
    end
  end

  final begin
    // Derived quantities
    automatic longint unsigned branch_total =
        perf_branch_taken + perf_branch_not_taken;
    automatic longint unsigned branch_mispredict =
        perf_branch_taken_miss + perf_branch_not_taken_miss;
    automatic longint unsigned redirect_cyc =
        (branch_mispredict + perf_jal_btb_miss + perf_jalr_redirect) * 2;
    // True prediction accuracy: fraction of branches that did NOT cause a redirect
    automatic real branch_acc =
        (branch_total > 0)
            ? 100.0 * (branch_total - branch_mispredict) / branch_total : 0.0;
    // Taken-branch prediction rate: taken branches correctly predicted as taken
    automatic real taken_acc =
        (perf_branch_taken > 0)
            ? 100.0 * (perf_branch_taken - perf_branch_taken_miss) / perf_branch_taken : 0.0;
    automatic real jal_hit_rate =
        (perf_jal_total > 0)
            ? 100.0 * perf_correct_jal    / perf_jal_total    : 0.0;
    automatic real jalr_hit_rate =
        (perf_jalr_total > 0)
            ? 100.0 * perf_correct_jalr   / perf_jalr_total   : 0.0;
    automatic real ipc =
        (perf_cycles > 0)
            ? 1.0 * perf_instrs_issued / perf_cycles : 0.0;

    $display("");
    $display("[PERF] ================= Performance Counters =================");
    $display("[PERF]  Total cycles             : %0d", perf_cycles);
    $display("[PERF]  Instructions issued      : %0d  (IPC = %0.3f)",
             perf_instrs_issued, ipc);
    $display("[PERF] ----- Stall cycles (mutually exclusive) ---------------");
    $display("[PERF]  LSU back-pressure        : %0d  (%0.1f%%)",
             perf_lsu_stall,    100.0 * perf_lsu_stall    / perf_cycles);
    $display("[PERF]  Load-use hazard          : %0d  (%0.1f%%)",
             perf_load_use,     100.0 * perf_load_use     / perf_cycles);
    $display("[PERF]  MulDiv stall             : %0d  (%0.1f%%)",
             perf_muldiv_stall, 100.0 * perf_muldiv_stall / perf_cycles);
    $display("[PERF]  Fetch bubbles            : %0d  (%0.1f%%)",
             perf_fetch_bubble, 100.0 * perf_fetch_bubble / perf_cycles);
    $display("[PERF] ----- Branch mispredictions (~2 cyc penalty each) -----");
    $display("[PERF]  Taken, not predicted     : %0d  (BTB miss or BHT counter<2)",
             perf_branch_taken_miss);
    $display("[PERF]  Not-taken, predicted     : %0d  (BHT aliasing or slow decay)",
             perf_branch_not_taken_miss);
    $display("[PERF]  Total branch mispredict  : %0d  (~%0d cyc lost)",
             branch_mispredict, branch_mispredict * 2);
    $display("[PERF]  JAL BTB misses           : %0d  (~%0d cyc lost)",
             perf_jal_btb_miss, perf_jal_btb_miss * 2);
    $display("[PERF]  JALR redirects           : %0d  (~%0d cyc lost)",
             perf_jalr_redirect, perf_jalr_redirect * 2);
    $display("[PERF]  Total redirect est.      : ~%0d cyc  (%0.1f%%)",
             redirect_cyc, 100.0 * redirect_cyc / perf_cycles);
    $display("[PERF] ----- Prediction accuracy ------------------------------------");
    $display("[PERF]  Branch true accuracy     : %0d/%0d  (%0.1f%%)",
             branch_total - branch_mispredict, branch_total, branch_acc);
    $display("[PERF]  Branch taken accuracy    : %0d/%0d  (%0.1f%%)",
             perf_branch_taken - perf_branch_taken_miss, perf_branch_taken, taken_acc);
    $display("[PERF]    (taken %0d / not-taken %0d = %0.0f%%/%0.0f%% of all branches)",
             perf_branch_taken, perf_branch_not_taken,
             100.0*perf_branch_taken/branch_total, 100.0*perf_branch_not_taken/branch_total);
    $display("[PERF]  JAL BTB hit rate         : %0d/%0d  (%0.1f%%)",
             perf_correct_jal,    perf_jal_total,    jal_hit_rate);
    $display("[PERF]  JALR RAS/BTB hit rate    : %0d/%0d  (%0.1f%%)",
             perf_correct_jalr,   perf_jalr_total,   jalr_hit_rate);
    $display("[PERF] ==========================================================");
  end
`endif

  // P7: MulDiv unit
  // freeze_i = lsu_bp_i pauses the divider counter while AXI is stalled.
  muldiv_unit u_muldiv (
    .clk            (clk),
    .rst            (rst),
    .valid_i        (muldiv_valid),
    .freeze_i       (lsu_bp_i),
    .op_i           (id_ex_i.f3),
    .a_i            (op1),
    .b_i            (op2),
    .stall_o        (muldiv_stall),
    .result_valid_o (muldiv_result_valid),
    .result_o       (muldiv_result)
  );

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
