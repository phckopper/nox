/**
 * nox_sim_linux.sv — Linux-mode Verilator testbench top
 *
 * Memory map:
 *   0x0200_0000   CLINT   (mtime / mtimecmp / msip)
 *   0x0C00_0000   PLIC    (1 external source, M+S contexts)
 *   0x1000_0000   UART    (NS16550A, 8 byte-wide registers at offsets 0-7)
 *   0x8000_0000+  Main memory (MAIN_MEM_KB_SIZE KB, dual-port)
 *                   Port A: fetch (read-only)
 *                   Port B: LSU  (read-write)
 *
 * LSU AXI routing (by awaddr/araddr[31:24]):
 *   0x02 → CLINT
 *   0x0C → PLIC
 *   0x10 → UART
 *   else → main memory port B
 *
 * Differences from nox_sim.sv:
 *   - No DRAM / IRAM_MIRROR split; single unified main memory for code+data
 *   - Real NS16550 UART at 0x1000_0000 (needed by OpenSBI + Linux kernel)
 *   - writeWordMain() for C++ ELF/binary loading
 */
module nox_sim_linux
  import amba_axi_pkg::*;
  import amba_ahb_pkg::*;
  import nox_utils_pkg::*;
(
  input               clk,
  input               rst
);

  // Masters: [0] = fetch, [1] = LSU
  s_axi_mosi_t  [1:0] masters_axi_mosi;
  s_axi_miso_t  [1:0] masters_axi_miso;

  // Peripheral slaves: [0]=CLINT, [1]=PLIC, [2]=UART
  s_axi_mosi_t  [2:0] periph_mosi;
  s_axi_miso_t  [2:0] periph_miso;

  // Main memory direct connections (port A = fetch, port B = LSU mux output)
  s_axi_mosi_t        mem_b_mosi;
  s_axi_miso_t        mem_b_miso;

  s_irq_t irq_wire;

  // --------------------------------------------------------------------------
  // Fetch always → main memory port A
  // --------------------------------------------------------------------------
  // (wired directly in the nox instantiation at the bottom)

  // --------------------------------------------------------------------------
  // LSU AXI mux: route by address to peripheral or main memory
  // Encoding: 0=main_mem 1=CLINT 2=PLIC 3=UART
  // --------------------------------------------------------------------------
  logic [1:0] wr_sel_ff, next_wr_sel;
  logic [1:0] rd_sel_ff, next_rd_sel;

  /* verilator lint_off PINMISSING */

  always_ff @(posedge clk) begin
    if (~rst) begin
      wr_sel_ff <= 2'd0;
      rd_sel_ff <= 2'd0;
    end else begin
      wr_sel_ff <= next_wr_sel;
      rd_sel_ff <= next_rd_sel;
    end
  end

  always_comb begin
    // Default: no peripheral selected (main memory)
    periph_mosi[0] = s_axi_mosi_t'('0);
    periph_mosi[1] = s_axi_mosi_t'('0);
    periph_mosi[2] = s_axi_mosi_t'('0);
    masters_axi_miso[1] = s_axi_miso_t'('0);
    mem_b_mosi          = s_axi_mosi_t'('0);

    next_wr_sel = wr_sel_ff;
    next_rd_sel = rd_sel_ff;

    // ---- AW write address decode ----
    if (masters_axi_mosi[1].awvalid) begin
      if      (masters_axi_mosi[1].awaddr[31:24] == 8'h02) next_wr_sel = 2'd1; // CLINT
      else if (masters_axi_mosi[1].awaddr[31:24] == 8'h0C) next_wr_sel = 2'd2; // PLIC
      else if (masters_axi_mosi[1].awaddr[31:24] == 8'h10) next_wr_sel = 2'd3; // UART
      else                                                   next_wr_sel = 2'd0; // main mem
    end

    // ---- Route AW channel ----
    if (next_wr_sel == 2'd0) begin       // main memory
      mem_b_mosi.awvalid          = masters_axi_mosi[1].awvalid;
      mem_b_mosi.awaddr           = masters_axi_mosi[1].awaddr;
      mem_b_mosi.awid             = masters_axi_mosi[1].awid;
      mem_b_mosi.awlen            = masters_axi_mosi[1].awlen;
      mem_b_mosi.awsize           = masters_axi_mosi[1].awsize;
      mem_b_mosi.awburst          = masters_axi_mosi[1].awburst;
      masters_axi_miso[1].awready = mem_b_miso.awready;
    end else if (next_wr_sel == 2'd1) begin  // CLINT
      periph_mosi[0].awvalid      = masters_axi_mosi[1].awvalid;
      periph_mosi[0].awaddr       = masters_axi_mosi[1].awaddr;
      periph_mosi[0].awid         = masters_axi_mosi[1].awid;
      periph_mosi[0].awlen        = masters_axi_mosi[1].awlen;
      periph_mosi[0].awsize       = masters_axi_mosi[1].awsize;
      periph_mosi[0].awburst      = masters_axi_mosi[1].awburst;
      masters_axi_miso[1].awready = periph_miso[0].awready;
    end else if (next_wr_sel == 2'd2) begin  // PLIC
      periph_mosi[1].awvalid      = masters_axi_mosi[1].awvalid;
      periph_mosi[1].awaddr       = masters_axi_mosi[1].awaddr;
      periph_mosi[1].awid         = masters_axi_mosi[1].awid;
      periph_mosi[1].awlen        = masters_axi_mosi[1].awlen;
      periph_mosi[1].awsize       = masters_axi_mosi[1].awsize;
      periph_mosi[1].awburst      = masters_axi_mosi[1].awburst;
      masters_axi_miso[1].awready = periph_miso[1].awready;
    end else begin                           // UART
      periph_mosi[2].awvalid      = masters_axi_mosi[1].awvalid;
      periph_mosi[2].awaddr       = masters_axi_mosi[1].awaddr;
      periph_mosi[2].awid         = masters_axi_mosi[1].awid;
      periph_mosi[2].awlen        = masters_axi_mosi[1].awlen;
      periph_mosi[2].awsize       = masters_axi_mosi[1].awsize;
      periph_mosi[2].awburst      = masters_axi_mosi[1].awburst;
      masters_axi_miso[1].awready = periph_miso[2].awready;
    end

    // ---- Route W/B channels (registered wr_sel) ----
    if (wr_sel_ff == 2'd0) begin       // main memory
      mem_b_mosi.wvalid           = masters_axi_mosi[1].wvalid;
      mem_b_mosi.wdata            = masters_axi_mosi[1].wdata;
      mem_b_mosi.wstrb            = masters_axi_mosi[1].wstrb;
      mem_b_mosi.wlast            = masters_axi_mosi[1].wlast;
      mem_b_mosi.bready           = masters_axi_mosi[1].bready;
      masters_axi_miso[1].wready  = mem_b_miso.wready;
      masters_axi_miso[1].bvalid  = mem_b_miso.bvalid;
      masters_axi_miso[1].bresp   = mem_b_miso.bresp;
      masters_axi_miso[1].bid     = mem_b_miso.bid;
    end else if (wr_sel_ff == 2'd1) begin  // CLINT
      periph_mosi[0].wvalid       = masters_axi_mosi[1].wvalid;
      periph_mosi[0].wdata        = masters_axi_mosi[1].wdata;
      periph_mosi[0].wstrb        = masters_axi_mosi[1].wstrb;
      periph_mosi[0].wlast        = masters_axi_mosi[1].wlast;
      periph_mosi[0].bready       = masters_axi_mosi[1].bready;
      masters_axi_miso[1].wready  = periph_miso[0].wready;
      masters_axi_miso[1].bvalid  = periph_miso[0].bvalid;
      masters_axi_miso[1].bresp   = periph_miso[0].bresp;
      masters_axi_miso[1].bid     = periph_miso[0].bid;
    end else if (wr_sel_ff == 2'd2) begin  // PLIC
      periph_mosi[1].wvalid       = masters_axi_mosi[1].wvalid;
      periph_mosi[1].wdata        = masters_axi_mosi[1].wdata;
      periph_mosi[1].wstrb        = masters_axi_mosi[1].wstrb;
      periph_mosi[1].wlast        = masters_axi_mosi[1].wlast;
      periph_mosi[1].bready       = masters_axi_mosi[1].bready;
      masters_axi_miso[1].wready  = periph_miso[1].wready;
      masters_axi_miso[1].bvalid  = periph_miso[1].bvalid;
      masters_axi_miso[1].bresp   = periph_miso[1].bresp;
      masters_axi_miso[1].bid     = periph_miso[1].bid;
    end else begin                           // UART
      periph_mosi[2].wvalid       = masters_axi_mosi[1].wvalid;
      periph_mosi[2].wdata        = masters_axi_mosi[1].wdata;
      periph_mosi[2].wstrb        = masters_axi_mosi[1].wstrb;
      periph_mosi[2].wlast        = masters_axi_mosi[1].wlast;
      periph_mosi[2].bready       = masters_axi_mosi[1].bready;
      masters_axi_miso[1].wready  = periph_miso[2].wready;
      masters_axi_miso[1].bvalid  = periph_miso[2].bvalid;
      masters_axi_miso[1].bresp   = periph_miso[2].bresp;
      masters_axi_miso[1].bid     = periph_miso[2].bid;
    end

    // ---- AR read address decode ----
    if (masters_axi_mosi[1].arvalid) begin
      if      (masters_axi_mosi[1].araddr[31:24] == 8'h02) next_rd_sel = 2'd1; // CLINT
      else if (masters_axi_mosi[1].araddr[31:24] == 8'h0C) next_rd_sel = 2'd2; // PLIC
      else if (masters_axi_mosi[1].araddr[31:24] == 8'h10) next_rd_sel = 2'd3; // UART
      else                                                   next_rd_sel = 2'd0; // main mem
    end

    // ---- Route AR channel ----
    if (next_rd_sel == 2'd0) begin       // main memory
      mem_b_mosi.arvalid          = masters_axi_mosi[1].arvalid;
      mem_b_mosi.araddr           = masters_axi_mosi[1].araddr;
      mem_b_mosi.arid             = masters_axi_mosi[1].arid;
      mem_b_mosi.arlen            = masters_axi_mosi[1].arlen;
      mem_b_mosi.arsize           = masters_axi_mosi[1].arsize;
      mem_b_mosi.arburst          = masters_axi_mosi[1].arburst;
      masters_axi_miso[1].arready = mem_b_miso.arready;
    end else if (next_rd_sel == 2'd1) begin  // CLINT
      periph_mosi[0].arvalid      = masters_axi_mosi[1].arvalid;
      periph_mosi[0].araddr       = masters_axi_mosi[1].araddr;
      periph_mosi[0].arid         = masters_axi_mosi[1].arid;
      periph_mosi[0].arlen        = masters_axi_mosi[1].arlen;
      periph_mosi[0].arsize       = masters_axi_mosi[1].arsize;
      periph_mosi[0].arburst      = masters_axi_mosi[1].arburst;
      masters_axi_miso[1].arready = periph_miso[0].arready;
    end else if (next_rd_sel == 2'd2) begin  // PLIC
      periph_mosi[1].arvalid      = masters_axi_mosi[1].arvalid;
      periph_mosi[1].araddr       = masters_axi_mosi[1].araddr;
      periph_mosi[1].arid         = masters_axi_mosi[1].arid;
      periph_mosi[1].arlen        = masters_axi_mosi[1].arlen;
      periph_mosi[1].arsize       = masters_axi_mosi[1].arsize;
      periph_mosi[1].arburst      = masters_axi_mosi[1].arburst;
      masters_axi_miso[1].arready = periph_miso[1].arready;
    end else begin                           // UART
      periph_mosi[2].arvalid      = masters_axi_mosi[1].arvalid;
      periph_mosi[2].araddr       = masters_axi_mosi[1].araddr;
      periph_mosi[2].arid         = masters_axi_mosi[1].arid;
      periph_mosi[2].arlen        = masters_axi_mosi[1].arlen;
      periph_mosi[2].arsize       = masters_axi_mosi[1].arsize;
      periph_mosi[2].arburst      = masters_axi_mosi[1].arburst;
      masters_axi_miso[1].arready = periph_miso[2].arready;
    end

    // ---- Route R channel (registered rd_sel) ----
    if (rd_sel_ff == 2'd0) begin       // main memory
      mem_b_mosi.rready           = masters_axi_mosi[1].rready;
      masters_axi_miso[1].rvalid  = mem_b_miso.rvalid;
      masters_axi_miso[1].rdata   = mem_b_miso.rdata;
      masters_axi_miso[1].rresp   = mem_b_miso.rresp;
      masters_axi_miso[1].rlast   = mem_b_miso.rlast;
      masters_axi_miso[1].rid     = mem_b_miso.rid;
    end else if (rd_sel_ff == 2'd1) begin  // CLINT
      periph_mosi[0].rready       = masters_axi_mosi[1].rready;
      masters_axi_miso[1].rvalid  = periph_miso[0].rvalid;
      masters_axi_miso[1].rdata   = periph_miso[0].rdata;
      masters_axi_miso[1].rresp   = periph_miso[0].rresp;
      masters_axi_miso[1].rlast   = periph_miso[0].rlast;
      masters_axi_miso[1].rid     = periph_miso[0].rid;
    end else if (rd_sel_ff == 2'd2) begin  // PLIC
      periph_mosi[1].rready       = masters_axi_mosi[1].rready;
      masters_axi_miso[1].rvalid  = periph_miso[1].rvalid;
      masters_axi_miso[1].rdata   = periph_miso[1].rdata;
      masters_axi_miso[1].rresp   = periph_miso[1].rresp;
      masters_axi_miso[1].rlast   = periph_miso[1].rlast;
      masters_axi_miso[1].rid     = periph_miso[1].rid;
    end else begin                           // UART
      periph_mosi[2].rready       = masters_axi_mosi[1].rready;
      masters_axi_miso[1].rvalid  = periph_miso[2].rvalid;
      masters_axi_miso[1].rdata   = periph_miso[2].rdata;
      masters_axi_miso[1].rresp   = periph_miso[2].rresp;
      masters_axi_miso[1].rlast   = periph_miso[2].rlast;
      masters_axi_miso[1].rid     = periph_miso[2].rid;
    end
  end

  /* verilator lint_on PINMISSING */

  // --------------------------------------------------------------------------
  // Dual-port main memory
  // --------------------------------------------------------------------------
  axi_mem_dp #(
    .MEM_KB(`MAIN_MEM_KB_SIZE)
  ) u_main_mem (
    .clk       (clk),
    .rst       (rst),
    .axi_a_mosi(masters_axi_mosi[0]),  // fetch (read-only)
    .axi_a_miso(masters_axi_miso[0]),
    .axi_b_mosi(mem_b_mosi),           // LSU (read-write, via mux)
    .axi_b_miso(mem_b_miso)
  );

  // --------------------------------------------------------------------------
  // Peripherals
  // --------------------------------------------------------------------------
  clint u_clint (
    .clk       (clk),
    .rst       (rst),
    .axi_mosi  (periph_mosi[0]),
    .axi_miso  (periph_miso[0]),
    .timer_irq (irq_wire.timer_irq),
    .sw_irq    (irq_wire.sw_irq)
  );

  logic uart_irq;

  plic_stub u_plic (
    .clk       (clk),
    .rst       (rst),
    .ext_src_i (uart_irq),
    .axi_mosi  (periph_mosi[1]),
    .axi_miso  (periph_miso[1]),
    .m_ext_irq (irq_wire.ext_irq),
    .s_ext_irq (irq_wire.s_ext_irq)
  );

  ns16550 u_uart (
    .clk       (clk),
    .rst       (rst),
    .axi_mosi  (periph_mosi[2]),
    .axi_miso  (periph_miso[2]),
    .uart_irq_o(uart_irq)
  );

  // --------------------------------------------------------------------------
  // NoX core
  // --------------------------------------------------------------------------
  nox u_nox (
    .clk              (clk),
    .arst             (rst),
    .start_fetch_i    (1'b1),
    .start_addr_i     (64'(`ENTRY_ADDR)),
    .irq_i            (irq_wire),
    .instr_axi_mosi_o (masters_axi_mosi[0]),
    .instr_axi_miso_i (masters_axi_miso[0]),
    .lsu_axi_mosi_o   (masters_axi_mosi[1]),
    .lsu_axi_miso_i   (masters_axi_miso[1])
  );

  // --------------------------------------------------------------------------
  // Memory initialization helpers (called from testbench_linux.cpp)
  // addr_val: 32-bit word index into the main memory flat array
  //           (byte_offset / 4, relative to MAIN_MEM_ADDR = 0x8000_0000)
  // word_val: 32-bit little-endian word to write
  // --------------------------------------------------------------------------
  // synthesis translate_off
  function automatic void writeWordMain(addr_val, word_val);
    /* verilator public */
    logic [31:0] addr_val;
    logic [31:0] word_val;
    if (addr_val[0])
      u_main_mem.mem_loading[addr_val>>1][63:32] = word_val;
    else
      u_main_mem.mem_loading[addr_val>>1][31:0]  = word_val;
  endfunction
  // synthesis translate_on

endmodule
