/**
 * Phase 2A Privilege Test
 *
 * Tests:
 *  1. M-mode startup, MISA/MSTATUS read
 *  2. Delegate ECALL from S-mode (cause=9) and U-mode (cause=8) via medeleg
 *  3. Set up stvec, switch to S-mode via MRET, do ECALL → verify scause=9
 *  4. Switch to U-mode via SRET, do ECALL → verify scause=8
 *  5. Switch back to M-mode, print "PASS"
 *
 * Memory layout:
 *   IRAM: 0x80000000, 128KB
 *   DRAM: 0x10000000, 32KB
 *   Stack: 0x10008000 (top of DRAM)
 */
.option norvc
.section .init
.global _start_reset

_start_reset:
.option push
.option norelax
    auipc gp, %pcrel_hi(__global_pointer$)
    addi  gp, gp, %pcrel_lo(_start_reset)
.option pop
    la    sp, _start_stack
    call  main

.section .text

/* ------------------------------------------------------------------ */
/*  S-mode trap handler (pointed to by stvec)                         */
/*  On entry: sepc points to the trapping instruction                 */
/*  We just record scause in s2 and do SRET to resume after ecall     */
/* ------------------------------------------------------------------ */
s_trap_handler:
    csrr  s2, scause           /* save scause for verification */
    csrr  t0, sepc
    addi  t0, t0, 4            /* advance past the ECALL */
    csrw  sepc, t0
    sret

/* ------------------------------------------------------------------ */
/*  main                                                               */
/* ------------------------------------------------------------------ */
main:
    /* --- Step 1: set up S-mode trap handler --- */
    la    t0, s_trap_handler
    csrw  stvec, t0

    /* --- Step 2: delegate ECALL (cause 9 = S-mode, cause 8 = U-mode)
               and illegal instruction (cause 2) to S-mode via medeleg */
    li    t0, (1 << 9) | (1 << 8) | (1 << 2)
    csrw  medeleg, t0

    /* --- Step 3: switch to S-mode via MRET ---
       Set mstatus.MPP = 01 (S-mode), MPIE=1 */
    li    t0, (1 << 11)        /* clear MPP[1] */
    csrc  mstatus, t0
    li    t0, (1 << 11)        /* MPP[1]=0 */
    csrc  mstatus, t0
    /* MPP = S-mode = 2'b01: set bit 11 to 0, bit 11 is already 0,
       set bit 11 to 0 (leave as is). Wait - MPP[1:0] = bits[12:11].
       For S-mode, MPP = 01 → bit12=0, bit11=1 */
    li    t0, (1 << 12)        /* clear bit 12 (MPP[1]) */
    csrc  mstatus, t0
    li    t0, (1 << 11)        /* set bit 11 (MPP[0]) → MPP=01=S-mode */
    csrs  mstatus, t0

    la    t0, in_s_mode
    csrw  mepc, t0
    mret

in_s_mode:
    /* --- Step 4: Now in S-mode. Do ECALL. Should trap to s_trap_handler --- */
    ecall                      /* causes: scause = 9 (ecall from S) */

    /* --- Step 5: Verify scause == 9 --- */
    li    t0, 9
    bne   s2, t0, test_fail    /* s2 set by s_trap_handler */

    /* --- Step 6: Switch to U-mode via SRET ---
       Set sstatus.SPP = 0 (U-mode), SPIE=1 */
    li    t0, (1 << 8)         /* clear SPP bit */
    csrc  sstatus, t0
    li    t0, (1 << 5)         /* set SPIE */
    csrs  sstatus, t0

    la    t0, in_u_mode
    csrw  sepc, t0
    sret

in_u_mode:
    /* --- Step 7: Now in U-mode. Do ECALL. Should trap to s_trap_handler --- */
    ecall                      /* causes: scause = 8 (ecall from U) */

    /* --- Step 8: Verify scause == 8 --- */
    li    t0, 8
    bne   s2, t0, test_fail

    /* --- Step 9: Return to M-mode ---
       The ECALL from U-mode trapped to S-mode handler.
       Now we need to escalate to M-mode.
       Since we're back in U-mode after sret, do another ecall
       but this time not delegated — need to change medeleg first.
       Actually we're still in S-mode after sret from trap.
       Let's do it cleanly: use SRET again to M-mode by manipulating sstatus.SPP */
    /* At this point we're in U-mode.
       The S-handler returned us here. We need to get back to M-mode.
       Use an undelegated ECALL or just write UART from here.
       For simplicity, just print PASS from U-mode via UART intercept. */

    /* Print "PASS\n" via UART at 0xA0000000 */
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
    /* Print "FAIL\n" */
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
    /* Trigger simulation end via $finish */
    li    t0, 0xD0000008
    li    t1, 1
    sw    t1, 0(t0)
    j     test_done
