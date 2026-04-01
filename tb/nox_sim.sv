/**
 * File              : nox_sim.sv
 * License           : MIT license <Check LICENSE>
 * Author            : Anderson Ignacio da Silva (aignacio) <anderson@aignacio.com>
 * Date              : 12.12.2021
 * Last Modified Date: 2026-03-31 (Phase 2B: CLINT + PLIC)
 */
module nox_sim
  import amba_axi_pkg::*;
  import amba_ahb_pkg::*;
  import nox_utils_pkg::*;
(
  input               clk,
  input               rst
);
  // Masters: [0] = fetch/IRAM, [1] = LSU
  s_axi_mosi_t  [1:0] masters_axi_mosi;
  s_axi_miso_t  [1:0] masters_axi_miso;

  // Slaves: [0]=IRAM, [1]=DRAM, [2]=IRAM_MIRROR, [3]=CLINT, [4]=PLIC
  s_axi_mosi_t  [4:0] slaves_axi_mosi;
  s_axi_miso_t  [4:0] slaves_axi_miso;

  // Fetch port always → IRAM
  assign slaves_axi_mosi[0]  = masters_axi_mosi[0];
  assign masters_axi_miso[0] = slaves_axi_miso[0];

  s_irq_t irq_wire;

  /* verilator lint_off PINMISSING */
