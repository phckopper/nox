[![Lint](https://github.com/aignacio/nox/actions/workflows/lint.yaml/badge.svg)](https://github.com/aignacio/nox/actions/workflows/lint.yaml) 

<img align="right" alt="rvss" src="docs/img/rv_logo.png" width="100"/>
<img alt="nox" src="docs/img/logo_nox.svg" width="200"/>

# NoX RISC-V Core

## Table of Contents
* [Introduction](#intro)
* [Quickstart](#quick)
* [RTL uArch](#uarch)
* [NoX SoC](#nox_soc)
* [FreeRTOS](#freertos)
* [Compliance Tests](#compliance)
* [CoreMark](#coremark)
* [Synthesis](#synth)
* [License](#lic)

## <a name="intro"></a> Introduction
NoX is a 32-bit RISC-V core designed in System Verilog language aiming both `FPGA` and `ASIC` flows. The core was projected to be easily integrated and simulated as part of an SoC, with `makefile` targets for simple standalone simulation or with an interconnect and peripherals. In short, the core specs are listed here:

- RV32IMAZba_Zbb_ZicondZicsr
- 4 stages / single-issue / in-order pipeline
- M-mode privileged spec.
- 2.96 CoreMark/MHz (simulation, NanGate 45nm @ 333 MHz, -O3 + unroll/inline, RV32IM + Zba/Zbb/Zicond)
- Software/External/Timer interrupt
- Support non/vectored IRQs
- Configurable fetch FIFO size
- AXI4 or AHB I/F

The CSRs that are implemented in the core are listed down below, more CSRs can be easily integrated within [rtl/csr.sv](rtl/csr.sv) by extending the decoder. Instructions such as `ECALL/EBREAK` are supported as well and will synchronously trap the core, forcing a jump to the `MTVEC` value. All interrupts will redirect the core to the `MTVEC` as well as it is considered asynchronous traps.

|    |    CSR   |           Description           |
|:--:|:--------:|:-------------------------------:|
|  1 |  mstatus |         Status register         |
|  2 |    mie   |     Machine Interrupt enable    |
|  3 |   mtvec  |     Trap-vector base-address    |
|  4 | mscratch |         Scratch register        |
|  5 |   mepc   |    Exception program counter    |
|  6 |  mcause  |      Machine cause register     |
|  7 |   mtval  |        Machine trap value       |
|  8 |    mip   |    Machine pending interrupt    |
|  9 |   cycle  |       RO shadow of mcycle       |
| 10 |  cycleh  | RO shadow of mcycle [Upper 32b] |
| 11 |   misa   |       Machine ISA register      |
| 12 |  mhartid |         Hart ID register        |

## <a name="quick"></a> Quickstart
**NoX** uses a [docker container](https://hub.docker.com/repository/docker/aignacio/nox) to build and simulate a standalone instance of the core or an SoC requiring no additional tools to the user apart from docker itself. Please be aware that the process of building the simulator might require more resources than what is allocated to the `docker`, therefore if the output shows `Killed`, increase the **memory** and the **cpu** resources. To quickly build a simple instance of the core with two memories and simulate it through linux, follow:

```bash
make all # Will first download the docker container and build the design
make run # Should simulate the design for 100k clock cycles 
```
You should expect in the terminal an output like this:
```bash

  _   _       __  __
 | \ | |  ___ \ \/ /
 |  \| | / _ \ \  /
 | |\  || (_) |/  \
 |_| \_| \___//_/\_\
 NoX RISC-V Core RV32IM

 CSRs:
 mstatus        0x1880
 misa           0x40001100
 mhartid        0x0
 mie            0x0
 mip            0x0
 mtvec          0x80000101
 mepc           0x0
 mscratch       0x0
 mtval          0x0
 mcause         0x0
 cycle          110

[ASYNC TRAP] IRQ Software
[ASYNC TRAP] IRQ timer
[ASYNC TRAP] IRQ External
[ASYNC TRAP] IRQ External
[ASYNC TRAP] IRQ Software
[ASYNC TRAP] IRQ timer
...
```
If you have [gtkwave](http://gtkwave.sourceforge.net) installed, you can also open the simulation run `fst` with:
```
make GTKWAVE_PRE="" wave
```
For more `targets`, please run
```bash
make help
```

## <a name="uarch"></a> RTL micro architecture
NoX core is a **4-stages** single issue, in-order pipeline with [**full bypass**](https://en.wikipedia.org/wiki/Classic_RISC_pipeline#Solution_A._Bypassing). Most data hazards are resolved by forwarding with no stall penalty. Stalls occur in three cases: (1) load-use hazard — 1 cycle when a load result is consumed by the immediately following instruction; (2) multiply/divide — 2 cycles for MUL, 33 cycles for DIV/REM; (3) LSU back-pressure from an in-flight AXI transaction. The pipeline also includes a speculative branch predictor (64-entry BTB + 64-entry bimodal BHT + 4-entry RAS) to reduce the branch misprediction penalty to 2 cycles. The micro-architecture is presented in the figure below with all the signals matching the top [rtl/nox.sv](rtl/nox.sv).
![NoX uArch](docs/img/nox_diagram.svg)
In the file [rtl/inc/nox_pkg.svh](rtl/inc/nox_pkg.svh), there are two presets of `verilog` macros (Lines 8/9) that can be un/commented depending on the final target. For `TARGET_FPGA`, it is defined an **active-low** & **synchronous reset**. Otherwise, if the macro `TARGET_ASIC` is defined, then this change to **active-high** & **asynchronous reset**. In case it is required another combination of both, please follow what is coded there.

As an estimative of resources utilization, listed below are the synthesis numbers of the **original RV32I core** for the [Kintex 7 K325T](https://www.xilinx.com/support/documentation/data_sheets/ds182_Kintex_7_Data_Sheet.pdf) (`xc7k325tffg676-1`) @100MHz using Vivado 2020.2. These figures predate the branch predictor and RV32M additions and are provided for reference only.

| **Name**                           | **Slice LUTs** | **Slice Registers** | **F7 Muxes** | **F8 Muxes** | **Slice** | **LUT as Logic** |
|------------------------------------|:--------------:|:-------------------:|:------------:|:------------:|:---------:|:----------------:|
|   u_nox (nox)                      |   2517         |   1873              |   182        |   89         |   1225    |   2517           |
|   u_wb (wb)                        |   32           |   33                |   0          |   0          |   34      |   32             |
|   u_reset_sync (reset_sync)        |   1            |   2                 |   0          |   0          |   2       |   1              |
|   u_lsu (lsu)                      |   538          |   105               |   1          |   0          |   266     |   538            |
|   u_fetch (fetch)                  |   276          |   134               |   0          |   0          |   154     |   276            |
|   u_fifo_l0 (fifo)                 |   259          |   68                |   0          |   0          |   125     |   259            |
|   u_execute (execute)              |   229          |   359               |   0          |   0          |   254     |   229            |
|   u_csr (csr)                      |   187          |   255               |   0          |   0          |   206     |   187            |
|   u_decode (decode)                |   1445         |   1240              |   181        |   89         |   1000    |   1445           |
|   u_register_file (register_file)  |   615          |   1056              |   181        |   89         |   664     |   615            |

## <a name="nox_soc"></a> NoX SoC

Inside this repository it is also available a System-on-a-chip **(SoC)** with the following micro-architecture. It contains a **boot ROM** memory with the bootloader program [(sw/bootloader)](sw/bootloader) that can be used to transfer new programs to the SoC by using the [bootloader_elf.py](sw/bootloader_elf.py) script. The script will read an [ELF file](https://youtu.be/nC1U1LJQL8o) and transfer it through the serial UART to the address defined in its content memory map, also in the end of the transfer, it will set the `entry point address` of the ELF to the **RST Ctrl** peripheral forcing the NoX CPU to boot from this address in the next reset cycle. To return back to the bootloader program, an additional input (`bootloader_i`), once it is asserted, will force the RST Ctrl to be set back to the boot ROM address. To program an `Arty A7 FPGA` and download a program to the SoC, follow the steps below.

![nox_soc](docs/img/nox_soc.svg)

To generate the FPGA image and program the board (vivado required):
```bash
fusesoc library add core  .
fusesoc run --run --target=a7_synth core:nox:v0.0.1
```

Once it is finished and the board is programmed, the following output will be shown:
```bash
  __    __            __    __         ______              ______   
 |  \  |  \          |  \  |  \       /      \            /      \  
 | $$\ | $$  ______  | $$  | $$      |  $$$$$$\  ______  |  $$$$$$\ 
 | $$$\| $$ /      \  \$$\/  $$      | $$___\$$ /      \ | $$   \$$ 
 | $$$$\ $$|  $$$$$$\  >$$  $$        \$$    \ |  $$$$$$\| $$       
 | $$\$$ $$| $$  | $$ /  $$$$\        _\$$$$$$\| $$  | $$| $$   __  
 | $$ \$$$$| $$__/ $$|  $$ \$$\      |  \__| $$| $$__/ $$| $$__/  \ 
 | $$  \$$$ \$$    $$| $$  | $$       \$$    $$ \$$    $$ \$$    $$ 
  \$$   \$$  \$$$$$$  \$$   \$$        \$$$$$$   \$$$$$$   \$$$$$$  

 NoX SoC UART Bootloader 

 CSRs:
 mstatus        0x1880
 misa           0x40001100
 mhartid        0x0
 mie            0x0
 mip            0x0
 mtvec          0x101
 mepc           0x0
 mscratch       0x0
 mtval          0x0
 mcause         0x0
 cycle          2823444

 Freq. system:  50000000 Hz
 UART Speed:    115200 bits/s
 Type h+[ENTER] for help!

> 
```

To transfer a program through the bootloader script:
```bash
make -C sw/bootloader all
make -C sw/soc_hello_world all
python3 sw/bootloader_elf.py --elf sw/soc_hello_world/output/soc_hello_world.elf
# Press rst button in the board
```

### Example running on Kintex 7 Qmtech Board

If you have a [Kintex 7 Qmtech board](https://github.com/ChinaQMTECH/QMTECH_XC7K325T_CORE_BOARD?spm=a2g0o.detail.1000023.1.425dffdb5DOMQd), you can build/program the target with the commands below. 
```bash
make -C sw/bootloader all
fusesoc library add core  .
fusesoc run --run --target=x7_synth core:nox:v0.0.1
# Once the FPGA bitstream is downloaed, change the program to the demo
python3 sw/bootloader_elf.py --elf sw/soc_hello_world/output/soc_hello_world.elf --device YOUR_SERIAL_ADAPTER --speed 230400
```

The bootloader PB and the reset CPU are respectively SW2 and SW1 for the [K7 core board](https://github.com/ChinaQMTECH/DB_FPGA/blob/main/QMTECH_DB_For_FPGA_V04.pdf). You should have something like this:
![NoX SoC K7](docs/img/nox_soc_qmtech_k7.gif)

## <a name="freertos"></a> FreeRTOS

If you are willing to use FreeRTOS with this core, there is a template available here [NoX FreeRTOS template](https://github.com/aignacio/nox_freertos) with a running demo with `4x Tasks` running in parallel in the **NoX SoC**.

## <a name="compliance"></a> RISC-V ISA Compliance tests
To run the compliance tests, two steps needs to be followed.
1. Compile nox_sim with 2MB IRAM / 128KB DRAM
2. Run the RISCOF framework using SAIL-C RISC-V simulator as reference

```bash
make build_comp # It might take a while...
make run_comp
```
Once it is finished, you can open the report file available at **riscof_compliance/riscof_work/report.html** to check the status. The run should finished with a similar report like the one available at [docs/report_compliance.html](docs/report_compliance.html).

## <a name="coremark"></a> CoreMark
Inside the [sw/coremark](sw/coremark), there is a folder called **nox** which is the platform port of the [CoreMark benchmark](https://github.com/eembc/coremark) to the core. The NoX CoreMark score is **~2.960 CoreMark/MHz** (simulation, NanGate 45nm @ 333 MHz, RV32IM + Zba/Zbb/Zicond, GCC 15.2.0 -O3 -funroll-loops -finline-functions), verified with "Correct operation validated."

To build and run the CoreMark benchmark using the Verilator simulator:
```bash
# Build the simulator
make all WAVEFORM_USE=1 OUT_VERILATOR=output_verilator_m

# Build the CoreMark ELF with Zba/Zbb/Zicond (requires xPack GCC 15+)
GCC15=/path/to/xpack-riscv-none-elf-gcc-15.2.0-1/bin/riscv-none-elf-
make -C sw/coremark PORT_DIR=nox ITERATIONS=1500 \
  XCFLAGS="-O2 -DPERFORMANCE_RUN=1 -DUART_SIM -march=rv32im_zba_zbb_zicond_zicsr -mabi=ilp32" \
  UART_MODE=UART_SIM "RUN_CMD=$GCC15" "RUN_PY=python3"

# Run the simulation (≥1500 iterations needed for valid ≥10s result at 50 MHz CLOCKS_PER_SEC)
./output_verilator_m/nox_sim -s 650000000 -e sw/coremark/coremark.elf -w 900000000
```

**Performance run output (simulation, GCC 15.2.0, Zba+Zbb+Zicond):**
```
 -----------
 [NoX] Coremark Start
 -----------
2K performance run parameters for coremark.
CoreMark Size    : 666
Total ticks      : 547698287
Total time (secs): 10
Iterations/Sec   : 150
Iterations       : 1500
Compiler version : riscv-none-elf-gcc (xPack GNU RISC-V Embedded GCC x86_64) 15.2.0
Compiler flags   : -O2 -DPERFORMANCE_RUN=1 -DUART_SIM -march=rv32im_zba_zbb_zicond_zicsr -mabi=ilp32
Memory location  : STACK
seedcrc          : 0xe9f5
[0]crclist       : 0xe714
[0]crcmatrix     : 0x1fd7
[0]crcstate      : 0x8e3a
[0]crcfinal      : 0x25b5
Correct operation validated. See README.md for run and reporting rules.
```

CoreMark/MHz = 1,500 × 50,000,000 / 547,698,287 = **2.739 CM/MHz** at 300 MHz (+10.5% vs RV32IM baseline of 2.479).

## <a name="synth"></a> Synthesis

Adapting the setup to [Ibex Core - low risc](https://github.com/lowRISC/ibex/tree/master/syn), attached is the command to perform synthesis on the 45nm nangate PDK.
```bash
docker run  -v .:/test -w /test --rm aignacio/oss_cad_suite:latest bash -c "cd /test/synth && ./syn_yosys.sh"
```
Output lands in a timestamped directory under `synth/syn_out/`.

### Area & Timing results (NanGate 45nm, 2026-03-24, RV32IMZba_Zbb_ZicondZicsr + branch predictor):

| Metric | Value |
|---|---|
| Chip area | 70,748.8 µm² (88.66 KGE) |
| Total cells | 46,025 |
| Flip-flops | ~6,321 |

| Path group | WNS | Status |
|---|---|---|
| reg2reg | +0.05 ns | ✅ |
| in2reg  | +0.88 ns | ✅ |
| reg2out | +0.25 ns | ✅ |
| in2out  | (false path) | ✅ no paths |

Clock target: **333 MHz** (3.0 ns period). All paths met. The RV32A (atomics) extension has since been added to the RTL; a re-synthesis run is pending.

Previous passing result (pre-branch-predictor, pre-RV32M, RV32I core):
* 22,225.9 µm², 14,022 cells, ~1,917 FFs — WNS **+1.03 ns** reg2reg (all paths met @ 333 MHz)

Original RV32I baseline (pre-AI-improvements):
* 27.04 kGE @ 250MHz in 45nm

## AI improvements

The following improvements were made to the core with AI assistance (Claude Sonnet 4.6):

### Load-use stall & timing optimizations

- **Load-use hazard detection** (`rtl/execute.sv`): added a 1-cycle stall when a load result is consumed by the immediately following instruction, eliminating the combinational AXI-rdata → ALU → AXI-address path that caused a timing violation at 300 MHz on NanGate 45nm.
- **ALU forwarding mux** (`rtl/execute.sv`): merged a two-level mux (case + override) into a single priority-if/case, reducing the critical-path mux depth.
- **Word-load early return** (`rtl/wb.sv`): word loads (`RV_LSU_W`) bypass the barrel-shifter entirely since `addr[1:0]` is always zero, removing the shift-mux tree from the load-use forwarding path.
- **False-path STA constraint** (`synth/nox.nangate.sdc`): the AXI read-data → AXI write-address combinational path is a false path because `load_use_hazard` inserts a bubble before any dependent store can issue.
- **Register file write-through priority fix** (`rtl/register_file.sv`): write-through now correctly overrides the hold path during load-use stalls instead of the reverse.
- **Fetch deadlock fix** (`rtl/fetch.sv`): `data_ready` is asserted even when the L0 FIFO is full during a jump, preventing the fetch FSM from getting permanently stuck in `F_CLR`.
- **Decode write-through address fix** (`rtl/decode.sv`): during a load-use stall, the register file read addresses now use `id_ex_ff.rs1_addr`/`rs2_addr` (the stalled instruction's registers) instead of the next instruction's registers, ensuring the loaded value reaches the correct operand.

### Bimodal branch predictor

Added a speculative branch predictor to reduce branch penalty:

- **`rtl/branch_predictor.sv`** (new): 16-entry direct-mapped BTB (Branch Target Buffer) and 64-entry bimodal BHT (Branch History Table) with 2-bit saturating counters. The BTB is indexed by `PC[5:2]` and the BHT by `PC[7:2]`.
- **Speculative fetch redirect** (`rtl/fetch.sv`): when the BTB hits and the BHT predicts taken, the fetch stage redirects `next_pc_addr` to the predicted target without waiting for execute to confirm. The OT and L0 FIFOs were extended to carry a `bp_taken` tag alongside each instruction.
- **Correct-prediction suppression** (`rtl/execute.sv`): when execute confirms that a JAL or taken branch was correctly predicted, it suppresses `fetch_req_o` (avoiding a redundant pipeline flush) and fires a dedicated `decode_pc_update_o` pulse to fix up the decode stage's `pc_dec` without flushing the pipeline.
- **`pc_dec` tracking fix** (`rtl/decode.sv`): a new `decode_pc_update_i` input from execute corrects `pc_dec` for instructions that follow a correctly-predicted jump or branch, ensuring that `mepc` and AUIPC/JAL link-address computations carry the right PC value.
- **`jump_or_branch` guard relaxation** (`rtl/execute.sv`): introduced `no_jump_guard` so that a branch or jump in the cycle immediately after a correctly-predicted jump is not incorrectly suppressed.
- **Mispredicted not-taken branch suppression** (`rtl/execute.sv`): extended the `we_rd = 0` squash logic to cover the case where a branch was predicted taken but resolved not-taken, preventing wrong-path instructions from corrupting the register file.

### Fetch FIFO, performance counters, and BHT improvements

- **Fetch FIFO doubled** (`rtl/nox.sv`): `L0_BUFFER_SIZE` increased from 2 to 4 entries. The larger buffer absorbs post-redirect refill latency, reducing fetch bubbles from 8.2% to 4.2% of cycles. Gain: **+4.9% CoreMark/MHz** (2.739 → ~2.873), with total ticks dropping from 547,698,287 to 522,034,501.
- **Performance counters** (`rtl/execute.sv`, `ifdef SIMULATION`): 15-counter set printed at simulation end — IPC, stall breakdown (LSU back-pressure, load-use hazard, MulDiv stall, fetch bubbles), redirect events (branch mispredict split into taken-miss and not-taken-miss, JAL BTB miss, JALR redirect) with estimated cycles-lost, and prediction success rates for branches (true accuracy, taken/not-taken split), JAL BTB hits, and JALR RAS/BTB hits.
- **256-entry XOR-folded BHT** (`rtl/branch_predictor.sv`): expanded BHT from 64 to 256 entries and replaced the PC[7:2] index with a XOR-folded index `PC[9:2] ⊕ PC[17:10]` that mixes the intra-page offset with the page number, reducing inter-page aliasing. Not-taken-predicted mispredictions fell from ~3.5M to 3.07M. Branch true accuracy: 90.3% → 90.6%. Gain: **+0.1% CoreMark/MHz**.

### Fetch pipeline and branch predictor improvements

- **F_CLR state elimination** (`rtl/fetch.sv`, `rtl/execute.sv`): removed the mandatory one-cycle drain state after a misprediction. When the AXI address channel is idle or the request is accepted in the same cycle as the redirect, the new PC is issued immediately — reducing the misprediction penalty from 3 cycles to 2 cycles and increasing CoreMark/MHz by +5.2%.
- **4-entry Return Address Stack** (`rtl/fetch.sv`, `rtl/execute.sv`): added a hardware RAS to predict `JALR` returns. `JAL`/`JALR` with `rd=ra` push the link address; `JALR` with `rs1=ra, rd=x0` pops. Reduces function-return mispredictions from ~3 cycles each to zero, contributing to +7.1% CoreMark/MHz gain (combined with BTB expansion).
- **64-entry BTB** (`rtl/branch_predictor.sv`): expanded the Branch Target Buffer from 16 to 64 entries (index width 4→6 bits), eliminating aliasing conflicts in CoreMark's working set.

### Compiler optimization: -O3 with loop unrolling and inlining

- **GCC 15.2.0 -O3 -funroll-loops -finline-functions** (`sw/coremark/`): rebuilt CoreMark with aggressive compiler optimizations. Loop unrolling converts predictable taken-loop-back-edges into cheaper not-taken exits, and inlining reduces call overhead. Load-use hazard cycles fell 16% (31M → 26.1M) as the compiler scheduled around more hazards with the larger optimization scope. A `#pragma GCC optimize("O2")` guard was added to `nox/startup.c` to prevent the BSS/data-copy loops in `_reset` (which lives in `.init`) from being unrolled past the 0x100-byte vector-table offset enforced by `sections.ld`. Gain: **+2.9% CoreMark/MHz** (~2.876 → ~2.960), total ticks 520,947,845 → 506,072,095.

### RV32A atomics extension

- **`rtl/lsu.sv`**: added a 3-state AMO state machine (`AMO_IDLE → AMO_RD → AMO_WR`) that handles all 11 RV32A instructions. The machine reads the old memory value, computes the AMO result via `amo_compute()`, writes it back, and returns the old value (or 0/1 for SC.W) in `rd`. LR/SC reservation is tracked in `lr_reserved_ff`/`lr_addr_ff`; a single-hart implementation with no AXI exclusive-access signalling.
- **`rtl/decode.sv`**: new `RV_ATOMIC` (opcode `0x2F`) case. LR.W is decoded as `LSU_LOAD` with `amo_op=AMO_LR` (reuses the existing load path; the LSU sets the reservation as a side-effect). SC.W and all AMO* instructions are decoded as `LSU_AMO`.
- **`rtl/execute.sv`**: AMO rs2 forwarding, `amo_op` pass-through, and `load_use_hazard` extended to cover `LSU_AMO` (same forwarding timing as loads).
- **`rtl/wb.sv`**: `LSU_AMO` writeback path returns `lsu_rd_data_i` (old value or SC.W result code) to `rd`.
- **Test suite** (`sw/test_rv32a/`): 40+ checks covering all 11 instructions including LR/SC success and three failure modes (no prior LR, different address, intervening store), all 9 AMO operations (old value + new memory value), chained AMOs, and the LR/SC atomic-increment idiom — **ALL PASS**.

### RV32M hardware multiply/divide

- **`rtl/muldiv_unit.sv`** (new): timing-safe multiply/divide unit. Multiply is pipelined over 2 cycles (operands registered at cycle T, 33×33-bit signed product computed reg-to-reg at T+1 — a dedicated ~2.1 ns arc, safely under the 3.33 ns clock period). Division uses a 32-cycle restoring shift-subtract algorithm with pre-computed absolute values and sign flags so the inner loop is a pure unsigned comparison and subtract. All RISC-V spec corner cases are handled: divide-by-zero and signed overflow (INT_MIN/−1).
- **M-extension decode** (`rtl/decode.sv`): `funct7=0b0000001` on RV_OP is decoded as a MulDiv instruction and sets `is_muldiv` in the pipeline register; the standard ALU f3/f7 fields are not decoded for these instructions.
- **Pipeline stall integration** (`rtl/execute.sv`): while `muldiv_stall` is asserted, `we_rd=0` and `id_ready_o=0` hold the pipeline; when `result_valid_o` pulses, the result and `rd_addr` are injected directly into the write-back path. The `freeze_i` input is tied to `lsu_bp_i` so the divider counter freezes during memory back-pressure and result delivery is always mutually exclusive with LSU back-pressure.
- **ISA register update** (`rtl/inc/nox_pkg.svh`): `misa` bit 12 (M extension) set → `0x40001100`.
- **Gain**: +141.9% CoreMark/MHz (1.025 → 2.479), verified with "Correct operation validated."

## <a name="lic"></a> License

NoX is licensed under the permissive MIT license. Please refer to the [LICENSE](LICENSE) file for details.

## Ref.

```tex
@misc{silva2024noxcompactopensourceriscv,
      title={NoX: a Compact Open-Source RISC-V Processor for Multi-Processor Systems-on-Chip}, 
      author={Anderson I. Silva and Altamiro Susin and Fernanda L. Kastensmidt and Antonio Carlos S. Beck and Jose Rodrigo Azambuja},
      year={2024},
      eprint={2406.17878},
      archivePrefix={arXiv},
      primaryClass={cs.AR},
      url={https://arxiv.org/abs/2406.17878}, 
}
```
