# NOX RISC-V Core — Future Improvement Plans

## Synthesis History (NanGate 45nm, Yosys + OpenSTA)

| Date | RTL state | Area (µm²) | Cells | FFs | reg2reg WNS | in2reg WNS | reg2out WNS |
|------|-----------|-----------|-------|-----|-------------|------------|-------------|
| 2026-03-13 | RV32I + timing opts (pre-BP, pre-M) | 22,225.9 | 14,022 | 1,917 | **+1.03 ns ✅** | **+0.23 ns ✅** | **+0.58 ns ✅** |
| 2026-03-24 | RV32IMZba_Zbb_ZicondZicsr + branch predictor | 70,748.8 | 46,025 | ~6,321 | **+0.05 ns ✅** | **+0.88 ns ✅** | **+0.25 ns ✅** |

Clock target: **333 MHz** (3.0 ns). All paths met as of 2026-03-24 (`synth/syn_out/nox_24_03_2026_21_10_26/`).
RV32A (atomics) has since been added; a re-synthesis run is pending.

---

## Performance History

### Baseline (2026-03-23) — no branch predictor improvements
- **CoreMark/MHz: 0.909** at -O2, 333 MHz (NanGate 45nm)
- **IPC ≈ 0.664** (365M instructions / 550M cycles, 500-iter CoreMark -O2)

### After P2+P3 (2026-03-24) — 4-entry RAS + 64-entry BTB
- **CoreMark/MHz: 0.974** (+7.1% vs baseline), crcfinal=0xa14c ✓
- Total ticks: 513,409,720

### After P5 (2026-03-24) — eliminate F_CLR state (mispredict penalty 3→2 cycles)
- **CoreMark/MHz: 1.025** (+5.2% vs P2+P3), crcfinal=0xbd59 ✓ (600 iter, 11.70s)
- Total ticks: 487,607,017

### After P7 (2026-03-24) — RV32M hardware multiply/divide
- **CoreMark/MHz: 2.479** (+141.9% vs P5), crcfinal=0x25b5 ✓ (1500 iter, 12.10s)
- Cycles/iteration: 403,429

### After P8+P9+P10 (2026-03-24) — Zba + Zbb-subset + Zicond
- **CoreMark/MHz: 2.739** (+10.5% vs P7), crcfinal=0x25b5 ✓ (1500 iter, 10.95s)
- Cycles/iteration: 365,132 | Total ticks: 547,698,287
- Built with GCC 15.2.0 (`-march=rv32im_zba_zbb_zicond_zicsr -O2`)

### After P5b (2026-03-25) — fetch FIFO 2→4 entries
- **CoreMark/MHz: ~2.873** (+4.9% vs P8+P9+P10), crcfinal=0x25b5 ✓ (1500 iter)
- Total ticks: 522,034,501 | Cycles/iteration: ~348,023

### After P1+BHT improvements (2026-03-25) — 256-entry XOR-indexed BHT
- **CoreMark/MHz: ~2.876** (+0.1% vs P5b), crcfinal=0x25b5 ✓ (1500 iter)
- Total ticks: 520,947,845 | Cycles/iteration: ~347,298

### After P14+P17 (2026-03-26) — 128-entry BTB + full Zbb ← CURRENT BEST
- **CoreMark/MHz: 2.893** (+5.6% vs P8+P9+P10), crcfinal=0x25b5 ✓ (1500 iter, 10.37s)
- Total ticks: 518,472,885 | Cycles/iteration: 345,649
- Built with xPack GCC 10.2.0 (`-O2 -march=rv32im_zba_zbb_zicond`)
- ELF: `sw/coremark/coremark_1500iter_O2_rv32im_zba_zbb_zicond.elf`

#### Current stall breakdown (1500-iter O2 run, perf counters):
| Source | Cycles | % of total |
|--------|--------|-----------|
| Load-use hazard | 31.0M | **4.8%** |
| Fetch bubbles (total) | 24.7M | **3.8%** |
| — Branch mispredictions | 6.99M × ~2 cyc | ~14.0M (2.2%) |
| — JAL BTB misses | 0.68M × ~2 cyc | ~1.4M (0.2%) |
| — JALR redirects | 0.56M × ~2 cyc | ~1.1M (0.2%) |
| MulDiv stall | 14.1M | **2.2%** |
| **IPC** | | **0.871** |

Branch prediction: **true accuracy 91.2%** (72.8M/79.8M) | taken accuracy 91.3% | taken 55% / not-taken 45%
- Taken, not predicted: 3.83M — BTB miss or BHT counter<2
- Not-taken, predicted: 3.16M — BHT aliasing/slow decay
- JAL BTB hit rate: **99.5%** | JALR RAS/BTB hit rate: **82.7%**

