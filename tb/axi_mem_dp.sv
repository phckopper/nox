/**
 * axi_mem_dp.sv — dual-port AXI memory for Linux-mode testbench
 *
 * Port A (fetch): read-only AXI slave — fetch engine connects here.
 * Port B (LSU):   read-write AXI slave — LSU connects here.
 * Both ports share a single backing store (mem_ff).
 *
 * Writes from Port B are immediately visible to subsequent Port A reads
 * (no cross-port RAW forwarding; code self-modification requires FENCE.I).
 *
 * SIMULATION intercepts on Port B writes (in SIMULATION mode):
 *   0xA000_0000 and 0xD000_0008 → print byte to stdout (bare-metal UART shim)
 *   Intercepted addresses are NOT written to memory.
 *
 * Initialization: C++ writes to mem_loading[] via writeWord(), which is
 * copied to mem_ff at reset (initial block, same pattern as axi_mem.sv).
 */
module axi_mem_dp
  import amba_axi_pkg::*;
  import amba_ahb_pkg::*;
  import nox_utils_pkg::*;
#(
  parameter MEM_KB       = 65536,         // 64 MB default
  parameter DISPLAY_TEST = `DISPLAY_TEST
)(
  input               clk,
  input               rst,
  // Port A: fetch (read-only)
  input   s_axi_mosi_t  axi_a_mosi,
  output  s_axi_miso_t  axi_a_miso,
  // Port B: LSU (read-write)
  input   s_axi_mosi_t  axi_b_mosi,
  output  s_axi_miso_t  axi_b_miso
);

  localparam ADDR_RAM  = $clog2((MEM_KB*1024)/8);
  localparam NUM_WORDS = (MEM_KB*1024)/8;

  logic [NUM_WORDS-1:0][63:0] mem_ff;
  logic [NUM_WORDS-1:0][63:0] mem_loading;

  // --------------------------------------------------------------------------
  // Port A: read-only state
  // --------------------------------------------------------------------------
  axi_tid_t                axi_a_rid_ff,    next_axi_a_rid;
  logic                    axi_a_rd_vld_ff, next_axi_a_rd;
  axi_data_t               rd_a_data_ff,    next_rd_a_data;
  logic [ADDR_RAM-1:0]     rd_a_addr;
  logic [2:0]              byte_a_sel;

  // --------------------------------------------------------------------------
  // Port B: read-write state
  // --------------------------------------------------------------------------
  axi_tid_t                axi_b_rid_ff,    next_axi_b_rid;
  axi_tid_t                axi_b_wid_ff,    next_axi_b_wid;
  logic                    axi_b_rd_vld_ff, next_axi_b_rd;
  logic                    axi_b_wr_vld_ff, next_axi_b_wr;
  axi_data_t               rd_b_data_ff,    next_rd_b_data;
  axi_addr_t               wr_b_addr_ff,    next_wr_b_addr;
  axi_size_t               size_b_wr_ff,    next_wr_b_size;
  logic                    bvalid_b_ff;
  logic [ADDR_RAM-1:0]     rd_b_addr;
  logic [ADDR_RAM-1:0]     wr_b_addr;
  logic [2:0]              byte_b_sel_rd;
  logic [2:0]              byte_b_sel_wr;
  logic                    we_b_mem;
  logic [63:0]             next_b_wdata;
  logic                    raw_b_hit;

`ifdef SIMULATION
  logic [7:0] char_b_wr;
  logic       next_char_b, char_b_ff;
