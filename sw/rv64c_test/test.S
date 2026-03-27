# RV64IC compressed instruction test
# Tests basic C extension instruction expansion and execution
# Output: "OK\nPASS\n" via UART at 0xA0000000

.option push
.option norvc    # Start with non-compressed for setup

.section .text
.globl _start
_start:
    # Setup: use non-compressed instructions to set up base values
    li   a0, 0xA0000000      # UART print address
    li   sp, 0x10001000      # stack pointer (in DRAM region)
    li   t0, 0               # test accumulator
    li   t1, 42              # test value

.option pop
.option rvc      # Enable compressed instructions

    # --- Test 1: C.ADDI ---
    c.addi t0, 10            # t0 = 0 + 10 = 10
    c.addi t0, 21            # t0 = 10 + 21 = 31
    c.addi t0, 11            # t0 = 31 + 11 = 42

    # Compare t0 == t1 (both should be 42)
    bne  t0, t1, fail

    # --- Test 2: C.LI ---
    c.li   t2, 7             # t2 = 7
    li     t3, 7             # t3 = 7 (non-compressed)
    bne    t2, t3, fail

    # --- Test 3: C.MV ---
    c.mv   t4, t1            # t4 = t1 = 42
    bne    t4, t1, fail

    # --- Test 4: C.ADD ---
    c.li   t5, 20            # t5 = 20
    c.add  t5, t1            # t5 = 20 + 42 = 62
    li     t6, 62
    bne    t5, t6, fail

    # --- Test 5: C.SUB ---
    c.li   s0, 30            # s0 = 30
    c.li   s1, 8             # s1 = 8
    c.sub  s0, s1            # s0 = 30 - 8 = 22
    li     t2, 22
    bne    s0, t2, fail

    # --- Test 6: C.SLLI ---
    c.li   t0, 1             # t0 = 1
    c.slli t0, 5             # t0 = 1 << 5 = 32
    li     t2, 32
    bne    t0, t2, fail

    # --- Test 7: C.SRLI ---
    c.li   s0, -1            # s0 = 0xFFFF...FFFF
    c.srli s0, 60            # s0 = 0xF (logical shift right 60)
    li     t2, 0xF
    bne    s0, t2, fail

    # --- Test 8: C.ANDI ---
    c.li   s0, -1            # s0 = all 1s
    c.andi s0, 0x1F          # s0 = 0x1F
    li     t2, 0x1F
    bne    s0, t2, fail

    # --- Test 9: C.ADDIW ---
    li     s0, 0x7FFFFFFF    # max 32-bit signed
    c.addiw s0, 1            # s0 = 0x80000000 sign-extended to 0xFFFFFFFF80000000
    li     t2, -2147483648   # same value
    bne    s0, t2, fail

    # --- Test 10: C.LWSP / C.SWSP ---
    c.li   t0, 29            # t0 = 29
    addi   sp, sp, -16       # make stack space
    c.swsp t0, 0(sp)         # store on stack
    c.li   t0, 0             # clear t0
    c.lwsp t0, 0(sp)         # reload from stack
    addi   sp, sp, 16        # restore stack
    li     t2, 29
    bne    t0, t2, fail

    # --- Test 11: C.J ---
    c.j    test11_target
    j      fail              # should not reach here
test11_target:

    # --- Test 12: C.BEQZ ---
    c.li   s0, 0
    c.beqz s0, test12_target
    j      fail
test12_target:

    # --- Test 13: C.BNEZ ---
    c.li   s0, 1
    c.bnez s0, test13_target
    j      fail
test13_target:

.option push
.option norvc

    # All tests passed — print "OK\nPASS\n"
    li   t0, 'O'
    sb   t0, 0(a0)
    li   t0, 'K'
    sb   t0, 0(a0)
    li   t0, '\n'
    sb   t0, 0(a0)
    li   t0, 'P'
    sb   t0, 0(a0)
    li   t0, 'A'
    sb   t0, 0(a0)
    li   t0, 'S'
    sb   t0, 0(a0)
    li   t0, 'S'
    sb   t0, 0(a0)
    li   t0, '\n'
    sb   t0, 0(a0)

    # Terminate simulation
    li   t0, 0xC0000000
    sw   zero, 0(t0)
    j    .

fail:
    li   t0, 'F'
    sb   t0, 0(a0)
    li   t0, 'A'
    sb   t0, 0(a0)
    li   t0, 'I'
    sb   t0, 0(a0)
    li   t0, 'L'
    sb   t0, 0(a0)
    li   t0, '\n'
    sb   t0, 0(a0)
    li   t0, 0xC0000000
    sw   zero, 0(t0)
    j    .

.option pop