### After O3+unroll+inline (2026-03-25) — GCC -O3 -funroll-loops -finline-functions
- **CoreMark/MHz: ~2.960** (+2.9% vs BHT), crcfinal=0x25b5 ✓ (1500 iter, old simulator)
- Total ticks: 506,072,095 | Cycles/iteration: ~337,381
- Note: required GCC 15.2.0 (`-march=rv32im_zba_zbb_zicond_zicsr`); docker xPack 10.2.0 does not support -O3 with zicond
- ELF: `sw/coremark/coremark_1500iter_O3_unroll_inline_rv32im_zba_zbb_zicond.elf`

---

## Pending Improvements

### P4b — Push synthesis to 400 MHz
**File:** `synth/nox.nangate.sdc`

Change the clock period from 3.0 ns to 2.5 ns and re-run synthesis + STA. All current
WNS values are positive (reg2reg +0.05 ns, in2reg +0.88 ns, reg2out +0.25 ns), giving
headroom to attempt a higher frequency.

Also pending: re-synthesize to capture the RV32A addition (area increase expected to be minor).

Expected gain: **+20% raw CoreMark score** (CM/MHz unchanged, raw score ∝ frequency).

---

### P13 — Gshare branch predictor (DEFERRED — needs pipeline GHR snapshot)
**File:** `rtl/branch_predictor.sv`

Replace the bimodal BHT with a gshare predictor: XOR the fetch PC with a Global History
Register (GHR) before indexing the BHT. The GHR shifts in the outcome of every resolved
branch (1=taken, 0=not-taken).

**Why deferred:** A non-speculative GHR (updated only at execute, 2 cycles after fetch)
causes prediction and update to index *different* BHT entries — the GHR shifts 1–2 bits
between fetch-time query and execute-time update, completely de-correlating the predictor.
Attempt resulted in branch accuracy falling from 91% to 72% (+11% total ticks, invalid).

**Correct implementation requires:**
1. Propagate a GHR snapshot alongside each instruction through OT FIFO → L0 FIFO →
   decode pipeline register → execute.
2. Return the snapshot as `update_ghr_i` to `branch_predictor` so that the BHT entry
   trained at execute matches the entry queried at fetch.
3. On misprediction, restore the GHR to the snapshot value (already on the redirect path).

This is a moderate pipeline change touching fetch, decode, and the branch predictor interface.

Expected gain: **+0.5–1.0% CM/MHz** (reduces ~7M mispredict events).

---

---

### P15 — Faster integer divider (radix-4 SRT)
**File:** `rtl/muldiv_unit.sv`

The current restoring shift-subtract divider takes 32 cycles for all DIV/REM operations.
A radix-4 SRT (Sweeney–Robertson–Tocher) algorithm produces 2 quotient bits per cycle,
halving latency to ~16 cycles. Partial remainder and quotient digit selection require a
small lookup table (the carry-save adder and digit selection can be table-driven for
radix-4).

Alternatively, a non-restoring divider with the same 32-cycle loop but without the
restore step is simpler and still cuts average latency by ~20% (no wasted restore cycles).

MulDiv stall is 14.1M cycles (2.2% of total). If all were 32-cycle divides, halving latency
saves ~7M cycles ≈ 1% gain. In practice CoreMark uses more MUL than DIV, so the gain is
smaller but still measurable for divide-heavy workloads.

Expected CoreMark gain: **+0.3–0.8%** | General workload gain: **+0.5–1.5%** (divide-heavy).

---

### P16 — LTO (INVALID for CoreMark)
**Files:** `sw/coremark/` (build system only — no RTL changes)

`-flto` with the available xPack GCC 10.2.0 inlines so aggressively across translation
units that the benchmark runs in only ~12M ticks instead of ~520M (crcfinal=0xbced, wrong).
LTO eliminates the benchmark work entirely through constant propagation — **invalid result**.

PGO (`-fprofile-generate` / `-fprofile-use`) remains theoretically valid but requires a
two-pass build workflow not supported by the current Makefile setup. Skip for now.

---

### P17 — Remaining Zbb instructions
**Files:** `rtl/execute.sv`, `rtl/decode.sv`, `rtl/inc/riscv_pkg.svh`

The current Zbb subset covers min/max, sign/zero-extend, and logic-with-negate. The
remaining standard Zbb instructions not yet implemented:

