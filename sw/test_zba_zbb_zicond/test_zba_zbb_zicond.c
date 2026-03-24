/*
 * Zba / Zbb-subset / Zicond functional test
 *
 * Exercises every instruction added in P8-P10:
 *   Zba  : sh1add, sh2add, sh3add
 *   Zbb  : min, max, minu, maxu, andn, orn, xnor, sext.b, sext.h, zext.h
 *   Zicond: czero.eqz, czero.nez
 *
 * All instructions are encoded via .insn r so that GCC 10.2 (which lacks
 * mnemonics for these extensions) can still assemble them.
 *
 * R-type: .insn r opcode, funct3, funct7, rd, rs1, rs2
 *   opcode = 0x33 (OP)          funct3  funct7
 *   sh1add   f3=2   f7=0x10
 *   sh2add   f3=4   f7=0x10
 *   sh3add   f3=6   f7=0x10
 *   min      f3=4   f7=0x05
 *   max      f3=6   f7=0x05
 *   minu     f3=5   f7=0x05
 *   maxu     f3=7   f7=0x05
 *   andn     f3=7   f7=0x20
 *   orn      f3=6   f7=0x20
 *   xnor     f3=4   f7=0x20
 *   zext.h   f3=4   f7=0x04
 *   czero.eqz f3=5  f7=0x07
 *   czero.nez f3=7  f7=0x07
 *
 * OP-IMM (opcode=0x13): sext.b and sext.h
 *   sext.b   f3=1 (SLL slot) funct7=0x30 shamt=4  → imm=0x604
 *   sext.h   f3=1 (SLL slot) funct7=0x30 shamt=5  → imm=0x605
 *   .insn i  opcode, funct3, rd, rs1, simm  — use raw .word instead
 */

#include <stdint.h>

#define UART_ADDR  ((volatile uint32_t *)0xA0000000)

static void uart_putc(char c) { *UART_ADDR = (uint32_t)c; }
static void uart_puts(const char *s) { while (*s) uart_putc(*s++); }
static void uart_hex(uint32_t v) {
    const char h[] = "0123456789ABCDEF";
    uart_putc('0'); uart_putc('x');
    for (int i = 7; i >= 0; i--) uart_putc(h[(v >> (i*4)) & 0xF]);
}

static int failures = 0;
static void check(const char *name, uint32_t got, uint32_t expected) {
    if (got != expected) {
        uart_puts("FAIL "); uart_puts(name);
        uart_puts(" got="); uart_hex(got);
        uart_puts(" exp="); uart_hex(expected);
        uart_puts("\n");
        failures++;
    }
}

/* opcode=0x33 (OP), all R-type */
#define ZBA_SH1ADD(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x33,2,0x10,%0,%1,%2":"=r"(rd):"r"(rs1),"r"(rs2))
#define ZBA_SH2ADD(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x33,4,0x10,%0,%1,%2":"=r"(rd):"r"(rs1),"r"(rs2))
#define ZBA_SH3ADD(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x33,6,0x10,%0,%1,%2":"=r"(rd):"r"(rs1),"r"(rs2))

#define ZBB_MIN(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x33,4,0x05,%0,%1,%2":"=r"(rd):"r"(rs1),"r"(rs2))
#define ZBB_MAX(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x33,6,0x05,%0,%1,%2":"=r"(rd):"r"(rs1),"r"(rs2))
#define ZBB_MINU(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x33,5,0x05,%0,%1,%2":"=r"(rd):"r"(rs1),"r"(rs2))
#define ZBB_MAXU(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x33,7,0x05,%0,%1,%2":"=r"(rd):"r"(rs1),"r"(rs2))
#define ZBB_ANDN(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x33,7,0x20,%0,%1,%2":"=r"(rd):"r"(rs1),"r"(rs2))
#define ZBB_ORN(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x33,6,0x20,%0,%1,%2":"=r"(rd):"r"(rs1),"r"(rs2))
#define ZBB_XNOR(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x33,4,0x20,%0,%1,%2":"=r"(rd):"r"(rs1),"r"(rs2))
#define ZBB_ZEXTH(rd, rs1) \
    __asm__ volatile(".insn r 0x33,4,0x04,%0,%1,zero":"=r"(rd):"r"(rs1))

