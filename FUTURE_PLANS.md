# NOX RISC-V Core — Future Improvement Plans

## Current Performance Baseline (2026-03-23)

- **CoreMark/MHz: 0.909** at -O2, 300 MHz (NanGate 45nm)
- **IPC ≈ 0.664** (365M instructions / 550M cycles, 500-iter CoreMark -O2)
- ~34% of cycles wasted to stalls — breakdown estimated below

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

### 4. Branch misprediction penalty (~3 cycles)
With a 4-stage pipeline, mispredictions detected in Execute require flushing Fetch and
Decode and re-fetching from the correct PC. The bimodal BHT (64 entries) handles simple
loops well after warmup, but aliasing and cold-start misses still occur.

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

### P5 — Reduce misprediction penalty from 3 to 2 cycles
**Files:** `rtl/fetch.sv`, `rtl/execute.sv`

Currently the pipeline takes 3 cycles to redirect after a misprediction (detect in EX
→ F_CLR → new fetch begins). Investigate whether the F_CLR state can be eliminated by
allowing fetch to accept the redirect address in a single cycle (bypass the OT FIFO
flush). This is a pipeline restructuring change and requires careful verification.

Expected gain: **+2–5% CM/MHz** (depends on misprediction frequency from P1 data).

### P6 — Evaluate 2-stage fetch pipeline / instruction cache
If frequency is pushed beyond 400 MHz, the AXI fetch round-trip (1 cycle latency in
the current axi_mem testbench model) may become the bottleneck. A small direct-mapped
instruction cache (1–2 KB, 4-word lines) would hide DRAM latency and improve fetch
throughput for loops. This is a significant addition.

---

## Won't Do (and why)

| Idea | Reason |
|------|--------|
| Eliminate load-use stall entirely | Reintroduces the 3.11 ns in2out path that failed timing |
| Out-of-order execution | Major redesign; incompatible with current pipeline philosophy |
| Superscalar (dual-issue) | Significant area cost; diminishing returns for RV32I embedded use |
