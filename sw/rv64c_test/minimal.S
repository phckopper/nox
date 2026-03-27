# Minimal RV64C test — just one compressed instruction
.option push
.option norvc
.section .text
.globl _start
_start:
    li   a0, 0xD0000008      # UART address
    li   t0, 0               # accumulator
    li   t1, 10              # expected

.option pop
.option rvc
    c.addi t0, 10            # t0 = 10
.option push
.option norvc

    bne  t0, t1, fail

    # Print OK
    li   t0, 'O'
    sw   t0, 0(a0)
    li   t0, 'K'
    sw   t0, 0(a0)
    li   t0, '\n'
    sw   t0, 0(a0)

    # Terminate
    li   t0, 0xD0000000
    sw   zero, 0(t0)
    j    .

fail:
    li   t0, 'F'
    sw   t0, 0(a0)
    li   t0, '\n'
    sw   t0, 0(a0)
    li   t0, 0xD0000000
    sw   zero, 0(t0)
    j    .

.option pop
