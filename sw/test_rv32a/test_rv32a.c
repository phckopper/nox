/* RV32A (Atomic) extension test for NOX.
 * Tests: LR.W, SC.W (success + fail + post-store), AMOSWAP.W, AMOADD.W,
 *        AMOXOR.W, AMOAND.W, AMOOR.W, AMOMIN.W, AMOMAX.W, AMOMINU.W, AMOMAXU.W,
 *        chained AMOs, and the LR/SC atomic-increment idiom.
 */

#include <stdint.h>

#define UART_ADDR  ((volatile uint32_t *)0xA0000000)
static void uart_putc(char c) { *UART_ADDR = (uint32_t)c; }
static void uart_puts(const char *s) { while (*s) uart_putc(*s++); }
static void uart_hex(uint32_t v) {
    static const char h[] = "0123456789ABCDEF";
    uart_putc('0'); uart_putc('x');
    for (int i = 7; i >= 0; i--) uart_putc(h[(v >> (i*4)) & 0xF]);
}

static int failures = 0;
static void check(const char *name, uint32_t got, uint32_t exp) {
    if (got != exp) {
        failures++;
        uart_puts("FAIL "); uart_puts(name);
        uart_puts(" got="); uart_hex(got);
        uart_puts(" exp="); uart_hex(exp);
        uart_puts("\n");
    }
}

/* Atomic instruction wrappers */
static inline uint32_t lr_w(volatile uint32_t *a) {
    uint32_t v;
    asm volatile ("lr.w %0, (%1)" : "=r"(v) : "r"(a) : "memory");
    return v;
}
static inline uint32_t sc_w(volatile uint32_t *a, uint32_t v) {
    uint32_t r;
    asm volatile ("sc.w %0, %2, (%1)" : "=r"(r) : "r"(a), "r"(v) : "memory");
    return r;
}
static inline uint32_t amoswap_w(volatile uint32_t *a, uint32_t v)
    { uint32_t r; asm volatile("amoswap.w %0,%2,(%1)":"=r"(r):"r"(a),"r"(v):"memory"); return r; }
static inline uint32_t amoadd_w(volatile uint32_t *a, uint32_t v)
    { uint32_t r; asm volatile("amoadd.w %0,%2,(%1)":"=r"(r):"r"(a),"r"(v):"memory"); return r; }
static inline uint32_t amoxor_w(volatile uint32_t *a, uint32_t v)
    { uint32_t r; asm volatile("amoxor.w %0,%2,(%1)":"=r"(r):"r"(a),"r"(v):"memory"); return r; }
static inline uint32_t amoand_w(volatile uint32_t *a, uint32_t v)
    { uint32_t r; asm volatile("amoand.w %0,%2,(%1)":"=r"(r):"r"(a),"r"(v):"memory"); return r; }
static inline uint32_t amoor_w(volatile uint32_t *a, uint32_t v)
    { uint32_t r; asm volatile("amoor.w %0,%2,(%1)":"=r"(r):"r"(a),"r"(v):"memory"); return r; }
static inline uint32_t amomin_w(volatile uint32_t *a, int32_t v)
    { uint32_t r; asm volatile("amomin.w %0,%2,(%1)":"=r"(r):"r"(a),"r"(v):"memory"); return r; }
static inline uint32_t amomax_w(volatile uint32_t *a, int32_t v)
    { uint32_t r; asm volatile("amomax.w %0,%2,(%1)":"=r"(r):"r"(a),"r"(v):"memory"); return r; }
static inline uint32_t amominu_w(volatile uint32_t *a, uint32_t v)
    { uint32_t r; asm volatile("amominu.w %0,%2,(%1)":"=r"(r):"r"(a),"r"(v):"memory"); return r; }
static inline uint32_t amomaxu_w(volatile uint32_t *a, uint32_t v)
    { uint32_t r; asm volatile("amomaxu.w %0,%2,(%1)":"=r"(r):"r"(a),"r"(v):"memory"); return r; }

/* Test data in DRAM */
volatile uint32_t mem[8];

