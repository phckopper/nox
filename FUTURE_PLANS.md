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

### After O3+unroll+inline (2026-03-25) — GCC -O3 -funroll-loops -finline-functions ← CURRENT BEST
- **CoreMark/MHz: ~2.960** (+2.9% vs BHT), crcfinal=0x25b5 ✓ (1500 iter)
- Total ticks: 506,072,095 | Cycles/iteration: ~337,381
- Built with GCC 15.2.0 (`-O3 -funroll-loops -finline-functions -march=rv32im_zba_zbb_zicond_zicsr`)
- ELF: `sw/coremark/coremark_1500iter_O3_unroll_inline_rv32im_zba_zbb_zicond.elf`

#### Current stall breakdown (1500-iter run, perf counters):
| Source | Cycles | % of total |
|--------|--------|-----------|
| Load-use hazard | 26.1M | **4.0%** |
| Fetch bubbles (total) | 27.8M | **4.3%** |
| — Branch mispredictions | 7.31M × ~2 cyc | ~14.6M (2.2%) |
| — JAL BTB misses | 1.72M × ~2 cyc | ~3.4M (0.5%) |
| — JALR redirects | 0.22M × ~2 cyc | ~0.4M (0.1%) |
| MulDiv stall | 14.1M | **2.2%** |
| **IPC** | | **0.874** |

Branch prediction: **true accuracy 90.1%** (66.3M/73.6M) | taken accuracy 85.2% | taken 50% / not-taken 50%
- Taken, not predicted: 5.42M — up vs O2 (loop unrolling creates BTB-cold branches at unrolled exits)
- Not-taken, predicted: 1.89M — down vs O2 (less aliasing; fewer back-edge taken branches)
- JAL BTB hit rate: **98.9%** (down from 99.4%; inlining creates more unique call sites)
- JALR RAS hit rate: **89.3%** (up from 82.3%; inlining reduces call depth)
- Load-use hazard down 16% (26.1M vs 31M) — compiler scheduled around more hazards with O3

---

## Pending Improvements

### P1 — Performance counters ✅ DONE (2026-03-25) — see Completed section

### P4b — Push to 400 MHz
**File:** `synth/nox.nangate.sdc`

Timing is closed at 333 MHz (3.0 ns, all WNS positive). Next step: change the clock
period to 2.5 ns in `synth/nox.nangate.sdc` and re-run synthesis + STA.

Expected gain: **+20% raw CoreMark score** (CM/MHz unchanged, raw score ∝ frequency).

Also pending: re-synthesize to capture the RV32A addition (minor area increase expected).

### P5b — Fetch FIFO 2→4 entries ✅ DONE (2026-03-25) — see Completed section

### P6 — Instruction cache (only if memory latency increases)
**Files:** `rtl/fetch.sv`, new `rtl/icache.sv`

**Important:** In the current simulation the `axi_mem` testbench model has 1-cycle
read latency — identical to a cache hit. An instruction cache would have zero impact
on CoreMark score in this setup. All fetch bubbles are caused by misprediction
redirects, not memory latency.

A cache is only justified if:
- The design is integrated with off-chip DRAM (50–100+ cycle latency), or
- Clock is pushed beyond ~500 MHz where on-chip SRAM can no longer respond in 1 cycle.

If added: a small direct-mapped cache (1–2 KB, 4-word lines) is sufficient for
CoreMark's working set. Requires tag/valid arrays, line-fill logic, and a miss-stall
mechanism in fetch.

### P12 — C extension (Compressed instructions) — low priority for simulation
**Files:** `rtl/fetch.sv`, `rtl/decode.sv`, new fetch alignment buffer

The C extension maps the most common RV32I instructions to 16-bit encodings, reducing
code size by ~25–35%.

**Why it has limited benefit in simulation:** With 1-cycle AXI memory, instruction
fetch is never the bottleneck. The primary simulation benefit would be reduced BTB
aliasing: smaller code footprint → hot-path PCs more concentrated → fewer JAL BTB
misses (currently 0.84M events × 2 cyc = 1.7M cycles).

**On real hardware** the benefit is much larger: smaller binary fits better in I-cache,
reducing memory traffic. Worth implementing for FPGA deployment.

**Implementation complexity:** HIGH. The fetch stage must handle 2-byte-aligned PCs;
the AXI bus always returns 32-bit words so two compressed instructions can arrive in
one word; the decode stage must handle 16-bit instructions that may straddle a 4-byte
boundary. Requires a 48-bit fetch buffer.

Expected simulation gain: **+2–4%** (BTB). Expected FPGA/silicon gain: **+8–15%**.

