OUTPUT_ARCH("riscv")
ENTRY(_start)

MEMORY
{
    IRAM(rxai!w) : ORIGIN = 0x80000000, LENGTH = 16K
    DRAM(wxa!ri) : ORIGIN = 0x10000000, LENGTH = 8K
}

SECTIONS
{
    .text : {
        *(.text*)
    } > IRAM
}
