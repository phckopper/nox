/**
 * testbench_linux.cpp — Verilator C++ driver for Linux-mode simulation
 *
 * Supports:
 *   -e <elf>              Load ELF file (OpenSBI or a standalone bare-metal ELF)
 *   -b <hex_addr>:<file>  Load raw binary blob at physical address <hex_addr>
 *                         (can be specified multiple times: kernel Image, DTB, …)
 *   -s <cycles>           Simulation cycle limit  (default: 200,000,000)
 *   -w <cycle>            Start FST waveform dump at this cycle
 *   -f <cycle>            Alias for -w
 *
 * Memory map expected by this testbench:
 *   0x8000_0000+  Main memory (MAIN_MEM_KB_SIZE KB, unified code+data)
 *
 * UART output: printed directly by $write in ns16550.sv during eval().
 * No per-tick C++ polling is needed.
 */

#include <iostream>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <stdlib.h>
#include <signal.h>
#include <cstdlib>
#include <stdint.h>
#include <elfio/elfio.hpp>
#include <iomanip>
#include <chrono>

#include "inc/common.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include "verilated_fst_c.h"
#include "Vnox_sim_linux.h"
#include "Vnox_sim_linux__Syms.h"

#define STRINGIZE(x) #x
#define STRINGIZE_VALUE_OF(x) STRINGIZE(x)

using namespace std;

unsigned long tick_counter;

// A raw binary blob to load at a specific physical address
struct s_blob_t {
  uint64_t base_addr;
  string   path;
};

typedef struct {
  long         sim_cycles;
  int          waves_dump;
  unsigned long waves_timestamp;
  string       waves_path;
  string       elf_path;
  vector<s_blob_t> blobs;
} s_linux_setup_t;

template<class module> class testbench {
  VerilatedFstC *trace = new VerilatedFstC;
  unsigned long start_dumping;

  public:
    module *core = new module;

    testbench() {
      Verilated::traceEverOn(true);
      tick_counter = 0l;
    }

    ~testbench(void) {
      delete core;
      core = NULL;
    }

    virtual void reset(int rst_cyc) {
      for (int i = 0; i < rst_cyc; i++) {
        core->rst = 0;
        this->tick();
      }
      core->rst = 1;
      this->tick();
    }

    virtual void init_dump_setpoint(unsigned long val) {
      start_dumping = val;
    }

    virtual void opentrace(const char *name) {
      core->trace(trace, 99);
      trace->open(name);
    }

    virtual void close(void) {
      if (trace) {
        trace->close();
        trace = NULL;
      }
    }

    virtual void tick(void) {
      core->clk = 0;
      core->eval();
      tick_counter++;
      if (tick_counter > (start_dumping * 2))
        if (trace) trace->dump(tick_counter);

      core->clk = 1;
      core->eval();
      tick_counter++;
      if (tick_counter > (start_dumping * 2))
        if (trace) trace->dump(tick_counter);
    }

    virtual bool done(void) {
      return (Verilated::gotFinish());
    }
};

// Write a 32-bit word into the main memory at the given 32-bit word index
// (word_idx = byte_offset_from_MAIN_MEM_ADDR / 4)
static inline void writeWord(testbench<Vnox_sim_linux> *sim,
                              uint32_t word_idx, uint32_t word_val) {
  sim->core->nox_sim_linux->writeWordMain(word_idx, word_val);
}

