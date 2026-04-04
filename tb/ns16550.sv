/**
 * ns16550.sv — minimal NS16550A UART simulation model
 *
 * Implements what OpenSBI/Linux need to detect and use the UART:
 *
 *   Offset  Register   Simulation behaviour
 *   0x0     THR/RBR    Write (DLAB=0): print byte to stdout; read: return 0x00
 *   0x1     IER/DLH    Write: ignored; read: return 0x00
 *   0x2     IIR/FCR    Write: ignored; read: return 0xC1 (FIFO enabled, no IRQ)
 *   0x3     LCR        Write: capture DLAB bit (bit 7); read: return 0x00
 *   0x4     MCR        Write: ignored; read: return 0x00
 *   0x5     LSR        Write: ignored; read: return 0x60 (THRE=1, TEMT=1)
 *   0x6     MSR        Write: ignored; read: return 0x00
 *   0x7     SCR        Write: store; read: return stored value (UART detection)
 *
 * Register offset is decoded from araddr[2:0] / awaddr[2:0].
 * No interrupts are generated (uart_irq_o is always 0).
 *
 * AXI protocol note: uses the same single-cycle AW→W→B pattern as axi_mem.sv.
 * bvalid pulses for one cycle on wlast; bready is assumed always 1 (matches LSU).
 */
module ns16550
  import amba_axi_pkg::*;
  import amba_ahb_pkg::*;
(
  input               clk,
  input               rst,
  input   s_axi_mosi_t  axi_mosi,
  output  s_axi_miso_t  axi_miso,
  output  logic         uart_irq_o
);

  // Write path state
  logic         axi_wr_vld_ff, next_axi_wr;
  logic [2:0]   wr_reg_ff,     next_wr_reg;
  logic         bvalid_ff;
  axi_tid_t     axi_wid_ff,    next_axi_wid;

  // Read path state
  logic         axi_rd_vld_ff, next_axi_rd;
  axi_data_t    rd_data_ff,    next_rd_data;
  axi_tid_t     axi_rid_ff,    next_axi_rid;

  // UART internal registers
  logic         dlab_ff,  next_dlab;   // LCR[7]: DLAB
  logic [7:0]   scr_ff,   next_scr;    // Scratch register

  assign uart_irq_o = 1'b0;

  // Extract the single byte that is being written (finds the active wstrb lane)
  function automatic logic [7:0] extract_byte(axi_data_t data, axi_wr_strb_t wstrb);
    logic [7:0] b;
    b = 8'h00;
    for (int i = 0; i < 8; i++)
      if (wstrb[i]) b = data[i*8+:8];
    return b;
  endfunction

  // Place an 8-bit value on the correct AXI byte lane for the given offset
  function automatic axi_data_t place_byte(logic [7:0] val, logic [2:0] lane);
    axi_data_t d;
    d = '0;
    d[lane*8+:8] = val;
    return d;
  endfunction

  // --------------------------------------------------------------------------
  // Write path (combinational)
  // --------------------------------------------------------------------------
  always_comb begin
    next_axi_wr  = axi_wr_vld_ff;
    next_wr_reg  = wr_reg_ff;
    next_axi_wid = axi_wid_ff;
    next_dlab    = dlab_ff;
    next_scr     = scr_ff;

    axi_miso.awready = 1'b1;
    axi_miso.wready  = 1'b1;
    axi_miso.bvalid  = bvalid_ff;
    axi_miso.bresp   = AXI_OKAY;
    axi_miso.bid     = axi_wid_ff;
    axi_miso.buser   = '0;

    // AW address phase: latch register offset
    if (axi_mosi.awvalid) begin
      next_axi_wr  = 1'b1;
      next_wr_reg  = axi_mosi.awaddr[2:0];
      next_axi_wid = axi_mosi.awid;
    end

    // W data phase: update internal registers
    if (axi_mosi.wvalid && axi_wr_vld_ff) begin
      begin
        automatic logic [7:0] wr_byte = extract_byte(axi_mosi.wdata, axi_mosi.wstrb);
        case (wr_reg_ff)
          3'd3: next_dlab = wr_byte[7]; // LCR DLAB
          3'd7: next_scr  = wr_byte;    // SCR
          default: ; // all other registers accepted silently
        endcase
      end
    end
  end

  // --------------------------------------------------------------------------
  // Read path (combinational)
  // --------------------------------------------------------------------------
  always_comb begin
    next_rd_data = rd_data_ff;
    next_axi_rd  = 1'b0;
    next_axi_rid = axi_rid_ff;

    axi_miso.arready = ~axi_rd_vld_ff | axi_mosi.rready;
    axi_miso.rvalid  = axi_rd_vld_ff;
    axi_miso.rlast   = axi_rd_vld_ff;
    axi_miso.rdata   = axi_rd_vld_ff ? rd_data_ff : '0;
    axi_miso.rresp   = AXI_OKAY;
    axi_miso.rid     = axi_rid_ff;
    axi_miso.ruser   = axi_user_req_t'('0);

    if (axi_rd_vld_ff)
      next_axi_rd = ~axi_mosi.rready;

    if (axi_mosi.arvalid && axi_miso.arready) begin
      next_axi_rd  = 1'b1;
      next_axi_rid = axi_mosi.arid;
      case (axi_mosi.araddr[2:0])
        3'd2:    next_rd_data = place_byte(8'hC1, axi_mosi.araddr[2:0]); // IIR: FIFO+no-irq
        3'd5:    next_rd_data = place_byte(8'h60, axi_mosi.araddr[2:0]); // LSR: TX ready
        3'd7:    next_rd_data = place_byte(scr_ff, axi_mosi.araddr[2:0]); // SCR
        default: next_rd_data = '0;
      endcase
    end
  end

  // --------------------------------------------------------------------------
  // Sequential
  // --------------------------------------------------------------------------
  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      axi_wr_vld_ff <= 1'b0;
      wr_reg_ff     <= 3'd0;
      bvalid_ff     <= 1'b0;
      axi_wid_ff    <= '0;
      axi_rd_vld_ff <= 1'b0;
      rd_data_ff    <= '0;
      axi_rid_ff    <= '0;
      dlab_ff       <= 1'b0;
      scr_ff        <= 8'h00;
    end
    else begin
      axi_wr_vld_ff <= next_axi_wr;
      wr_reg_ff     <= next_wr_reg;
      bvalid_ff     <= axi_mosi.wlast;  // pulse bvalid one cycle after W (bready assumed=1)
      axi_wid_ff    <= next_axi_wid;
      axi_rd_vld_ff <= next_axi_rd;
      rd_data_ff    <= next_rd_data;
      axi_rid_ff    <= next_axi_rid;
      dlab_ff       <= next_dlab;
      scr_ff        <= next_scr;
`ifdef SIMULATION
      // Print character written to THR (offset 0) when DLAB=0
      if (axi_mosi.wvalid && axi_wr_vld_ff &&
          (wr_reg_ff == 3'd0) && ~dlab_ff)
        $write("%c", extract_byte(axi_mosi.wdata, axi_mosi.wstrb));
`endif
    end
  end

endmodule