| Instruction | Operation | Use case |
|-------------|-----------|----------|
| `clz` / `ctz` | count leading/trailing zeros | integer log2, bit-scan |
| `cpop` | population count | Hamming weight, crypto |
| `rol` / `ror` / `rori` | rotate left/right | crypto, hash functions |
| `orc.b` | OR-combine bytes (byte-wise any-set) | memchr-style scans |
| `rev8` | byte-reverse (endian swap) | network byte-order, crypto |

These add ~6 ALU operations and 2–3 new `funct3/funct7` decode cases. Limited CoreMark
benefit, but important for crypto (SHA-2, AES) and general embedded use.

Expected CoreMark gain: **<1%** | Useful for: cryptographic and bit-manipulation workloads.

---

### P6 — Instruction cache (only if memory latency increases)
**Files:** `rtl/fetch.sv`, new `rtl/icache.sv`

With the current 1-cycle `axi_mem` testbench model, all fetch bubbles are misprediction
redirects — not memory latency. An I-cache would have zero simulation impact.

Justified when:
- Integrated with off-chip DRAM (50–100+ cycle latency), or
- Clock pushed beyond ~500 MHz where on-chip SRAM can no longer respond in 1 cycle.

Design: direct-mapped, 1–2 KB, 4-word (128-bit) lines. Requires tag/valid arrays,
line-fill state machine in fetch, and a miss-stall signal to the pipeline.

Expected simulation gain: **0%** | Expected FPGA/silicon gain: **+30–100%** (memory-latency dependent).

---

### P18 — Data cache
**Files:** `rtl/lsu.sv`, new `rtl/dcache.sv`

Mirrors the I-cache justification: the `axi_mem` testbench is 1-cycle for both
instruction and data. A D-cache is only useful when data memory latency exceeds 1 cycle.

Additional complexity vs I-cache: write policy (write-through vs write-back), dirty
tracking, cache-coherency with AMO instructions (LR/SC invalidation), and the interaction
with load-use forwarding (a cache miss must extend the stall).

Expected simulation gain: **0%** | Expected FPGA/silicon gain: **+20–60%** (load/store heavy code).

---

### P12 — C extension (Compressed instructions)
**Files:** `rtl/fetch.sv`, `rtl/decode.sv`, new fetch alignment buffer

The C extension maps the most common RV32I instructions to 16-bit encodings, reducing
code size by ~25–35%.

**Why it has limited simulation benefit:** With 1-cycle AXI memory, instruction fetch is
never the bottleneck. The primary simulation benefit: smaller code footprint → hot-path
PCs more concentrated → fewer JAL BTB misses (currently 1.72M × 2 cyc = 3.4M cycles).

**On real hardware** the benefit is much larger: smaller binary fits better in I-cache,
reducing memory traffic. Worth implementing for FPGA deployment.

**Implementation complexity: HIGH.** Fetch must handle 2-byte-aligned PCs; the AXI bus
returns 32-bit words so two compressed instructions can arrive in one word; decode must
handle 16-bit instructions that may straddle a 4-byte boundary. Requires a 48-bit fetch
buffer and a pre-decode expander before the main decode stage.

Expected simulation gain: **+2–4%** (BTB) | Expected FPGA/silicon gain: **+8–15%**.

---

### P19 — Physical Memory Protection (PMP) + U-mode
**Files:** `rtl/csr.sv`, `rtl/execute.sv`, `rtl/lsu.sv`

Implementing the RISC-V PMP (Physical Memory Protection) CSRs (`pmpcfgX`, `pmpaddrX`)
and U-mode (user privilege level) would allow NoX to run a simple RTOS or bare-metal OS
with memory isolation.

Requirements:
- U-mode: add `mstatus.MPP` field, `mret` privilege switch, `ecall`/`ebreak` trap into M-mode.
- PMP: 4–8 PMP entries, checked on every fetch and data access in U-mode. A failed
  check raises a load/store/instruction access fault.
- Timing: PMP address comparison is on the critical path for data memory accesses.
  With 8 entries this can be done as a parallel priority encode without impacting timing.

This is a prerequisite for running FreeRTOS, Zephyr, or other embedded OSes.

**Implementation complexity: MEDIUM–HIGH.** U-mode is straightforward; PMP adds
combinational checks on every memory access.

---

## Won't Do (and why)