`endif

  // --------------------------------------------------------------------------
  // Utility functions (mirrors of axi_mem.sv)
  // --------------------------------------------------------------------------
  function automatic axi_data_t mask_axi_w(axi_data_t    data,
                                           logic [2:0]   byte_sel,
                                           axi_wr_strb_t wstrb);
    axi_data_t data_o;
    for (int i = 0; i < 8; i++)
      data_o[i*8+:8] = wstrb[i] ? data[i*8+:8] : 8'h0;
    data_o = data_o << (8*byte_sel);
    return data_o;
  endfunction

  function automatic axi_data_t mask_axi(axi_data_t  data,
                                         logic [2:0] byte_sel,
                                         axi_size_t  sz);
    axi_data_t   data_o;
    logic [63:0] mask_val;
    case (sz)
      AXI_BYTE:      mask_val = 64'hFF;
      AXI_HALF_WORD: mask_val = 64'hFFFF;
      AXI_WORD:      mask_val = 64'hFFFF_FFFF;
      default:       mask_val = 64'hFFFF_FFFF_FFFF_FFFF;
    endcase
    data_o = data & (mask_val << (8*byte_sel));
    return data_o;
  endfunction

  // Initialization function called from C++ via Verilator public interface
  function automatic void writeWord(addr_val, word_val);
    /* verilator public */
    logic [31:0] addr_val;
    logic [31:0] word_val;
    if (addr_val[0])
      mem_loading[addr_val>>1][63:32] = word_val;
    else
      mem_loading[addr_val>>1][31:0]  = word_val;
  endfunction

  // --------------------------------------------------------------------------
  // Port A: read-only (fetch)
  // --------------------------------------------------------------------------
  always_comb begin : port_a_rd
    rd_a_addr      = axi_a_mosi.araddr[3+:ADDR_RAM];
    byte_a_sel     = 3'h0;
    next_axi_a_rd  = 1'b0;
    next_rd_a_data = rd_a_data_ff;
    next_axi_a_rid = axi_a_rid_ff;

    // Tie off write channels — fetch never writes
    axi_a_miso.awready = 1'b0;
    axi_a_miso.wready  = 1'b0;
    axi_a_miso.bvalid  = 1'b0;
    axi_a_miso.bresp   = AXI_OKAY;
    axi_a_miso.bid     = '0;
    axi_a_miso.buser   = '0;

    axi_a_miso.arready = ~axi_a_rd_vld_ff | axi_a_mosi.rready;
    axi_a_miso.rvalid  = axi_a_rd_vld_ff;
    axi_a_miso.rlast   = axi_a_rd_vld_ff;
    axi_a_miso.rdata   = axi_a_rd_vld_ff ? axi_data_t'(rd_a_data_ff) : axi_data_t'('0);
    axi_a_miso.rresp   = AXI_OKAY;
    axi_a_miso.rid     = axi_a_rid_ff;
    axi_a_miso.ruser   = axi_user_req_t'('0);

    if (axi_a_rd_vld_ff)
      next_axi_a_rd = ~axi_a_mosi.rready;

    if (axi_a_mosi.arvalid && axi_a_miso.arready) begin
      next_axi_a_rd  = 1'b1;
      byte_a_sel     = axi_a_mosi.araddr[2:0];
      next_axi_a_rid = axi_a_mosi.arid;
      next_rd_a_data = mask_axi(mem_ff[rd_a_addr], byte_a_sel, axi_a_mosi.arsize);
    end
  end : port_a_rd

  // --------------------------------------------------------------------------
  // Port B: read-write (LSU)
  // --------------------------------------------------------------------------
  always_comb begin : port_b_rw
    next_wr_b_addr = axi_addr_t'('0);
    next_axi_b_wr  = axi_b_wr_vld_ff;
    next_wr_b_size = axi_size_t'('0);
    wr_b_addr      = wr_b_addr_ff[3+:ADDR_RAM];
    byte_b_sel_wr  = 3'h0;
    we_b_mem       = 1'b0;
    next_b_wdata   = 64'h0;
    next_axi_b_wid = axi_b_wid_ff;
    rd_b_addr      = axi_b_mosi.araddr[3+:ADDR_RAM];
    byte_b_sel_rd  = 3'h0;
    next_axi_b_rd  = 1'b0;
    next_rd_b_data = rd_b_data_ff;
    next_axi_b_rid = axi_b_rid_ff;
    raw_b_hit      = axi_b_mosi.arvalid && we_b_mem &&
                     (axi_b_mosi.araddr == wr_b_addr_ff);

`ifdef SIMULATION
    next_char_b    = 1'b0;
    char_b_wr      = 8'h0;
