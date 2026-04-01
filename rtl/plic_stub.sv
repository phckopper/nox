/**
 * File   : plic_stub.sv
 * Date   : 2026-03-31
 *
 * RISC-V PLIC stub — AXI4 slave, 1 interrupt source
 *
 * Memory map (offset from base address):
 *   0x000004 : source 1 priority  [2:0]
 *   0x001000 : pending[0]         [31:0]  — bit[1] = source 1 pending (read-only)
 *   0x002000 : enable ctx 0 M     [31:0]  — bit[1] = enable source 1 for M-mode
 *   0x002080 : enable ctx 1 S     [31:0]  — bit[1] = enable source 1 for S-mode
 *   0x200000 : threshold ctx 0 M  [2:0]
 *   0x200004 : claim/complete ctx 0 M — read=claim (returns source ID), write=complete
 *   0x201000 : threshold ctx 1 S  [2:0]
 *   0x201004 : claim/complete ctx 1 S
 *
 * m_ext_irq = pending[1] && enable_m[1] && priority[1] > threshold_m
 * s_ext_irq = pending[1] && enable_s[1] && priority[1] > threshold_s
 *
 * The external interrupt input (ext_src_i) sets pending[1].
 * Pending is cleared by a claim read from any context.
 */
module plic_stub
  import amba_axi_pkg::*;
  import nox_utils_pkg::*;
#(
  parameter logic [63:0] BASE_ADDR = 64'h0C00_0000
)(
  input               clk,
  input               rst,
  input               ext_src_i,    // External interrupt source 1
  input  s_axi_mosi_t axi_mosi,
  output s_axi_miso_t axi_miso,
  output logic        m_ext_irq,
  output logic        s_ext_irq
);
  // Internal registers
  logic [2:0]  priority_ff;    // Source 1 priority
  logic        pending_ff;     // Source 1 pending
  logic        enable_m_ff;    // Enable source 1 for M-mode context
  logic        enable_s_ff;    // Enable source 1 for S-mode context
  logic [2:0]  threshold_m_ff; // Priority threshold for M-mode context
  logic [2:0]  threshold_s_ff; // Priority threshold for S-mode context

  // AXI state
  logic        wr_active_ff;
  axi_addr_t   wr_addr_ff;
  logic        rd_valid_ff;
  axi_data_t   rd_data_ff;
  axi_tid_t    rd_id_ff;

  // Interrupt output combinational logic
  logic src1_above_m, src1_above_s;
  assign src1_above_m = (priority_ff > threshold_m_ff);
  assign src1_above_s = (priority_ff > threshold_s_ff);
  assign m_ext_irq = pending_ff && enable_m_ff && src1_above_m;
  assign s_ext_irq = pending_ff && enable_s_ff && src1_above_s;

  // ---- Write path ----
  always_comb begin
    axi_miso.awready = ~wr_active_ff;
    axi_miso.wready  = wr_active_ff;
    axi_miso.bid     = axi_tid_t'('0);
    axi_miso.bresp   = AXI_OKAY;
    axi_miso.buser   = '0;
    axi_miso.bvalid  = wr_active_ff & axi_mosi.wvalid;
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
  end

  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      priority_ff    <= 3'd1;  // Default priority 1
      pending_ff     <= '0;
      enable_m_ff    <= '0;
      enable_s_ff    <= '0;
      threshold_m_ff <= '0;
      threshold_s_ff <= '0;
      wr_active_ff   <= '0;
      wr_addr_ff     <= '0;
      rd_valid_ff    <= '0;
      rd_data_ff     <= '0;
      rd_id_ff       <= '0;
    end
    else begin
      // Latch external source into pending
      if (ext_src_i)
        pending_ff <= 1'b1;

      // --- AW channel ---
      if (axi_mosi.awvalid && ~wr_active_ff) begin
        wr_active_ff <= 1'b1;
        wr_addr_ff   <= axi_mosi.awaddr;
      end

      // --- W channel ---
      if (wr_active_ff && axi_mosi.wvalid) begin
        wr_active_ff <= 1'b0;
        case (wr_addr_ff[20:0])
          21'h000004: priority_ff    <= axi_mosi.wdata[wr_addr_ff[2:0]*8 +: 3];
          21'h002000: enable_m_ff    <= axi_mosi.wdata[1];
          21'h002080: enable_s_ff    <= axi_mosi.wdata[1];
          21'h200000: threshold_m_ff <= axi_mosi.wdata[2:0];
          // Complete for M-mode context: clear pending
          21'h200004: pending_ff     <= 1'b0;
          21'h201000: threshold_s_ff <= axi_mosi.wdata[2:0];
          // Complete for S-mode context: clear pending
          21'h201004: pending_ff     <= 1'b0;
          default: ;
        endcase
      end

      // --- AR channel ---
      if (rd_valid_ff && axi_mosi.rready) begin
        rd_valid_ff <= 1'b0;
      end

      if (axi_mosi.arvalid && ~rd_valid_ff) begin
        rd_valid_ff <= 1'b1;
        rd_id_ff    <= axi_mosi.arid;
        case (axi_mosi.araddr[20:0])
          21'h000004: rd_data_ff <= {61'h0, priority_ff} << (axi_mosi.araddr[2:0] * 8);
          21'h001000: rd_data_ff <= {62'h0, pending_ff, 1'b0};  // bit[1] = source 1
          21'h002000: rd_data_ff <= {62'h0, enable_m_ff, 1'b0};
          21'h002080: rd_data_ff <= {62'h0, enable_s_ff, 1'b0};
          21'h200000: rd_data_ff <= {61'h0, threshold_m_ff};
          // Claim for M-mode: return source ID (1) if pending, else 0
          21'h200004: begin
            rd_data_ff <= pending_ff ? 64'h1 : 64'h0;
            pending_ff <= 1'b0;  // Claim clears pending
          end
          21'h201000: rd_data_ff <= {61'h0, threshold_s_ff};
          // Claim for S-mode: return source ID (1) if pending, else 0
          21'h201004: begin
            rd_data_ff <= pending_ff ? 64'h1 : 64'h0;
            pending_ff <= 1'b0;  // Claim clears pending
          end
          default: rd_data_ff <= '0;
        endcase
      end
    end
  end
endmodule
