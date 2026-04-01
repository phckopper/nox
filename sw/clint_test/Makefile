CC      := riscv-none-embed-gcc
MARCH   ?= rv64imc
MABI    ?= lp64
LDSCRIPT = ../coremark/sections.ld
TARGET   = clint_test.elf

CFLAGS  := -march=$(MARCH) -mabi=$(MABI) -nostdlib -static -Wl,--gc-sections

all: $(TARGET)

$(TARGET): test.S $(LDSCRIPT)
	$(CC) $(CFLAGS) -T $(LDSCRIPT) -o $@ $<

clean:
	rm -f $(TARGET)
