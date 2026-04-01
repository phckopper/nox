/**
 * File              : csr.sv
 * License           : MIT license <Check LICENSE>
 * Author            : Anderson Ignacio da Silva (aignacio) <anderson@aignacio.com>
 * Date              : 23.01.2022
 * Last Modified Date: 2026-03-31 (Phase 2A: S-mode, U-mode, trap delegation)
 */
module csr
  import amba_axi_pkg::*;
  import amba_ahb_pkg::*;
  import nox_utils_pkg::*;
#(
  parameter int SUPPORT_DEBUG = 1,
  parameter int MTVEC_DEFAULT_VAL = 'h1000, // 4KB
  parameter int unsigned M_HART_ID = `M_HART_ID
)(
  input                     clk,
  input                     rst,
  input                     stall_i,
  input   s_csr_t           csr_i,
  input   rdata_t           rs1_data_i,
  input   imm_t             imm_i,
  output  rdata_t           csr_rd_o,
  // Interrupts [async trap] & Exceptions [sync trap]
  input   pc_t              pc_addr_i,
  input   pc_t              pc_lsu_i,
  input   s_irq_t           irq_i,
  input                     will_jump_i,
  input                     eval_trap_i,
  input   s_trap_info_t     dec_trap_i,
  input   s_trap_info_t     instr_addr_mis_i,
  input   s_trap_info_t     fetch_trap_i,
  input                     ecall_i,
  input                     ebreak_i,
  input                     mret_i,
  input                     sret_i,
  input                     wfi_i,
  input   s_trap_lsu_info_t lsu_trap_i,
  output  s_trap_info_t     trap_o,
  // Privilege mode output (used by execute for SFENCE checks and future MMU)
  output  logic [1:0]       priv_mode_o
);
  typedef struct packed {
    csr_t   op;
    logic   rs1_is_x0;
    imm_t   imm;
    rdata_t rs1;
    rdata_t csr_rd;
    rdata_t mask;
  } s_wr_csr_t;

  logic mcause_interrupt;
  pc_t  mtvec_base_addr;
  logic mtvec_vectored;
  rdata_t trap_offset;
  logic   dbg_irq_mtime;
  logic   dbg_irq_msoft;
  logic   dbg_irq_mext;
  logic   traps_can_happen_wo_exec;

  mcause_int_t async_int;

  rdata_ext_t csr_minstret_ff,  next_minstret,
              csr_cycle_ff,     next_cycle,
              csr_time_ff,      next_time;

  // M-mode CSRs
  rdata_t csr_mstatus_ff,   next_mstatus,
          csr_mie_ff,       next_mie,
          csr_mtvec_ff,     next_mtvec,
          csr_mscratch_ff,  next_mscratch,
          csr_mepc_ff,      next_mepc,
          csr_mcause_ff,    next_mcause,
          csr_mtval_ff,     next_mtval,
          csr_mip_ff,       next_mip,
          csr_medeleg_ff,   next_medeleg,
          csr_mideleg_ff,   next_mideleg;

  // S-mode CSRs
  rdata_t csr_stvec_ff,     next_stvec,
          csr_sscratch_ff,  next_sscratch,
          csr_sepc_ff,      next_sepc,
          csr_scause_ff,    next_scause,
          csr_stval_ff,     next_stval,
          csr_satp_ff,      next_satp;

  // Current privilege mode: M=2'b11, S=2'b01, U=2'b00
  logic [1:0] priv_mode_ff, next_priv_mode;

  s_wr_csr_t csr_wr_args;

  s_trap_info_t trap_ff, next_trap;

  logic [2:0] irq_vec;

  // sstatus write mask: only S-visible bits of mstatus
  // SIE(1), SPIE(5), SPP(8), SUM(18), MXR(19), UXL(33:32)
  localparam rdata_t SSTATUS_MASK = 64'h0000_0003_000D_E162;

  // mstatus write mask (extended for S-mode bits)
  // UIE(0), SIE(1), MIE(3), UPIE(4), SPIE(5), MPIE(7), SPP(8),
  // MPP(12:11), MPRV(17), SUM(18), MXR(19), TVM(20), TW(21), TSR(22)
  localparam rdata_t MSTATUS_MASK = 64'h0000_0000_807F_F9BB | (1 << 10);

  function automatic rdata_t wr_csr_val(s_wr_csr_t wr_arg);
    rdata_t wr_val;

    case (wr_arg.op)
      RV_CSR_RW:  wr_val = wr_arg.rs1;
      RV_CSR_RS:  wr_val = wr_arg.csr_rd | wr_arg.rs1;
      RV_CSR_RC:  wr_val = wr_arg.csr_rd & ~wr_arg.rs1;
      RV_CSR_RWI: wr_val = wr_arg.imm;
      RV_CSR_RSI: wr_val = wr_arg.csr_rd | wr_arg.imm;
      RV_CSR_RCI: wr_val = wr_arg.csr_rd & ~wr_arg.imm;
      default:    wr_val = wr_arg.csr_rd;
    endcase

    if ((wr_arg.op != RV_CSR_RW) && (wr_arg.op != RV_CSR_RWI)) begin
      wr_val = wr_arg.rs1_is_x0 ? wr_arg.csr_rd : wr_val;
    end

    wr_val = (wr_val & wr_arg.mask);
    wr_val = stall_i ? wr_arg.csr_rd : wr_val;
    return wr_val;
  endfunction

  always_comb begin : rd_wr_csr
    // Output is combo cause there's a mux in the exe stg
    csr_rd_o = rdata_t'('0);

    next_cycle    = csr_cycle_ff + 'd1;
    next_time     = csr_time_ff;
    next_mstatus  = csr_mstatus_ff;
    next_mie      = csr_mie_ff;
    next_mtvec    = csr_mtvec_ff;
    next_mscratch = csr_mscratch_ff;
    next_mepc     = csr_mepc_ff;
    next_mcause   = csr_mcause_ff;
    next_mtval    = csr_mtval_ff;
    next_mip      = csr_mip_ff;
    next_medeleg  = csr_medeleg_ff;
    next_mideleg  = csr_mideleg_ff;
    next_stvec    = csr_stvec_ff;
    next_sscratch = csr_sscratch_ff;
    next_sepc     = csr_sepc_ff;
    next_scause   = csr_scause_ff;
    next_stval    = csr_stval_ff;
    next_satp     = csr_satp_ff;
    next_priv_mode = priv_mode_ff;

    csr_wr_args.op        = csr_i.op;
    csr_wr_args.rs1_is_x0 = csr_i.rs1_is_x0;
    csr_wr_args.imm       = imm_i;
    csr_wr_args.rs1       = rs1_data_i;
    csr_wr_args.csr_rd    = '0;
    csr_wr_args.mask      = '1;

    case(csr_i.addr)
      // ---- S-mode CSRs ----
      RV_CSR_SSTATUS: begin
        // Shadow of mstatus, S-visible bits only
        csr_rd_o           = csr_mstatus_ff & SSTATUS_MASK;
        csr_wr_args.mask   = SSTATUS_MASK;
        csr_wr_args.csr_rd = csr_rd_o;
        next_mstatus       = (csr_mstatus_ff & ~SSTATUS_MASK) |
                             (wr_csr_val(csr_wr_args) & SSTATUS_MASK);
      end
      RV_CSR_SIE: begin
        // Shadow of mie — S-level bits: SSIP(1), STIP(5), SEIP(9)
        csr_rd_o           = csr_mie_ff & 64'h222;
        csr_wr_args.mask   = 64'h222;
        csr_wr_args.csr_rd = csr_rd_o;
        next_mie           = (csr_mie_ff & ~64'h222) |
                             (wr_csr_val(csr_wr_args) & 64'h222);
      end
      RV_CSR_STVEC: begin
        csr_wr_args.mask   = 64'hFFFF_FFFF_FFFF_FFFD;
        csr_rd_o           = csr_stvec_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_stvec         = wr_csr_val(csr_wr_args);
      end
      RV_CSR_SSCRATCH: begin
        csr_rd_o           = csr_sscratch_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_sscratch      = wr_csr_val(csr_wr_args);
      end
      RV_CSR_SEPC: begin
        csr_wr_args.mask   = 64'hFFFF_FFFF_FFFF_FFFC;
        csr_rd_o           = csr_sepc_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_sepc          = wr_csr_val(csr_wr_args);
      end
      RV_CSR_SCAUSE: begin
        csr_rd_o = csr_scause_ff;
      end
      RV_CSR_STVAL: begin
        csr_rd_o           = csr_stval_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_stval         = wr_csr_val(csr_wr_args);
      end
      RV_CSR_SIP: begin
        // Shadow of mip — S-level read: SSIP(1), STIP(5), SEIP(9)
        // Only SSIP is software-writable from S-mode
        csr_rd_o           = csr_mip_ff & 64'h222;
        csr_wr_args.mask   = 64'h2;   // only SSIP writable
        csr_wr_args.csr_rd = csr_rd_o;
        next_mip           = (csr_mip_ff & ~64'h2) |
                             (wr_csr_val(csr_wr_args) & 64'h2);
      end
      RV_CSR_SATP: begin
        csr_rd_o           = csr_satp_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_satp          = wr_csr_val(csr_wr_args);
      end
      // ---- M-mode CSRs ----
      RV_CSR_MSTATUS: begin
        csr_wr_args.mask   = MSTATUS_MASK;
        csr_rd_o           = csr_mstatus_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_mstatus       = wr_csr_val(csr_wr_args);
      end
      RV_CSR_MIE: begin
        // M-mode can access all interrupt enable bits
        csr_wr_args.mask   = 64'hAAA;
        csr_rd_o           = csr_mie_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_mie           = wr_csr_val(csr_wr_args);
      end
      RV_CSR_MTVEC: begin
        csr_wr_args.mask   = 64'hFFFF_FFFF_FFFF_FFFD;
        csr_rd_o           = csr_mtvec_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_mtvec         = wr_csr_val(csr_wr_args);
      end
      RV_CSR_MSCRATCH: begin
        csr_rd_o           = csr_mscratch_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_mscratch      = wr_csr_val(csr_wr_args);
      end
      RV_CSR_MEPC: begin
        csr_wr_args.mask   = 64'hFFFF_FFFF_FFFF_FFFC;
        csr_rd_o           = csr_mepc_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_mepc          = wr_csr_val(csr_wr_args);
      end
      RV_CSR_MCAUSE: begin
        csr_rd_o = csr_mcause_ff;
      end
      RV_CSR_MTVAL: begin
        csr_rd_o           = csr_mtval_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_mtval         = wr_csr_val(csr_wr_args);
      end
      RV_CSR_MIP: begin
        csr_wr_args.mask   = 64'hAAA;
        csr_rd_o           = csr_mip_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_mip           = wr_csr_val(csr_wr_args);
      end
      RV_CSR_MEDELEG: begin
        // Not delegatable: illegal instr(2), ecall from M(11), machine NMI
        csr_wr_args.mask   = 64'hFFFF_FFFF_FFFF_F3FF;
        csr_rd_o           = csr_medeleg_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_medeleg       = wr_csr_val(csr_wr_args);
      end
      RV_CSR_MIDELEG: begin
        csr_wr_args.mask   = 64'hAAA;
        csr_rd_o           = csr_mideleg_ff;
        csr_wr_args.csr_rd = csr_rd_o;
        next_mideleg       = wr_csr_val(csr_wr_args);
      end
      RV_CSR_CYCLE:     csr_rd_o = csr_cycle_ff[63:0];
      RV_CSR_CYCLEH:    csr_rd_o = csr_cycle_ff[127:64];
      RV_CSR_MISA:      csr_rd_o = `M_ISA_ID;
      RV_CSR_MHARTID:   csr_rd_o = rdata_t'(M_HART_ID);
      default:          csr_rd_o = rdata_t'('0);
    endcase

    next_trap  = s_trap_info_t'('0);
    dbg_irq_mtime = 'b0;
    dbg_irq_msoft = 'b0;
    dbg_irq_mext  = 'b0;

    // Update MIP bits from external signals
    next_mip[`RV_MIE_MTIP] = irq_i.timer_irq;
    next_mip[`RV_MIE_MEIP] = irq_i.ext_irq;
    next_mip[`RV_MIE_SEIP] = irq_i.s_ext_irq;

    // ---------------------------------------------------------------
    // Trap priority encoder
    // Priority: MEI > MSI > MTI > SEI > SSI > STI > sync exceptions
    //
    // Interrupt enable gating rules (priv spec):
    //  - M-mode interrupts: taken if priv<M OR (priv==M AND mstatus.MIE)
    //  - S-mode interrupts: taken if priv<S OR (priv==S AND mstatus.SIE)
    //    (only when delegated via mideleg)
    // ---------------------------------------------------------------

    // Helper: is M-mode interrupt globally enabled?
    // (We handle both "priv<M" and "priv==M && MIE" cases)
    // is_s_irq_enabled: S-mode interrupts enabled for current context?

    priority case(1)
      // ---- M-level external interrupt ----
      ((priv_mode_ff != `RV_PRIV_M || csr_mstatus_ff[`RV_MST_MIE]) &&
       irq_i.ext_irq &&
       csr_mie_ff[`RV_MIE_MEIP] &&
       ~csr_mideleg_ff[11]): begin
        next_mepc              = pc_addr_i;
        next_mcause            = 64'h8000_0000_0000_000B;
        next_mtval             = rdata_t'('h0);
        next_trap.active       = 'b1;
        next_priv_mode         = `RV_PRIV_M;
        dbg_irq_mext           = 'b1;
      end
      // ---- M-level software interrupt ----
      ((priv_mode_ff != `RV_PRIV_M || csr_mstatus_ff[`RV_MST_MIE]) &&
       irq_i.sw_irq &&
       csr_mie_ff[`RV_MIE_MSIP] &&
       ~csr_mideleg_ff[3]): begin
        next_mip[`RV_MIE_MSIP] = 'b1;
        next_mepc              = pc_addr_i;
        next_mcause            = 64'h8000_0000_0000_0003;
        next_mtval             = rdata_t'('h0);
        next_trap.active       = 'b1;
        next_priv_mode         = `RV_PRIV_M;
        dbg_irq_msoft          = 'b1;
      end
      // ---- M-level timer interrupt ----
      ((priv_mode_ff != `RV_PRIV_M || csr_mstatus_ff[`RV_MST_MIE]) &&
       irq_i.timer_irq &&
       csr_mie_ff[`RV_MIE_MTIP] &&
       ~csr_mideleg_ff[7]): begin
        next_mepc              = pc_addr_i;
        next_mcause            = 64'h8000_0000_0000_0007;
        next_mtval             = rdata_t'('h0);
        next_trap.active       = 'b1;
        next_priv_mode         = `RV_PRIV_M;
        dbg_irq_mtime          = 'b1;
      end
      // ---- S-level external interrupt (delegated) ----
      ((priv_mode_ff == `RV_PRIV_U ||
        (priv_mode_ff == `RV_PRIV_S && csr_mstatus_ff[`RV_MST_SIE])) &&
       irq_i.ext_irq &&
       csr_mie_ff[`RV_MIE_SEIP] &&
       csr_mideleg_ff[9]): begin
        next_sepc              = pc_addr_i;
        next_scause            = 64'h8000_0000_0000_0009;
        next_stval             = rdata_t'('h0);
        next_trap.active       = 'b1;
        next_priv_mode         = `RV_PRIV_S;
      end
      // ---- S-level software interrupt (delegated) ----
      ((priv_mode_ff == `RV_PRIV_U ||
        (priv_mode_ff == `RV_PRIV_S && csr_mstatus_ff[`RV_MST_SIE])) &&
       csr_mip_ff[`RV_MIE_SSIP] &&
       csr_mie_ff[`RV_MIE_SSIP] &&
       csr_mideleg_ff[1]): begin
        next_sepc              = pc_addr_i;
        next_scause            = 64'h8000_0000_0000_0001;
        next_stval             = rdata_t'('h0);
        next_trap.active       = 'b1;
        next_priv_mode         = `RV_PRIV_S;
      end
      // ---- S-level timer interrupt (delegated) ----
      ((priv_mode_ff == `RV_PRIV_U ||
        (priv_mode_ff == `RV_PRIV_S && csr_mstatus_ff[`RV_MST_SIE])) &&
       irq_i.timer_irq &&
       csr_mie_ff[`RV_MIE_STIP] &&
       csr_mideleg_ff[5]): begin
        next_sepc              = pc_addr_i;
        next_scause            = 64'h8000_0000_0000_0005;
        next_stval             = rdata_t'('h0);
        next_trap.active       = 'b1;
        next_priv_mode         = `RV_PRIV_S;
      end
      // ---- Fetch trap ----
      fetch_trap_i.active: begin
        next_mepc        = pc_addr_i;
        next_mcause      = 'd1;
        next_mtval       = rdata_t'(fetch_trap_i.mtval);
        next_trap.active = 'b1;
        next_priv_mode   = `RV_PRIV_M;
      end
      // ---- Decode/illegal instruction trap ----
      (dec_trap_i.active && ~will_jump_i): begin
        if (csr_medeleg_ff[2] && priv_mode_ff != `RV_PRIV_M) begin
          next_sepc        = dec_trap_i.pc_addr;
          next_scause      = 'd2;
          next_stval       = rdata_t'(dec_trap_i.mtval);
          next_priv_mode   = `RV_PRIV_S;
        end else begin
          next_mepc        = dec_trap_i.pc_addr;
          next_mcause      = 'd2;
          next_mtval       = rdata_t'(dec_trap_i.mtval);
          next_priv_mode   = `RV_PRIV_M;
        end
        next_trap.active = 'b1;
      end
      // ---- Instruction address misaligned ----
      instr_addr_mis_i.active: begin
        next_mepc        = pc_addr_i;
        next_mcause      = 'd0;
        next_mtval       = rdata_t'(instr_addr_mis_i.mtval);
        next_trap.active = 'b1;
        next_priv_mode   = `RV_PRIV_M;
      end
      // ---- ECALL — cause depends on current privilege ----
      ecall_i: begin
        logic [5:0] ecall_cause_idx;
        rdata_t     ecall_cause;
        case (priv_mode_ff)
          `RV_PRIV_U: begin ecall_cause = 'd8;  ecall_cause_idx = 6'd8;  end
          `RV_PRIV_S: begin ecall_cause = 'd9;  ecall_cause_idx = 6'd9;  end
          default:    begin ecall_cause = 'd11; ecall_cause_idx = 6'd11; end
        endcase
        if (csr_medeleg_ff[ecall_cause_idx] && priv_mode_ff != `RV_PRIV_M) begin
          next_sepc        = pc_addr_i;
          next_scause      = ecall_cause;
          next_stval       = rdata_t'('h0);
          next_priv_mode   = `RV_PRIV_S;
        end else begin
          next_mepc        = pc_addr_i;
          next_mcause      = ecall_cause;
          next_mtval       = rdata_t'('h0);
          next_priv_mode   = `RV_PRIV_M;
        end
        next_trap.active = 'b1;
      end
      // ---- EBREAK ----
      ebreak_i: begin
        next_mepc        = pc_addr_i;
        next_mcause      = 'd3;
        next_mtval       = '0;
        next_trap.active = 'b1;
        next_priv_mode   = `RV_PRIV_M;
      end
      // ---- MRET — return from M-mode trap ----
      mret_i: begin
        next_mtval       = rdata_t'('h0);
        next_trap.active = 'b1;
      end
      // ---- SRET — return from S-mode trap ----
      sret_i: begin
        next_stval       = rdata_t'('h0);
        next_trap.active = 'b1;
      end
      // ---- LSU misaligned load ----
      lsu_trap_i.ld_mis.active: begin
        next_mepc        = pc_lsu_i;
        next_mcause      = 'd4;
        next_mtval       = pc_lsu_i;
        next_trap.active = 'b1;
        next_priv_mode   = `RV_PRIV_M;
      end
      // ---- LSU load access fault ----
      lsu_trap_i.ld.active: begin
        next_mepc        = pc_lsu_i;
        next_mcause      = 'd5;
        next_mtval       = pc_lsu_i;
        next_trap.active = 'b1;
        next_priv_mode   = `RV_PRIV_M;
      end
      // ---- LSU misaligned store ----
      lsu_trap_i.st_mis.active: begin
        next_mepc        = pc_lsu_i;
        next_mcause      = 'd6;
        next_mtval       = pc_lsu_i;
        next_trap.active = 'b1;
        next_priv_mode   = `RV_PRIV_M;
      end
      // ---- LSU store access fault ----
      lsu_trap_i.st.active: begin
        next_mepc        = pc_lsu_i;
        next_mcause      = 'd7;
        next_mtval       = pc_lsu_i;
        next_trap.active = 'b1;
        next_priv_mode   = `RV_PRIV_M;
      end
      default: next_trap  = s_trap_info_t'('0);
    endcase

    irq_vec = {dbg_irq_mtime, dbg_irq_msoft, dbg_irq_mtime};

    // These traps don't need eval_trap_i to fire
    traps_can_happen_wo_exec = (fetch_trap_i.active       ||
                                lsu_trap_i.st.active      ||
                                lsu_trap_i.ld.active      ||
                                lsu_trap_i.st_mis.active  ||
                                lsu_trap_i.ld_mis.active);

    if (~traps_can_happen_wo_exec) begin
      if (~eval_trap_i && ~wfi_i) begin
        next_trap.active = 'b0;
      end
    end

    // ---------------------------------------------------------------
    // Compute trap target address and update mstatus / privilege state
    // ---------------------------------------------------------------

    // M-mode trap target from mtvec
    mtvec_base_addr   = {csr_mtvec_ff[63:2],2'h0};
    mtvec_vectored    = csr_mtvec_ff[0];
    mcause_interrupt  = next_mcause[63];
    async_int         = mcause_int_t'(next_mcause[3:0]);
    trap_offset       = 'h0;
    next_trap.pc_addr = mtvec_base_addr;

    // Vectored mode and MCAUSE is async interrupt
    if (mtvec_vectored && mcause_interrupt) begin
      case(async_int)
        RV_M_SW_INT:    trap_offset = 'h0c;
        RV_M_TIMER_INT: trap_offset = 'h1c;
        RV_M_EXT_INT:   trap_offset = 'h2c;
        default:        trap_offset = 'h0;
      endcase
    end

    // ---- Trap entry: update mstatus xPIE/xIE/xPP ----
    if (next_trap.active && ~mret_i && ~sret_i) begin
      if (next_priv_mode == `RV_PRIV_S) begin
        // Delegated to S-mode: update SPIE/SIE/SPP, use stvec
        next_mstatus[`RV_MST_SPIE] = csr_mstatus_ff[`RV_MST_SIE];
        next_mstatus[`RV_MST_SIE]  = 'b0;
        next_mstatus[`RV_MST_SPP]  = priv_mode_ff[0];  // 1=S, 0=U
        // Trap target from stvec
        next_trap.pc_addr = {csr_stvec_ff[63:2], 2'h0};
        if (csr_stvec_ff[0] && next_scause[63]) begin
          // Vectored S-mode: target = stvec_base + 4*cause
          next_trap.pc_addr = {csr_stvec_ff[63:2], 2'h0} + {next_scause[61:0], 2'h0};
        end
      end else begin
        // M-mode trap: update MPIE/MIE/MPP
        next_mstatus[`RV_MST_MPIE]         = csr_mstatus_ff[`RV_MST_MIE];
        next_mstatus[`RV_MST_MIE]          = 'b0;
        next_mstatus[`RV_MST_MPP_HI:`RV_MST_MPP_LO] = priv_mode_ff;
        next_trap.pc_addr = mtvec_base_addr + trap_offset;
        if (wfi_i && (|irq_vec)) begin
          // WFI: mepc = pc + 4
          next_mepc = next_mepc + 'd4;
        end
      end
    end

    // ---- MRET: restore M-mode state ----
    if (mret_i) begin
      next_trap.pc_addr = csr_mepc_ff;
      next_mstatus[`RV_MST_MIE]            = csr_mstatus_ff[`RV_MST_MPIE];
      next_mstatus[`RV_MST_MPIE]           = 'b1;
      // Restore privilege from MPP, then set MPP to U
      next_priv_mode = csr_mstatus_ff[`RV_MST_MPP_HI:`RV_MST_MPP_LO];
      next_mstatus[`RV_MST_MPP_HI:`RV_MST_MPP_LO] = `RV_PRIV_U;
    end

    // ---- SRET: restore S-mode state ----
    if (sret_i) begin
      next_trap.pc_addr = csr_sepc_ff;
      next_mstatus[`RV_MST_SIE]  = csr_mstatus_ff[`RV_MST_SPIE];
      next_mstatus[`RV_MST_SPIE] = 'b1;
      // Restore privilege from SPP, then set SPP to U
      next_priv_mode = {1'b0, csr_mstatus_ff[`RV_MST_SPP]};
      next_mstatus[`RV_MST_SPP]  = 'b0;
    end

    trap_o = trap_ff;
    priv_mode_o = priv_mode_ff;

  end

  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      csr_mstatus_ff  <=  'h1880;
      csr_mie_ff      <=  `OP_RST_L;
      csr_mtvec_ff    <=  rdata_t'(MTVEC_DEFAULT_VAL);
      csr_mscratch_ff <=  `OP_RST_L;
      csr_mepc_ff     <=  `OP_RST_L;
      csr_mcause_ff   <=  `OP_RST_L;
      csr_mtval_ff    <=  `OP_RST_L;
      csr_mip_ff      <=  `OP_RST_L;
      csr_medeleg_ff  <=  `OP_RST_L;
      csr_mideleg_ff  <=  `OP_RST_L;
      csr_stvec_ff    <=  `OP_RST_L;
      csr_sscratch_ff <=  `OP_RST_L;
      csr_sepc_ff     <=  `OP_RST_L;
      csr_scause_ff   <=  `OP_RST_L;
      csr_stval_ff    <=  `OP_RST_L;
      csr_satp_ff     <=  `OP_RST_L;
      csr_cycle_ff    <=  `OP_RST_L;
      priv_mode_ff    <=  `RV_PRIV_M;  // Boot in M-mode
      trap_ff         <=  `OP_RST_L;
    end
    else begin
      csr_mstatus_ff  <=  next_mstatus;
      csr_mie_ff      <=  next_mie;
      csr_mtvec_ff    <=  next_mtvec;
      csr_mscratch_ff <=  next_mscratch;
      csr_mepc_ff     <=  next_mepc;
      csr_mcause_ff   <=  next_mcause;
      csr_mtval_ff    <=  next_mtval;
      csr_mip_ff      <=  next_mip;
      csr_medeleg_ff  <=  next_medeleg;
      csr_mideleg_ff  <=  next_mideleg;
      csr_stvec_ff    <=  next_stvec;
      csr_sscratch_ff <=  next_sscratch;
      csr_sepc_ff     <=  next_sepc;
      csr_scause_ff   <=  next_scause;
      csr_stval_ff    <=  next_stval;
      csr_satp_ff     <=  next_satp;
      csr_cycle_ff    <=  next_cycle;
      priv_mode_ff    <=  next_priv_mode;
      trap_ff         <=  next_trap;
    end
  end
endmodule
