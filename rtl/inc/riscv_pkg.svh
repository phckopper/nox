`ifndef _RISCV_PKG_
`define _RISCV_PKG_
  `define PC_WIDTH      64
  `define XLEN          64

  // Privilege levels
  `define RV_PRIV_U  2'b00
  `define RV_PRIV_S  2'b01
  `define RV_PRIV_M  2'b11

  // mstatus field bit positions
  `define RV_MST_UIE    0
  `define RV_MST_SIE    1
  `define RV_MST_MIE    3
  `define RV_MST_UPIE   4
  `define RV_MST_SPIE   5
  `define RV_MST_MPIE   7
  `define RV_MST_SPP    8
  `define RV_MST_MPP_LO 11
  `define RV_MST_MPP_HI 12
  `define RV_MST_MPRV   17
  `define RV_MST_SUM    18
  `define RV_MST_MXR    19
  `define RV_MST_TVM    20
  `define RV_MST_TW     21
  `define RV_MST_TSR    22

  // MIE/MIP bit positions
  `define RV_MIE_SSIP   1
  `define RV_MIE_MSIP   3
  `define RV_MIE_STIP   5
  `define RV_MIE_MTIP   7
  `define RV_MIE_SEIP   9
  `define RV_MIE_MEIP   11

  typedef logic [31:0]              instr_raw_t;  // Instructions are always 32-bit
  typedef logic [`PC_WIDTH-1:0]     pc_t;
  typedef logic [`XLEN-1:0]         lsu_addr_t;
  typedef logic [`XLEN-1:0]         b_addr_t;
  typedef logic [`XLEN-1:0]         j_addr_t;

  typedef logic [4:0]               raddr_t;      // 32 registers → always 5-bit address
  typedef logic [`XLEN-1:0]         rdata_t;
  typedef logic [(`XLEN*2)-1:0]     rdata_ext_t;
  typedef logic [`XLEN-1:0]         imm_t;
  typedef logic [5:0]               shamt_t;      // RV64: 6-bit shift amounts (0–63)
  typedef logic [`XLEN-1:0]         alu_t;
  typedef logic [11:0]              csr_addr_t;

  typedef enum logic [11:0] {
    // S-mode CSRs
    RV_CSR_SSTATUS    = 12'h100,  // Shadow of mstatus (S-visible bits)
    RV_CSR_SIE        = 12'h104,  // Shadow of mie (S-level bits)
    RV_CSR_STVEC      = 12'h105,
    RV_CSR_SCOUNTEREN = 12'h106,
    RV_CSR_SSCRATCH   = 12'h140,
    RV_CSR_SEPC       = 12'h141,
    RV_CSR_SCAUSE     = 12'h142,
    RV_CSR_STVAL      = 12'h143,
    RV_CSR_SIP        = 12'h144,  // Shadow of mip (S-level bits)
    RV_CSR_SATP       = 12'h180,
    // M-mode CSRs
    RV_CSR_MSTATUS    = 12'h300,
    RV_CSR_MISA       = 12'h301,
    RV_CSR_MEDELEG    = 12'h302,
    RV_CSR_MIDELEG    = 12'h303,
    RV_CSR_MIE        = 12'h304,
    RV_CSR_MTVEC      = 12'h305,
    RV_CSR_MCOUNTEREN = 12'h306,
    RV_CSR_MSCRATCH   = 12'h340,
    RV_CSR_MEPC       = 12'h341,
    RV_CSR_MCAUSE     = 12'h342,
    RV_CSR_MTVAL      = 12'h343,
    RV_CSR_MIP        = 12'h344,
    RV_CSR_MCYCLE     = 12'hB00,
    RV_CSR_MCYCLEH    = 12'hB80,
    RV_CSR_MINSTRET   = 12'hB02,
    RV_CSR_MINSTRETH  = 12'hB82,
    RV_CSR_CYCLE      = 12'hC00,
    RV_CSR_CYCLEH     = 12'hC80,
    RV_CSR_TIME       = 12'hC01,
    RV_CSR_TIMEH      = 12'hC81,
    RV_CSR_INSTRET    = 12'hC02,
    RV_CSR_INSTRETH   = 12'hC82,
    RV_CSR_MVENDORID  = 12'hF11,
    RV_CSR_MARCHID    = 12'hF12,
    RV_CSR_MIMPLID    = 12'hF13,
    RV_CSR_MHARTID    = 12'hF14
  } addr_csrs_t;

  typedef enum logic [1:0] {
    REG_RF,
    IMM,
    ZERO,
    PC
  } oper_mux_t;

  typedef enum logic [3:0] {
    RV_M_SW_INT    = 4'd3,
    RV_M_TIMER_INT = 4'd7,
    RV_M_EXT_INT   = 4'd11
  } mcause_int_t;

  typedef enum logic [2:0] {
    RV_CSR_NONE = 3'b000,
    RV_CSR_RW   = 3'b001,
    RV_CSR_RS   = 3'b010,
    RV_CSR_RC   = 3'b011,
    RV_CSR_RWI  = 3'b101,
    RV_CSR_RSI  = 3'b110,
    RV_CSR_RCI  = 3'b111
  } csr_t;

  typedef enum logic [2:0] {
    RV_LSU_B  = 3'b000,
    RV_LSU_H  = 3'b001,
    RV_LSU_W  = 3'b010,
    RV_LSU_D  = 3'b011,    // RV64: doubleword (LD/SD)
    RV_LSU_BU = 3'b100,
    RV_LSU_HU = 3'b101,
    RV_LSU_WU = 3'b110     // RV64: unsigned word (LWU)
  } lsu_w_t;

  typedef enum logic [1:0] {
    NO_LSU,
    LSU_LOAD,
    LSU_STORE,
    LSU_AMO       // P11: RV32A — atomic read-modify-write (covers LR/SC/AMO*)
  } lsu_t;

  // P11: RV32A — funct5 field for all atomic instructions
  typedef enum logic [4:0] {
    AMO_ADD   = 5'b00000,
    AMO_SWAP  = 5'b00001,
    AMO_LR    = 5'b00010,
    AMO_SC    = 5'b00011,
    AMO_XOR   = 5'b00100,
    AMO_OR    = 5'b01000,
    AMO_AND   = 5'b01100,
    AMO_MIN   = 5'b10000,
    AMO_MAX   = 5'b10100,
    AMO_MINU  = 5'b11000,
    AMO_MAXU  = 5'b11100
  } amo_op_t;

  typedef enum logic {
    RV_SRL = 1'b0,
    RV_SRA = 1'b1
  } rshift_t;

  typedef enum logic [6:0]{
    RV_F7_SRL = 7'b0000000,
    RV_F7_SRA = 7'b0100000
  } funct7_t;

  typedef enum logic {
    RV_F7_0,
    RV_F7_1
  } sfunct7_t;

  typedef enum logic {
    RV_TYPE_JAL,
    RV_TYPE_JALR
  } j_type_t;

  typedef enum logic [2:0]{
    RV_B_BEQ   = 3'b000,
    RV_B_BNE   = 3'b001,
    RV_B_BLT   = 3'b100,
    RV_B_BGE   = 3'b101,
    RV_B_BLTU  = 3'b110,
    RV_B_BGEU  = 3'b111
  } branch_t;

  typedef enum logic [2:0]{
    RV_F3_ADD_SUB = 3'b000,
    RV_F3_SLT     = 3'b010,
    RV_F3_SLTU    = 3'b011,
    RV_F3_XOR     = 3'b100,
    RV_F3_OR      = 3'b110,
    RV_F3_AND     = 3'b111,
    RV_F3_SLL     = 3'b001,
    RV_F3_SRL_SRA = 3'b101
  } funct3_t;

  typedef enum logic [6:0]{
    RV_LOAD       = 'b00_000_11,
    RV_custom_0   = 'b00_010_11,
    RV_MISC_MEM   = 'b00_011_11,
    RV_OP_IMM     = 'b00_100_11,
    RV_AUIPC      = 'b00_101_11,
    RV_OP_IMM_32  = 'b00_110_11,
    RV_STORE      = 'b01_000_11,
    RV_custom_1   = 'b01_010_11,
    RV_ATOMIC     = 'b01_011_11,  // P11: RV32A (opcode 0x2F)
    RV_OP         = 'b01_100_11,
    RV_LUI        = 'b01_101_11,
    RV_OP_32      = 'b01_110_11,
    RV_custom_2   = 'b10_110_11,
    RV_BRANCH     = 'b11_000_11,
    RV_JALR       = 'b11_001_11,
    RV_JAL        = 'b11_011_11,
    RV_SYSTEM     = 'b11_100_11,
    RV_custom_3   = 'b11_110_11
  } op_t;

  typedef enum logic [2:0]{
    I_IMM,
    S_IMM,
    B_IMM,
    U_IMM,
    J_IMM,
    CSR_IMM
  } imm_type_t;

  typedef struct packed {
    csr_t       op;
    csr_addr_t  addr;
    logic       rs1_is_x0;
  } s_csr_t;

  typedef struct packed {
    funct7_t    f7;
    raddr_t     rs2;
    raddr_t     rs1;
    funct3_t    f3;
    raddr_t     rd;
    op_t        op;
  } s_instr_t;

  typedef struct packed {
    logic ext_irq;    // MEIP — M-mode external (PLIC M-context)
    logic sw_irq;     // MSIP — M-mode software (CLINT)
    logic timer_irq;  // MTIP — M-mode timer (CLINT mtime >= mtimecmp)
    logic s_ext_irq;  // SEIP — S-mode external (PLIC S-context)
  } s_irq_t;

  typedef struct packed {
    pc_t        pc_addr;
    logic [`XLEN-1:0] mtval;    // RV64: XLEN-wide (stores faulting addr or instruction)
    logic       active;
  } s_trap_info_t;

  typedef struct packed {
    // Trap - MEM access fault
    s_trap_info_t st;
    s_trap_info_t ld;
    // Trap - MEM misaligned addr
    s_trap_info_t st_mis;
    s_trap_info_t ld_mis;
  } s_trap_lsu_info_t;

  typedef struct packed {
    logic         we_rd;
    pc_t          pc_dec;
    oper_mux_t    rs1_op;
    oper_mux_t    rs2_op;
    lsu_t         lsu;
    lsu_w_t       lsu_w;
    logic         branch;
    logic         jump;
    sfunct7_t     f7;
    raddr_t       rd_addr;
    funct3_t      f3;
    rshift_t      rshift;
    imm_t         imm;
    raddr_t       rs1_addr;
    raddr_t       rs2_addr;
    s_csr_t       csr;
    logic         ecall;
    logic         ebreak;
    logic         mret;
    logic         sret;        // Phase 2A: S-mode return
    logic         sfence_vma;  // Phase 2A: supervisor fence
    logic         fence_i;     // Phase 2A: instruction fence
    logic         wfi;
    s_trap_info_t trap;
    // Branch predictor: set when the BP predicted this instruction as a
    // taken branch so execute can suppress the redirect on correct predictions.
    logic         bp_taken;
    // BP predicted target address carried through the pipeline.
    // Allows execute to suppress the JALR redirect when the BTB/RAS
    // correctly predicted the return address (avoids the 3-cycle penalty).
    pc_t          bp_predict_target;
    // P7: RV32M extension — instruction is a MUL/DIV/REM from funct7=0000001
    logic         is_muldiv;
    // P8-P10: raw funct7 bits for Zba/Zbb/Zicond dispatch in execute
    logic [6:0]   funct7_raw;
    // P11: RV-A — AMO operation type (funct5 from atomic instruction encoding)
    amo_op_t      amo_op;
    // RV64: word-width operation flag (*W instructions: ADDIW, SLLW, DIVW, etc.)
    // When set, execute truncates result to 32 bits and sign-extends to 64.
    logic         is_word_op;
    // RV64C: instruction was a compressed (16-bit) instruction.
    // Used for link address calculation: JAL/JALR → pc+2 instead of pc+4.
    logic         is_compressed;
  } s_id_ex_t;

  typedef struct packed {
    lsu_t       lsu;
    logic       we_rd;
    raddr_t     rd_addr;
    alu_t       result;
  } s_ex_mem_wb_t;

  typedef struct packed {
    logic       take_branch;
    logic       b_act;
    b_addr_t    b_addr;
  } s_branch_t;

  typedef struct packed {
    logic       j_act;
    j_addr_t    j_addr;
  } s_jump_t;

  typedef struct packed {
    lsu_t       op_typ;
    lsu_w_t     width;
    lsu_addr_t  addr;
    rdata_t     wdata;
    pc_t        pc_addr; // We have to store the pc in case of LSU exception
    amo_op_t    amo_op;  // P11: AMO operation (valid when op_typ==LSU_AMO)
  } s_lsu_op_t;

  typedef struct packed {
    rdata_t     rd_data;
    raddr_t     rd_addr;
    logic       we_rd;
  } s_wb_t;

  function automatic imm_t gen_imm(instr_raw_t instr, imm_type_t imm_type);
    imm_t imm_res;

    unique case(imm_type)
      I_IMM:    imm_res = {{53{instr[31]}},instr[30:25],instr[24:21],instr[20]};
      S_IMM:    imm_res = {{53{instr[31]}},instr[30:25],instr[11:8],instr[7]};
      B_IMM:    imm_res = {{52{instr[31]}},instr[7],instr[30:25],instr[11:8],1'b0};
      U_IMM:    imm_res = {{33{instr[31]}},instr[30:20],instr[19:12],12'd0};
      J_IMM:    imm_res = {{44{instr[31]}},instr[19:12],instr[20],instr[30:25],instr[24:21],1'b0};
      CSR_IMM:  imm_res = {{59{1'b0}},instr[19:15]};
      default:  `ERROR("Immediate encoding not valid!",imm_type)
    endcase
    return  imm_res;
  endfunction
`endif