`endif

    axi_b_miso.awready = 1'b1;
    axi_b_miso.wready  = 1'b1;
    axi_b_miso.bid     = axi_b_wid_ff;
    axi_b_miso.bresp   = AXI_OKAY;
    axi_b_miso.buser   = '0;
    axi_b_miso.bvalid  = bvalid_b_ff;

    // AW address decode
    if (axi_b_mosi.awvalid && axi_b_miso.awready) begin
      next_axi_b_wid = axi_b_mosi.awid;
`ifdef SIMULATION
      if (axi_b_mosi.awaddr == 64'hA000_0000 ||
          axi_b_mosi.awaddr == 64'hD000_0008) begin
        next_char_b = 1'b1;
      end else begin
        next_wr_b_addr = axi_b_mosi.awaddr;
        next_axi_b_wr  = 1'b1;
        next_wr_b_size = axi_b_mosi.awsize;
      end
`else
      next_wr_b_addr = axi_b_mosi.awaddr;
      next_axi_b_wr  = 1'b1;
      next_wr_b_size = axi_b_mosi.awsize;
`endif
    end

    // W data phase
    if (axi_b_mosi.wvalid && axi_b_wr_vld_ff) begin
      byte_b_sel_wr = wr_b_addr_ff[2:0];
      next_b_wdata  = mask_axi_w(axi_b_mosi.wdata, byte_b_sel_wr, axi_b_mosi.wstrb);
      we_b_mem      = 1'b1;
    end

    // B response
    axi_b_miso.bvalid = bvalid_b_ff;

    // AR read
    axi_b_miso.arready = ~axi_b_rd_vld_ff | axi_b_mosi.rready;
    axi_b_miso.rresp   = AXI_OKAY;
    axi_b_miso.ruser   = axi_user_req_t'('0);
    axi_b_miso.rvalid  = axi_b_rd_vld_ff;
    axi_b_miso.rlast   = axi_b_rd_vld_ff;
    axi_b_miso.rid     = axi_b_rid_ff;
    axi_b_miso.rdata   = axi_b_rd_vld_ff ? axi_data_t'(rd_b_data_ff) : axi_data_t'('0);

    if (axi_b_rd_vld_ff)
      next_axi_b_rd = ~axi_b_mosi.rready;

    if (axi_b_mosi.arvalid && axi_b_miso.arready) begin
      next_axi_b_rd  = 1'b1;
      byte_b_sel_rd  = axi_b_mosi.araddr[2:0];
      next_axi_b_rid = axi_b_mosi.arid;
      if (raw_b_hit) begin
        // RAW forwarding: return write-merged value
        next_rd_b_data = mem_ff[rd_b_addr];
        for (int i = 0; i < 8; i++)
          if (axi_b_mosi.wstrb[i])
            next_rd_b_data[i*8+:8] = axi_b_mosi.wdata[i*8+:8];
      end else begin
        next_rd_b_data = mask_axi(mem_ff[rd_b_addr], byte_b_sel_rd, axi_b_mosi.arsize);
      end
    end
  end : port_b_rw

  // --------------------------------------------------------------------------
  // Sequential
  // --------------------------------------------------------------------------
  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      rd_a_data_ff    <= axi_data_t'('0);
      axi_a_rd_vld_ff <= 1'b0;
      axi_a_rid_ff    <= '0;
      rd_b_data_ff    <= axi_data_t'('0);
      axi_b_rd_vld_ff <= 1'b0;
      axi_b_wr_vld_ff <= 1'b0;
      wr_b_addr_ff    <= axi_addr_t'('0);
      size_b_wr_ff    <= axi_size_t'('0);
      bvalid_b_ff     <= 1'b0;
      axi_b_rid_ff    <= '0;
      axi_b_wid_ff    <= '0;
`ifdef SIMULATION
      char_b_ff       <= 1'b0;
`endif
    end
    else begin
      rd_a_data_ff    <= next_rd_a_data;
      axi_a_rd_vld_ff <= next_axi_a_rd;
      axi_a_rid_ff    <= next_axi_a_rid;
      rd_b_data_ff    <= next_rd_b_data;
      axi_b_rd_vld_ff <= next_axi_b_rd;
      axi_b_wr_vld_ff <= next_axi_b_wr;
      wr_b_addr_ff    <= next_wr_b_addr;
      size_b_wr_ff    <= next_wr_b_size;
      bvalid_b_ff     <= axi_b_mosi.wlast;
      axi_b_rid_ff    <= next_axi_b_rid;
      axi_b_wid_ff    <= next_axi_b_wid;
`ifdef SIMULATION
      char_b_ff       <= next_char_b;
      if (char_b_ff && axi_b_mosi.wvalid)
        $write("%c", axi_b_mosi.wdata[7:0]);
`endif
      if (we_b_mem) begin
        for (int i = 0; i < 8; i++)
          if (axi_b_mosi.wstrb[i])
            mem_ff[wr_b_addr][i*8+:8] <= axi_b_mosi.wdata[i*8+:8];
      end
    end
  end

  // Copy loader contents to active memory at reset (time-0 initial block)
  initial begin
    `ifdef ACT_H_RESET
    if (rst) begin
    `else
    if (~rst) begin
    `endif
      mem_ff = mem_loading;
    end
  end

endmodule
