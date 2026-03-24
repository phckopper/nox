/*
 * RV32M functional test — exercises MUL, MULH, MULHSU, MULHU,
 * DIV, DIVU, REM, REMU including corner cases.
 *
 * Prints "PASS" or a description of the failure via UART simulation.
 * Memory-mapped UART: write a byte to 0xA000_0000 to print it.
 */

#include <stdint.h>

#define UART_ADDR  ((volatile uint32_t *)0xA0000000)

static void uart_putc(char c) {
    *UART_ADDR = (uint32_t)c;
}

static void uart_puts(const char *s) {
    while (*s) uart_putc(*s++);
}

static void uart_hex(uint32_t v) {
    const char hex[] = "0123456789ABCDEF";
    uart_putc('0'); uart_putc('x');
    for (int i = 7; i >= 0; i--)
        uart_putc(hex[(v >> (i * 4)) & 0xF]);
}

static int failures = 0;

static void check(const char *name, uint32_t got, uint32_t expected) {
    if (got != expected) {
        uart_puts("FAIL ");
        uart_puts(name);
        uart_puts(" got=");
        uart_hex(got);
        uart_puts(" exp=");
        uart_hex(expected);
        uart_puts("\n");
        failures++;
    }
}

/* Force the compiler to use hardware mul/div instructions */
__attribute__((noinline))
static uint32_t hw_mul(uint32_t a, uint32_t b) {
    uint32_t r;
    __asm__ volatile("mul %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
__attribute__((noinline))
static uint32_t hw_mulh(int32_t a, int32_t b) {
    uint32_t r;
    __asm__ volatile("mulh %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
__attribute__((noinline))
static uint32_t hw_mulhu(uint32_t a, uint32_t b) {
    uint32_t r;
    __asm__ volatile("mulhu %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
__attribute__((noinline))
static uint32_t hw_mulhsu(int32_t a, uint32_t b) {
    uint32_t r;
    __asm__ volatile("mulhsu %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
__attribute__((noinline))
static int32_t hw_div(int32_t a, int32_t b) {
    int32_t r;
    __asm__ volatile("div %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
__attribute__((noinline))
static uint32_t hw_divu(uint32_t a, uint32_t b) {
    uint32_t r;
    __asm__ volatile("divu %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
__attribute__((noinline))
static int32_t hw_rem(int32_t a, int32_t b) {
    int32_t r;
    __asm__ volatile("rem %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}
__attribute__((noinline))
static uint32_t hw_remu(uint32_t a, uint32_t b) {
    uint32_t r;
    __asm__ volatile("remu %0, %1, %2" : "=r"(r) : "r"(a), "r"(b));
    return r;
}

int main(void) {
    uart_puts("MulDiv Test\n");

    /* MUL: lower 32 bits */
    check("MUL 6*7",    hw_mul(6, 7),               42);
    check("MUL 0*x",    hw_mul(0, 0xDEADBEEF),      0);
    check("MUL -1*-1",  hw_mul((uint32_t)-1, (uint32_t)-1), 1);
    check("MUL 1000*1000", hw_mul(1000, 1000),       1000000);
    check("MUL hi",     hw_mul(0x80000000, 2),       0);  /* overflow wraps */
    check("MUL neg",    hw_mul((uint32_t)-5, 3),     (uint32_t)-15);

    /* MULH: upper 32, signed*signed */
    check("MULH 6*7",       hw_mulh(6, 7),           0);
    check("MULH -1*-1",     hw_mulh(-1, -1),         0);
    check("MULH MIN*-1",    hw_mulh(-2147483648, -1),(int32_t)0);  /* 2^31 fits in upper */
    check("MULH 0x80000000*2", hw_mulh(-2147483648, 2), (int32_t)0xFFFFFFFF); /* -2^32 upper */

    /* MULHU: upper 32, unsigned*unsigned */
    check("MULHU 1*1",      hw_mulhu(1, 1),          0);
    check("MULHU max*max",  hw_mulhu(0xFFFFFFFF, 0xFFFFFFFF), 0xFFFFFFFE);
    check("MULHU 0x10000*0x10000", hw_mulhu(0x10000, 0x10000), 1); /* 2^32 */

    /* MULHSU: upper 32, signed*unsigned */
    check("MULHSU 1*1",     hw_mulhsu(1, 1),         0);
    check("MULHSU -1*1",    hw_mulhsu(-1, 1),        0xFFFFFFFF); /* -1 * 1 = -1, upper = -1 */
    check("MULHSU -1*2",    hw_mulhsu(-1, 2),        0xFFFFFFFF); /* -2 upper = 0xFFFFFFFF */

    /* DIV: signed */
    check("DIV 20/4",    (uint32_t)hw_div(20, 4),    5);
    check("DIV -20/4",   (uint32_t)hw_div(-20, 4),   (uint32_t)-5);
    check("DIV 20/-4",   (uint32_t)hw_div(20, -4),   (uint32_t)-5);
    check("DIV -20/-4",  (uint32_t)hw_div(-20, -4),  5);
    check("DIV /0",      (uint32_t)hw_div(1, 0),     0xFFFFFFFF);  /* div by zero */
    check("DIV MIN/-1",  (uint32_t)hw_div(-2147483648, -1), (uint32_t)-2147483648); /* overflow */

    /* DIVU: unsigned */
    check("DIVU 20/4",   hw_divu(20, 4),             5);
    check("DIVU max/2",  hw_divu(0xFFFFFFFF, 2),     0x7FFFFFFF);
    check("DIVU /0",     hw_divu(5, 0),              0xFFFFFFFF);

    /* REM: signed */
    check("REM 20%7",    (uint32_t)hw_rem(20, 7),    6);
    check("REM -20%7",   (uint32_t)hw_rem(-20, 7),   (uint32_t)-6);
    check("REM 20%-7",   (uint32_t)hw_rem(20, -7),   6);
    check("REM -20%-7",  (uint32_t)hw_rem(-20, -7),  (uint32_t)-6);
    check("REM %0",      (uint32_t)hw_rem(42, 0),    42);  /* rem by zero = dividend */
    check("REM MIN%-1",  (uint32_t)hw_rem(-2147483648, -1), 0); /* overflow rem = 0 */

    /* REMU: unsigned */
    check("REMU 20%7",   hw_remu(20, 7),             6);
    check("REMU max%3",  hw_remu(0xFFFFFFFF, 3),     0);   /* 0xFFFFFFFF = 3*1431655765 */
    check("REMU %0",     hw_remu(7, 0),              7);

    if (failures == 0)
        uart_puts("ALL PASS\n");
    else {
        uart_puts("FAILURES: ");
        uart_putc('0' + failures);
        uart_putc('\n');
    }

    /* Halt: infinite loop, $finish will be called by sim timeout */
    while (1) {}
    return 0;
}
