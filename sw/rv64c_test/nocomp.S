# Test with NO compressed instructions to verify new fetch + store
.option norvc
.section .text
.globl _start
_start:
    li   a0, 0xA0000000
    # Warm up: some NOPs so the first store doesn't arrive too early
    nop
    nop
    nop
    nop
    li   t0, 'H'
    sb   t0, 0(a0)
    li   t0, 'I'
    sb   t0, 0(a0)
    li   t0, '\n'
    sb   t0, 0(a0)
    li   t0, 0xC0000000
    sw   zero, 0(t0)
    j    .
