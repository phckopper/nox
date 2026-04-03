/**
 * Sub-phase 2C MMU Test
 *
 * Tests:
 *  1. Set up Sv39 1G identity pages (entries [0] and [2] in root PT)
 *  2. Enable MMU (satp write + sfence.vma)
 *  3. Switch to S-mode via MRET (MMU now active)
 *  4. D-TLB: store/load word through identity-mapped DRAM → verify round-trip
 *  5. I-TLB: execution continues at 0x80000000 (1G identity) with no fault
 *  6. Page fault: load from unmapped VA 0x40000000 (VPN[2]=1, no entry)
 *     → M-mode trap handler verifies mcause==13 (load page fault)
 *     → sets s0=1, advances mepc+4, MRET back to S-mode
 *  7. Verify s0==1 (page fault was handled correctly)
 *  8. Print PASS / FAIL via UART intercept at 0xA0000000, then loop
 *
 * Memory layout:
 *   IRAM: 0x80000000, 128KB
 *   DRAM: 0x10000000, 32KB
 *   Stack: 0x10008000 (top of DRAM, grows down)
 *   Root PT: 0x10006000 (page table in DRAM, 4KB)
 *
 * Page table:
 *   Entry [0] offset  0: PTE = 0x00000000_000000CF → 1G identity 0x00000000..0x3FFFFFFF
 *   Entry [2] offset 16: PTE = 0x00000000_200000CF → 1G identity 0x80000000..0xBFFFFFFF
 *   (VPN[2] = va[38:30]; for 32-bit addresses VPN[2] = va[31:30])
 */
.option norvc
.section .init
.global _start_reset

_start_reset:
.option push
.option norelax
.Lgp_hi:
    auipc gp, %pcrel_hi(__global_pointer$)
    addi  gp, gp, %pcrel_lo(.Lgp_hi)
.Lsp_hi:
    auipc sp, %pcrel_hi(_start_stack)
    addi  sp, sp, %pcrel_lo(.Lsp_hi)
.option pop
    j     main

.section .text

/* ================================================================
 *  M-mode trap handler
 *  Handles load page fault (cause 13) from S-mode.
 *  Sets s0 = 1, advances mepc by 4 (skip the faulting load), MRET.
 *  Any other cause falls through to test_fail.
 * ================================================================ */
.align 4
m_trap_handler:
    csrr  t0, mcause
    li    t1, 13                /* load page fault */
    bne   t0, t1, trap_other
    /* It is a load page fault */
    li    s0, 1                 /* pf_ok = 1 */
    csrr  t0, mepc
    addi  t0, t0, 4             /* skip the faulting ld/lw */
    csrw  mepc, t0
    mret

trap_other:
    /* Unexpected trap: print "T|I<cause_hex_lo><cause_hex_hi>\n"
     * 'I' if interrupt bit (bit63) set, 'E' otherwise */
    li    t2, 0xA0000000
    li    t1, 'T'
    sw    t1, 0(t2)
    csrr  t0, mcause
    bltz  t0, 1f             /* branch if bit 63 set (interrupt) */
    li    t1, 'E'
    j     2f
1:  li    t1, 'I'
2:  sw    t1, 0(t2)
    /* print lower nibble of mcause */
    csrr  t0, mcause
    andi  t3, t0, 0xF
    li    t4, 10
    blt   t3, t4, 1f
    addi  t3, t3, ('a'-10)
    j     2f
1:  addi  t3, t3, '0'
2:  sw    t3, 0(t2)
    /* print upper nibble */
    srli  t3, t0, 4
    andi  t3, t3, 0xF
    li    t4, 10
    blt   t3, t4, 3f
    addi  t3, t3, ('a'-10)
    j     4f
3:  addi  t3, t3, '0'
4:  sw    t3, 0(t2)
    li    t1, '\n'
    sw    t1, 0(t2)
5:  j     5b

/* ================================================================
 *  main
 * ================================================================ */
main:
    /* --- Disable all interrupts up front --- */
    csrw  mie, zero           /* clear all interrupt enables */
    csrci mstatus, 8          /* clear mstatus.MIE */

    /* --- Step 1: Install M-mode trap handler --- */
.option push
.option norelax
.Ltvec_hi:
    auipc t0, %pcrel_hi(m_trap_handler)
    addi  t0, t0, %pcrel_lo(.Ltvec_hi)
