/**
 * File              : rvc_expander.sv
 * License           : MIT license <Check LICENSE>
 * Author            : NoX v2 — RV64C compressed instruction expander
 * Date              : 26.03.2026
 *
 * Pure combinational module that expands 16-bit RV64C compressed instructions
 * into their 32-bit canonical RV64I/M equivalents.  Covers all Quadrant 0/1/2
 * instructions defined by the RISC-V C extension for RV64.
 *
 * F/D floating-point compressed instructions (C.FLD, C.FSD, C.FLDSP, C.FSDSP)
 * are decoded as illegal since the FPU is not yet implemented.
 */
module rvc_expander (
  input  logic [15:0] instr_i,      // 16-bit compressed instruction
  output logic [31:0] instr_o,      // 32-bit expanded instruction
  output logic        illegal_o     // 1 = illegal / unsupported compressed encoding
);

  // Compressed register addresses: 3-bit field maps to x8–x15
  function automatic logic [4:0] cr(logic [2:0] c);
    return {2'b01, c};
  endfunction

  logic [15:0] c;
  assign c = instr_i;

  // Bit-field aliases
  logic [2:0]  funct3;
  logic [4:0]  rd_rs1;    // bits [11:7] — full 5-bit register in Q2
  logic [4:0]  rs2_full;  // bits [6:2]  — full 5-bit register in Q2
  logic [2:0]  rd_c;      // bits [4:2]  — compressed rd' (Q0/Q1)
  logic [2:0]  rs1_c;     // bits [9:7]  — compressed rs1' (Q0/Q1)
  logic [2:0]  rs2_c;     // bits [4:2]  — compressed rs2' (Q0/Q1)

  assign funct3  = c[15:13];
  assign rd_rs1  = c[11:7];
  assign rs2_full = c[6:2];
  assign rd_c    = c[4:2];
  assign rs1_c   = c[9:7];
  assign rs2_c   = c[4:2];

  /* verilator lint_off UNUSEDSIGNAL */
  always_comb begin
    instr_o   = 32'h0;
    illegal_o = 1'b0;

    case (c[1:0])
      // ================================================================
      // Quadrant 0
      // ================================================================
      2'b00: begin
        case (funct3)
          3'b000: begin
            // C.ADDI4SPN: addi rd', x2, nzuimm
            // nzuimm[5:4|9:6|2|3] = c[12:5]
            logic [9:0] nzuimm;
            nzuimm = {c[10:7], c[12:11], c[5], c[6], 2'b00};
            if (nzuimm == 10'b0)
              illegal_o = 1'b1;  // nzuimm=0 is reserved
            else
              // addi rd', x2, nzuimm
              instr_o = {2'b0, nzuimm, 5'd2, 3'b000, cr(rd_c), 7'b0010011};
          end

          3'b001: begin
            // C.FLD — illegal (no FPU)
            illegal_o = 1'b1;
          end

          3'b010: begin
            // C.LW: lw rd', offset(rs1')
            // offset[5:3|2|6] = c[12:10,6,5]
            logic [6:0] off_lw;
            off_lw = {c[5], c[12:10], c[6], 2'b00};
            // lw rd', off(rs1')
            instr_o = {5'b0, off_lw, cr(rs1_c), 3'b010, cr(rd_c), 7'b0000011};
          end

          3'b011: begin
            // C.LD: ld rd', offset(rs1')  (RV64 only)
            // offset[5:3|7:6] = c[12:10,6,5]
            logic [7:0] off_ld;
            off_ld = {c[6:5], c[12:10], 3'b000};
            // ld rd', off(rs1')
            instr_o = {4'b0, off_ld, cr(rs1_c), 3'b011, cr(rd_c), 7'b0000011};
          end

          3'b100: begin
            // Reserved
            illegal_o = 1'b1;
          end

          3'b101: begin
            // C.FSD — illegal (no FPU)
            illegal_o = 1'b1;
          end

          3'b110: begin
            // C.SW: sw rs2', offset(rs1')
            // offset[5:3|2|6] = c[12:10,6,5]
            logic [6:0] off_sw;
            off_sw = {c[5], c[12:10], c[6], 2'b00};
            // sw rs2', off(rs1')
            instr_o = {5'b0, off_sw[6:5], cr(rs2_c), cr(rs1_c), 3'b010, off_sw[4:0], 7'b0100011};
          end

          3'b111: begin
            // C.SD: sd rs2', offset(rs1')  (RV64 only)
            // offset[5:3|7:6] = c[12:10,6,5]
            logic [7:0] off_sd;
            off_sd = {c[6:5], c[12:10], 3'b000};
            // sd rs2', off(rs1')
            instr_o = {4'b0, off_sd[7:5], cr(rs2_c), cr(rs1_c), 3'b011, off_sd[4:0], 7'b0100011};
          end
        endcase
      end

      // ================================================================
      // Quadrant 1
      // ================================================================
      2'b01: begin
        case (funct3)
          3'b000: begin
            // C.NOP (rd=0) / C.ADDI: addi rd, rd, nzimm
            // nzimm[5] = c[12], nzimm[4:0] = c[6:2]
            logic [5:0] nzimm;
            nzimm = {c[12], c[6:2]};
            // addi rd, rd, sext(nzimm)
            instr_o = {{6{nzimm[5]}}, nzimm, rd_rs1, 3'b000, rd_rs1, 7'b0010011};
          end

          3'b001: begin
            // C.ADDIW: addiw rd, rd, imm  (RV64; was C.JAL in RV32)
            logic [5:0] imm_w;
            imm_w = {c[12], c[6:2]};
            if (rd_rs1 == 5'b0)
              illegal_o = 1'b1;  // rd=0 is reserved for C.ADDIW
            else
              // addiw rd, rd, sext(imm)
              instr_o = {{6{imm_w[5]}}, imm_w, rd_rs1, 3'b000, rd_rs1, 7'b0011011};
          end

          3'b010: begin
            // C.LI: addi rd, x0, imm
            logic [5:0] imm_li;
            imm_li = {c[12], c[6:2]};
            instr_o = {{6{imm_li[5]}}, imm_li, 5'd0, 3'b000, rd_rs1, 7'b0010011};
          end

          3'b011: begin
            if (rd_rs1 == 5'd2) begin
              // C.ADDI16SP: addi x2, x2, nzimm
              // nzimm[9] = c[12], nzimm[4|6|8:7|5] = c[6:2]
              logic [9:0] nzimm16;
              nzimm16 = {c[12], c[4:3], c[5], c[2], c[6], 4'b0000};
              if (nzimm16 == 10'b0)
                illegal_o = 1'b1;  // nzimm=0 is reserved
              else
                // addi x2, x2, sext(nzimm)
                instr_o = {{2{nzimm16[9]}}, nzimm16, 5'd2, 3'b000, 5'd2, 7'b0010011};
            end else begin
              // C.LUI: lui rd, nzimm
              // nzimm[17] = c[12], nzimm[16:12] = c[6:2]
              logic [5:0] nzimm_lui;
              nzimm_lui = {c[12], c[6:2]};
              if (nzimm_lui == 6'b0 || rd_rs1 == 5'b0)
                illegal_o = 1'b1;  // nzimm=0 or rd=0 is reserved
              else
                // lui rd, sext(nzimm[17:12])
                instr_o = {{14{nzimm_lui[5]}}, nzimm_lui, rd_rs1, 7'b0110111};
            end
          end

          3'b100: begin
            // ALU group
            case (c[11:10])
              2'b00: begin
                // C.SRLI: srli rd', rd', shamt
                // shamt[5] = c[12], shamt[4:0] = c[6:2]
                logic [5:0] shamt_srli;
                shamt_srli = {c[12], c[6:2]};
                // srli rd', rd', shamt (RV64: 6-bit shamt OK)
                instr_o = {6'b000000, shamt_srli, cr(rs1_c), 3'b101, cr(rs1_c), 7'b0010011};
              end

              2'b01: begin
                // C.SRAI: srai rd', rd', shamt
                logic [5:0] shamt_srai;
                shamt_srai = {c[12], c[6:2]};
                // srai rd', rd', shamt
                instr_o = {6'b010000, shamt_srai, cr(rs1_c), 3'b101, cr(rs1_c), 7'b0010011};
              end

              2'b10: begin
                // C.ANDI: andi rd', rd', imm
                logic [5:0] imm_andi;
                imm_andi = {c[12], c[6:2]};
                // andi rd', rd', sext(imm)
                instr_o = {{6{imm_andi[5]}}, imm_andi, cr(rs1_c), 3'b111, cr(rs1_c), 7'b0010011};
              end

              2'b11: begin
                case ({c[12], c[6:5]})
                  3'b000: begin
                    // C.SUB: sub rd', rd', rs2'
                    instr_o = {7'b0100000, cr(rs2_c), cr(rs1_c), 3'b000, cr(rs1_c), 7'b0110011};
                  end
                  3'b001: begin
                    // C.XOR: xor rd', rd', rs2'
                    instr_o = {7'b0000000, cr(rs2_c), cr(rs1_c), 3'b100, cr(rs1_c), 7'b0110011};
                  end
                  3'b010: begin
                    // C.OR: or rd', rd', rs2'
                    instr_o = {7'b0000000, cr(rs2_c), cr(rs1_c), 3'b110, cr(rs1_c), 7'b0110011};
                  end
                  3'b011: begin
                    // C.AND: and rd', rd', rs2'
                    instr_o = {7'b0000000, cr(rs2_c), cr(rs1_c), 3'b111, cr(rs1_c), 7'b0110011};
                  end
                  3'b100: begin
                    // C.SUBW: subw rd', rd', rs2'  (RV64)
                    instr_o = {7'b0100000, cr(rs2_c), cr(rs1_c), 3'b000, cr(rs1_c), 7'b0111011};
                  end
                  3'b101: begin
                    // C.ADDW: addw rd', rd', rs2'  (RV64)
                    instr_o = {7'b0000000, cr(rs2_c), cr(rs1_c), 3'b000, cr(rs1_c), 7'b0111011};
                  end
                  default: begin
                    // Reserved
                    illegal_o = 1'b1;
                  end
                endcase
              end
            endcase
          end

          3'b101: begin
            // C.J: jal x0, offset
            // offset[11|4|9:8|10|6|7|3:1|5] = c[12:2]
            logic [11:0] off_j;
            off_j = {c[12], c[8], c[10:9], c[6], c[7], c[2], c[11], c[5:3], 1'b0};
            // jal x0, sext(offset)
            instr_o = {off_j[11], off_j[10:1], off_j[11], {8{off_j[11]}}, 5'd0, 7'b1101111};
          end

          3'b110: begin
            // C.BEQZ: beq rs1', x0, offset
            // offset[8|4:3|7:6|2:1|5] = c[12:10,6:2]
            logic [8:0] off_beq;
            off_beq = {c[12], c[6:5], c[2], c[11:10], c[4:3], 1'b0};
            // beq rs1', x0, sext(offset)
            // BEQ: {imm[12],imm[10:5]} | rs2 | rs1 | f3 | {imm[4:1],imm[11]} | opcode
            // Sign-extend 9-bit offset to 13-bit: imm[12:9] = {4{off[8]}}
            instr_o = {{4{off_beq[8]}}, off_beq[7:5], 5'd0, cr(rs1_c), 3'b000, off_beq[4:1], off_beq[8], 7'b1100011};
          end

          3'b111: begin
            // C.BNEZ: bne rs1', x0, offset
            // offset[8|4:3|7:6|2:1|5] = c[12:10,6:2]
            logic [8:0] off_bne;
            off_bne = {c[12], c[6:5], c[2], c[11:10], c[4:3], 1'b0};
            // bne rs1', x0, sext(offset)
            // BNE: {imm[12],imm[10:5]} | rs2 | rs1 | f3 | {imm[4:1],imm[11]} | opcode
            instr_o = {{4{off_bne[8]}}, off_bne[7:5], 5'd0, cr(rs1_c), 3'b001, off_bne[4:1], off_bne[8], 7'b1100011};
          end
        endcase
      end

      // ================================================================
      // Quadrant 2
      // ================================================================
      2'b10: begin
        case (funct3)
          3'b000: begin
            // C.SLLI: slli rd, rd, shamt
            logic [5:0] shamt_slli;
            shamt_slli = {c[12], c[6:2]};
            if (rd_rs1 == 5'b0)
              illegal_o = 1'b1;  // rd=0 reserved (HINT)
            else
              // slli rd, rd, shamt
              instr_o = {6'b000000, shamt_slli, rd_rs1, 3'b001, rd_rs1, 7'b0010011};
          end

          3'b001: begin
            // C.FLDSP — illegal (no FPU)
            illegal_o = 1'b1;
          end

          3'b010: begin
            // C.LWSP: lw rd, offset(x2)
            // offset[5] = c[12], offset[4:2|7:6] = c[6:2]
            logic [7:0] off_lwsp;
            off_lwsp = {c[3:2], c[12], c[6:4], 2'b00};
            if (rd_rs1 == 5'b0)
              illegal_o = 1'b1;  // rd=0 reserved
            else
              // lw rd, off(x2)
              instr_o = {4'b0, off_lwsp, 5'd2, 3'b010, rd_rs1, 7'b0000011};
          end

          3'b011: begin
            // C.LDSP: ld rd, offset(x2)  (RV64)
            // offset[5] = c[12], offset[4:3|8:6] = c[6:2]
            logic [8:0] off_ldsp;
            off_ldsp = {c[4:2], c[12], c[6:5], 3'b000};
            if (rd_rs1 == 5'b0)
              illegal_o = 1'b1;  // rd=0 reserved
            else
              // ld rd, off(x2)
              instr_o = {3'b0, off_ldsp, 5'd2, 3'b011, rd_rs1, 7'b0000011};
          end

          3'b100: begin
            if (c[12] == 1'b0) begin
              if (rs2_full == 5'b0) begin
                // C.JR: jalr x0, 0(rs1)
                if (rd_rs1 == 5'b0)
                  illegal_o = 1'b1;  // reserved
                else
                  instr_o = {12'b0, rd_rs1, 3'b000, 5'd0, 7'b1100111};
              end else begin
                // C.MV: add rd, x0, rs2
                instr_o = {7'b0000000, rs2_full, 5'd0, 3'b000, rd_rs1, 7'b0110011};
              end
            end else begin
              if (rs2_full == 5'b0) begin
                if (rd_rs1 == 5'b0) begin
                  // C.EBREAK: ebreak
                  instr_o = 32'h00100073;
                end else begin
                  // C.JALR: jalr x1, 0(rs1)
                  instr_o = {12'b0, rd_rs1, 3'b000, 5'd1, 7'b1100111};
                end
              end else begin
                // C.ADD: add rd, rd, rs2
                instr_o = {7'b0000000, rs2_full, rd_rs1, 3'b000, rd_rs1, 7'b0110011};
              end
            end
          end

          3'b101: begin
            // C.FSDSP — illegal (no FPU)
            illegal_o = 1'b1;
          end

          3'b110: begin
            // C.SWSP: sw rs2, offset(x2)
            // offset[5:2|7:6] = c[12:7]
            logic [7:0] off_swsp;
            off_swsp = {c[8:7], c[12:9], 2'b00};
            // sw rs2, off(x2)
            instr_o = {4'b0, off_swsp[7:5], rs2_full, 5'd2, 3'b010, off_swsp[4:0], 7'b0100011};
          end

          3'b111: begin
            // C.SDSP: sd rs2, offset(x2)  (RV64)
            // offset[5:3|8:6] = c[12:7]
            logic [8:0] off_sdsp;
            off_sdsp = {c[9:7], c[12:10], 3'b000};
            // sd rs2, off(x2)
            instr_o = {3'b0, off_sdsp[8:5], rs2_full, 5'd2, 3'b011, off_sdsp[4:0], 7'b0100011};
          end
        endcase
      end

      // ================================================================
      // c[1:0] == 2'b11 should never reach this module (not compressed)
      // ================================================================
      default: begin
        illegal_o = 1'b1;
      end
    endcase
  end

endmodule
