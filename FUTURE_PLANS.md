# NOX RISC-V Core — Future Improvement Plans

## Performance History

### Baseline (2026-03-23) — no branch predictor improvements
- **CoreMark/MHz: 0.909** at -O2, 300 MHz (NanGate 45nm)
- **IPC ≈ 0.664** (365M instructions / 550M cycles, 500-iter CoreMark -O2)

### After P2+P3 (2026-03-24) — 4-entry RAS + 64-entry BTB
- **CoreMark/MHz: 0.974** (+7.1% vs baseline), crcfinal=0xa14c ✓
- **IPC ≈ 0.730** (~375M instructions / 513M cycles, +9.9% vs baseline)
- Total ticks: 513,409,720 (vs 549,990,280 baseline)

#### P2+P3 stall breakdown (500-iter -O2 CoreMark, 700M cycle window):
| Source | Count | Est. cycles lost |
|--------|-------|-----------------|
| Fetch bubbles (total) | 107.1M cycles | **15.3%** of all cycles |
| — Branch mispredictions | 24.8M events × ~3 cyc | ~74.5M (~70% of bubbles) |
| — JAL BTB misses | 780K events × ~3 cyc | ~2.3M |
| — JALR redirects | 268K events × ~3 cyc | ~0.8M ← RAS nearly eliminates these |
| Load-use stalls | 9.9M cycles | **1.4%** |

Branch mispredictions are now the clear dominant bottleneck (~10.6% of all cycles).
JALR redirects are near-zero thanks to the RAS — down from ~9.5M projected cycles
without RAS to ~0.8M with it. Load-use stalls are minor at 1.4%.

**Next target: P5b (increase L0_BUFFER_SIZE 2→4) or P4 (push to 400 MHz)**

### After P5 (2026-03-24) — eliminate F_CLR state (reduce mispredict penalty 3→2 cycles)
- **CoreMark/MHz: 1.025** (+5.2% vs P2+P3, +12.8% vs baseline), crcfinal=0xa14c ✓
- **IPC ≈ 0.829** (~405M instructions / 488M cycles, +13.5% vs baseline)
- Total ticks: 487,607,017 (vs 513,409,720 P2+P3, vs 549,990,280 baseline)
- Validation run (600 iter) confirmed: 585,126,618 ticks → **11.70s ≥ 10s** EEMBC check ✓, crcfinal=0xbd59 ✓

#### P5 stall breakdown (700M cycle window, includes post-CoreMark loop):
| Source | Count | Est. cycles lost |
|--------|-------|-----------------|
| Fetch bubbles (total) | 81.3M cycles | **11.6%** of all cycles |
| — Branch mispredictions | 24.8M events × ~2 cyc | ~49.6M (reduced from ~3 cyc) |
| — JAL BTB misses | 780K events × ~2 cyc | ~1.6M |
| — JALR redirects | 268K events × ~2 cyc | ~0.5M |
| Load-use stalls | 9.9M cycles | **1.4%** |

Misprediction penalty reduced from ~3 to ~2 cycles by eliminating the F_CLR state.
Fetch bubbles dropped from 15.3% (P2+P3) to 11.6% — a 3.7 percentage-point reduction.
Branch mispredictions remain the dominant bottleneck, but each now costs 2 cycles instead of 3.

**Remaining high-value opportunities: P4 (push to 400 MHz, +33% raw score) or P5b (L0_BUFFER_SIZE 2→4)**

### After P7 (2026-03-24) — RV32M hardware multiply/divide
- **CoreMark/MHz: 2.479** (+141.9% vs P5, +172.7% vs baseline), crcfinal=0x25b5 ✓
- **Cycles/iteration: 403,429** (down from 1,111,664 at rv32i -O2)
- Total ticks: 605,144,165 (1500 iterations) → **12.10s ≥ 10s** EEMBC check ✓
- "Correct operation validated." — VALID EEMBC score