// --------------------------------------------------------------------------
// Load an ELF file: all PT_LOAD segments that fall within the main memory
// window are copied to main memory.
// --------------------------------------------------------------------------
bool loadELF(testbench<Vnox_sim_linux> *sim, const string &path, bool en_print) {
  ELFIO::elfio prog;

  if (!prog.load(path)) {
    cerr << "[ELF Loader] Cannot open: " << path << endl;
    return true;
  }

  if ((prog.get_class() != ELFCLASS32 && prog.get_class() != ELFCLASS64) ||
      prog.get_machine() != 0xf3) {
    cerr << "[ELF Loader] Not a RISC-V ELF: " << path << endl;
    return true;
  }

  uint64_t mem_base = (uint64_t)MAIN_MEM_ADDR;
  uint64_t mem_end  = mem_base + ((uint64_t)MAIN_MEM_KB_SIZE * 1024ULL);

  if (en_print) {
    cout << "\n[ELF Loader] " << path << endl;
    cout << "  Entry: 0x" << hex << prog.get_entry() << dec << endl;
    cout << "  Segments: " << prog.segments.size() << endl;
  }

  for (unsigned i = 0; i < prog.segments.size(); i++) {
    const ELFIO::segment *seg = prog.segments[i];
    uint64_t lma      = seg->get_physical_address();
    uint64_t file_sz  = seg->get_file_size();
    uint64_t mem_sz   = seg->get_memory_size();

    if (seg->get_type() != PT_LOAD || file_sz == 0)
      continue;

    if (lma < mem_base || lma >= mem_end) {
      if (en_print)
        cout << "  [seg " << i << "] 0x" << hex << lma
             << " outside main memory — skipped" << dec << endl;
      continue;
    }

    if (lma + mem_sz > mem_end) {
      cerr << "[ELF Loader] Segment 0x" << hex << lma
           << " extends beyond main memory!" << dec << endl;
      return true;
    }

    if (en_print)
      cout << "  [seg " << i << "] 0x" << hex << lma
           << "  file=" << dec << file_sz
           << " B  mem=" << mem_sz << " B" << endl;

    uint64_t offset = lma - mem_base;   // byte offset from start of main memory
    const uint8_t *data = (const uint8_t *)seg->get_data();

    for (uint64_t p = 0; p < file_sz; p += 4) {
      uint32_t word = 0;
      for (int b = 0; b < 4 && (p + b) < file_sz; b++)
        word |= ((uint32_t)data[p + b]) << (b * 8);
      writeWord(sim, (uint32_t)((offset + p) / 4), word);
    }
  }
  return false;
}

// --------------------------------------------------------------------------
// Load a raw binary blob at a specific physical base address
// --------------------------------------------------------------------------
bool loadBlob(testbench<Vnox_sim_linux> *sim,
              uint64_t base_addr, const string &path, bool en_print) {
  ifstream f(path, ios::binary | ios::ate);
  if (!f) {
    cerr << "[Blob Loader] Cannot open: " << path << endl;
    return true;
  }

  uint64_t size = (uint64_t)f.tellg();
  f.seekg(0, ios::beg);

  uint64_t mem_base = (uint64_t)MAIN_MEM_ADDR;
  uint64_t mem_end  = mem_base + ((uint64_t)MAIN_MEM_KB_SIZE * 1024ULL);

  if (base_addr < mem_base || base_addr >= mem_end) {
    cerr << "[Blob Loader] Address 0x" << hex << base_addr
         << " outside main memory" << dec << endl;
    return true;
  }

  if (en_print)
    cout << "\n[Blob Loader] 0x" << hex << base_addr
         << " ← " << dec << size << " B  (" << path << ")" << endl;

  uint64_t offset = base_addr - mem_base;
  vector<uint8_t> buf(size, 0);
  f.read((char *)buf.data(), size);

  for (uint64_t p = 0; p < size; p += 4) {
    uint32_t word = 0;
    for (int b = 0; b < 4 && (p + b) < size; b++)
      word |= ((uint32_t)buf[p + b]) << (b * 8);
    writeWord(sim, (uint32_t)((offset + p) / 4), word);
  }
  return false;
}

// --------------------------------------------------------------------------
// Argument parsing
// --------------------------------------------------------------------------
static void show_usage_linux(void) {
  cerr << "Usage:\n"
       << "  -h, --help            Show this help\n"
       << "  -e, --elf  <file>     ELF to load (OpenSBI or bare-metal test)\n"
       << "  -b, --blob <addr:file> Load raw binary at hex address\n"
       << "                         e.g. -b 0x80200000:Image\n"
       << "  -s, --sim  <N>        Simulation cycles (default 200000000)\n"
       << "  -f, --waves_start <N> Start FST dump at cycle N\n"
       << endl;
}