---

## Won't Do (and why)

| Idea | Reason |
|------|--------|
| Eliminate load-use stall entirely | Reintroduces the 3.11 ns in2out path that failed timing at 333 MHz |
| Instruction cache (current sim) | axi_mem is already 1-cycle; all fetch bubbles are misprediction redirects, not memory latency |
| F/D/Q extensions (floating point) | CoreMark is pure integer; zero benefit |
| V extension (vector) | Fundamental core redesign; not compatible with 4-stage in-order philosophy |
| Out-of-order execution | Major redesign; incompatible with current pipeline |
| Superscalar (dual-issue) | Would push CM/MHz toward ~4.5 but requires 2× decode width, 4-read-port register file, and dual hazard logic — a near-complete redesign. Worth considering as a separate "NoX v2" project. |

---

## Completed Improvements

### P1 — Performance counters ✅ DONE (2026-03-25)
**File:** `rtl/execute.sv` (`ifdef SIMULATION` block)

15 counters printed at simulation end: IPC, stall breakdown (LSU back-pressure,
load-use hazard, MulDiv stall, fetch bubbles — mutually exclusive), redirect events
(branch mispredict split into taken-miss and not-taken-miss, JAL BTB miss, JALR redirect)
with estimated cycles-lost, and prediction success rates (branch true accuracy %,
taken/not-taken split, JAL BTB hit %, JALR RAS/BTB hit %).

---

### BHT expansion + XOR-folded index ✅ DONE (2026-03-25)
**File:** `rtl/branch_predictor.sv`
**Actual gain: +0.1% CM/MHz** (2.873 → ~2.876; 522,034,501 → 520,947,845 ticks)

Investigation triggered by apparent "50% prediction rate" — which was a counter bug
(the metric showed correctly-predicted-taken / all-branches, not true accuracy).
True accuracy was 90.3% (P5b) → 90.6% (after BHT improvements).

Two improvements applied:
1. **BHT entries: 64 → 256** (512 bits total, negligible area). More entries reduce capacity
   aliasing between branches at the same PC[7:2] offset in different 256-byte pages.
2. **XOR-folded index:** `PC[9:2] ⊕ PC[17:10]` mixes the intra-page offset with the page
   number. Previously `PC[7:2]` aliased branches that differed only in the high page bits.
   Not-taken-predicted events fell from ~3.5M → 3.07M.

Remaining ~9.4% mispredictions are near the bimodal ceiling — data-dependent branches
(list sort comparisons, state machine transitions) that alternate taken/not-taken each call.
A gshare predictor (XOR PC with global history) could recover another 0.5–1%.

Also fixed `BLKLOOPINIT` Verilator warning: reset of 256-entry BHT array must use blocking
`=` (not `<=`) in for-loop; Verilator only supports non-blocking in for-loops up to ~64 entries.

---

### P5b — Fetch FIFO 2→4 entries ✅ DONE (2026-03-25)
**File:** `rtl/nox.sv` (`L0_BUFFER_SIZE` default 2→4)
**Actual gain: +4.9% CM/MHz** (2.739 → ~2.873; 547,698,287 → 522,034,501 ticks)

A larger fetch FIFO absorbs post-redirect refill latency — the pipeline can drain
more instructions from the buffer before stalling. Fetch bubbles fell from 8.2% to
4.2% of cycles. Also fixed a `WIDTHEXPAND` lint warning in `fetch.sv` (explicit
`buffer_t'()` casts on line 107, exposed because `$clog2(4)=2` gives a 3-bit type).

---

### P2 — Add Return Address Stack (RAS) ✅ DONE (2026-03-24)
**File:** `rtl/branch_predictor.sv` (+ `rtl/fetch.sv`, `rtl/execute.sv`)
**Actual gain: +7.1% CM/MHz combined with P3** (0.909 → 0.974)

Added a 4-entry RAS alongside the BTB/BHT:
- `JAL`/`JALR` with `rd=ra` (call convention) push the link address.
- `JALR` with `rs1=ra, rd=x0` (return convention) pops and predicts the return target.

Result: JALR redirects fell from ~9.5M projected cycles without RAS to ~0.8M with it.

---

### P3 — Expand BTB from 16 to 64 entries ✅ DONE (2026-03-24)
**File:** `rtl/branch_predictor.sv`
**Actual gain: +7.1% CM/MHz combined with P2** (0.909 → 0.974)

Changed `BTB_ENTRIES` from 16 to 64, widening the index from PC[5:2] to PC[7:2].
Eliminated the aliasing conflicts that caused frequent BTB evictions in CoreMark's
multi-function working set.