#### P7 stall breakdown (750M cycle window, 1500-iter run):
| Source | Count | Est. cycles lost |
|--------|-------|-----------------|
| Fetch bubbles (total) | 70.1M cycles | **9.3%** of all cycles |
| — Branch mispredictions | 12.3M events × ~2 cyc | ~24.7M |
| — JAL BTB misses | 2.3M events × ~2 cyc | ~4.6M |
| — JALR redirects | 0.77M events × ~2 cyc | ~1.5M |
| Load-use stalls | 29.5M cycles | **3.9%** |

Load-use stalls rose from 1.4% → 3.9% of cycles. With hardware multiply the coremark
inner loops no longer spend the bulk of their time in `__mulsi3`; the remaining code is
memory-intensive (matrix/list operations), so load-use stalls are proportionally more visible.

**Remaining high-value opportunities: P8 (Zba+Zbb+Zicond bit-manipulation extensions, +6–12%) or P4 (push to 400 MHz, +33% raw score)**

---

## Post-P7 Bottleneck Analysis (current state, 2026-03-24)

After RV32M, the CoreMark inner loops now expose the actual computation bottlenecks — no longer masked by software multiply. The 1500-iter rv32im stall profile:

| Bottleneck | Cycles lost | % of total |
|-----------|-------------|-----------|
| Branch mispredictions (12.3M × ~2 cyc) | ~24.7M | 3.3% |
| JAL BTB misses (2.3M × ~2 cyc) | ~4.6M | 0.6% |
| JALR redirects (0.77M × ~2 cyc) | ~1.5M | 0.2% |
| Load-use stalls | 29.5M | 3.9% |
| **All fetch bubbles** | **70.1M** | **9.3%** |
| **All stalls + bubbles** | **~100M** | **~13%** |

The 87% efficient cycles carry the real work. Two levers remain:

**1. Reduce instruction count** (ISA extensions): fewer instructions → fewer cycles at fixed IPC. Even a 5% reduction in instruction count saves ~30M cycles and moves CM/MHz from 2.479 → ~2.60. Extensions Zba and Zbb directly reduce the instruction count in the hot matrix and list kernels.

**2. Reduce branch mispredictions** (Zicond / better prediction): 12.3M events × 2 cycles = 24.7M cycles. Branchless conditional ops (Zicond) let GCC replace small if-then-else sequences with `czero` pairs, removing branches that are inherently hard to predict (data-dependent 50/50 splits).

**Theoretical ceiling** (zero stalls, zero bubbles): 605M − 100M = 505M cycles for 1500 iter → 2.97 CM/MHz. Extensions pushing instruction count down ~10% would move toward ~2.8–3.0 CM/MHz.

---

## Bottleneck Analysis

### 1. Missing Return Address Stack (RAS) — biggest quick win
Every function return is a `JALR` instruction. The branch predictor only predicts `JAL`
(static target); `JALR` has no prediction and always triggers a misprediction + pipeline
flush. CoreMark has many hot function calls in its inner loops (`crcu8`, `crcu16`,
`core_bench_list`, `core_state_transition`, etc.), each paying a ~3-cycle penalty on
return.

A 4–8 entry RAS would predict all function returns perfectly at negligible hardware cost.

### 2. BTB too small (16 entries, direct-mapped)
The BTB is indexed by PC[5:2] (4-bit index), so only 16 branches can be tracked
simultaneously. Any two branches whose PCs differ only in bits [5:2] alias and evict
each other. CoreMark's working set spans multiple functions, causing frequent conflict
misses. A 64-entry BTB would nearly eliminate aliasing for this workload.

### 3. Load-use stall (1 cycle, unavoidable with current timing constraint)
A 1-cycle bubble is inserted after every load instruction whose destination register is
read by the immediately following instruction. This was intentionally introduced to break
the in2out timing path (AXI rdata → ALU → AXI address outputs). The compiler schedules
around this at -O2 when possible, but cannot always. Eliminating it would require
re-introducing the long combinational path (or pipelining it at the cost of a 2-cycle
penalty), so it is low priority.

### 4. Fetch bubbles — misprediction penalty is the dominant cause (~3 cycles each)
With a 4-stage pipeline, mispredictions detected in Execute require flushing Fetch and
Decode and re-fetching from the correct PC. The fetch state machine enters F_CLR to
drain in-flight AXI transactions before restarting — this is the source of the 3-cycle
penalty. From P1 perf counters (2M cycle hello_world run): fetch bubbles were 14.8% of
all cycles, with ~61% of those caused by branch mispredictions, JALR redirects, and JAL
BTB misses. The bimodal BHT (64 entries) handles simple loops after warmup, but the
redirect penalty itself is the main lever.