static void parse_input_linux(int argc, char **argv, s_linux_setup_t *s) {
  for (int i = 1; i < argc; i++) {
    string arg = argv[i];
    if (arg == "-h" || arg == "--help") {
      show_usage_linux();
      exit(EXIT_SUCCESS);
    } else if (arg == "-e" || arg == "--elf") {
      s->elf_path = argv[++i];
    } else if (arg == "-b" || arg == "--blob") {
      string spec = argv[++i];
      size_t colon = spec.find(':');
      if (colon == string::npos) {
        cerr << "Bad -b argument (need addr:file): " << spec << endl;
        exit(EXIT_FAILURE);
      }
      s_blob_t blob;
      blob.base_addr = strtoull(spec.substr(0, colon).c_str(), nullptr, 16);
      blob.path      = spec.substr(colon + 1);
      s->blobs.push_back(blob);
    } else if (arg == "-s" || arg == "--sim") {
      s->sim_cycles = atol(argv[++i]);
    } else if (arg == "-f" || arg == "-w" || arg == "--waves_start") {
      s->waves_timestamp = atol(argv[++i]);
    }
  }

  if (s->elf_path.empty() && s->blobs.empty()) {
    cerr << "[Error] No ELF or binary blobs specified. Use -e or -b." << endl;
    show_usage_linux();
    exit(EXIT_FAILURE);
  }

  cout << "=================================================" << endl;
  cout << "Linux-mode simulation:" << endl;
  cout << "  Main memory : " << MAIN_MEM_KB_SIZE << " KB @ 0x"
       << hex << (uint64_t)MAIN_MEM_ADDR << dec << endl;
  cout << "  Cycle limit : " << s->sim_cycles << endl;
  if (!s->elf_path.empty())
    cout << "  ELF         : " << s->elf_path << endl;
  for (auto &b : s->blobs)
    cout << "  Blob 0x" << hex << b.base_addr << dec << " : " << b.path << endl;
  cout << "=================================================" << endl;
}

// --------------------------------------------------------------------------
// Main
// --------------------------------------------------------------------------
int main(int argc, char **argv, char **env) {
  Verilated::commandArgs(argc, argv);

  auto *dut = new testbench<Vnox_sim_linux>;

  s_linux_setup_t setup;
  setup.sim_cycles      = 200000000L;  // 200 M cycles default
  setup.waves_dump      = WAVEFORM_USE;
  setup.waves_timestamp = 0;
  setup.waves_path      = STRINGIZE_VALUE_OF(WAVEFORM_FST);

  if (argc == 1) {
    show_usage_linux();
    exit(EXIT_FAILURE);
  }

  parse_input_linux(argc, argv, &setup);

  long sim_cycles_timeout = setup.sim_cycles;

  if (WAVEFORM_USE)
    dut->opentrace(STRINGIZE_VALUE_OF(WAVEFORM_FST));

  dut->init_dump_setpoint(setup.waves_timestamp);

  // Load ELF (if provided)
  if (!setup.elf_path.empty()) {
    if (loadELF(dut, setup.elf_path, true)) {
      cerr << "Error loading ELF." << endl;
      exit(EXIT_FAILURE);
    }
  }

  // Load raw binary blobs (kernel Image, DTB, initramfs …)
  for (auto &b : setup.blobs) {
    if (loadBlob(dut, b.base_addr, b.path, true)) {
      cerr << "Error loading blob." << endl;
      exit(EXIT_FAILURE);
    }
  }

  auto t0 = chrono::steady_clock::now();

  dut->reset(2);
  while (!Verilated::gotFinish() && setup.sim_cycles--) {
    dut->tick();
    // Flush stdout every 100k cycles so UART output appears in real-time
    if ((setup.sim_cycles % 100000) == 0)
      fflush(stdout);
  }

  auto t1 = chrono::steady_clock::now();
  long elapsed = chrono::duration_cast<chrono::seconds>(t1 - t0).count();

  cout << "\n[SIM Summary]" << endl;
  long ran = sim_cycles_timeout - (setup.sim_cycles + 1);
  cout << "Clk cycles elapsed   = " << ran << endl;
  cout << "Remaining clk cycles = " << setup.sim_cycles + 1 << endl;
  cout << "Elapsed time [s]     = " << elapsed << endl;
  if (elapsed > 0)
    cout << "Sim. frequency [Hz]  = " << ran / elapsed << endl;

  dut->core->final();
  dut->close();
  exit(EXIT_SUCCESS);
}

double sc_time_stamp() {
  return tick_counter;
}