.option pop
    csrw  mtvec, t0

    /* Checkpoint: print 'M' to confirm we reached main */
    li    t0, 0xA0000000
    li    t1, 'M'
    sw    t1, 0(t0)

    /* --- Checkpoint A: after mtvec setup, before page table writes --- */
    li    t1, 'A'
    sw    t1, 0(t0)

    /* --- Step 2: Build root page table at physical 0x10006000 ---
     *
     * Entry [0] (offset 0):  1G identity map for [0x00000000, 0x3FFFFFFF]
     *   PA of 1G page = 0x00000000 → PPN = 0
     *   PTE = (PPN << 10) | flags = (0 << 10) | 0xCF = 0xCF
     *   flags: D=1,A=1,G=0,U=0,X=1,W=1,R=1,V=1 = 0xCF
     *
     * Entry [2] (offset 16): 1G identity map for [0x80000000, 0xBFFFFFFF]
     *   PA of 1G page = 0x80000000 → PPN[43:0] = PA>>12 = 0x80000
     *   PTE = (0x80000 << 10) | 0xCF = 0x20000000 | 0xCF = 0x200000CF
     */
    li    t0, 0x10006000        /* root page table base */

    /* Entry [0]: covers 0x00000000..0x3FFFFFFF (DRAM + peripherals) */
    li    t1, 0xCF
    sd    t1, 0(t0)

    /* Entry [2]: covers 0x80000000..0xBFFFFFFF (IRAM + UART intercept) */
    lui   t1, 0x20000           /* 0x20000000 */
    ori   t1, t1, 0xCF
    sd    t1, 16(t0)            /* offset = 2 * 8 = 16 */

    /* --- Checkpoint B: after page table stores --- */
    li    t0, 0xA0000000
    li    t1, 'B'
    sw    t1, 0(t0)

    /* --- Step 3: Write satp = MODE(8) | ASID(0) | PPN(root_pt>>12)
     *   root PPN = 0x10006000 >> 12 = 0x10006
     */
    li    t2, 0x10006           /* root page table PPN */
    li    t0, 8
    slli  t0, t0, 60            /* MODE = 8 (Sv39) in bits 63:60 */
    or    t0, t0, t2
    csrw  satp, t0
    sfence.vma                  /* flush all TLBs */

    /* --- Step 4: Switch to S-mode via MRET ---
     *   mstatus.MPP = 01 (S-mode): clear bit 12 (MPP[1]), set bit 11 (MPP[0])
     */
    li    t0, (1 << 12)
    csrc  mstatus, t0           /* clear MPP[1] */
    li    t0, (1 << 11)
    csrs  mstatus, t0           /* set  MPP[0] → MPP = 01 = S-mode */
    li    t0, (1 << 7)
    csrs  mstatus, t0           /* set MPIE */
.option push
.option norelax
.Lmepc_hi:
    auipc t0, %pcrel_hi(in_s_mode)
    addi  t0, t0, %pcrel_lo(.Lmepc_hi)
.option pop
    csrw  mepc, t0
    mret                        /* → S-mode at in_s_mode; MMU now active */

/* ================================================================
 *  S-mode code path (MMU active, identity mapping)
 * ================================================================ */
in_s_mode:
    /* Checkpoint: print 'S' to confirm we're in S-mode */
    li    t0, 0xA0000000
    li    t1, 'S'
    sw    t1, 0(t0)

    /* --- Test 1: D-TLB store+load round-trip ---
     *   Write 0xABCD1234 to 0x10000100, read back, verify.
     *   This exercises the D-TLB with a 1G superpage hit.
     */
    li    t0, 0x10000100
    li    t1, 0xABCD1234
    sw    t1, 0(t0)
    lwu   t2, 0(t0)       /* lwu: zero-extend; lw would sign-extend 0xABCD1234 */
    bne   t1, t2, test_fail

    /* --- Test 2: Load page fault from unmapped address ---
     *   VA = 0x40000000 → VPN[2] = 1, no page table entry → load PF (cause 13)
     *   The M-mode handler will set s0=1 and MRET here+4.
     */
    li    s0, 0                 /* clear flag */
    li    t0, 0x40000000
    lw    t1, 0(t0)             /* ← this load should fault; handler sets s0=1 */
    /* Execution resumes here after MRET from trap handler */
    li    t0, 1
    bne   s0, t0, test_fail     /* if s0 != 1, page fault didn't fire */

    /* --- All tests passed: print "PASS\n" to UART intercept --- */
    li    t0, 0xA0000000
    li    t1, 'P'
    sw    t1, 0(t0)
    li    t1, 'A'
    sw    t1, 0(t0)
    li    t1, 'S'
    sw    t1, 0(t0)
    li    t1, 'S'
    sw    t1, 0(t0)
    li    t1, '\n'
    sw    t1, 0(t0)
    j     test_done

test_fail:
    li    t0, 0xA0000000
    li    t1, 'F'
    sw    t1, 0(t0)
    li    t1, 'A'
    sw    t1, 0(t0)
    li    t1, 'I'
    sw    t1, 0(t0)
    li    t1, 'L'
    sw    t1, 0(t0)
    li    t1, '\n'
    sw    t1, 0(t0)

test_done:
    j     test_done             /* spin forever (sim exits on cycle limit) */