`ifndef RV_COMPLIANCE

  // --------------------------------------------------------------------------
  // LSU AXI mux: 0=idle 1=DRAM 2=IRAM_MIRROR 3=CLINT 4=PLIC
  // --------------------------------------------------------------------------
  logic [2:0] wr_sel_ff, next_wr_sel;
  logic [2:0] rd_sel_ff, next_rd_sel;

  always_ff @(posedge clk) begin
    if (~rst) begin
      wr_sel_ff <= 3'd0;
      rd_sel_ff <= 3'd0;
    end else begin
      wr_sel_ff <= next_wr_sel;
      rd_sel_ff <= next_rd_sel;
    end
  end

  always_comb begin
    // Default: zero all slave inputs
    slaves_axi_mosi[1] = s_axi_mosi_t'('0);
    slaves_axi_mosi[2] = s_axi_mosi_t'('0);
    slaves_axi_mosi[3] = s_axi_mosi_t'('0);
    slaves_axi_mosi[4] = s_axi_mosi_t'('0);
    masters_axi_miso[1] = s_axi_miso_t'('0);

    next_wr_sel = wr_sel_ff;
    next_rd_sel = rd_sel_ff;

    // ---- AW write address decode ----
    if (masters_axi_mosi[1].awvalid) begin
      if      (masters_axi_mosi[1].awaddr[31:24] == 8'h02) next_wr_sel = 3'd3; // CLINT
      else if (masters_axi_mosi[1].awaddr[31:24] == 8'h0C) next_wr_sel = 3'd4; // PLIC
      else                                                   next_wr_sel = 3'd1; // DRAM
    end

    // ---- Route AW channel ----
    if (next_wr_sel == 3'd1) begin
      slaves_axi_mosi[1].awvalid  = masters_axi_mosi[1].awvalid;
      slaves_axi_mosi[1].awaddr   = masters_axi_mosi[1].awaddr;
      slaves_axi_mosi[1].awid     = masters_axi_mosi[1].awid;
      slaves_axi_mosi[1].awlen    = masters_axi_mosi[1].awlen;
      slaves_axi_mosi[1].awsize   = masters_axi_mosi[1].awsize;
      slaves_axi_mosi[1].awburst  = masters_axi_mosi[1].awburst;
      masters_axi_miso[1].awready = slaves_axi_miso[1].awready;
    end else if (next_wr_sel == 3'd3) begin
      slaves_axi_mosi[3].awvalid  = masters_axi_mosi[1].awvalid;
      slaves_axi_mosi[3].awaddr   = masters_axi_mosi[1].awaddr;
      slaves_axi_mosi[3].awid     = masters_axi_mosi[1].awid;
      slaves_axi_mosi[3].awlen    = masters_axi_mosi[1].awlen;
      slaves_axi_mosi[3].awsize   = masters_axi_mosi[1].awsize;
      slaves_axi_mosi[3].awburst  = masters_axi_mosi[1].awburst;
      masters_axi_miso[1].awready = slaves_axi_miso[3].awready;
    end else if (next_wr_sel == 3'd4) begin
      slaves_axi_mosi[4].awvalid  = masters_axi_mosi[1].awvalid;
      slaves_axi_mosi[4].awaddr   = masters_axi_mosi[1].awaddr;
      slaves_axi_mosi[4].awid     = masters_axi_mosi[1].awid;
      slaves_axi_mosi[4].awlen    = masters_axi_mosi[1].awlen;
      slaves_axi_mosi[4].awsize   = masters_axi_mosi[1].awsize;
      slaves_axi_mosi[4].awburst  = masters_axi_mosi[1].awburst;
      masters_axi_miso[1].awready = slaves_axi_miso[4].awready;
    end else begin
      masters_axi_miso[1].awready = 1'b1;
    end

    // ---- Route W/B channels (use registered wr_sel) ----
    if (wr_sel_ff == 3'd1) begin
      slaves_axi_mosi[1].wvalid   = masters_axi_mosi[1].wvalid;
      slaves_axi_mosi[1].wdata    = masters_axi_mosi[1].wdata;
      slaves_axi_mosi[1].wstrb    = masters_axi_mosi[1].wstrb;
      slaves_axi_mosi[1].wlast    = masters_axi_mosi[1].wlast;
      slaves_axi_mosi[1].bready   = masters_axi_mosi[1].bready;
      masters_axi_miso[1].wready  = slaves_axi_miso[1].wready;
      masters_axi_miso[1].bvalid  = slaves_axi_miso[1].bvalid;
      masters_axi_miso[1].bresp   = slaves_axi_miso[1].bresp;
      masters_axi_miso[1].bid     = slaves_axi_miso[1].bid;
    end else if (wr_sel_ff == 3'd3) begin
      slaves_axi_mosi[3].wvalid   = masters_axi_mosi[1].wvalid;
      slaves_axi_mosi[3].wdata    = masters_axi_mosi[1].wdata;
      slaves_axi_mosi[3].wstrb    = masters_axi_mosi[1].wstrb;
      slaves_axi_mosi[3].wlast    = masters_axi_mosi[1].wlast;
      slaves_axi_mosi[3].bready   = masters_axi_mosi[1].bready;
      masters_axi_miso[1].wready  = slaves_axi_miso[3].wready;
      masters_axi_miso[1].bvalid  = slaves_axi_miso[3].bvalid;
      masters_axi_miso[1].bresp   = slaves_axi_miso[3].bresp;
      masters_axi_miso[1].bid     = slaves_axi_miso[3].bid;
    end else if (wr_sel_ff == 3'd4) begin
      slaves_axi_mosi[4].wvalid   = masters_axi_mosi[1].wvalid;
      slaves_axi_mosi[4].wdata    = masters_axi_mosi[1].wdata;
      slaves_axi_mosi[4].wstrb    = masters_axi_mosi[1].wstrb;
      slaves_axi_mosi[4].wlast    = masters_axi_mosi[1].wlast;
      slaves_axi_mosi[4].bready   = masters_axi_mosi[1].bready;
      masters_axi_miso[1].wready  = slaves_axi_miso[4].wready;
      masters_axi_miso[1].bvalid  = slaves_axi_miso[4].bvalid;
      masters_axi_miso[1].bresp   = slaves_axi_miso[4].bresp;
      masters_axi_miso[1].bid     = slaves_axi_miso[4].bid;
    end else begin
      masters_axi_miso[1].wready  = 1'b1;
      masters_axi_miso[1].bvalid  = masters_axi_mosi[1].wlast;
      masters_axi_miso[1].bresp   = AXI_OKAY;
      masters_axi_miso[1].bid     = '0;
    end

    // ---- AR read address decode ----
    if (masters_axi_mosi[1].arvalid) begin
      if      (masters_axi_mosi[1].araddr[31:16] == 16'h8000) next_rd_sel = 3'd2; // IRAM_MIRROR
      else if (masters_axi_mosi[1].araddr[31:24] == 8'h02)    next_rd_sel = 3'd3; // CLINT
      else if (masters_axi_mosi[1].araddr[31:24] == 8'h0C)    next_rd_sel = 3'd4; // PLIC
      else                                                      next_rd_sel = 3'd1; // DRAM
    end

    // ---- Route AR channel ----
    if (next_rd_sel == 3'd1) begin
      slaves_axi_mosi[1].arvalid  = masters_axi_mosi[1].arvalid;
      slaves_axi_mosi[1].araddr   = masters_axi_mosi[1].araddr;
      slaves_axi_mosi[1].arid     = masters_axi_mosi[1].arid;
      slaves_axi_mosi[1].arlen    = masters_axi_mosi[1].arlen;
      slaves_axi_mosi[1].arsize   = masters_axi_mosi[1].arsize;
      slaves_axi_mosi[1].arburst  = masters_axi_mosi[1].arburst;
      masters_axi_miso[1].arready = slaves_axi_miso[1].arready;
    end else if (next_rd_sel == 3'd2) begin
      slaves_axi_mosi[2].arvalid  = masters_axi_mosi[1].arvalid;
      slaves_axi_mosi[2].araddr   = masters_axi_mosi[1].araddr;
      slaves_axi_mosi[2].arid     = masters_axi_mosi[1].arid;
      slaves_axi_mosi[2].arlen    = masters_axi_mosi[1].arlen;
      slaves_axi_mosi[2].arsize   = masters_axi_mosi[1].arsize;
      slaves_axi_mosi[2].arburst  = masters_axi_mosi[1].arburst;
      masters_axi_miso[1].arready = slaves_axi_miso[2].arready;
    end else if (next_rd_sel == 3'd3) begin
      slaves_axi_mosi[3].arvalid  = masters_axi_mosi[1].arvalid;
      slaves_axi_mosi[3].araddr   = masters_axi_mosi[1].araddr;
      slaves_axi_mosi[3].arid     = masters_axi_mosi[1].arid;
      slaves_axi_mosi[3].arlen    = masters_axi_mosi[1].arlen;
      slaves_axi_mosi[3].arsize   = masters_axi_mosi[1].arsize;
      slaves_axi_mosi[3].arburst  = masters_axi_mosi[1].arburst;
      masters_axi_miso[1].arready = slaves_axi_miso[3].arready;
    end else if (next_rd_sel == 3'd4) begin
      slaves_axi_mosi[4].arvalid  = masters_axi_mosi[1].arvalid;
      slaves_axi_mosi[4].araddr   = masters_axi_mosi[1].araddr;
      slaves_axi_mosi[4].arid     = masters_axi_mosi[1].arid;
      slaves_axi_mosi[4].arlen    = masters_axi_mosi[1].arlen;
      slaves_axi_mosi[4].arsize   = masters_axi_mosi[1].arsize;
      slaves_axi_mosi[4].arburst  = masters_axi_mosi[1].arburst;
      masters_axi_miso[1].arready = slaves_axi_miso[4].arready;
    end else begin
      masters_axi_miso[1].arready = 1'b1;
    end

    // ---- Route R channel (use registered rd_sel) ----
    if (rd_sel_ff == 3'd1) begin
      slaves_axi_mosi[1].rready   = masters_axi_mosi[1].rready;
      masters_axi_miso[1].rvalid  = slaves_axi_miso[1].rvalid;
      masters_axi_miso[1].rdata   = slaves_axi_miso[1].rdata;
      masters_axi_miso[1].rresp   = slaves_axi_miso[1].rresp;
      masters_axi_miso[1].rlast   = slaves_axi_miso[1].rlast;
      masters_axi_miso[1].rid     = slaves_axi_miso[1].rid;
    end else if (rd_sel_ff == 3'd2) begin
      slaves_axi_mosi[2].rready   = masters_axi_mosi[1].rready;
      masters_axi_miso[1].rvalid  = slaves_axi_miso[2].rvalid;
      masters_axi_miso[1].rdata   = slaves_axi_miso[2].rdata;
      masters_axi_miso[1].rresp   = slaves_axi_miso[2].rresp;
      masters_axi_miso[1].rlast   = slaves_axi_miso[2].rlast;
      masters_axi_miso[1].rid     = slaves_axi_miso[2].rid;
    end else if (rd_sel_ff == 3'd3) begin
      slaves_axi_mosi[3].rready   = masters_axi_mosi[1].rready;
      masters_axi_miso[1].rvalid  = slaves_axi_miso[3].rvalid;
      masters_axi_miso[1].rdata   = slaves_axi_miso[3].rdata;
      masters_axi_miso[1].rresp   = slaves_axi_miso[3].rresp;
      masters_axi_miso[1].rlast   = slaves_axi_miso[3].rlast;
      masters_axi_miso[1].rid     = slaves_axi_miso[3].rid;
    end else if (rd_sel_ff == 3'd4) begin
      slaves_axi_mosi[4].rready   = masters_axi_mosi[1].rready;
      masters_axi_miso[1].rvalid  = slaves_axi_miso[4].rvalid;
      masters_axi_miso[1].rdata   = slaves_axi_miso[4].rdata;
      masters_axi_miso[1].rresp   = slaves_axi_miso[4].rresp;
      masters_axi_miso[1].rlast   = slaves_axi_miso[4].rlast;
      masters_axi_miso[1].rid     = slaves_axi_miso[4].rid;
    end else begin
      masters_axi_miso[1].rvalid  = 1'b0;
      masters_axi_miso[1].rdata   = '0;
      masters_axi_miso[1].rresp   = AXI_OKAY;
      masters_axi_miso[1].rlast   = 1'b0;
      masters_axi_miso[1].rid     = '0;
    end
  end

  axi_mem #(
    .MEM_KB(`IRAM_KB_SIZE)
  ) u_iram_mirror (
    .clk      (clk),
    .rst      (rst),
    .axi_mosi (slaves_axi_mosi[2]),
    .axi_miso (slaves_axi_miso[2])
  );