| Idea | Reason |
|------|--------|
| Eliminate load-use stall entirely | Reintroduces the 3.11 ns in2out path that failed timing at 333 MHz |
| F/D/Q extensions (floating point) | CoreMark is pure integer; zero benefit; Zfinx is the better path if needed |
| V extension (vector) | Fundamental redesign; incompatible with 4-stage in-order philosophy |
| Out-of-order execution | Major redesign; incompatible with current pipeline |
| Superscalar (dual-issue) | Would push CM/MHz toward ~4.5 but requires 2× decode width, 4-read-port register file, dual hazard logic — near-complete redesign. Consider as a separate "NoX v2". |

---

## Completed Improvements

### P14 — 128-entry BTB ✅ DONE (2026-03-26)
**File:** `rtl/branch_predictor.sv`
**Actual gain: part of +5.6% CM/MHz** (2.739 → 2.893; 547,698,287 → 518,472,885 ticks)

Changed `BTB_ENTRIES` from 64 to 128 (index width 6→7 bits, tag 25→23 bits). JAL BTB
hit rate improved from ~97.1% to 99.5%; fetch bubbles fell from ~70M to 24.7M cycles.

---

### P17 — Full Zbb instruction set ✅ DONE (2026-03-26)
**File:** `rtl/execute.sv`
**Actual gain: combined with P14 above**

Added `clz`/`ctz`/`cpop`/`rol` (funct3=001, funct7=0x30, imm[4:0] disambiguates) and
`ror`/`rori` (funct7=0x30), `orc.b` (funct7=0x28), `rev8` (funct7=0x35) in funct3=101.
No decode.sv changes needed — funct7_raw was already captured for OP and OP-IMM shifts.

---

### O3 + loop unrolling + inlining ✅ DONE (2026-03-25)
**File:** `sw/coremark/nox/startup.c`, build system
**Actual gain: +2.9% CM/MHz** (~2.876 → ~2.960; 520,947,845 → 506,072,095 ticks)

Rebuilt CoreMark with GCC 15.2.0 `-O3 -funroll-loops -finline-functions`. Key effects:
load-use hazard fell 16% (31M → 26.1M cycles, compiler scheduled around hazards); loop
back-edges converted to cheaper not-taken exits; call overhead reduced by inlining.

Root cause of linker failure: `_reset` in `.init` calls `main()`; with `-finline-functions`
GCC inlined all of CoreMark into `.init`, pushing it past the 0x100-byte vector-table
offset in `sections.ld`. Fix: `#pragma GCC optimize("O2")` + `__attribute__((noinline))`
on `main()` in `nox/startup.c`, keeping the benchmark code at O3 and startup at O2.

---

### P1 — Performance counters ✅ DONE (2026-03-25)
**File:** `rtl/execute.sv` (`ifdef SIMULATION` block)

15 counters printed at simulation end: IPC, stall breakdown (LSU back-pressure, load-use
hazard, MulDiv stall, fetch bubbles), redirect events (branch mispredict split into
taken-miss and not-taken-miss, JAL BTB miss, JALR redirect) with estimated cycles-lost,
and prediction success rates (branch true accuracy %, taken/not-taken split, JAL BTB
hit %, JALR RAS/BTB hit %).

---

### BHT expansion + XOR-folded index ✅ DONE (2026-03-25)
**File:** `rtl/branch_predictor.sv`
**Actual gain: +0.1% CM/MHz** (2.873 → ~2.876; 522,034,501 → 520,947,845 ticks)

Investigation triggered by apparent "50% prediction rate" — a counter bug (the metric
showed correctly-predicted-taken / all-branches, not true accuracy). True accuracy was
90.3% → 90.6% after fixes.

Two improvements:
1. **BHT 64 → 256 entries** (negligible area). Reduces capacity aliasing.
2. **XOR-folded index:** `PC[9:2] ⊕ PC[17:10]` mixes intra-page offset with page number,
   reducing inter-page aliasing. Not-taken-predicted events fell from ~3.5M → 3.07M.

Remaining ~9.4% mispredictions are near the bimodal ceiling — data-dependent branches
that alternate taken/not-taken each call. Gshare (P13) is the path to further improvement.

Also fixed `BLKLOOPINIT` Verilator warning: BHT reset loop must use blocking `=` for
arrays above ~64 entries.

---

### P5b — Fetch FIFO 2→4 entries ✅ DONE (2026-03-25)
**File:** `rtl/nox.sv` (`L0_BUFFER_SIZE` default 2→4)
**Actual gain: +4.9% CM/MHz** (2.739 → ~2.873; 547,698,287 → 522,034,501 ticks)

Larger fetch FIFO absorbs post-redirect refill latency. Fetch bubbles fell from 8.2% to
4.2% of cycles. Also fixed a `WIDTHEXPAND` Verilator warning in `fetch.sv` (explicit
`buffer_t'()` casts exposed because `$clog2(4)=2` gives a 3-bit type).