An instruction cache does **not** help here — the testbench memory is already 1-cycle,
so all fetch bubbles are structural (misprediction drain), not memory-latency driven.

### 5. Clock frequency — zero RTL change required
Synthesis shows **+1.03 ns WNS** at 300 MHz (reg-to-reg critical path ≈ 2.30 ns).
The design can realistically be pushed to **~400–430 MHz** by tightening the SDC
constraint and re-running synthesis. CoreMark/MHz stays constant, but raw CoreMark score
scales linearly with frequency.

| Clock     | CoreMark/MHz | Raw CoreMark (est.) |
|-----------|-------------|---------------------|
| 300 MHz   | 0.909       | ~109                |
| 400 MHz   | 0.909       | ~146                |
| 430 MHz   | 0.909       | ~157                |

---

## Planned Improvements (priority order)

### P1 — Add performance counters (prerequisite for all tuning)
Before optimizing, instrument the simulation to measure exact stall counts:
- Load-use stall cycles (`load_use_hazard` high)
- Branch misprediction count (jump_i fires on non-correct prediction)
- Fetch-stall cycles (fetch_valid_i=0 while pipeline is ready)

Add as `$display`-based simulation counters in `execute.sv` / `fetch.sv`, printed at
end of run alongside the coremark result. This gives real data to prioritize against.

### P2 — Add Return Address Stack (RAS)
**File:** `rtl/branch_predictor.sv`

Add a 4–8 entry RAS alongside the existing BTB/BHT:
- Push return address on every `JAL rd, imm` where `rd = x1` (call convention)
- Pop and predict on every `JALR x0, rs1, 0` where `rs1 = x1` (return convention)
- Heuristic: check opcode encoding in fetch stage to identify call/return pairs

Expected gain: **+5–10% CM/MHz** depending on function-call density.

### P3 — Expand BTB from 16 to 64 entries
**File:** `rtl/branch_predictor.sv`

Change `BTB_ENTRIES` parameter from 16 to 64. This increases the index width from 4 to
6 bits (PC[7:2]), reducing aliasing conflicts significantly. Area cost is minimal (~64
× (1 + 26 + 32) bits ≈ 0.5 KB of flop/SRAM).

Expected gain: **+3–7% CM/MHz**.

### P4 — Push clock frequency to 400 MHz
**File:** `synth/nox.nangate.sdc`

Change the clock period constraint from 3.333 ns to 2.5 ns (400 MHz) and re-run
synthesis + STA. With +1.03 ns margin at 300 MHz the design should close at 400 MHz
with the existing RTL. If timing is tight, the in2reg path (+0.23 ns margin) may need
attention first.

Expected gain: **+33% raw CoreMark score** (CM/MHz unchanged).

### P5 — Reduce misprediction penalty from 3 to 2 cycles ✅ DONE (2026-03-24)
**Files:** `rtl/fetch.sv`, `rtl/execute.sv`
**Actual gain: +5.2% CM/MHz** (0.974 → 1.025; predicted +3–5%)

Implementation: F_CLR is only entered when `req_ff && ~addr_ready` (address channel
still pending). In all other cases (addr idle or accepted this cycle), execute immediately
issues the new PC — saving one redirect bubble. Old in-flight data beats are silently
discarded because `clear_fifo=fetch_req_i` empties the OT FIFO before their response
arrives, so there is no valid OT entry to match and they are dropped.

Key insight: the original F_CLR drained every redirect through an extra cycle even when
the address channel was already idle. Now only the rare case (addr pending) enters F_CLR.

Result: fetch bubbles fell from 15.3% → 11.6% of cycles in the 700M cycle window.

### P7 — Implement RV32M extension (hardware multiply/divide) ✅ DONE (2026-03-24)
**Files:** `rtl/muldiv_unit.sv` (new), `rtl/execute.sv`, `rtl/decode.sv`, `rtl/inc/riscv_pkg.svh`, `rtl/inc/nox_pkg.svh`
**Actual gain: +141.9% CM/MHz** (1.025 → 2.479; predicted +138%)

