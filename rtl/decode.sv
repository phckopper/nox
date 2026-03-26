/**
 * File              : decode.sv
 * License           : MIT license <Check LICENSE>
 * Author            : Anderson Ignacio da Silva (aignacio) <anderson@aignacio.com>
 * Date              : 28.10.2021
 * Last Modified Date: 01.07.2022
 */
module decode
  import amba_axi_pkg::*;
  import amba_ahb_pkg::*;
  import nox_utils_pkg::*;
#(
  parameter int SUPPORT_DEBUG = 1
)(
  input                 clk,
  input                 rst,
  // Control signals
  input                 jump_i,
  input   pc_t          pc_reset_i,
  input   pc_t          pc_jump_i,
  // From FETCH stg I/F
  input   valid_t       fetch_valid_i,
  output  ready_t       fetch_ready_o,
  input   instr_raw_t   fetch_instr_i,
  input   logic         fetch_bp_taken_i,          // BP predicted this instruction taken
  input   pc_t          fetch_bp_predict_target_i, // P2: BP predicted target address
  // From MEM/WB stg I/F
  input   s_wb_t        wb_dec_i,
  // To EXEC stg I/F
  output  s_id_ex_t     id_ex_o,
  output  rdata_t       rs1_data_o,
  output  rdata_t       rs2_data_o,
  output  valid_t       id_valid_o,
  input   ready_t       id_ready_i,
  // PC tracking update from execute on correct prediction (no pipeline flush)
  input                 decode_pc_update_i,
  input   pc_t          decode_pc_update_addr_i
);
  valid_t     dec_valid_ff, next_vld_dec;
  s_instr_t   instr_dec;
  logic       wait_inst_ff, next_wait_inst;
  logic       wfi_stop_ff, next_wfi_stop;
  s_id_ex_t   id_ex_ff, next_id_ex;

  always_comb begin
    next_vld_dec  = dec_valid_ff;
    fetch_ready_o = id_ready_i && ~wfi_stop_ff;
    id_valid_o = dec_valid_ff;
    if (~id_valid_o || (id_valid_o && id_ready_i)) begin
      next_vld_dec = fetch_valid_i;
    end
    else if (id_valid_o && ~id_ready_i) begin
      next_vld_dec = 'b1;
    end
  end

  always_comb begin
    if (jump_i) begin
      // ...Insert a NOP
      id_ex_o = s_id_ex_t'('0);
      id_ex_o.pc_dec = id_ex_ff.pc_dec;
    end
    else if (wfi_stop_ff) begin
      // ...Insert a WFI
      id_ex_o = s_id_ex_t'('0);
      id_ex_o.pc_dec = id_ex_ff.pc_dec;
      id_ex_o.wfi    = 'b1;
    end
    else begin
      id_ex_o = id_ex_ff;
    end
  end

  always_comb begin : dec_op
    instr_dec   = fetch_instr_i;

    // Defaults
    next_id_ex          = s_id_ex_t'('0);
    next_id_ex.trap     = s_trap_info_t'('0);
    next_id_ex.rd_addr  = instr_dec.rd;
    next_id_ex.rs1_addr = instr_dec.rs1;
    next_id_ex.rs2_addr = instr_dec.rs2;

    case(instr_dec.op)
      RV_OP_IMM: begin
        next_id_ex.f3     = instr_dec.f3;
        next_id_ex.rs1_op = REG_RF;
        next_id_ex.rs2_op = IMM;
        next_id_ex.imm    = gen_imm(fetch_instr_i, I_IMM);
        next_id_ex.rshift = instr_dec[30] ? RV_SRA : RV_SRL;
        next_id_ex.we_rd  = 1'b1;
        // Only propagate funct7_raw for shift instructions (funct3=001 SLL, funct3=101 SRL/SRA).
        // For ADDI/SLTI/XORI/ORI/ANDI the upper immediate bits must NOT trigger
        // extension dispatch in execute (their imm[11:5] could alias extension encodings).
        // sext.b/sext.h are OP_IMM+SLL with funct7=0110000 — captured here correctly.
        if (instr_dec.f3 == RV_F3_SLL || instr_dec.f3 == RV_F3_SRL_SRA)
          next_id_ex.funct7_raw = fetch_instr_i[31:25];
      end
      RV_LUI: begin
        next_id_ex.f3     = RV_F3_ADD_SUB;
        next_id_ex.rs1_op = ZERO;
        next_id_ex.rs2_op = IMM;
        next_id_ex.imm    = gen_imm(fetch_instr_i, U_IMM);
        next_id_ex.we_rd  = 1'b1;
      end
      RV_AUIPC: begin
        next_id_ex.f3     = RV_F3_ADD_SUB;
        next_id_ex.rs1_op = PC;
        next_id_ex.rs2_op = IMM;
        next_id_ex.imm    = gen_imm(fetch_instr_i, U_IMM);
        next_id_ex.we_rd  = 1'b1;
      end
      RV_OP: begin
        next_id_ex.f3         = instr_dec.f3;
        next_id_ex.funct7_raw = fetch_instr_i[31:25];
        next_id_ex.rs1_op     = REG_RF;
        next_id_ex.rs2_op     = REG_RF;
        next_id_ex.we_rd      = 1'b1;
        case (fetch_instr_i[31:25])
          7'b000_0001: begin                         // P7: RV32M (funct7=0000001)
            next_id_ex.is_muldiv = 1'b1;
          end
          7'b010_0000: begin                         // SUB/SRA (base I) + Zbb andn/orn/xnor
            next_id_ex.f7     = RV_F7_1;
            next_id_ex.rshift = RV_SRA;
          end
          // Zba (0010000), Zbb min/max (0000101), Zbb zext.h (0000100),
          // Zicond (0000111): funct7_raw already captured; execute handles dispatch
          default: begin                             // funct7=0000000: ADD/SLT/SLL/XOR/OR/AND/SRL
            next_id_ex.f7     = RV_F7_0;
            next_id_ex.rshift = RV_SRL;
          end
        endcase
      end
      // RV64I: OP-IMM-32 — ADDIW, SLLIW, SRLIW, SRAIW (32-bit immediate ops)
      RV_OP_IMM_32: begin
        next_id_ex.f3        = instr_dec.f3;
        next_id_ex.rs1_op    = REG_RF;
        next_id_ex.rs2_op    = IMM;
        next_id_ex.imm       = gen_imm(fetch_instr_i, I_IMM);
        next_id_ex.rshift    = instr_dec[30] ? RV_SRA : RV_SRL;
        next_id_ex.we_rd     = 1'b1;
        next_id_ex.is_word_op = 1'b1;
        if (instr_dec.f3 == RV_F3_SLL || instr_dec.f3 == RV_F3_SRL_SRA)
          next_id_ex.funct7_raw = fetch_instr_i[31:25];
      end
      // RV64I: OP-32 — ADDW, SUBW, SLLW, SRLW, SRAW + RV64M MULW/DIVW/REMW
      RV_OP_32: begin
        next_id_ex.f3         = instr_dec.f3;
        next_id_ex.funct7_raw = fetch_instr_i[31:25];
        next_id_ex.rs1_op     = REG_RF;
        next_id_ex.rs2_op     = REG_RF;
        next_id_ex.we_rd      = 1'b1;
        next_id_ex.is_word_op = 1'b1;
        case (fetch_instr_i[31:25])
          7'b000_0001: begin                         // RV64M: MULW/DIVW/DIVUW/REMW/REMUW
            next_id_ex.is_muldiv = 1'b1;
          end
          7'b010_0000: begin                         // SUBW/SRAW
            next_id_ex.f7     = RV_F7_1;
            next_id_ex.rshift = RV_SRA;
          end
          default: begin                             // ADDW/SLLW/SRLW
            next_id_ex.f7     = RV_F7_0;
            next_id_ex.rshift = RV_SRL;
          end
        endcase
      end
      RV_JAL: begin
        next_id_ex.jump   = 1'b1;
        next_id_ex.f3     = RV_F3_ADD_SUB;
        next_id_ex.rs1_op = PC;
        next_id_ex.rs2_op = IMM;
        next_id_ex.imm    = gen_imm(fetch_instr_i, J_IMM);
        next_id_ex.we_rd  = 1'b1;
      end
      RV_JALR: begin
        next_id_ex.jump   = 1'b1;
        next_id_ex.f3     = RV_F3_ADD_SUB;
        next_id_ex.rs1_op = REG_RF;
        next_id_ex.rs2_op = IMM;
        next_id_ex.imm    = gen_imm(fetch_instr_i, I_IMM);
        next_id_ex.we_rd  = 1'b1;
      end
      RV_BRANCH: begin
        next_id_ex.branch = 1'b1;
        next_id_ex.f3     = instr_dec.f3;
        next_id_ex.rs1_op = REG_RF;
        next_id_ex.rs2_op = REG_RF;
        next_id_ex.imm    = gen_imm(fetch_instr_i, B_IMM);
      end
      RV_LOAD: begin
        next_id_ex.lsu    = LSU_LOAD;
        next_id_ex.f3     = RV_F3_ADD_SUB;
        next_id_ex.rs1_op = REG_RF;
        next_id_ex.rs2_op = IMM;
        next_id_ex.we_rd  = 1'b1;
        next_id_ex.lsu_w  = lsu_w_t'(instr_dec.f3);
        next_id_ex.imm    = gen_imm(fetch_instr_i, I_IMM);
      end
      RV_STORE: begin
        next_id_ex.lsu     = LSU_STORE;
        next_id_ex.f3      = RV_F3_ADD_SUB;
        next_id_ex.rs1_op  = REG_RF;
        next_id_ex.rs2_op  = IMM;
        next_id_ex.lsu_w   = lsu_w_t'(instr_dec.f3);
        next_id_ex.imm     = gen_imm(fetch_instr_i, S_IMM);
      end
      // P11: RV32A — LR.W, SC.W, and AMO*
      // All use R-type format: rd=dest, rs1=address (no offset), rs2=source operand.
      // LR.W is decoded as LSU_LOAD (normal load path) with amo_op=AMO_LR so the
      // LSU can set the reservation register on completion.
      // SC.W and AMO* are decoded as LSU_AMO and handled by the LSU state machine.
      RV_ATOMIC: begin
        next_id_ex.f3     = RV_F3_ADD_SUB;  // addr = rs1 + 0
        next_id_ex.rs1_op = REG_RF;          // op1 = rs1 (base address)
        next_id_ex.rs2_op = ZERO;            // op2 = 0 (no offset; rs2 is AMO operand)
        next_id_ex.lsu_w  = RV_LSU_W;        // RV32A: always word
        next_id_ex.we_rd  = 1'b1;
        next_id_ex.amo_op = amo_op_t'(fetch_instr_i[31:27]);
        if (fetch_instr_i[31:27] == 5'b00010) begin
          // LR.W: load with reservation — use normal LOAD path + amo_op tag
          next_id_ex.lsu = LSU_LOAD;
        end else begin
          // SC.W and all AMO*: handled by LSU state machine
          next_id_ex.lsu = LSU_AMO;
        end
      end
      RV_MISC_MEM: begin
        next_id_ex.f3     = RV_F3_ADD_SUB;
        next_id_ex.rs1_op = ZERO;
        next_id_ex.rs2_op = ZERO;
      end
      RV_SYSTEM: begin
        next_id_ex.f3         = RV_F3_ADD_SUB;
        next_id_ex.rs1_op     = ZERO;
        next_id_ex.rs2_op     = ZERO;
        next_id_ex.imm        = gen_imm(fetch_instr_i, CSR_IMM);
        if ((instr_dec.f3 != RV_F3_ADD_SUB) && (instr_dec.f3 != RV_F3_XOR)) begin
          next_id_ex.rs1_op   = REG_RF;
          next_id_ex.csr.op   = csr_t'(instr_dec.f3);
          next_id_ex.csr.addr = instr_dec[31:20];
          // When rd != x0
          next_id_ex.csr.rs1_is_x0 = (instr_dec.rs1 == 'h0) ? 'b1 : 'b0;
          if (instr_dec.rd != 'h0) begin
            next_id_ex.we_rd  = 1'b1;
          end
        end
        else if ((instr_dec.f3 == RV_F3_ADD_SUB) &&
                 (instr_dec.rd == 'h0) &&
                 (instr_dec.rs1 == 'h0)) begin
          case (1)
            (instr_dec.rs2 == 'h0): begin
                next_id_ex.ecall = 'b1;
            end
            (instr_dec.rs2 == 'h1): begin
              next_id_ex.ebreak = 'b1;
            end
            ((instr_dec.rs2 == 'h2) && (instr_dec.f7 == 'h18)): begin
              next_id_ex.mret = 'b1;
            end
            ((instr_dec.rs2 == 'h5) && (instr_dec.f7 == 'h8)): begin
              next_id_ex.wfi = 'b1;
            end
            default: begin
              if (fetch_valid_i && id_ready_i) begin
                next_id_ex.trap.active  = 1'b1;
                next_id_ex.trap.mtval   = {32'b0, fetch_instr_i};
                `P_MSG ("DEC", "Instruction non-supported")
              end
            end
          endcase
        end
        else begin
          if (fetch_valid_i && id_ready_i) begin
            next_id_ex.trap.active  = 1'b1;
            next_id_ex.trap.mtval   = {32'b0, fetch_instr_i};
            `P_MSG ("DEC", "Instruction non-supported")
          end
        end
      end
      default: begin
        if (fetch_valid_i && id_ready_i) begin
          next_id_ex.trap.active  = 1'b1;
          next_id_ex.trap.mtval   = {32'b0, fetch_instr_i};
          `P_MSG ("DEC", "Instruction non-supported")
        end
      end
    endcase

    if (fetch_valid_i && id_ready_i && wait_inst_ff && ~wfi_stop_ff) begin
      next_id_ex.pc_dec  = id_ex_ff.pc_dec + 'd4;
    end
    else begin
      next_id_ex.pc_dec  = id_ex_ff.pc_dec;
    end

    if (jump_i) begin
      next_id_ex.pc_dec  = pc_jump_i;
    end

    // When execute correctly predicted a JAL/taken-branch and suppressed
    // fetch_req_o, jump_i stays 0 and pc_dec would otherwise increment by 4
    // from the jump's PC instead of the actual target.  Use the dedicated
    // update signal to fix up pc_dec without flushing the pipeline.
    //
    // When execute correctly predicted a JAL/taken-branch and suppressed
    // fetch_req_o, jump_i stays 0 and pc_dec would otherwise increment by 4
    // from the jump's PC instead of the actual target.  Use the dedicated
    // update signal to fix up pc_dec without flushing the pipeline.
    //
    // There are three cases:
    //  a) An instruction is being consumed this cycle (fetch_valid_i && id_ready_i):
    //     set pc_dec = TARGET directly so the instruction gets the right PC.
    //  b) wait_inst_ff=0 (after a misprediction redirect): the +4 increment does
    //     NOT fire when the next instruction arrives, so set TARGET directly.
    //  c) FIFO empty, wait_inst_ff=1: +4 WILL fire on next arrival → set T-4.
    //     (When id_ready_i=0 the stall override below discards this anyway.)
    if (decode_pc_update_i && ~jump_i) begin
      if ((fetch_valid_i && id_ready_i) || ~wait_inst_ff) begin
        next_id_ex.pc_dec = decode_pc_update_addr_i;
      end else begin
        next_id_ex.pc_dec = decode_pc_update_addr_i - 'd4;
      end
    end

    next_id_ex.trap.pc_addr = next_id_ex.pc_dec;

    next_wait_inst = wait_inst_ff;
    if (~wait_inst_ff) begin
      next_wait_inst = (fetch_valid_i && id_ready_i);
    end
    else if (jump_i) begin
      next_wait_inst = 'b0;
    end

    // If we have a WFI, first we insert a NOP
    // to avoid any pending operations when
    // WFI reaches execute stage
    next_wfi_stop = wfi_stop_ff;
    if (wfi_stop_ff == 'b0) begin
      if (fetch_valid_i && next_id_ex.wfi && id_ready_i) begin
        next_wfi_stop = 'b1;
      end
    end

    if (wfi_stop_ff) begin
      if (jump_i) begin
        next_wfi_stop = 'b0;
      end
    end

    // Propagate branch-predictor tag alongside the decoded instruction.
    // Only set when there is a valid instruction being consumed.
    next_id_ex.bp_taken          = fetch_bp_taken_i;
    next_id_ex.bp_predict_target = fetch_bp_predict_target_i;

    // We are stalling due to bp on the LSU
    if (~id_ready_i) begin
      next_id_ex = id_ex_ff;
    end
  end : dec_op

  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      dec_valid_ff    <= 'b0;
      id_ex_ff        <= `OP_RST_L;
      id_ex_ff.pc_dec <= pc_reset_i;
      wait_inst_ff    <= 'b0;
      wfi_stop_ff     <= 'b0;
    end
    else begin
      dec_valid_ff    <= next_vld_dec;
      id_ex_ff        <= next_id_ex;
      wait_inst_ff    <= next_wait_inst;
      wfi_stop_ff     <= next_wfi_stop;
    end
  end

  register_file u_register_file(
    .clk       (clk),
    .rst       (rst),
    // During a load-use stall (id_ready_i=0), the FIFO is not consumed so
    // instr_dec points to the NEXT instruction, not the stalled one.
    // The write-through comparison must use the stalled instruction's register
    // addresses (from id_ex_ff) so WB's loaded value reaches rs1_ff/rs2_ff.
    .rs1_addr_i(id_ready_i ? raddr_t'(instr_dec.rs1) : id_ex_ff.rs1_addr),
    .rs2_addr_i(id_ready_i ? raddr_t'(instr_dec.rs2) : id_ex_ff.rs2_addr),
    .rd_addr_i (wb_dec_i.rd_addr),
    .rd_data_i (wb_dec_i.rd_data),
    .we_i      (wb_dec_i.we_rd),
    .re_i      (id_ready_i),
    .rs1_data_o(rs1_data_o),
    .rs2_data_o(rs2_data_o)
  );

  // *SIMULATION ONLY*
  // - Additional logic to log retired instructions from the core
`ifdef SIMULATION
  instr_raw_t instr_retired_ff, next_instr;
  logic will_be_executed;

  always_comb begin
    will_be_executed = 'b0;
    next_instr = instr_retired_ff;

    if (id_ready_i) begin
      next_instr = instr_dec;
    end

    if (id_valid_o && ~jump_i && ~wfi_stop_ff && id_ready_i) begin
      will_be_executed = 'b1;
    end
  end

  integer j;
  initial begin
      j = 0;
  end

  always_ff @ (posedge clk) begin
    if (will_be_executed) begin
      j++;
      if (j % 10000000 == 0)
        $display("[HEARTBEAT] %0d instructions retired, last pc=%08h", j, id_ex_ff.pc_dec);
    end
  end

  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      instr_retired_ff <= '0;
    end
    else begin
      instr_retired_ff <= next_instr;
    end
  end
`endif
`ifdef COCOTB_SIM
  `ifdef XCELIUM
    `DUMP_WAVES_XCELIUM
  `endif
`endif
endmodule
