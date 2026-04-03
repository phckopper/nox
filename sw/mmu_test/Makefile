CROSS  ?= riscv-none-embed-
MARCH  ?= rv64imc_zicsr
MABI   ?= lp64
CC     := $(CROSS)gcc
OBJCOPY ?= $(CROSS)objcopy

CFLAGS = -march=$(MARCH) -mabi=$(MABI) -mcmodel=medany -nostartfiles -static

LDSCRIPT = ../coremark/sections.ld

TARGET = mmu_test.elf

all: $(TARGET)

$(TARGET): test.S $(LDSCRIPT)
	$(CC) $(CFLAGS) -T $(LDSCRIPT) -o $@ $<

clean:
	rm -f $(TARGET)

.PHONY: all clean