`else
  assign slaves_axi_mosi[1]  = masters_axi_mosi[1];
  assign masters_axi_miso[1] = slaves_axi_miso[1];
`endif

  axi_mem #(
    .MEM_KB(`IRAM_KB_SIZE)
  ) u_iram (
    .clk      (clk),
    .rst      (rst),
    .axi_mosi (slaves_axi_mosi[0]),
    .axi_miso (slaves_axi_miso[0])
  );

  axi_mem #(
    .MEM_KB(`DRAM_KB_SIZE)
  ) u_dram (
    .clk      (clk),
    .rst      (rst),
    .axi_mosi (slaves_axi_mosi[1]),
    .axi_miso (slaves_axi_miso[1])
  );

`ifndef RV_COMPLIANCE
  clint u_clint (
    .clk        (clk),
    .rst        (rst),
    .axi_mosi   (slaves_axi_mosi[3]),
    .axi_miso   (slaves_axi_miso[3]),
    .timer_irq  (irq_wire.timer_irq),
    .sw_irq     (irq_wire.sw_irq)
  );

  plic_stub u_plic (
    .clk        (clk),
    .rst        (rst),
    .ext_src_i  (1'b0),
    .axi_mosi   (slaves_axi_mosi[4]),
    .axi_miso   (slaves_axi_miso[4]),
    .m_ext_irq  (irq_wire.ext_irq),
    .s_ext_irq  (irq_wire.s_ext_irq)
  );
`else
  assign slaves_axi_mosi[3] = s_axi_mosi_t'('0);
  assign slaves_axi_mosi[4] = s_axi_mosi_t'('0);
  assign irq_wire = s_irq_t'('0);
