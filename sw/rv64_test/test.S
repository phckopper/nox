# Minimal RV64 test — writes "OK\n" to UART and finishes
# UART address: 0xA0000000 (byte write triggers printf in axi_mem)
# Finish address: 0xC0000000 (write triggers $finish)

.section .text
.global _start

_start:
    # Set up stack (not really needed, but good practice)
    li sp, 0x10002000

    # Write 'O' to UART
    li t0, 0xA0000000
    li t1, 0x4F        # 'O'
    sb t1, 0(t0)

    # Write 'K' to UART
    li t1, 0x4B        # 'K'
    sb t1, 0(t0)

    # Write newline to UART
    li t1, 0x0A        # '\n'
    sb t1, 0(t0)

    # Test some RV64-specific operations
    # ADDIW: sign-extend 32-bit result
    li t2, 0x00000000FFFFFFFF
    addiw t3, t2, 1        # should give 0 (32-bit overflow wraps to 0, sign-extended)

    # LD/SD test
    li t4, 0x123456789ABCDEF0
    li t5, 0x10000000
    sd t4, 0(t5)           # store doubleword
    ld t6, 0(t5)           # load doubleword
    bne t4, t6, fail       # verify round-trip

    # SLLW/SRLW test
    li t2, 0x80000001
    slliw t3, t2, 1        # should give 0x00000002, sign-extended to 0x0000000000000002
    li t4, 2
    bne t3, t4, fail

    srliw t3, t2, 1        # 0x80000001 >> 1 = 0x40000000 (unsigned), sign-ext = 0x0000000040000000
    li t4, 0x40000000
    bne t3, t4, fail

    sraiw t3, t2, 1        # 0x80000001 >> 1 (arith) = 0xC0000000, sign-ext = 0xFFFFFFFFC0000000
    li t4, 0xFFFFFFFFC0000000
    bne t3, t4, fail

    # Write "PASS" to UART
    li t0, 0xA0000000
    li t1, 0x50        # 'P'
    sb t1, 0(t0)
    li t1, 0x41        # 'A'
    sb t1, 0(t0)
    li t1, 0x53        # 'S'
    sb t1, 0(t0)
    li t1, 0x53        # 'S'
    sb t1, 0(t0)
    li t1, 0x0A        # '\n'
    sb t1, 0(t0)

    # Finish simulation
    li t0, 0xC0000000
    sw zero, 0(t0)

    # Infinite loop (shouldn't reach here)
1:  j 1b

fail:
    # Write "FAIL" to UART
    li t0, 0xA0000000
    li t1, 0x46        # 'F'
    sb t1, 0(t0)
    li t1, 0x41        # 'A'
    sb t1, 0(t0)
    li t1, 0x49        # 'I'
    sb t1, 0(t0)
    li t1, 0x4C        # 'L'
    sb t1, 0(t0)
    li t1, 0x0A        # '\n'
    sb t1, 0(t0)

    # Finish simulation
    li t0, 0xC0000000
    sw zero, 0(t0)

1:  j 1b