---

### P2 — Add Return Address Stack (RAS) ✅ DONE (2026-03-24)
**File:** `rtl/branch_predictor.sv` (+ `rtl/fetch.sv`, `rtl/execute.sv`)
**Actual gain: +7.1% CM/MHz combined with P3** (0.909 → 0.974)

4-entry RAS: `JAL`/`JALR` with `rd=ra` push the link address; `JALR` with `rs1=ra, rd=x0`
pops. JALR redirects fell from ~9.5M projected cycles without RAS to ~0.8M with it.

---

### P3 — Expand BTB from 16 to 64 entries ✅ DONE (2026-03-24)
**File:** `rtl/branch_predictor.sv`
**Actual gain: +7.1% CM/MHz combined with P2** (0.909 → 0.974)

Widened BTB index from PC[5:2] to PC[7:2]. Eliminated aliasing conflicts in CoreMark's
multi-function working set.

---

### P4a — Timing closure at 333 MHz ✅ DONE (2026-03-24)
**Files:** `synth/nox.nangate.sdc`, `rtl/execute.sv`

All paths met at 333 MHz in run `synth/syn_out/nox_24_03_2026_21_10_26/`:
reg2reg WNS: +0.05 ns | in2reg WNS: +0.88 ns | reg2out WNS: +0.25 ns ✅

Fixes: pre-registered JALR address match (`j_addr_matched_pred_ff`) to remove a 32-bit
equality from the reg2reg critical path; added `set_false_path` for `lsu_axi_miso_i →
all_registers` (justified by `load_use_hazard` blocking all register writes during AXI
read forwarding).

---

### P5 — Reduce misprediction penalty from 3 to 2 cycles ✅ DONE (2026-03-24)
**Files:** `rtl/fetch.sv`, `rtl/execute.sv`
**Actual gain: +5.2% CM/MHz** (0.974 → 1.025)

F_CLR is only entered when `req_ff && ~addr_ready` (address beat still pending). In all
other cases, execute immediately issues the new PC. Fetch bubbles fell from 15.3% → 11.6%.

---

### P7 — RV32M hardware multiply/divide ✅ DONE (2026-03-24)
**Files:** `rtl/muldiv_unit.sv` (new), `rtl/execute.sv`, `rtl/decode.sv`, `rtl/inc/riscv_pkg.svh`, `rtl/inc/nox_pkg.svh`
**Actual gain: +141.9% CM/MHz** (1.025 → 2.479)

Multiply pipelined over 2 cycles (33×33-bit product). Division uses a 32-cycle restoring
shift-subtract. All RISC-V spec corner cases handled (divide-by-zero, signed overflow
INT_MIN/−1). 57% of all CoreMark instructions were inside `__mulsi3`; hardware MUL
reduced each call from ~64 instructions to 1, saving ~430K instructions/iteration.

---

### P8+P9+P10 — Zba + Zbb-subset + Zicond extensions ✅ DONE (2026-03-24)
**Files:** `rtl/execute.sv`, `rtl/decode.sv`, `rtl/inc/riscv_pkg.svh`
**Actual gain: +10.5% CM/MHz** (2.479 → 2.739)

**Zba:** sh1add/sh2add/sh3add — fused shift-and-add for array indexing.
**Zbb subset:** min/max/minu/maxu, sext.b/sext.h, zext.h, andn/orn/xnor.
**Zicond:** czero.eqz/czero.nez — branchless conditional select, eliminates 50/50
unpredictable branches in list sort and state transition hot paths.

All 15 instructions verified (`sw/test_zba_zbb_zicond/`, 55 tests, ALL PASS).
Requires GCC 15+ (`-march=rv32im_zba_zbb_zicond_zicsr`).

---

### P11 — RV32A atomics extension ✅ DONE (2026-03-24)
**Files:** `rtl/lsu.sv`, `rtl/decode.sv`, `rtl/execute.sv`, `rtl/wb.sv`, `rtl/inc/riscv_pkg.svh`

All 11 RV32A instructions verified (`sw/test_rv32a/`, ALL PASS): LR.W, SC.W, AMOSWAP.W,
AMOADD.W, AMOXOR.W, AMOAND.W, AMOOR.W, AMOMIN.W, AMOMAX.W, AMOMINU.W, AMOMAXU.W.

3-state AMO state machine (`AMO_IDLE → AMO_RD → AMO_WR`) in `lsu.sv`. LR.W reuses the
load path with a reservation side-effect. Single-hart: no AXI exclusive-access signalling.
