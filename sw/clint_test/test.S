/**
 * Phase 2B CLINT + PLIC Interrupt Test - Debug version
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

m_trap_handler:
    csrr  t0, mcause
    la    t1, last_mcause
    sd    t0, 0(t1)
    la    t1, trap_count
    ld    t0, 0(t1)
    addi  t0, t0, 1
    sd    t0, 0(t1)
    la    t1, last_mcause
    ld    t0, 0(t1)
    li    t1, 7
    li    t2, 1
    slli  t2, t2, 63
    or    t1, t1, t2
    beq   t0, t1, .Lclear_timer
    li    t1, 3
    li    t2, 1
    slli  t2, t2, 63
    or    t1, t1, t2
    beq   t0, t1, .Lclear_sw
    mret

.Lclear_timer:
    li    t0, 0x02000000
    li    t1, 0x4008
    add   t0, t0, t1
    li    t1, -1
    sd    t1, 0(t0)
    li    t1, (1<<7)
    csrc  mie, t1
    mret

.Lclear_sw:
    li    t0, 0x02000000
    sw    zero, 0(t0)
    li    t1, (1<<3)
    csrc  mie, t1
    mret

.global main
main:
    la    t0, m_trap_handler
    csrw  mtvec, t0

    la    a0, str_start
    call  puts

    /* Read mtime */
    li    t0, 0x02000000
    li    t1, 0xBFF0
    add   t0, t0, t1
    ld    t1, 0(t0)

    la    a0, str_after_mtime
    call  puts

    /* Set mtimecmp = mtime + 500 */
    addi  t1, t1, 500
    li    t0, 0x02000000
    li    t2, 0x4008
    add   t0, t0, t2
    sd    t1, 0(t0)

    la    a0, str_after_mtimecmp
    call  puts

    /* Enable MTIE + MIE */
    li    t1, (1<<7)
    csrs  mie, t1
    csrsi mstatus, (1<<3)

    li    t2, 50000
.Lwait_timer:
    la    t0, trap_count
    ld    t1, 0(t0)
    bnez  t1, .Ltimer_ok
    addi  t2, t2, -1
    bnez  t2, .Lwait_timer
    la    a0, str_fail_timer
    call  puts
    j     .Ldone

.Ltimer_ok:
    la    a0, str_timer_fired
    call  puts

    la    t0, last_mcause
    ld    t0, 0(t0)
    li    t1, 7
    li    t2, 1
    slli  t2, t2, 63
    or    t1, t1, t2
    bne   t0, t1, .Lfail_timer_cause

    /* TEST 2: SW interrupt */
    la    t0, trap_count
    sd    zero, 0(t0)
    li    t1, (1<<3)
    csrs  mie, t1
    li    t0, 0x02000000
    li    t1, 1
    sw    t1, 0(t0)

    li    t2, 50000
.Lwait_sw:
    la    t0, trap_count
    ld    t1, 0(t0)
    bnez  t1, .Lsw_ok
    addi  t2, t2, -1
    bnez  t2, .Lwait_sw
    la    a0, str_fail_sw
    call  puts
    j     .Ldone

.Lsw_ok:
    la    t0, last_mcause
    ld    t0, 0(t0)
    li    t1, 3
    li    t2, 1
    slli  t2, t2, 63
    or    t1, t1, t2
    bne   t0, t1, .Lfail_sw_cause

    /* TEST 3: PLIC read-back */
    li    t0, 0x0C000000
    li    t1, 4
    add   t2, t0, t1
    li    t1, 3
    sw    t1, 0(t2)

    li    t1, 0x2000
    add   t2, t0, t1
    li    t1, 2
    sw    t1, 0(t2)

    li    t1, 0x200000
    add   t2, t0, t1
    sw    zero, 0(t2)

    li    t1, 4
    add   t2, t0, t1
    lw    t1, 0(t2)
    andi  t1, t1, 7
    li    t3, 3
    bne   t1, t3, .Lfail_plic

    li    t1, 0x2000
    add   t2, t0, t1
    lw    t1, 0(t2)
    andi  t1, t1, 2
    li    t3, 2
    bne   t1, t3, .Lfail_plic

    li    t1, 0x200000
    add   t2, t0, t1
    lw    t1, 0(t2)
    andi  t1, t1, 7
    bnez  t1, .Lfail_plic

    la    a0, str_pass
    call  puts
    j     .Ldone

.Lfail_timer_cause:
    la    a0, str_fail_timer_cause
    call  puts
    j     .Ldone

.Lfail_sw_cause:
    la    a0, str_fail_sw_cause
    call  puts
    j     .Ldone

.Lfail_plic:
    la    a0, str_fail_plic
    call  puts

.Ldone:
1:  wfi
    j     1b

puts:
    li    t0, 0xA0000000
.Lputs_loop:
    lb    t1, 0(a0)
    beqz  t1, .Lputs_ret
    sw    t1, 0(t0)
    addi  a0, a0, 1
    j     .Lputs_loop
.Lputs_ret:
    ret

.section .rodata
str_start:            .asciz "START\n"
str_after_mtime:      .asciz "MTIME OK\n"
str_after_mtimecmp:   .asciz "MTIMECMP OK\n"
str_timer_fired:      .asciz "TIMER FIRED\n"
str_pass:             .asciz "PASS\n"
str_fail_timer:       .asciz "FAIL: timer timeout\n"
str_fail_timer_cause: .asciz "FAIL: timer mcause\n"
str_fail_sw:          .asciz "FAIL: sw timeout\n"
str_fail_sw_cause:    .asciz "FAIL: sw mcause\n"
str_fail_plic:        .asciz "FAIL: PLIC readback\n"

.section .bss
.align 3
last_mcause: .skip 8
trap_count:  .skip 8