`endif

  /* verilator lint_on PINMISSING */

  nox u_nox(
    .clk              (clk),
    .arst             (rst),
    .start_fetch_i    ('b1),
    .start_addr_i     (64'(`ENTRY_ADDR)),
`ifndef RV_COMPLIANCE
    .irq_i            (irq_wire),
`else
    .irq_i            ('0),
`endif
    .instr_axi_mosi_o (masters_axi_mosi[0]),
    .instr_axi_miso_i (masters_axi_miso[0]),
    .lsu_axi_mosi_o   (masters_axi_mosi[1]),
    .lsu_axi_miso_i   (masters_axi_miso[1])
  );

  // synthesis translate_off
  function automatic void writeWordIRAM(addr_val, word_val);
    /*verilator public*/
    logic [31:0] addr_val;
    logic [31:0] word_val;
    if (addr_val[0]) begin
      u_iram.mem_loading[addr_val>>1][63:32]        = word_val;
`ifndef RV_COMPLIANCE
      u_iram_mirror.mem_loading[addr_val>>1][63:32] = word_val;
`endif
    end else begin
      u_iram.mem_loading[addr_val>>1][31:0]        = word_val;
`ifndef RV_COMPLIANCE
      u_iram_mirror.mem_loading[addr_val>>1][31:0] = word_val;
`endif
    end
  endfunction

  function automatic void writeWordDRAM(addr_val, word_val);
    /*verilator public*/
    logic [31:0] addr_val;
    logic [31:0] word_val;
    if (addr_val[0])
      u_dram.mem_loading[addr_val>>1][63:32] = word_val;
    else
      u_dram.mem_loading[addr_val>>1][31:0] = word_val;
  endfunction
  // synthesis translate_on
endmodule