void test_rv32a(void) {
    uint32_t old, sc_res;
    uart_puts("RV32A Test\n");

    /* ── LR.W ─────────────────────────────────────────────────────────── */
    mem[0] = 0xDEAD0001U;
    old = lr_w(&mem[0]);
    check("lr.w ret",      old,    0xDEAD0001U);
    check("lr.w mem",      mem[0], 0xDEAD0001U);

    /* ── SC.W success (after LR.W same address) ──────────────────────── */
    mem[0] = 0xDEAD0001U;
    lr_w(&mem[0]);
    sc_res = sc_w(&mem[0], 0xBEEF0002U);
    check("sc.w succ ret", sc_res,  0U);
    check("sc.w succ mem", mem[0],  0xBEEF0002U);

    /* ── SC.W failure (no prior LR.W) ────────────────────────────────── */
    mem[1] = 0x12345678U;
    sc_res = sc_w(&mem[1], 0xABCDABCDU);
    check("sc.w fail ret", sc_res,  1U);
    check("sc.w fail mem", mem[1],  0x12345678U);

    /* ── SC.W failure (LR.W to different address) ────────────────────── */
    mem[2] = 0x11111111U;
    mem[3] = 0x22222222U;
    lr_w(&mem[2]);
    sc_res = sc_w(&mem[3], 0x33333333U);
    check("sc.w diff fail ret", sc_res, 1U);
    check("sc.w diff fail mem", mem[3], 0x22222222U);

    /* ── SC.W failure (intervening store invalidates reservation) ─────── */
    mem[4] = 0xAAAAAAAAU;
    lr_w(&mem[4]);
    mem[4] = 0xBBBBBBBBU;   /* regular store → reservation cleared */
    sc_res = sc_w(&mem[4], 0xCCCCCCCCU);
    check("sc.w post-store fail ret", sc_res, 1U);
    check("sc.w post-store fail mem", mem[4], 0xBBBBBBBBU);

    /* ── AMOSWAP.W ────────────────────────────────────────────────────── */
    mem[0] = 0x00000010U;
    old = amoswap_w(&mem[0], 0x00000020U);
    check("amoswap old",   old,    0x00000010U);
    check("amoswap mem",   mem[0], 0x00000020U);

    /* ── AMOADD.W ─────────────────────────────────────────────────────── */
    mem[0] = 5U;
    old = amoadd_w(&mem[0], 3U);
    check("amoadd old",    old,    5U);
    check("amoadd mem",    mem[0], 8U);

    mem[0] = 0xFFFFFFFFU;
    old = amoadd_w(&mem[0], 1U);
    check("amoadd wrap old", old,    0xFFFFFFFFU);
    check("amoadd wrap mem", mem[0], 0x00000000U);

    /* ── AMOXOR.W ─────────────────────────────────────────────────────── */
    mem[0] = 0xAAAAAAAAU;
    old = amoxor_w(&mem[0], 0x55555555U);
    check("amoxor old",    old,    0xAAAAAAAAU);
    check("amoxor mem",    mem[0], 0xFFFFFFFFU);

    /* ── AMOAND.W ─────────────────────────────────────────────────────── */
    mem[0] = 0xFFFF0000U;
    old = amoand_w(&mem[0], 0x0F0F0F0FU);
    check("amoand old",    old,    0xFFFF0000U);
    check("amoand mem",    mem[0], 0x0F0F0000U);

    /* ── AMOOR.W ──────────────────────────────────────────────────────── */
    mem[0] = 0x0000FFFFU;
    old = amoor_w(&mem[0], 0xFFFF0000U);
    check("amoor old",     old,    0x0000FFFFU);
    check("amoor mem",     mem[0], 0xFFFFFFFFU);

    /* ── AMOMIN.W (signed) ────────────────────────────────────────────── */
    mem[0] = (uint32_t)5;
    old = amomin_w(&mem[0], 3);
    check("amomin old",    old,    (uint32_t)5);
    check("amomin mem",    mem[0], (uint32_t)3);

    mem[0] = (uint32_t)(-2);
    old = amomin_w(&mem[0], 1);
    check("amomin neg old", old,    (uint32_t)(-2));
    check("amomin neg mem", mem[0], (uint32_t)(-2));

    /* ── AMOMAX.W (signed) ────────────────────────────────────────────── */
    mem[0] = (uint32_t)3;
    old = amomax_w(&mem[0], 7);
    check("amomax old",    old,    (uint32_t)3);
    check("amomax mem",    mem[0], (uint32_t)7);

    mem[0] = (uint32_t)(-1);
    old = amomax_w(&mem[0], 0);
    check("amomax neg old", old,    (uint32_t)(-1));
    check("amomax neg mem", mem[0], (uint32_t)(0));

    /* ── AMOMINU.W (unsigned) ─────────────────────────────────────────── */
    mem[0] = 0xFFFFFFFFU;
    old = amominu_w(&mem[0], 0x7FFFFFFFU);
    check("amominu old",   old,    0xFFFFFFFFU);
    check("amominu mem",   mem[0], 0x7FFFFFFFU);

    /* ── AMOMAXU.W (unsigned) ─────────────────────────────────────────── */
    mem[0] = 0x00000001U;
    old = amomaxu_w(&mem[0], 0xFFFFFFFFU);
    check("amomaxu old",   old,    0x00000001U);
    check("amomaxu mem",   mem[0], 0xFFFFFFFFU);

    /* ── Chained AMOs ─────────────────────────────────────────────────── */
    mem[0] = 0U;
    amoadd_w(&mem[0], 10U);
    amoadd_w(&mem[0], 20U);
    amoadd_w(&mem[0], 30U);
    check("amoadd chain",  mem[0], 60U);

    /* ── LR/SC atomic-increment idiom ────────────────────────────────── */
    mem[0] = 100U;
    do {
        old    = lr_w(&mem[0]);
        sc_res = sc_w(&mem[0], old + 1U);
    } while (sc_res != 0);
    check("lr/sc incr",    mem[0], 101U);

    /* ── Summary ──────────────────────────────────────────────────────── */
    if (failures == 0)
        uart_puts("ALL PASS\n");
    else {
        uart_puts("FAILED: "); uart_hex(failures); uart_puts(" test(s)\n");
    }
}

int main(void) {
    test_rv32a();
    return 0;
}
