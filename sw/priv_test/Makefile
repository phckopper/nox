CROSS  ?= riscv-none-embed-
MARCH  ?= rv64imc
MABI   ?= lp64
LD     ?= $(CROSS)ld
CC     := riscv-none-embed-gcc
OBJCOPY ?= $(CROSS)objcopy

CFLAGS = -march=$(MARCH) -mabi=$(MABI) -mcmodel=medany -nostartfiles -static

LDSCRIPT = ../coremark/sections.ld

TARGET = priv_test.elf

all: $(TARGET)

$(TARGET): test.S $(LDSCRIPT)
	$(CC) $(CFLAGS) -T $(LDSCRIPT) -o $@ $<

clean:
	rm -f $(TARGET)

.PHONY: all clean