---

### P4a — Timing closure at 333 MHz ✅ DONE (2026-03-24)
**Files:** `synth/nox.nangate.sdc`, `rtl/execute.sv`

All paths met at 333 MHz (3.0 ns) in run `synth/syn_out/nox_24_03_2026_21_10_26/`:
- reg2reg WNS: +0.05 ns ✅ | in2reg WNS: +0.88 ns ✅ | reg2out WNS: +0.25 ns ✅

Fixes applied (commit c6912dd):
1. `execute.sv`: pre-registered JALR address match as 1-bit `j_addr_matched_pred_ff` — removed 32-bit equality from the critical reg2reg path.
2. `nox.nangate.sdc`: `set_false_path -from [get_ports {lsu_axi_miso_i[*]}] -to [all_registers]` — justified by `load_use_hazard` blocking all register writes while AXI read data is in the forwarding path.

---

### P5 — Reduce misprediction penalty from 3 to 2 cycles ✅ DONE (2026-03-24)
**Files:** `rtl/fetch.sv`, `rtl/execute.sv`
**Actual gain: +5.2% CM/MHz** (0.974 → 1.025)

F_CLR is only entered when `req_ff && ~addr_ready` (address channel still pending).
In all other cases (addr idle or accepted this cycle), execute immediately issues the
new PC — saving one redirect bubble. Fetch bubbles fell from 15.3% → 11.6% of cycles.

---

### P7 — RV32M hardware multiply/divide ✅ DONE (2026-03-24)
**Files:** `rtl/muldiv_unit.sv` (new), `rtl/execute.sv`, `rtl/decode.sv`, `rtl/inc/riscv_pkg.svh`, `rtl/inc/nox_pkg.svh`
**Actual gain: +141.9% CM/MHz** (1.025 → 2.479)

Timing-safe multiply/divide unit: multiply is pipelined over 2 cycles (operands
registered at T, 33×33-bit product computed reg-to-reg at T+1). Division uses a
32-cycle restoring shift-subtract algorithm. All RISC-V spec corner cases handled
(divide-by-zero, signed overflow INT_MIN/−1).

57% of all CoreMark instructions were inside `__mulsi3`; hardware MUL reduced each
call from ~64 instructions to 1, saving ~430K instructions/iteration.

---

### P8+P9+P10 — Zba + Zbb-subset + Zicond extensions ✅ DONE (2026-03-24)
**Files:** `rtl/execute.sv`, `rtl/decode.sv`, `rtl/inc/riscv_pkg.svh`
**Actual gain: +10.5% CM/MHz** (2.479 → 2.739)

**Zba (P8):** sh1add/sh2add/sh3add — fused shift-and-add for array indexing.
**Zbb (P9):** min/max/minu/maxu, sext.b/sext.h, zext.h, andn/orn/xnor — eliminates
compare+branch+select sequences and multi-instruction sign/zero extends.
**Zicond (P10):** czero.eqz/czero.nez — branchless conditional select, eliminates
50/50 unpredictable branches in list sort and state transition hot paths.

All 15 instructions verified via `sw/test_zba_zbb_zicond/` (55 tests, ALL PASS).
Requires GCC 15+ (`-march=rv32im_zba_zbb_zicond_zicsr`).

Critical decode bug fixed: for OP-IMM instructions, `funct7_raw` was incorrectly
captured from upper immediate bits, causing false extension dispatch. Fix: only
capture `funct7_raw` for OP-IMM shifts (funct3=SLL/SRL_SRA).

---

### P11 — RV32A atomics extension ✅ DONE (2026-03-24)
**Files:** `rtl/lsu.sv`, `rtl/decode.sv`, `rtl/execute.sv`, `rtl/wb.sv`, `rtl/inc/riscv_pkg.svh`

All 11 RV32A instructions implemented and verified (`sw/test_rv32a/`, ALL PASS):
LR.W, SC.W, AMOSWAP.W, AMOADD.W, AMOXOR.W, AMOAND.W, AMOOR.W, AMOMIN.W, AMOMAX.W, AMOMINU.W, AMOMAXU.W.

LR.W reuses the existing load path (`LSU_LOAD`); the LSU sets `lr_reserved_ff`/`lr_addr_ff`
as a side-effect. SC.W and all AMO* use a new `LSU_AMO` op type handled by a 3-state
state machine (`AMO_IDLE → AMO_RD → AMO_WR`) in lsu.sv. Single-hart: no AXI
exclusive-access signalling; reservation is local to the LSU.