/* zext.h reuses rs2=x0; sext.b/h are OP-IMM encoded as .word */
/* sext.b: funct7=0x30 shamt=4 funct3=1 opcode=0x13 → imm = (0x30<<5)|4 = 0x604 */
/* sext.h: funct7=0x30 shamt=5 funct3=1 opcode=0x13 → imm = (0x30<<5)|5 = 0x605 */
#define ZBB_SEXTB(rd, rs1) \
    __asm__ volatile(".insn i 0x13,1,%0,%1,0x604":"=r"(rd):"r"(rs1))
#define ZBB_SEXTH(rd, rs1) \
    __asm__ volatile(".insn i 0x13,1,%0,%1,0x605":"=r"(rd):"r"(rs1))

/* Zicond: opcode=0x33 */
#define ZICOND_CZERO_EQZ(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x33,5,0x07,%0,%1,%2":"=r"(rd):"r"(rs1),"r"(rs2))
#define ZICOND_CZERO_NEZ(rd, rs1, rs2) \
    __asm__ volatile(".insn r 0x33,7,0x07,%0,%1,%2":"=r"(rd):"r"(rs1),"r"(rs2))

void main(void) {
    uint32_t r;
    uart_puts("Zba/Zbb/Zicond Test\n");

    /* ── Zba: sh1add  (rs1<<1) + rs2 ─────────────────────────────── */
    ZBA_SH1ADD(r, 3u, 10u);  check("sh1add(3,10)",  r, 16u);
    ZBA_SH1ADD(r, 0u, 5u);   check("sh1add(0,5)",   r,  5u);
    ZBA_SH1ADD(r, 7u, 0u);   check("sh1add(7,0)",   r, 14u);
    ZBA_SH1ADD(r, 0xFFFFFFFFu, 1u); check("sh1add(~0,1)", r, 0xFFFFFFFFu); /* (~0<<1)+1 = 0xFFFFFFFE+1 */

    /* ── Zba: sh2add  (rs1<<2) + rs2 ─────────────────────────────── */
    ZBA_SH2ADD(r, 3u, 10u); check("sh2add(3,10)", r, 22u);
    ZBA_SH2ADD(r, 1u, 0u);  check("sh2add(1,0)",  r,  4u);

    /* ── Zba: sh3add  (rs1<<3) + rs2 ─────────────────────────────── */
    ZBA_SH3ADD(r, 3u, 10u); check("sh3add(3,10)", r, 34u);
    ZBA_SH3ADD(r, 1u, 0u);  check("sh3add(1,0)",  r,  8u);

    /* ── Zbb: min (signed) ────────────────────────────────────────── */
    ZBB_MIN(r, 5u,  3u);  check("min(5,3)",   r, 3u);
    ZBB_MIN(r, (uint32_t)-1, 0u); check("min(-1,0)", r, (uint32_t)-1);
    ZBB_MIN(r, 0u, (uint32_t)-1); check("min(0,-1)", r, (uint32_t)-1);
    ZBB_MIN(r, 7u, 7u);  check("min(7,7)",    r, 7u);

    /* ── Zbb: max (signed) ────────────────────────────────────────── */
    ZBB_MAX(r, 5u,  3u);  check("max(5,3)",   r, 5u);
    ZBB_MAX(r, (uint32_t)-1, 0u); check("max(-1,0)", r, 0u);
    ZBB_MAX(r, 0u, (uint32_t)-1); check("max(0,-1)", r, 0u);

    /* ── Zbb: minu (unsigned) ─────────────────────────────────────── */
    ZBB_MINU(r, 5u,  3u);           check("minu(5,3)",    r, 3u);
    ZBB_MINU(r, 0xFFu, 0x80u);      check("minu(FF,80)",  r, 0x80u);
    ZBB_MINU(r, 0xFFFFFFFFu, 0u);   check("minu(~0,0)",   r, 0u);

    /* ── Zbb: maxu (unsigned) ─────────────────────────────────────── */
    ZBB_MAXU(r, 5u, 3u);            check("maxu(5,3)",    r, 5u);
    ZBB_MAXU(r, 0xFFFFFFFFu, 0u);   check("maxu(~0,0)",   r, 0xFFFFFFFFu);

    /* ── Zbb: andn   rs1 & ~rs2 ───────────────────────────────────── */
    ZBB_ANDN(r, 0xFFu,  0x0Fu);  check("andn(FF,0F)",  r, 0xF0u);
    ZBB_ANDN(r, 0xAAu,  0xAAu);  check("andn(AA,AA)",  r, 0u);
    ZBB_ANDN(r, 0xFFu,  0u);     check("andn(FF,0)",   r, 0xFFu);

    /* ── Zbb: orn    rs1 | ~rs2 ───────────────────────────────────── */
    ZBB_ORN(r, 0u, 0u);          check("orn(0,0)",     r, 0xFFFFFFFFu);
    ZBB_ORN(r, 0xF0u, 0x0Fu);    check("orn(F0,0F)",   r, 0xFFFFFFF0u);

    /* ── Zbb: xnor   ~(rs1 ^ rs2) ────────────────────────────────── */
    ZBB_XNOR(r, 0u, 0u);           check("xnor(0,0)",     r, 0xFFFFFFFFu);
    ZBB_XNOR(r, 0xFFFFFFFFu, 0xFFFFFFFFu); check("xnor(~0,~0)", r, 0xFFFFFFFFu);
    ZBB_XNOR(r, 0xAu, 0x5u);       check("xnor(A,5)",     r, ~(0xAu ^ 0x5u));

    /* ── Zbb: sext.b  sign-extend byte ───────────────────────────── */
    ZBB_SEXTB(r, 0x7Fu);  check("sext.b(7F)",  r, 0x0000007Fu);
    ZBB_SEXTB(r, 0x80u);  check("sext.b(80)",  r, 0xFFFFFF80u);
    ZBB_SEXTB(r, 0xFFu);  check("sext.b(FF)",  r, 0xFFFFFFFFu);
    ZBB_SEXTB(r, 0x100u); check("sext.b(100)", r, 0u);

    /* ── Zbb: sext.h  sign-extend halfword ───────────────────────── */
    ZBB_SEXTH(r, 0x7FFFu);  check("sext.h(7FFF)",  r, 0x00007FFFu);
    ZBB_SEXTH(r, 0x8000u);  check("sext.h(8000)",  r, 0xFFFF8000u);
    ZBB_SEXTH(r, 0xFFFFu);  check("sext.h(FFFF)",  r, 0xFFFFFFFFu);
    ZBB_SEXTH(r, 0x10000u); check("sext.h(10000)", r, 0u);

    /* ── Zbb: zext.h  zero-extend halfword ───────────────────────── */
    ZBB_ZEXTH(r, 0xABCDEFu); check("zext.h(ABCDEF)", r, 0x0000CDEFu);
    ZBB_ZEXTH(r, 0xFFFFu);   check("zext.h(FFFF)",   r, 0x0000FFFFu);
    ZBB_ZEXTH(r, 0u);        check("zext.h(0)",       r, 0u);

    /* ── Zicond: czero.eqz  (rs2==0) ? 0 : rs1 ───────────────────── */
    ZICOND_CZERO_EQZ(r, 5u, 0u);  check("czero.eqz(5,0)",  r, 0u);
    ZICOND_CZERO_EQZ(r, 5u, 1u);  check("czero.eqz(5,1)",  r, 5u);
    ZICOND_CZERO_EQZ(r, 5u, 99u); check("czero.eqz(5,99)", r, 5u);
    ZICOND_CZERO_EQZ(r, 0u, 0u);  check("czero.eqz(0,0)",  r, 0u);
    ZICOND_CZERO_EQZ(r, 0xFFFFFFFFu, 0u); check("czero.eqz(~0,0)", r, 0u);

    /* ── Zicond: czero.nez  (rs2!=0) ? 0 : rs1 ───────────────────── */
    ZICOND_CZERO_NEZ(r, 5u, 0u);  check("czero.nez(5,0)",  r, 5u);
    ZICOND_CZERO_NEZ(r, 5u, 1u);  check("czero.nez(5,1)",  r, 0u);
    ZICOND_CZERO_NEZ(r, 5u, 99u); check("czero.nez(5,99)", r, 0u);
    ZICOND_CZERO_NEZ(r, 0u, 0u);  check("czero.nez(0,0)",  r, 0u);

    if (failures == 0)
        uart_puts("ALL PASS\n");
    else {
        uart_puts("FAILED: "); uart_hex(failures); uart_puts(" test(s)\n");
    }

    for (;;) __asm__ volatile("wfi");
}
