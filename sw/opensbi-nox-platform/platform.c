// SPDX-License-Identifier: BSD-2-Clause
// OpenSBI minimal platform for NoX RV64 SoC
//
// Memory map:
//   0x02000000  CLINT  (mtime/mtimecmp/msip)
//   0x0C000000  PLIC   (1 external source, M+S contexts)
//   0x10000000  UART   (NS16550A, byte-width registers)
//   0x80000000  RAM    (64 MB)

#include <sbi/riscv_asm.h>
#include <sbi/riscv_encoding.h>
#include <sbi/sbi_const.h>
#include <sbi/sbi_platform.h>
#include <sbi_utils/ipi/aclint_mswi.h>
#include <sbi_utils/irqchip/plic.h>
#include <sbi_utils/serial/uart8250.h>
#include <sbi_utils/timer/aclint_mtimer.h>

// ---- Peripheral addresses ----
#define NOX_CLINT_ADDR       0x02000000UL
#define NOX_PLIC_ADDR        0x0C000000UL
#define NOX_PLIC_SIZE        0x04000000UL
#define NOX_UART_ADDR        0x10000000UL

// CLINT layout (standard ACLINT):
//   MSWI  at CLINT_BASE + CLINT_MSWI_OFFSET   = 0x02000000
//   MTIMER at CLINT_BASE + CLINT_MTIMER_OFFSET = 0x02004000
//     MTIMECMP at MTIMER + 0x0000 = 0x02004000
//     MTIME    at MTIMER + 0x7FF8 = 0x0200BFF8
#define NOX_CLINT_MSWI_ADDR  (NOX_CLINT_ADDR + CLINT_MSWI_OFFSET)
#define NOX_CLINT_MTIMER_ADDR (NOX_CLINT_ADDR + CLINT_MTIMER_OFFSET)

// timebase-frequency in DTS = 10 MHz → mtime ticks per second
#define NOX_MTIME_FREQ       10000000UL

#define NOX_HART_COUNT       1

// ---- PLIC ----
// context_map[hart][PLIC_M_CONTEXT=0 / PLIC_S_CONTEXT=1] = context index
// Context 0 = M-mode (threshold 0x200000, claim 0x200004)
// Context 1 = S-mode (threshold 0x201000, claim 0x201004)
static struct {
	struct plic_data d;
	s16 map[NOX_HART_COUNT][2];
} nox_plic = {
	.d = {
		.unique_id = 0,
		.addr      = NOX_PLIC_ADDR,
		.size      = NOX_PLIC_SIZE,
		.num_src   = 1,
	},
	.map = { { 0, 1 } },   // hart 0: M-ctx=0, S-ctx=1
};

// ---- CLINT MSWI (software interrupts) ----
static struct aclint_mswi_data nox_mswi = {
	.addr        = NOX_CLINT_MSWI_ADDR,
	.size        = ACLINT_MSWI_SIZE,
	.first_hartid = 0,
	.hart_count  = NOX_HART_COUNT,
};

// ---- CLINT MTIMER (timer) ----
static struct aclint_mtimer_data nox_mtimer = {
	.mtime_freq     = NOX_MTIME_FREQ,
	.mtime_addr     = NOX_CLINT_MTIMER_ADDR + ACLINT_DEFAULT_MTIME_OFFSET,
	.mtime_size     = ACLINT_DEFAULT_MTIME_SIZE,
	.mtimecmp_addr  = NOX_CLINT_MTIMER_ADDR + ACLINT_DEFAULT_MTIMECMP_OFFSET,
	.mtimecmp_size  = ACLINT_DEFAULT_MTIMECMP_SIZE,
	.first_hartid   = 0,
	.hart_count     = NOX_HART_COUNT,
	.has_64bit_mmio = false,   // clint.sv exposes 32-bit registers at standard offsets
};

static int nox_early_init(bool cold_boot)
{
	int rc;

	if (!cold_boot)
		return 0;

	rc = uart8250_init(NOX_UART_ADDR, 50000000, 115200,
	                   0 /* reg_shift */,
	                   1 /* reg_width: byte */,
	                   0 /* reg_offset */,
	                   0 /* caps */);
	if (rc)
		return rc;

	return aclint_mswi_cold_init(&nox_mswi);
}

static int nox_final_init(bool cold_boot)
{
	return 0;
}

static int nox_irqchip_init(void)
{
	return plic_cold_irqchip_init(&nox_plic.d);
}

static int nox_timer_init(void)
{
	return aclint_mtimer_cold_init(&nox_mtimer, NULL);
}

const struct sbi_platform_operations platform_ops = {
	.early_init   = nox_early_init,
	.final_init   = nox_final_init,
	.irqchip_init = nox_irqchip_init,
	.timer_init   = nox_timer_init,
};

const struct sbi_platform platform = {
	.opensbi_version   = OPENSBI_VERSION,
	.platform_version  = SBI_PLATFORM_VERSION(0x0, 0x01),
	.name              = "NoX RV64",
	.features          = SBI_PLATFORM_DEFAULT_FEATURES,
	.hart_count        = NOX_HART_COUNT,
	.hart_stack_size   = SBI_PLATFORM_DEFAULT_HART_STACK_SIZE,
	.heap_size         = SBI_PLATFORM_DEFAULT_HEAP_SIZE(NOX_HART_COUNT),
	.platform_ops_addr = (unsigned long)&platform_ops,
};
