# NoX v2 — Application-Level RISC-V Processor

**Goal:** A Linux-capable RV64GC processor with out-of-order execution, hardware FPU, and
virtual memory — targeting competitive single-thread performance on real Linux workloads.

**North star metric:** ≥ 3.5 CoreMark/MHz at ≥ 1 GHz on 28/45nm (≥ 3,500 CoreMark raw).
Linux boot to shell, SPEC CPU 2017 INT estimated IPC ≥ 2.0.

---

## Table of Contents

1. [Why v2 — What v1 Cannot Do](#why-v2)
2. [ISA Target](#isa-target)
3. [Architecture Overview](#arch-overview)
4. [Component Designs](#components)
   - [64-bit Datapath](#64bit)
   - [FPU](#fpu)
   - [MMU and Virtual Memory](#mmu)
   - [Privilege and CSR Expansion](#privilege)
   - [Caches](#caches)
   - [Out-of-Order Engine](#ooo)
   - [Branch Predictor Upgrade](#bp)
   - [Compressed Instructions (C extension)](#compressed)
5. [Pipeline Structure](#pipeline)
6. [Implementation Roadmap](#roadmap)
7. [Complexity and Risk Assessment](#risk)
8. [Won't Do (v2 scope)](#wont-do)

---

## <a name="why-v2"></a> 1. Why v2 — What v1 Cannot Do

NoX v1 is an in-order RV32 core with M-mode only. It cannot run Linux because:

| Requirement | v1 status | v2 target |
|---|---|---|
| 64-bit address space | ✗ RV32 (4 GB) | ✓ RV64 (512 GB Sv39) |
| Supervisor mode | ✗ M-mode only | ✓ M+S+U modes |
| Virtual memory (MMU) | ✗ none | ✓ Sv39, TLB, PTW |
| Double-precision FP | ✗ none | ✓ F+D (RV64D) |
| Compressed instructions | ✗ none | ✓ C extension |
| `mret`/`sret` | partial | ✓ full privilege switching |
| `SFENCE.VMA` | ✗ | ✓ TLB shootdown |
| `FENCE.I` | ✗ | ✓ I-cache invalidation |
| Out-of-order execution | ✗ in-order | ✓ ROB + OOO issue |
| Hardware divide latency | 32 cycles | ≤ 10 cycles (radix-4 SRT) |

The v1 → v2 jump is not incremental. It is a clean-sheet redesign sharing the test
infrastructure (Verilator, CoreMark port, AXI bus package) but rewriting all RTL.

---

## <a name="isa-target"></a> 2. ISA Target

**RV64GCZba_Zbb_Zicond_Zicsr_Zifencei**

where G = IMAFD:
- **I** — base integer (64-bit registers, LW/LD/SD, ADDIW, etc.)
- **M** — multiply/divide (MUL, MULW, DIV, DIVW, REM, REMW)
- **A** — atomics (LR/SC, AMO* — already in v1)
- **F** — single-precision FP (32 FP registers, FADD.S, FMUL.S, FDIV.S, FSQRT.S, FMA)
- **D** — double-precision FP (extends F registers to 64 bits, FADD.D, ...)
- **C** — compressed 16-bit instructions (~25% code-size reduction)
- **Zba/Zbb/Zicond** — already in v1 (carry forward)
- **Zicsr** — CSR instructions (already in v1)
- **Zifencei** — FENCE.I for I-cache coherency (trivial: flush I-TLB + pipeline)

**Not targeted for v2:**
- V (vector): fundamental redesign of data paths; better as "v3"
- H (hypervisor): not needed for bare-metal Linux
- Zfinx: using separate FP register file (simpler, better FP IPC)
- Zkn/Zks (crypto): useful but orthogonal to performance goals

### Why 64-bit?

All mainstream Linux distributions now target RV64. The 32-bit address space of RV32 is
a practical limitation for modern applications (no mmap of large files, no >4 GB heap).
The register width cost is real — the register file doubles in area — but unavoidable.

---

## <a name="arch-overview"></a> 3. Architecture Overview

```
                  ┌─────────────────────────────────────────────────────┐
                  │                   NoX v2 Pipeline                   │
                  │                                                     │
  ┌──────────┐    │ ┌──────┐ ┌───────┐ ┌────────┐ ┌──────┐ ┌───────┐  │
  │  L2 Cache│◄───┤ │ BPU  │ │ Fetch │ │ Decode │ │Rename│ │Dispatch│  │
  │(256 KB   │    │ │(TAGE)│ │+I-TLB │ │+decomp │ │+RAT  │ │+IQ    │  │
  │  shared) │    │ └──┬───┘ └───┬───┘ └───┬────┘ └──┬───┘ └───┬───┘  │
  └──────────┘    │   │         │          │         │         │       │
       ▲          │   └─────────┴──────────┴─────────┴─────────┘       │
       │          │                Front-End (5 stages)                 │
  ┌────┴─────┐    │                                                     │
  │  D-Cache │    │ ┌──────────┐ ┌──────────┐ ┌──────────┐ ┌───────┐  │
  │ (32 KB,  │◄───┤ │ Int ALU  │ │ FP Unit  │ │ Ld/St    │ │  ROB  │  │
  │  D-TLB)  │    │ │ 2× pipes │ │ FADD/FMUL│ │ +D-TLB   │ │ (64e) │  │
  └──────────┘    │ └──────────┘ └──────────┘ └──────────┘ └───────┘  │
                  │              Back-End (6 stages)                    │
                  └─────────────────────────────────────────────────────┘
```

**Key parameters:**

| Parameter | Value | Rationale |
|---|---|---|
| Issue width | 2 instructions/cycle (superscalar) | Balanced ILP vs complexity |
| OOO depth | 64-entry ROB | ~8-10 cycle mispredict budget |
| Physical registers | 96 INT + 96 FP | 64 rename slots above 32 architectural |
| Issue queues | 16-entry INT, 8-entry FP, 8-entry Mem | Separate scheduling domains |
| Branch predictor | TAGE (6 tables) | ~96% accuracy target |
| L1 I-cache | 32 KB, 4-way, 64B lines | 1-cycle hit, sufficient for Linux |
| L1 D-cache | 32 KB, 4-way, 64B lines | 4-cycle load-to-use |
| L2 cache | 256 KB unified, 8-way | Shared, 12-cycle hit |
| I-TLB | 32-entry, fully associative | Near-zero miss rate for code |
| D-TLB | 64-entry, fully associative | Most Linux workloads fit |
| Pipeline stages | 11 | Allows 1 GHz+ on 28nm |
| Target frequency | 1 GHz (28nm), 333 MHz (45nm) | Matches TSMC 28nm HPC |

---

## <a name="components"></a> 4. Component Designs

---

### <a name="64bit"></a> 4.1 — 64-bit Datapath

**Impact:** Pervasive — every register, immediate, ALU, and memory path widens.

**New instructions vs v1:**
- Word-width ALU ops: ADDIW, SLLIW, SRLIW, SRAIW, ADDW, SUBW, SLLW, SRLW, SRAW, MULW, DIVW, etc.
- Wider load/store: LD, LWU, SD (v1 only had LW, LH, LB, SW, SH, SB)
- 64-bit multiply: MULH, MULHSU, MULHU must produce 64-bit upper halves

**Multiplier:**
- v1: 33×33-bit signed product, 2-cycle pipelined
- v2: 65×65-bit product (for MULH*), 3-4 cycle pipelined
- Alternatively: 64×64 unsigned with separate sign correction for signed variants

**Divider:**
- v1: 32-cycle restoring shift-subtract
- v2: radix-4 SRT divider, 16 cycles for 64-bit (eliminates most MulDiv stalls)
- DIVW/REMW reuse the 32-bit path (zero-extend inputs, sign-extend result)

**Register file:**
- 32 × 64-bit INT registers (doubles v1 area)
- 32 × 64-bit FP registers (new; shared for F and D)
- For OOO: 96-entry physical INT register file + 96-entry physical FP register file

---

### <a name="fpu"></a> 4.2 — Floating-Point Unit (FPU)

Linux glibc, libm, and essentially all C code uses FP extensively.
D extension (double-precision) is required; F alone would cause library emulation overhead.

**FP register file:** 32 × 64-bit (lower 32 bits hold SP floats, full 64 bits hold DP floats).

**Pipeline design:**

```
  Operands ──► Align/Unpack ──► [Exponent] ──► Normalize ──► Round ──► Result
               (stage 1)         (stage 2)      (stage 3)    (stage 4)
```

| Operation | Stages | Notes |
|---|---|---|
| FADD/FSUB | 4 | Exponent align → mantissa add → normalize → round |
| FMUL | 4 | Mantissa multiply (64×52+1 bit product) → normalize → round |
| FMADD/FMSUB (FMA) | 5 | As FMUL but with add tree merged into normalize |
| FDIV/FSQRT | 16 | SRT radix-2 iterative (reuses HW, low area cost) |
| FCVT.* | 2 | Integer↔FP conversion |
| FCMP, FCLASS | 1 | Comparators on exponent+mantissa |
| FMV.* | 1 | Register copy, no arithmetic |

**Area estimate (45nm):** ~40,000 gates for DP FPU (vs 88.66 KGE for entire v1 core).

**FP → INT forwarding:** FCVT/FMV results can be forwarded to INT pipeline in the same
cycle they commit from the FP pipe.

**Denormal handling:** Support IEEE 754-2008 denormals in hardware (required by Linux).
The `mstatus.FS` field tracks whether FP state is dirty (for context switch efficiency).

---

### <a name="mmu"></a> 4.3 — MMU and Virtual Memory

This is the most complex new component and the **hard prerequisite for Linux**.

**Virtual address scheme: Sv39**
- 39-bit virtual address (256 GB per process)
- 3-level page table (PGD → PMD → PTE), each level has 512 × 8-byte entries
- Page size: 4 KB (also supports 2 MB and 1 GB hugepages via early termination)

**`satp` CSR:** MODE[63:60] | ASID[59:44] | PPN[43:0]
- MODE = 8 → Sv39 enabled; 0 → bare (physical addressing, used in M-mode)

**TLBs:**

| TLB | Size | Associativity | Latency |
|---|---|---|---|
| I-TLB | 32 entries | Fully associative | 0 cycles (parallel with cache index) |
| D-TLB | 64 entries | Fully associative | 0 cycles (parallel with cache index) |
| Joint L2 TLB | 512 entries, shared | 4-way | 3-4 cycles (on I/D-TLB miss) |

For most Linux workloads, a 64-entry D-TLB covers the working set.

**Page Table Walker (PTW):**
- Hardware state machine, triggered on TLB miss
- Issues up to 3 sequential L2-cached loads (one per page table level)
- Best case: 3 × L2 hit latency ≈ 3 × 12 = 36 cycles
- If any level misses L2: main memory walk (~100+ cycles)
- Supports hugepage shortcut (stop at PGD or PMD with leaf PTE)
- Generates page fault exceptions (instruction/load/store access fault, page fault)

**SFENCE.VMA:**
- Flushes TLB entries matching RS1 (VA) and RS2 (ASID)
- RS1=x0 → flush all entries for ASID
- RS2=x0 → flush all entries for VA across all ASIDs
- Full flush (both x0) → flush entire TLB

**Critical path consideration:**
- The TLB lookup is in parallel with cache index computation (VA[11:0] directly indexes the cache, no translation needed for 4-way 32 KB I$/D$ with 64B lines)
- The physical tag comparison follows TLB → 1 cycle total (virtually-indexed, physically-tagged / VIPT)

---

### <a name="privilege"></a> 4.4 — Privilege and CSR Expansion

**Privilege modes:** M (machine) → S (supervisor, Linux kernel) → U (user, applications)

**Trap delegation:** `medeleg` / `mideleg` allow M-mode to delegate exceptions/interrupts
to S-mode. Linux expects all page faults and syscall traps to land in S-mode.

**New S-mode CSRs:**

| CSR | Purpose |
|---|---|
| `satp` | Address translation control (Sv39 enable + ASID + root PPN) |
| `stvec` | S-mode trap vector |
| `sepc` | S-mode exception program counter |
| `scause` | S-mode trap cause |
| `stval` | S-mode trap value |
| `sstatus` | S-mode status (shadow of mstatus with restricted view) |
| `sie` / `sip` | S-mode interrupt enable / pending (shadows of mie/mip) |
| `sscratch` | S-mode scratch register |
| `scounteren` | Counter access from U-mode control |

**Additional M-mode CSRs needed:**

| CSR | Purpose |
|---|---|
| `medeleg` | Exception delegation to S-mode |
| `mideleg` | Interrupt delegation to S-mode |
| `mcounteren` | Counter access from S-mode control |
| `mtime` / `mtimecmp` | Timer (memory-mapped, not CSRs proper) |
| `pmpcfg0-3`, `pmpaddr0-15` | Physical memory protection (optional for v2) |

**Interrupt controller:**
- A CLINT (Core-Local Interrupt) is needed for timer and software interrupts
- A PLIC (Platform-Level Interrupt Controller) for external interrupts
- Both are memory-mapped peripherals outside the core; the core just has MIP bits

---

### <a name="caches"></a> 4.5 — Caches

Without caches, an OOO core gains nothing — the bottleneck shifts to memory latency.
Caches are **the most impactful component for real-world Linux performance**.

**L1 Instruction Cache (32 KB, 4-way, 64B lines):**
- VIPT: index on VA[11:6], tag on PA[55:12] (no aliasing for 4-way 32 KB with 64B lines)
- 2 fetch slots per cycle (for 2-wide fetch)
- Critical path: 1 cycle hit latency (registered output)
- On miss: stall fetch, issue L2 request, 12-cycle fill (best case)
- FENCE.I: invalidate all I-cache lines (full flush acceptable for v2)
- Miss rate target: < 1% for typical Linux workloads

**L1 Data Cache (32 KB, 4-way, 64B lines):**
- Same VIPT indexing as I-cache
- Write policy: write-back, write-allocate
- **Load-to-use latency: 4 cycles** (address → TLB → tag compare → data → execute)
- 4 MSHRs (Miss Status Holding Registers) for out-of-order miss handling
- Store buffer: 8-entry FIFO before cache; stores commit from ROB to buffer, drain to cache
- AMO operations: acquired from L2 as exclusive lines

**L2 Unified Cache (256 KB, 8-way, 64B lines):**
- Physically-indexed, physically-tagged (PIPT)
- Shared between I and D caches
- 12-cycle hit latency (pipelined access)
- Inclusive of L1 (simplifies coherency)
- Write policy: write-back

**Cache coherency:**
- Single-core for v2: no coherency protocol needed
- SFENCE.VMA flushes D-TLB only; cache is PA-indexed so no flush required on address space switch
- LR/SC: exclusive access request to L2 on LR; reservation broken by any other store to same PA

---

### <a name="ooo"></a> 4.6 — Out-of-Order Engine

OOO is the single largest complexity increase vs v1. It enables IPC > 1 by executing
independent instructions while waiting for earlier loads, divides, or FP ops.

**Why OOO matters vs just going superscalar in-order:**
An in-order 2-wide core stalls both slots when one instruction has a long-latency
dependency. OOO allows the second slot to continue with independent work during a
64-bit divide (16 cycles) or L2 cache miss (12 cycles). Expected IPC lift: ~1.5× vs in-order.

**Core OOO structures:**

#### Register Alias Table (RAT)
- Maps 32 architectural INT + 32 FP registers → physical register IDs
- On rename: allocate new physical register for each destination
- Size: 64 architectural → 96 physical per register file
- 2 write ports (2-wide rename), 4 read ports (2 × 2 source operands)

#### Reorder Buffer (ROB)
- 64 entries, circular queue (head=oldest, tail=newest)
- Each entry: PC, physical dest reg, old physical reg (for freelist reclaim on commit),
  exception info, branch misprediction flag, FP dirty bit, load/store type
- **Commit rule:** entries commit in-order when head is marked complete and no exception
- On misprediction: flush ROB from tail back to mispredicted branch, restore RAT
  from the architectural register checkpoint

#### Issue Queues (Reservation Stations)
- **Integer IQ:** 16 entries, wakes up when both source operands have results
  - Executes on 2 integer ALU pipelines (symmetric: both handle ADD/SHIFT/BRANCH)
  - Age-priority or oldest-first selection
- **FP IQ:** 8 entries, feeds FPU pipeline
- **Memory IQ:** 8 entries, feeds load/store unit
  - Loads can issue speculatively out-of-order (store-to-load forwarding from store buffer)
  - Stores must wait for both address and data to be known

#### Load/Store Unit with Memory Disambiguation
- **Load Queue:** 16 entries, holds in-flight loads until commit
- **Store Queue:** 16 entries, holds stores until ROB commit (then drain to D-cache)
- **Store-to-load forwarding:** if a load address matches a store in the store queue, forward
  data directly (avoids D-cache round-trip)
- **Memory ordering:** detect load-store ordering violations after-the-fact (requires
  re-execution) or conservatively (simpler, slight performance loss)

#### Physical Register File (PRF)
- 96 INT × 64-bit + 96 FP × 64-bit
- 4 read ports + 2 write ports each (for 2-wide)
- Area: ~6× larger than architectural register file
- Mapped via RAT; free list managed as ROB entries retire

#### Misprediction Recovery
- On misprediction (detected at branch execute, ~7 cycles after fetch):
  1. Flush ROB entries after the branch (squash speculative work)
  2. Restore RAT to the checkpoint saved at branch dispatch
  3. Reclaim physical registers freed by squashed instructions
  4. Redirect fetch to correct PC
- Checkpoint saved per branch in ROB entry (adds 96+96 bits of state per ROB entry)
  OR use a walk-back scheme (simpler, but slower recovery: one cycle per squashed instruction)

**Recommended for v2:** Walk-back RAT recovery (simpler, ~10 cycle recovery overhead).
Checkpoint-based recovery for later optimization.

---

### <a name="bp"></a> 4.7 — Branch Predictor Upgrade

With an 11-stage pipeline, a misprediction costs ~9 cycles instead of 2.
Branch predictor accuracy becomes **much more critical** than in v1.

**TAGE (TAgged GEometric history length):**
- Base bimodal predictor + 6 tagged predictor tables with geometric history lengths
- History lengths: 5, 10, 20, 40, 80, 160 bits
- Each tagged table: 256–512 entries, 2-bit saturating counter + tag + usefulness counter
- Prediction: longest-matching history table wins; fallback to shorter history or base
- Accuracy: ~96-97% on SPEC CPU 2017 INT (vs ~91% with bimodal in v1)
- Expected benefit: mispredict rate 9% → 3-4%, saving ~6% × 9 cycles = significant

**Indirect Branch Predictor (ITTAGE or simple BTB):**
- v1 RAS handles returns well (82.7% hit rate)
- For Linux: indirect calls via vtables and function pointers; a dedicated 64-entry ITTAGE
  table with history would improve coverage
- Simpler alternative: 64-entry indirect BTB (last-value predictor per target)

**BTB:** 512 entries, 4-way, indexed by PC[10:1] — larger footprint than v1's 128-entry
direct-mapped BTB, handles bigger working sets from Linux kernel + libraries.

**RAS:** 16 entries (v1 had 4; Linux kernel has deep call stacks during syscalls)

---

### <a name="compressed"></a> 4.8 — Compressed Instructions (C Extension)

The C extension maps common RV64I instructions to 16-bit encodings:
- 32 instructions covering ~90% of dynamic instruction stream
- ~25-30% code size reduction → better I-cache utilization
- Required by all standard Linux toolchains (GCC/Clang default -march=rv64gc)

**Implementation complexity: HIGH** (but unavoidable for Linux ABI compatibility)

The challenge: instructions can be 16 or 32 bits, and they can straddle 4-byte boundaries.
Fetch must buffer 48 bits and handle alignment correctly.

**Implementation approach:**
1. **Fetch buffer:** fetch 64-bit aligned words; maintain a 64-bit shift register
2. **Pre-decode:** identify 16-bit vs 32-bit boundaries before decode
3. **Expander:** convert 16-bit C instructions to 32-bit canonical form before decode
   - This is a pure combinational mapping — ~100 lines of case statements
   - No new opcodes added to the decode/execute pipeline
4. **Instruction alignment:** for 2-wide fetch, pack 2 instructions regardless of 16/32 mix

The expander is a well-defined mapping specified in the RISC-V ISA manual (appendix C).
Total gate count: ~2,000 gates per expander (two needed for 2-wide).

---

## <a name="pipeline"></a> 5. Pipeline Structure

**11-stage pipeline:**

```
Stage | Name         | Key Work
------+--------------+----------------------------------------------------------
  1   | PC Gen       | PC mux: branch prediction, exception, redirect
  2   | Fetch        | I-cache lookup, I-TLB lookup (parallel)
  3   | Align        | C-extension alignment, 48-bit fetch buffer management
  4   | Decode       | Instruction decode, C expansion, illegal instruction detect
  5   | Rename       | RAT lookup, physical register allocation, ROB entry alloc
  6   | Dispatch     | Insert into IQ, read PRF for ready operands
  7   | Issue        | Wake-up + select: oldest-ready instruction wins
  8   | Reg Read     | PRF read (for late-arriving operands)
  9   | Execute      | ALU / FP stage 1 / D-TLB + D-cache address
 10   | Memory       | D-cache data read / FP stage 2 / MUL stage 2
 11   | Writeback    | PRF write, ROB complete mark, FP stage 3
 --   | Commit       | In-order ROB commit (not a pipeline stage; runs every cycle)
```

**Branch misprediction penalty:** stages 1-7 must be flushed = ~7 wasted cycles.

**Load-to-use latency:** stages 9-11 = 3 cycles (address → TLB → cache data → writeback).
A dependent instruction issued 3+ cycles later has zero penalty; issued earlier stalls in IQ.

---

## <a name="roadmap"></a> 6. Implementation Roadmap

The components divide naturally into 5 phases, each independently testable.

### Phase 1: RV64 In-Order Core (foundation)
**Estimated complexity: MEDIUM**

Start with v1 architecture, widen to 64 bits.
- [x] Widen all registers, immediates, ALU to 64 bits
- [x] Add LD/LWU/SD, ADDIW/SUBW/SLL/SRLx/SRAx word variants
- [x] Extend multiplier to 65×65 (MULH, MULHSU, MULHU)
- [x] Add C extension expander (pre-decode stage)
- [x] Carry forward all v1 optimizations (branch predictor, RAS, forwarding)

**Test:** CoreMark 64-bit, basic Linux boot (M-mode only, no MMU, no FP)

---

### Phase 2: Privilege + MMU (Linux prerequisite)
**Estimated complexity: HIGH** — **2A/2B/2C COMPLETE; 2D IN PROGRESS (2026-04-04)**

- [x] Add S-mode and U-mode privilege levels
- [x] Implement `medeleg` / `mideleg` delegation
- [x] Add all S-mode CSRs (`satp`, `stvec`, `sepc`, `scause`, `stval`, `sstatus`, `sie`, `sip`)
- [x] Implement Sv39 TLBs (I-TLB 32-entry + D-TLB 64-entry, fully associative)
- [x] Implement hardware Page Table Walker
- [x] Add `SFENCE.VMA` and `FENCE.I`
- [x] Connect timer (CLINT) and external interrupt (PLIC stub)
- [x] Linux testbench (`tb/nox_sim_linux.sv`): unified 64 MB dual-port memory, NS16550A UART
- [x] OpenSBI minimal `nox` platform (`sw/opensbi/platform/nox/`) — 133 KB binary
- [x] Linux v6.6 kernel with embedded BusyBox 1.36.1 initramfs (`sw/linux/`, `sw/busybox/`)
- [x] Device tree (`sw/nox.dts` / `sw/nox.dtb`) and boot script (`sw/run_linux.sh`)
- [ ] **First boot run** — Linux kernel to BusyBox `/bin/sh` (acceptance gate)

**Sub-phase tests:**
- `sw/priv_test/priv_test.elf` — ECALL delegation → S-mode → SRET. **Prints PASS.**
- `sw/clint_test/clint_test.elf` — timer IRQ, SW IRQ (MSIP), PLIC readback. **All PASS.**
- `sw/mmu_test/mmu_test.elf` — gigapage identity map, D-TLB store/load, load page fault
  trap+MRET, SFENCE.VMA. **Prints PASS.**

**Boot command:**
```bash
make linux_sim WAVEFORM_USE=0 OUT_LINUX=output_linux_sim
./sw/run_linux.sh
```

**Acceptance gate:** Linux kernel boots to BusyBox shell (`cat /proc/cpuinfo` works).

---

### Phase 3: Caches
**Estimated complexity: MEDIUM-HIGH**

- [ ] L1 I-cache (32 KB, 4-way, 64B lines) with VIPT and FENCE.I
- [ ] L1 D-cache (32 KB, 4-way, 64B lines, write-back, 4 MSHRs)
- [ ] Store buffer (8-entry commit FIFO)
- [ ] L2 unified cache (256 KB, 8-way)
- [ ] AMO exclusive access through cache hierarchy
- [ ] L2 miss to AXI main memory

**Test:** Linux with filesystem I/O, cache miss rate, dhrystone/CoreMark under Linux.

---

### Phase 4: FPU
**Estimated complexity: MEDIUM**

- [ ] 32 × 64-bit FP register file
- [ ] 4-stage pipelined FADD/FSUB/FMUL (SP and DP)
- [ ] 5-stage FMADD/FMSUB/FNMADD/FNMSUB (FMA)
- [ ] Iterative FDIV/FSQRT (radix-2 SRT, 16 cycles)
- [ ] FCVT.* (integer↔FP conversion)
- [ ] FCMP, FCLASS, FMV.*
- [ ] IEEE 754-2008 compliance: rounding modes, denormals, NaN, infinity, exceptions
- [ ] `mstatus.FS` dirty tracking

**Test:** glibc FP, SPEC CPU 2017 FP subset, `libm` test suite.

---

### Phase 5: Out-of-Order Engine
**Estimated complexity: VERY HIGH**

This is the major performance multiplier. Best approached iteratively:

**Phase 5a: 2-wide in-order superscalar** (intermediate milestone)
- Fetch 2 instructions per cycle
- Issue in-order, detect structural/data hazards for pairs
- Expected gain: ~1.5× over single-issue in-order (IPC ~1.3)

**Phase 5b: Register renaming (RAT + freelist)**
- Add physical register file (96 INT + 96 FP)
- Implement RAT rename on dispatch
- Still in-order issue (test renaming independently of scheduling)

**Phase 5c: ROB + OOO issue**
- Circular ROB, 64 entries
- Per-domain issue queues (INT 16, FP 8, Mem 8)
- Wake-up/select logic
- In-order commit from ROB head

**Phase 5d: Misprediction recovery + memory disambiguation**
- Walk-back RAT restore on branch misprediction
- Load/store queue with store-to-load forwarding
- Memory ordering violation detection

**Phase 5e: TAGE branch predictor**
- Replace bimodal BHT with TAGE (6 tables)
- Integrate with OOO speculative fetch

**Expected final IPC:** 2.0–2.5 for CoreMark, 1.8–2.2 for SPEC CPU INT.

---

## <a name="risk"></a> 7. Complexity and Risk Assessment

| Component | Complexity | Risk | Mitigation |
|---|---|---|---|
| 64-bit widening | MEDIUM | LOW | Mechanical widening of v1; well-understood |
| C extension expander | MEDIUM | LOW | Pure combinational mapping; well-specified |
| Privilege (M+S+U) | MEDIUM | ~~MEDIUM~~ **DONE** | CSR interactions subtle; Linux boot as gate |
| Sv39 TLBs | MEDIUM | ~~MEDIUM~~ **DONE** | Correctness-critical; use riscv-tests vectors |
| Page Table Walker | MEDIUM-HIGH | ~~MEDIUM~~ **DONE** | Corner cases: misaligned PTE, A/D bits, hugepages |
| L1/L2 caches | MEDIUM-HIGH | LOW | Well-understood; start with direct-mapped |
| FPU | MEDIUM | LOW | IEEE 754 compliance tools available (TestFloat) |
| 2-wide superscalar (in-order) | MEDIUM | LOW | Limited new hazard cases |
| Register renaming | HIGH | MEDIUM | Correctness tricky; test with formal verification |
| ROB + OOO scheduling | VERY HIGH | HIGH | Most complex state machine; needs extensive sim |
| Memory disambiguation | HIGH | HIGH | Load-store ordering violations are subtle bugs |
| TAGE predictor | MEDIUM | LOW | Isolated module; correctness tested on prediction accuracy |

**Overall:** Phases 1-4 are feasible with ~6-12 months of focused work. Phase 5 (OOO) is a
6-12 month project on its own. **Linux boot (Phase 2) is the first hard milestone** — it
validates the privilege/MMU implementation before investing in performance features.

---

## <a name="wont-do"></a> 8. Won't Do (v2 Scope)

| Feature | Reason |
|---|---|
| RV32 compatibility | Clean 64-bit design is simpler; no mixed-width support |
| V extension (vector) | Would double the back-end; plan for v3 if desired |
| H extension (hypervisor) | Not needed for bare-metal Linux; Sv39 is sufficient |
| SMT (simultaneous multithreading) | Another core is simpler for throughput at this scale |
| Hardware prefetcher | Good caches + OOO memory parallelism covers most cases |
| ECC / RAS features | Relevant for server-class; out of scope for v2 |
| Custom trace / debug | Use existing RISC-V debug spec (external JTAG DTM) |
| PMP | Useful for security but not required for functional Linux boot |
| Out-of-order commit | In-order commit (ROB) is sufficient for non-server workloads |

---

## Sizing Summary

| Metric | NoX v1 | NoX v2 (estimate) |
|---|---|---|
| Gate count | 88.66 KGE | ~800–1,200 KGE |
| Flip-flops | ~6,321 | ~40,000–60,000 |
| Register file | 32×32b = 1 Kbit | 2×96×64b = 12 Kbit (OOO PRF) |
| Pipeline depth | 4 stages | 11 stages |
| Branch mispredict penalty | 2 cycles | ~7 cycles |
| L1 I-cache | none | 32 KB (4-way) |
| L1 D-cache | none | 32 KB (4-way) |
| L2 cache | none | 256 KB (8-way) |
| Target frequency (45nm) | 333 MHz | 500 MHz (in-order), 400 MHz (OOO) |
| Target frequency (28nm) | — | 1–1.2 GHz (OOO) |
| CoreMark/MHz | 2.893 | ~3.5–4.5 (target) |
| IPC (CoreMark) | 0.871 | ~2.0–2.5 (OOO) |

The gate count increase is driven primarily by caches (~500 KGE for both L1+L2), the
physical register files (~60 KGE), ROB + issue queues (~40 KGE), and the FPU (~40 KGE).
Without caches, the core logic alone would be ~200–300 KGE — comparable to the ARM Cortex-A5.

---

## Progress Log

### Phase 1: RV64 In-Order Core

**2026-03-26 — Step 1: Widen core parameters to 64-bit** ✅
- `riscv_pkg.svh`: `PC_WIDTH` 32→64, `XLEN` 32→64, `shamt_t` 5→6 bits
  - Fixed `instr_raw_t` hardcoded to 32-bit (was XLEN-dependent)
  - Fixed `raddr_t` hardcoded to 5-bit (was `$clog2(XLEN)-1:0`)
  - Added `RV_LSU_D` (doubleword) and `RV_LSU_WU` (unsigned word) to `lsu_w_t`
  - Added `is_word_op` flag to `s_id_ex_t` for *W instruction support
  - Widened `gen_imm` sign-extension for all immediate types
  - Widened `s_trap_info_t.mtval` to XLEN (was `instr_raw_t`)
- `core_bus_pkg.svh`: `CB_ADDR_WIDTH` 32→64, `CB_DATA_WIDTH` 32→64, added `CB_DWORD`
- `nox_pkg.svh`: `M_ISA_ID` → RV64 MXL=2 encoding
- `amba_axi_pkg.sv`: `AXI_ADDR_WIDTH` 32→64, `AXI_DATA_WIDTH` 32→64

**2026-03-26 — Step 2: Fix width mismatches across all RTL** ✅
- `csr.sv`: 64-bit constants, mcause bit 63, MTVEC widening, interrupt cause widths
- `lsu.sv`: 64-bit bus, LD/SD/LWU support, mask_strobe, AMO widening
- `execute.sv`: 64-bit ALU, Zbb widening (clz/ctz/cpop/rol/ror/orc.b/rev8 for 64-bit)
- `wb.sv`: 64-bit `fmt_load` sign/zero extension (LB/LH/LW/LD/LBU/LHU/LWU)
- `fetch.sv`: 64-bit PC, instruction lane selection from 64-bit bus word

**2026-03-26 — Step 3: Widen muldiv_unit to 64-bit** ✅
- 65×65 signed multiplier (was 33×33), 130-bit product
- 64-cycle restoring divider (was 32-cycle), 64-bit remainder/quotient
- Added `word_op_i` port for *W instructions (MULW/DIVW/REMW)
- Word ops: sign-extend inputs, use 32-cycle div, sign-extend 32-bit result

**2026-03-26 — Step 4: Add *W instruction decode** ✅
- `decode.sv`: Added `RV_OP_IMM_32` case (ADDIW, SLLIW, SRLIW, SRAIW)
- `decode.sv`: Added `RV_OP_32` case (ADDW, SUBW, SLLW, SRLW, SRAW, MULW, DIVW, REMW)
- Both cases set `is_word_op = 1` and dispatch through existing ALU/muldiv paths
- `execute.sv`: Added word-op operand narrowing before ALU (zero-extend for SRLW, sign-extend for SRAW)
- `execute.sv`: Added 32→64 sign-extension of ALU result for word ops

**2026-03-26 — Step 5: Widen testbench** ✅
- `tb/axi_mem.sv`: 64-bit memory words, 64-bit address constants, widened functions
- `tb/nox_sim.sv`: writeWordIRAM/DRAM pack 32-bit words into 64-bit memory entries
- `tb/cpp/testbench.cpp`: Accept both ELFCLASS32 and ELFCLASS64

**Build status:** Clean compilation, zero Verilator warnings. Simulator binary: `output_verilator_rv64/nox_sim`

**2026-03-27 — Step 6: Add C extension (compressed instructions)** ✅
- `rtl/rvc_expander.sv`: New module — pure combinational 16→32 bit instruction expander
  - Covers all RV64C instructions: C.ADDI, C.LI, C.LUI, C.ADDI16SP, C.ADDIW, C.SRLI,
    C.SRAI, C.ANDI, C.SUB, C.XOR, C.OR, C.AND, C.SUBW, C.ADDW, C.J, C.BEQZ, C.BNEZ,
    C.SLLI, C.LWSP, C.LDSP, C.MV, C.ADD, C.JALR, C.JR, C.SWSP, C.SDSP, C.LW, C.LD,
    C.SW, C.SD, C.NOP, C.EBREAK
- `rtl/fetch.sv`: Complete rewrite for variable-width instruction alignment
  - 64-bit bus word → parcel-based alignment engine (4 × 16-bit parcels per word)
  - Handles 16/32-bit instruction boundaries, including 32-bit instructions straddling
    64-bit bus word boundaries (pending parcel mechanism)
  - RVC expander integrated inline; `is_compressed` flag propagated through L0 FIFO
  - L0 FIFO widened to 98 bits: [97:34]=predict_target, [33]=bp_taken, [32]=is_compressed, [31:0]=instr
- `rtl/decode.sv`: PC tracking updated for compressed instructions
  - PC increment: `+2` for compressed, `+4` for full-width (based on previous `is_compressed`)
  - Fixed `is_compressed` corruption during pipeline bubbles — only update bp_taken,
    bp_predict_target, is_compressed when consuming a valid instruction (`fetch_valid_i && id_ready_i`)
  - PC override mechanism for branch predictor updates arriving during FIFO-empty states
- `rtl/execute.sv`: Instruction address misalignment checks relaxed for C extension
  - Changed from 4-byte alignment (`addr[1]`) to 2-byte alignment (`addr[0]`)
  - Added `branch_compressed_ff` register for correct fall-through address (+2 vs +4)
  - JAL/JALR return address: `pc + 2` for compressed, `pc + 4` for full-width
- `rtl/nox.sv`: Added `is_compressed` signal wiring (fetch→decode)
- `rtl/inc/riscv_pkg.svh`: Added `is_compressed` field to `s_id_ex_t`
- `rtl/inc/nox_pkg.svh`: Reduced `FIFO_SLOTS` 4→2 (optimized for alignment engine)
- `tb/axi_mem.sv`: Fixed AXI `arready` back-pressure (was unconditionally accepting
  read requests, causing response data overwrites)

**Test status:**
- RV64C test (13 compressed instruction types + C.SWSP/C.LWSP stack operations): **PASS**
- Non-compressed test (`.option norvc`): **PASS** (no regression)
- hello_world (existing RV64 test): **PASS** (no regression)

### Phase 1 Checklist
- [x] Widen all registers, immediates, ALU to 64 bits
- [x] Add LD/LWU/SD, ADDIW/SUBW/SLL/SRLx/SRAx word variants
- [x] Extend multiplier to 65×65 (MULH, MULHSU, MULHU)
- [x] Add C extension expander (pre-decode stage)
- [x] Carry forward all v1 optimizations (branch predictor, RAS, forwarding)

### Phase 2: Privilege + MMU Progress Log

**2026-04-01 — Phase 2A: Privilege modes + S-mode CSRs + CLINT + PLIC** ✅
- `rtl/csr.sv`: `priv_mode_ff[1:0]` (reset=M), S-mode CSRs (stvec/sscratch/sepc/scause/stval),
  `medeleg`/`mideleg`, `satp` (MODE+ASID+PPN), SRET, trap delegation, ECALL cause by priv level,
  sstatus/sie/sip as masked views of mstatus/mie/mip
- `rtl/decode.sv`: Decode SRET, SFENCE.VMA, FENCE.I
- `rtl/clint.sv`: AXI slave at `0x0200_0000` — mtime (free-running), mtimecmp, msip
- `rtl/plic_stub.sv`: AXI slave at `0x0C00_0000` — 1 source, M+S contexts, claim/complete
- `tb/nox_sim.sv`: 5-slave AXI mux, CLINT/PLIC instantiated, IRQs wired to core

**2026-04-03 — Phase 2C: Sv39 MMU** ✅
- `rtl/inc/mmu_pkg.svh`: TLB entry type, Sv39 PTE format, `mmu_access_t`
- `rtl/tlb.sv`: Fully-associative TLB, PLRU replacement, SFENCE.VMA invalidation
- `rtl/ptw.sv`: 3-level Sv39 PTW (IDLE→L2→L1→L0→DONE/FAULT), shared data bus
- `rtl/mmu.sv`: I-TLB (32) + D-TLB (64) + PTW shim between pipeline and cb_to_axi
- Three RTL bugs found and fixed during verification (see `project_phase2.md` in `.claude/`)

**Build:** `make all WAVEFORM_USE=0 OUT_VERILATOR=output_nox_v2`
**Test:** `sw/mmu_test/mmu_test.elf` — **PASS**

### Next steps
- [ ] Phase 2D: Linux boot — OpenSBI + kernel + BusyBox on Verilator
