/**
 * File   : clint.sv
 * Date   : 2026-03-31
 *
 * RISC-V CLINT (Core Local Interruptor) — AXI4 slave
 *
 * Standard memory map (base address supplied externally):
 *   offset 0x0000 : MSIP       [31:0] — bit[0] = M-mode software interrupt
 *   offset 0x4000 : MTIMECMP_LO [31:0] — lower 32 bits of mtimecmp
 *   offset 0x4004 : MTIMECMP_HI [31:0] — upper 32 bits of mtimecmp
 *   offset 0xBFF8 : MTIME_LO   [31:0] — lower 32 bits of mtime (read-only from SW)
 *   offset 0xBFFC : MTIME_HI   [31:0] — upper 32 bits of mtime (read-only from SW)
 *
 * mtime increments every clock cycle.
 * timer_irq = (mtime >= mtimecmp)
 * sw_irq    = msip[0]
 */
module clint
  import amba_axi_pkg::*;
  import nox_utils_pkg::*;
#(
  parameter logic [63:0] BASE_ADDR = 64'h0200_0000
)(
  input               clk,
  input               rst,
  input  s_axi_mosi_t axi_mosi,
  output s_axi_miso_t axi_miso,
  output logic        timer_irq,
  output logic        sw_irq
);
  // Internal registers
  logic [63:0] msip_ff;        // Only bit[0] used
  logic [63:0] mtimecmp_ff;
  logic [63:0] mtime_ff;

  // AXI handshake state
  logic        wr_active_ff;   // AW accepted, waiting for W
  axi_addr_t   wr_addr_ff;
  axi_size_t   wr_size_ff;

  logic        rd_valid_ff;
  axi_data_t   rd_data_ff;
  axi_tid_t    rd_id_ff;

  logic [15:0] wr_off, rd_off;

  // Interrupt outputs
  assign timer_irq = (mtime_ff >= mtimecmp_ff);
  assign sw_irq    = msip_ff[0];

  // ---- Write path ----
  always_comb begin
    axi_miso.awready = ~wr_active_ff;
    axi_miso.wready  = wr_active_ff;
    axi_miso.bid     = axi_tid_t'('0);
    axi_miso.bresp   = AXI_OKAY;
    axi_miso.buser   = '0;
    axi_miso.bvalid  = wr_active_ff & axi_mosi.wvalid;
    wr_off           = wr_addr_ff[15:0];
  end

  // ---- Read path ----
  always_comb begin
    axi_miso.arready = ~rd_valid_ff;
    axi_miso.rvalid  = rd_valid_ff;
    axi_miso.rdata   = rd_data_ff;
    axi_miso.rlast   = rd_valid_ff;
    axi_miso.rresp   = AXI_OKAY;
    axi_miso.rid     = rd_id_ff;
    axi_miso.ruser   = '0;
    rd_off           = axi_mosi.araddr[15:0];
  end

  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      msip_ff       <= '0;
      mtimecmp_ff   <= 64'hFFFF_FFFF_FFFF_FFFF;  // Compare set to max → no IRQ at reset
      mtime_ff      <= '0;
      wr_active_ff  <= '0;
      wr_addr_ff    <= '0;
      wr_size_ff    <= axi_size_t'('0);
      rd_valid_ff   <= '0;
      rd_data_ff    <= '0;
      rd_id_ff      <= '0;
    end
    else begin
      // MTIME free-running counter
      mtime_ff <= mtime_ff + 1;

      // --- AW channel: latch address ---
      if (axi_mosi.awvalid && ~wr_active_ff) begin
        wr_active_ff <= 1'b1;
        wr_addr_ff   <= axi_mosi.awaddr;
        wr_size_ff   <= axi_mosi.awsize;
      end

      // --- W channel: perform write ---
      if (wr_active_ff && axi_mosi.wvalid) begin
        wr_active_ff <= 1'b0;
        case (wr_addr_ff[15:0])
          16'h0000: msip_ff[31:0]        <= axi_mosi.wdata[31:0];
          16'h4000: mtimecmp_ff[31:0]    <= axi_mosi.wdata[31:0];
          16'h4004: mtimecmp_ff[63:32]   <= axi_mosi.wdata[31:0];
          16'h4008: mtimecmp_ff          <= axi_mosi.wdata;  // 64-bit write
          16'hBFF8: mtime_ff[31:0]       <= axi_mosi.wdata[31:0];
          16'hBFFC: mtime_ff[63:32]      <= axi_mosi.wdata[31:0];
          default: ;
        endcase
      end

      // --- AR channel: latch and respond ---
      if (rd_valid_ff && axi_mosi.rready) begin
        rd_valid_ff <= 1'b0;
      end

      if (axi_mosi.arvalid && ~rd_valid_ff) begin
        rd_valid_ff <= 1'b1;
        rd_id_ff    <= axi_mosi.arid;
        case (axi_mosi.araddr[15:0])
          16'h0000: rd_data_ff <= {32'h0, msip_ff[31:0]};
          16'h4000: rd_data_ff <= {32'h0, mtimecmp_ff[31:0]};
          16'h4004: rd_data_ff <= {32'h0, mtimecmp_ff[63:32]};
          16'h4008: rd_data_ff <= mtimecmp_ff;
          16'hBFF8: rd_data_ff <= {32'h0, mtime_ff[31:0]};
          16'hBFFC: rd_data_ff <= {32'h0, mtime_ff[63:32]};
          16'hBFF0: rd_data_ff <= mtime_ff;  // 64-bit aligned mtime read
          default:  rd_data_ff <= '0;
        endcase
      end
    end
  end
endmodule