**Expected gain: ~+138% CM/MHz** (1.025 → ~2.44), measured from simulation profiling.

CoreMark profiling (instruction-retirement sampling, P5 -O2 run) shows **57% of all
instructions** execute inside `__mulsi3` — the GCC software multiply loop from libgcc.
There are approximately **6,829 multiply calls per CoreMark iteration**, each taking an
average of ~64 instructions (shift-and-add loop over the multiplier's set bits).
Hardware MUL reduces each call from ~64 instructions to 1, saving ~430K instructions/iter.

Projected with hardware multiply:
- Instructions/iter: 770K → ~340K (−56%)
- Cycles/iter at IPC~0.83: ~975K → ~410K
- CM/MHz: 1.025 → **~2.44**

This is confirmed by the observation that every well-known in-order core reporting
~2.5 CM/MHz (ibex, VexRiscv-full, SiFive E31) implements RV32IM. The README's
FPGA score of 2.5 CM/MHz was a hardware measurement error (cycle counter running at
~1/8 CPU frequency) — but the 2.5 target is correct and achievable with M extension.

**Instructions to add** (RV32M, `funct7=0b0000001`, opcode=OP):

| funct3 | Instruction | Operation |
|--------|-------------|-----------|
| 000    | MUL         | rd = (rs1 × rs2)[31:0] |
| 001    | MULH        | rd = (rs1 × rs2)[63:32] (signed×signed) |
| 010    | MULHSU      | rd = (rs1 × rs2)[63:32] (signed×unsigned) |
| 011    | MULHU       | rd = (rs1 × rs2)[63:32] (unsigned×unsigned) |
| 100    | DIV         | rd = rs1 / rs2 (signed) |
| 101    | DIVU        | rd = rs1 / rs2 (unsigned) |
| 110    | REM         | rd = rs1 % rs2 (signed) |
| 111    | REMU        | rd = rs1 % rs2 (unsigned) |

**Implementation notes:**
- MUL/MULH/MULHSU/MULHU: a 32×32→64-bit multiplier in the execute stage. Synthesis
  tools infer a multiplier from `$signed(a) * $signed(b)`. If 1-cycle multiply is
  acceptable (check timing), no stall needed. Otherwise insert a 1-cycle stall
  (similar to load-use) to allow the multiplier to settle.
- DIV/DIVU/REM/REMU: 32-bit divide takes 32+ cycles iteratively. Either use a
  multi-cycle divider with a stall signal (simplest) or a radix-4/SRT divider (faster
  but more area). CoreMark barely uses divide so latency matters less than MUL.
- Update `M_ISA_ID` in `nox_pkg.svh`: set bit 12 (`1 << 12`) → `'h40001100`.
- Update CoreMark compile flags to `-march=rv32im` to use `mul`/`div` instructions
  instead of `__mulsi3`/`__divsi3`.

### P5b — Increase L0_BUFFER_SIZE from 2 to 4
**File:** `rtl/fetch.sv` (parameter only — no logic changes)

The fetch FIFO currently holds 2 instructions. After any redirect the FIFO is cleared
and the pipeline stalls until 2 new instructions arrive. A 4-entry FIFO absorbs
momentary decode backpressure and reduces bubbles from buffer underrun after short
redirects. Area cost is minimal (~4 × 33 bits of flop).

Expected gain: **+1–2% CM/MHz**.

### P6 — Instruction cache (only if memory latency increases)
**Files:** `rtl/fetch.sv`, new `rtl/icache.sv`

**Important:** In the current simulation the `axi_mem` testbench model has 1-cycle
read latency — identical to a cache hit. An instruction cache would have zero impact
on CoreMark score in this setup. All fetch bubbles are caused by misprediction
redirects, not memory latency.

A cache is only justified if:
- The design is integrated with off-chip DRAM (50-100+ cycle latency), or
- Clock is pushed beyond ~500 MHz where on-chip SRAM can no longer respond in 1 cycle.

If added: a small direct-mapped cache (1–2 KB, 4-word lines) is sufficient for
CoreMark's working set. This is a significant addition requiring tag/valid arrays,
line-fill logic, and a miss-stall mechanism in fetch.

### P8 — Zba: address-generation bit-manipulation extension
**Files:** `rtl/execute.sv`, `rtl/decode.sv`, `rtl/inc/riscv_pkg.svh`

Zba adds three R-type instructions: `sh1add` (rd = rs1<<1 + rs2), `sh2add` (rd = rs1<<2 + rs2), `sh3add` (rd = rs1<<3 + rs2). All share funct7=`0010000`, opcode=OP (unallocated in RV32IM), distinguished by funct3=010/100/110.

**Why it helps CoreMark:** The hot kernels all index integer arrays:
- `matrix_mul_*`: double-nested loops over `int16_t[40][40]` — inner index `a[i][j]` = base + i×80 + j×2 → `sh1add j, j, row_ptr` saves one instruction per column
- `core_bench_list`: linked-list element access with `int32_t` fields — `sh2add` for any 4-byte-stride index
- `core_bench_state`: enum/byte array indexing

Without Zba, each stride-4 index requires `slli + add` (2 instructions). With `sh2add` the compiler fuses them to 1. GCC emits `sh1add`/`sh2add`/`sh3add` automatically with `-march=rv32im_zba`.

**Implementation:** In `decode.sv`, detect funct7=`0010000` on `RV_OP` (not already M extension, which is funct7=`0000001`). Add `is_shnadd` flag to `s_id_ex_t`. In `execute.sv` ALU: compute `(op1 << {1,2,3}) + op2`. No pipeline changes required (single-cycle ALU op).

Expected gain: **+4–8% CM/MHz** (2.479 → ~2.60–2.68)

---

### P9 — Zbb: basic bit-manipulation subset (min/max/sext)
**Files:** `rtl/execute.sv`, `rtl/decode.sv`

Prioritised subset of Zbb (full Zbb has 30+ ops; only the high-value ones for CoreMark):

| Instruction | Encoding (funct7/funct3) | Operation | Benefit |
|------------|--------------------------|-----------|---------|
| `min`  | 0000101/100, OP | rd = signed min(rs1, rs2) | replaces `blt + mv` pair |
| `minu` | 0000101/101, OP | rd = unsigned min | ditto for unsigned comparisons |
| `max`  | 0000101/110, OP | rd = signed max | |
| `maxu` | 0000101/111, OP | rd = unsigned max | |
| `sext.b` | 0110000/rs2=00100, OP-IMM | sign-extend byte | replaces `slli 24 + srai 24` |
| `sext.h` | 0110000/rs2=00101, OP-IMM | sign-extend halfword | replaces `slli 16 + srai 16` |
| `zext.h` | 0000100/100, OP (PACK w/ rs2=x0) | zero-extend halfword | replaces `slli 16 + srli 16` |
| `andn`/`orn`/`xnor` | 0100000/111/110/100, OP | logical with inversion | CRC bit manipulation |

**Why it helps CoreMark:**
- `min`/`max`: `core_bench_list` sorts elements with compare+branch+select; `max` replaces these with a single data op, eliminating 50/50 unpredictable branches. `core_state_transition` also uses clamping patterns.
- `sext.b`/`sext.h`: `crcu8`/`crcu16` load bytes/halfwords and sign-extend them; currently 2 shifts → 1 instruction.
- `andn`: CRC XOR-masking (`crc & mask → crc ^ masked_poly`) uses `andn` natively.

GCC flag: `-march=rv32im_zbb` (or `_zbb_zba` combined).

**Implementation:** All are single-cycle ALU operations. `min`/`max` decode identically to other R-type via funct7=`0000101`. `sext.b`/`sext.h` use the existing OP-IMM decoder extended to check funct7=`0110000`. No pipeline changes required.

Expected gain: **+3–6% CM/MHz** (2.479 → ~2.55–2.63)

---

### P10 — Zicond: integer conditional operations
**Files:** `rtl/execute.sv`, `rtl/decode.sv`

Adds two R-type instructions:
- `czero.eqz rd, rs1, rs2`: rd = (rs2 == 0) ? 0 : rs1 — zero `rs1` if condition is zero
- `czero.nez rd, rs1, rs2`: rd = (rs2 != 0) ? 0 : rs1 — zero `rs1` if condition is non-zero

Encoding: funct7=`0000111`, opcode=OP (unallocated in RV32IM), funct3=101/111.

**Why it helps CoreMark:** A branchless conditional select `rd = cond ? a : b` becomes:
```asm
czero.nez t0, a, cond   # t0 = (cond != 0) ? 0 : a  →  a if cond==0
czero.eqz t1, b, cond   # t1 = (cond == 0) ? 0 : b  →  b if cond!=0
or        rd, t0, t1    # rd = a|b (only one is non-zero)
```
This is 3 instructions vs `beq/bne + mv` (branch + move), and — critically — **never mispredicts**. CoreMark's 12.3M misprediction events (24.7M lost cycles, 3.3% of total) come from data-dependent comparisons in list sorting and state transitions that are fundamentally unpredictable. Zicond eliminates the branches themselves.

GCC uses Zicond automatically with `-march=rv32im_zicond -O2` for eligible if-then-else patterns.

**Implementation:** Single-cycle ALU: `(rs2 == 0) ? 0 : rs1` is a 32-bit mux controlled by NOR-reduce of rs2. No pipeline changes required.

Expected gain: **+3–5% CM/MHz** (2.479 → ~2.55–2.60). Depends on how many unpredictable branches GCC converts to czero sequences.

---

### P8+P9+P10 combined — Zba + Zbb + Zicond package
Enabling all three together with `-march=rv32imzba_zbb_zicond` allows GCC to co-optimize across them. Combined expected gain: **+8–15% CM/MHz** → ~2.68–2.85 CM/MHz. The upper bound approaches the theoretical stall-free ceiling of ~2.97.

Implementation order: P8 (Zba) first — highest ROI per instruction added, and simplest ALU change. P9 (Zbb min/max subset) second. P10 (Zicond) third.

---

### P11 — C extension (Compressed instructions) — low priority for simulation
**Files:** `rtl/fetch.sv`, `rtl/decode.sv`, new fetch alignment buffer

The C extension maps the most common RV32I instructions to 16-bit encodings, reducing code size by ~25–35%.

**Why it has limited benefit in simulation:** With 1-cycle AXI memory, instruction fetch is never the bottleneck — all fetch bubbles are from misprediction redirects, not memory latency. The primary simulation benefit would be reduced BTB aliasing: smaller code footprint means hot-path PCs are more concentrated within the 64-entry BTB's index space, improving hit rate for JAL BTB misses (currently 2.3M events × 2 cyc = 4.6M cycles = 0.6% of total).

**On real hardware** the benefit is much larger: smaller binary fits better in I-cache, reducing memory traffic. Worth implementing for FPGA deployment.

**Implementation complexity:** HIGH. The fetch stage must handle 2-byte-aligned PCs, the AXI bus always returns 32-bit words so two compressed instructions can arrive in one word, and the decode stage must handle 16-bit instructions that may straddle a 4-byte boundary. Requires a 48-bit fetch buffer (hold current word + possible carry-over halfword).

Expected simulation gain: **+2–4%** (BTB). Expected FPGA/silicon gain: **+8–15%** (I-cache efficiency).

---

## Won't Do (and why)

| Idea | Reason |
|------|--------|
| Eliminate load-use stall entirely | Reintroduces the 3.11 ns in2out path that failed timing at 300 MHz |
| Instruction cache (current sim) | axi_mem is already 1-cycle; all fetch bubbles are misprediction redirects, not memory latency |
| F/D/Q extensions (floating point) | CoreMark is pure integer; zero benefit |
| A extension (atomics) | CoreMark is single-threaded; zero benefit |
| V extension (vector) | Fundamental core redesign; not compatible with 4-stage in-order philosophy |
| Out-of-order execution | Major redesign; incompatible with current pipeline |
| Superscalar (dual-issue) | Would push CM/MHz toward ~4.5 but requires 2× decode width, 4-read-port register file, and dual hazard logic — a near-complete redesign. Worth considering as a separate "NoX v2" project. |
