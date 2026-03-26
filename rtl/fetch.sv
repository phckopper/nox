/**
* File              : fetch.sv
 * License           : MIT license <Check LICENSE>
 * Author            : Anderson Ignacio da Silva (aignacio) <anderson@aignacio.com>
 * Date              : 16.10.2021
 * Last Modified Date: 03.07.2022
 */
module fetch
  import amba_axi_pkg::*;
  import amba_ahb_pkg::*;
  import nox_utils_pkg::*;
#(
  parameter int SUPPORT_DEBUG  = 1,
  parameter int L0_BUFFER_SIZE = 2  // Max instrs locally stored
)(
  input                 clk,
  input                 rst,
  // Core bus fetch I/F
  output  s_cb_mosi_t   instr_cb_mosi_o,
  input   s_cb_miso_t   instr_cb_miso_i,
  // Start I/F
  input                 fetch_start_i,
  input   pc_t          fetch_start_addr_i,
  // From EXEC stg
  input                 fetch_req_i,
  input   pc_t          fetch_addr_i,
  // Branch predictor update from execute
  input                 bp_update_i,
  input   pc_t          bp_update_pc_i,
  input   logic         bp_update_taken_i,
  input   pc_t          bp_update_target_i,
  // P2: RAS call/return signals from execute → branch_predictor
  input   logic         bp_is_call_i,
  input   pc_t          bp_call_ret_addr_i,
  input   logic         bp_is_return_i,
  // To DEC I/F
  output  valid_t       fetch_valid_o,
  input   ready_t       fetch_ready_i,
  output  instr_raw_t   fetch_instr_o,
  output  logic         fetch_bp_taken_o,          // BP predicted taken
  output  pc_t          fetch_bp_predict_target_o, // P2: BP predicted target
  // Trap - Instruction access fault
  output  s_trap_info_t trap_info_o
);
  typedef logic [$clog2(L0_BUFFER_SIZE):0] buffer_t;

  logic         get_next_instr;
  logic         write_instr;
  buffer_t      buffer_space;
  instr_raw_t   instr_buffer;  // driven by assign from l0_data_out[31:0]
  logic         full_fifo;
  logic         data_valid;
  logic         data_ready;
  logic         jump;
  logic         clear_fifo;
  logic         valid_addr;
  logic         read_ot_fifo;
  logic         ot_empty;

  cb_addr_t     pc_addr_ff, next_pc_addr;
  cb_addr_t     pc_buff_ff, next_pc_buff;
  logic         req_ff, next_req;
  logic         valid_txn_i;
  logic         valid_txn_o;  // driven by assign from ot_data_out[0]
  logic         addr_ready;
  logic         instr_access_fault;

  logic         predict_taken;
  pc_t          predict_target;

  // OT FIFO: [66:3]=predict_target, [2]=pc_bit2, [1]=bp_taken, [0]=valid_txn  (67 bits)
  logic [66:0]  ot_data_out;
  logic         bp_taken_txn;   // bp_taken  propagated from OT FIFO to L0 FIFO
  pc_t          bp_target_txn;  // predict_target propagated from OT FIFO to L0 FIFO
  logic         pc_bit2_txn;    // PC[2] for 32-bit lane selection from 64-bit bus

  // L0 FIFO: [96:33]=predict_target, [32]=bp_taken, [31:0]=instruction  (97 bits)
  logic [96:0]  l0_data_out;

  typedef enum logic [1:0] {
    F_STP,
    F_REQ,
    F_CLR
  } fetch_st_t;

  fetch_st_t st_ff, next_st;
  buffer_t   ot_cnt_ff, next_ot;

  always_comb begin : addr_chn_req
    instr_cb_mosi_o.wr_addr       = cb_addr_t'('0);
    instr_cb_mosi_o.wr_size       = cb_size_t'('0);
    instr_cb_mosi_o.wr_addr_valid = 1'b0;
    instr_cb_mosi_o.wr_data       = cb_data_t'('0);
    instr_cb_mosi_o.wr_strobe     = cb_strb_t'('0);
    instr_cb_mosi_o.wr_data_valid = 1'b0;
    instr_cb_mosi_o.wr_resp_ready = 1'b0;

    data_valid   = instr_cb_miso_i.rd_valid;
    addr_ready   = instr_cb_miso_i.rd_addr_ready;
    clear_fifo   = (fetch_req_i || (~fetch_start_i));
    valid_addr   = 1'b0;
    next_pc_addr = pc_addr_ff;
    next_pc_buff = pc_buff_ff;
    next_st      = st_ff;
    jump         = fetch_req_i;
    valid_txn_i  = 1'b0;

    next_ot = ot_cnt_ff + buffer_t'(req_ff && addr_ready) - buffer_t'(data_valid && data_ready);

    case (st_ff)
      F_STP: begin
        next_st = fetch_start_i ? F_REQ : F_STP;

        if (req_ff && ~addr_ready) begin
          valid_addr  = 1'b1; // Keep driving high to complete txn
          valid_txn_i = 1'b0;
        end
      end
      F_REQ: begin
        if (req_ff && ~addr_ready) begin
          valid_addr  = 1'b1; // Keep driving high to complete txn
          valid_txn_i = 1'b1;
        end

        if (req_ff && addr_ready) begin
          valid_txn_i = 1'b1;
          // If the predictor says this fetch address is a taken branch,
          // redirect to the predicted target instead of falling through.
          // The confirmed-jump redirect (fetch_req_i) takes priority via
          // the jump block below.
          if (predict_taken && ~jump) begin
            next_pc_addr = predict_target;
          end else begin
            next_pc_addr = pc_addr_ff + 'd4;
          end
        end

        if ((req_ff && addr_ready) || ~req_ff) begin
          // Next txn — also gate if FIFO is about to fill while decode stalls
          if (next_ot < (buffer_t'(L0_BUFFER_SIZE))) begin
            valid_addr  = ~full_fifo && ~(write_instr && (buffer_space == buffer_t'(L0_BUFFER_SIZE-1)) && ~get_next_instr);
          end
        end

        if (jump) begin
          next_pc_addr = fetch_addr_i;
          next_pc_buff = pc_addr_ff;
          valid_txn_i  = 1'b0;

          if (req_ff && ~addr_ready) begin
            // P5: Only enter F_CLR when an address beat is still pending —
            // must keep driving the address until AXI acknowledges it.
            next_st    = F_CLR;
          end else begin
            // P5: Address channel is idle or completes this cycle.
            // Any in-flight data beats drain naturally: clear_fifo flushed
            // the OT FIFO so returning beats have no OT entry and are
            // discarded without stalling.  Issue the jump target now,
            // saving one redirect bubble vs. waiting in F_CLR.
            valid_addr = 1'b1;
          end
        end

        if (~fetch_start_i) begin
          next_st = F_STP;
        end
      end
      F_CLR: begin
        // P5: Reached only when the address channel was still pending at
        // jump time.  Keep driving the pre-jump address (pc_buff_ff, via
        // the rd_addr mux) until AXI accepts it (valid_txn_i=0 marks it
        // as discard).  Once accepted, immediately issue the jump target —
        // no need to wait for in-flight data since the OT FIFO was cleared
        // and returning beats are silently discarded.
        valid_txn_i = 1'b0;
        if (req_ff && ~addr_ready) begin
          valid_addr  = 1'b1;  // keep driving old address until accepted
        end else begin
          next_st    = F_REQ;
          valid_addr = 1'b1;   // immediately issue jump target
        end
      end
      default: valid_addr = 1'b0;
    endcase

    next_req = valid_addr;
    instr_cb_mosi_o.rd_addr_valid = req_ff;
    instr_cb_mosi_o.rd_addr       = req_ff ? ((st_ff == F_CLR) ? pc_buff_ff : pc_addr_ff) : '0;
    instr_cb_mosi_o.rd_size       = req_ff ? cb_size_t'(CB_DWORD) : cb_size_t'('0);
  end : addr_chn_req

  // Decode OT FIFO output: bit[0]=valid_txn, bit[1]=bp_taken, bit[2]=pc_bit2, [66:3]=predict_target
  assign valid_txn_o   = ot_data_out[0];
  assign bp_taken_txn  = ot_data_out[1];
  assign pc_bit2_txn   = ot_data_out[2];
  assign bp_target_txn = ot_data_out[66:3];
  // Decode L0 FIFO output: bits[31:0]=instruction, bit[32]=bp_taken, [96:33]=predict_target
  assign instr_buffer              = instr_raw_t'(l0_data_out[31:0]);
  assign fetch_bp_taken_o          = l0_data_out[32];
  assign fetch_bp_predict_target_o = l0_data_out[96:33];

  always_comb begin : rd_chn
    write_instr = 'b0;
    data_ready = (st_ff == F_REQ) ? (~full_fifo || fetch_req_i) : 'b1;
    instr_cb_mosi_o.rd_ready = data_ready;
    read_ot_fifo = ot_empty ? 1'b0 : (data_valid && data_ready);
    // Only write in the FIFO if
    // 1 - When there's no jump req
    // 2 - When there's vld data phase (opposite means discarding)
    // 3 - There valid data in the bus
    // 4 - We don't have a full fifo
    if (~fetch_req_i && ~ot_empty && valid_txn_o && data_valid && ~full_fifo) begin
      write_instr = 'b1;
    end
  end : rd_chn

  always_comb begin : trap_control
    trap_info_o = s_trap_info_t'('0);
    instr_access_fault = instr_cb_miso_i.rd_valid &&
                         (instr_cb_miso_i.rd_resp != CB_OKAY);

    if (instr_access_fault) begin
      trap_info_o.active  = 'b1;
      trap_info_o.pc_addr = pc_addr_ff;
      trap_info_o.mtval   = pc_addr_ff;
    end
  end : trap_control

  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      pc_addr_ff   <= cb_addr_t'(fetch_start_addr_i);
      pc_buff_ff   <= cb_addr_t'(fetch_start_addr_i);
      st_ff        <= F_STP;
      req_ff       <= 1'b0;
      ot_cnt_ff    <= buffer_t'('0);
    end
    else begin
      pc_addr_ff   <= next_pc_addr;
      pc_buff_ff   <= next_pc_buff;
      st_ff        <= next_st;
      req_ff       <= next_req;
      ot_cnt_ff    <= next_ot;
    end
  end

  always_comb begin : fetch_proc_if
    fetch_valid_o = 'b0;
    fetch_instr_o = 'd0;
    get_next_instr = 'b0;

    // We assert valid instr if:
    // 1 - There's no req to fetch a new addr
    // 2 - There's data inside the FIFO
    if (fetch_start_i && ~fetch_req_i && (buffer_space != 'd0)) begin
      // We request to read the FIFO if:
      // 3 - The next stage is ready to receive
      fetch_valid_o  = 'b1;
      fetch_instr_o  = instr_buffer;
      get_next_instr = fetch_ready_i;
    end
  end : fetch_proc_if

  // OT tracking FIFO: WIDTH=67, [66:3]=predict_target, [2]=pc_bit2, [1]=bp_taken, [0]=valid_txn.
  // predict_taken and predict_target are captured at address-phase so they travel
  // with the transaction and are forwarded into the L0 FIFO on the data phase.
  fifo_nox #(
    .SLOTS    (L0_BUFFER_SIZE),
    .WIDTH    (67)
  ) u_fifo_ot_rd (
    .clk      (clk),
    .rst      (rst),
    .clear_i  (clear_fifo),
    .write_i  ((req_ff && addr_ready)),
    .read_i   (read_ot_fifo),
    .data_i   ({predict_target, pc_addr_ff[2], predict_taken && ~jump, valid_txn_i}),
    .data_o   (ot_data_out),
    .error_o  (),
    .full_o   (),
    .empty_o  (ot_empty),
    .ocup_o   ()
  );

  // Select correct 32-bit instruction lane from 64-bit read data based on PC[2]
  // pc_bit2_txn is captured at address-phase and travels through the OT FIFO
  // so it matches the returning data beat, not the current fetch address.
  logic [31:0] instr_from_bus;
  assign instr_from_bus = pc_bit2_txn ? instr_cb_miso_i.rd_data[63:32]
                                      : instr_cb_miso_i.rd_data[31:0];

  // Instruction FIFO: WIDTH=97, [96:33]=predict_target, [32]=bp_taken, [31:0]=instruction.
  fifo_nox #(
    .SLOTS    (L0_BUFFER_SIZE),
    .WIDTH    (97)
  ) u_fifo_l0 (
    .clk      (clk),
    .rst      (rst),
    .clear_i  (clear_fifo),
    .write_i  (write_instr),
    .read_i   (get_next_instr),
    .data_i   ({bp_target_txn, bp_taken_txn, instr_from_bus}),
    .data_o   (l0_data_out),
    .error_o  (),
    .full_o   (full_fifo),
    .empty_o  (),
    .ocup_o   (buffer_space)
  );

  branch_predictor u_branch_predictor (
    .clk               (clk),
    .rst               (rst),
    // Query: use current fetch address so the prediction is ready
    // combinationally when computing next_pc_addr.
    .fetch_pc_i        (pc_addr_ff),
    .predict_taken_o   (predict_taken),
    .predict_target_o  (predict_target),
    // Update from execute on every resolved branch/jump
    .update_i          (bp_update_i),
    .update_pc_i       (bp_update_pc_i),
    .update_taken_i    (bp_update_taken_i),
    .update_target_i   (bp_update_target_i),
    // P2: RAS push/pop control from execute
    .is_call_i          (bp_is_call_i),
    .call_ret_addr_i    (bp_call_ret_addr_i),
    .is_return_i        (bp_is_return_i)
  );

`ifdef COCOTB_SIM
  `ifdef XCELIUM
    `DUMP_WAVES_XCELIUM
  `endif
`endif
endmodule
