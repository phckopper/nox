/**
 * File              : fetch.sv
 * License           : MIT license <Check LICENSE>
 * Author            : Anderson Ignacio da Silva (aignacio) <anderson@aignacio.com>
 * Date              : 16.10.2021
 * Last Modified Date: 26.03.2026
 *
 * RV64IC fetch unit with compressed instruction (C extension) support.
 *
 * Architecture:
 *   Address path → AXI bus → word buffer → alignment engine → L0 FIFO → decode
 *
 * The alignment engine extracts 16-bit or 32-bit instructions from 64-bit bus
 * words, handles 32-bit instructions that straddle 8-byte boundaries, and
 * expands compressed (16-bit) instructions to their 32-bit canonical form
 * via the rvc_expander module.
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
  output  pc_t          fetch_bp_predict_target_o, // BP predicted target
  output  logic         fetch_is_compressed_o,     // Instruction was compressed (16-bit)
  // Trap - Instruction access fault
  output  s_trap_info_t trap_info_o
);
  typedef logic [$clog2(L0_BUFFER_SIZE):0] buffer_t;

  // ================================================================
  // Signals
  // ================================================================

  // --- Address path ---
  cb_addr_t     fetch_addr_ff, next_fetch_addr;
  cb_addr_t     fetch_addr_buf_ff, next_fetch_addr_buf;  // saved addr for F_CLR
  logic         req_ff, next_req;
  logic         addr_ready;

  typedef enum logic [1:0] {
    F_STP,
    F_REQ,
    F_CLR
  } fetch_st_t;

  fetch_st_t    st_ff, next_st;

  // Outstanding transaction tracking
  logic [2:0]   ot_cnt_ff, next_ot_cnt;       // outstanding bus transactions
  logic [2:0]   discard_cnt_ff, next_discard;  // responses to discard

  // --- Word buffer (holds current 64-bit bus word) ---
  logic [63:0]  word_buf_ff;
  logic         word_valid_ff, next_word_valid;
  logic [1:0]   parcel_pos_ff, next_parcel_pos;  // current parcel (0-3)
  logic [63:0]  next_word_buf;
  logic         load_word;  // accept bus data into word buffer

  // --- Pending half (first 16 bits of straddling 32-bit instruction) ---
  logic [15:0]  pending_half_ff;
  logic         pending_valid_ff, next_pending_valid;
  logic [15:0]  next_pending_half;

  // --- Instruction PC ---
  pc_t          instr_pc_ff, next_instr_pc;

  // --- Alignment engine outputs ---
  logic         align_produce;     // alignment engine produces an instruction this cycle
  logic [31:0]  align_instr;       // expanded 32-bit instruction
  logic         align_compressed;  // was a compressed instruction
  logic         align_redirect;    // BP redirect from alignment engine
  pc_t          align_redirect_addr;

  // --- RVC expander ---
  logic [15:0]  rvc_instr_in;
  logic [31:0]  rvc_instr_out;
  logic         rvc_illegal;

  // --- Branch predictor ---
  logic         predict_taken;
  pc_t          predict_target;

  // --- Bus interface signals ---
  logic         data_valid;
  logic         data_ready;
  logic         valid_addr;

  // --- L0 FIFO ---
  logic         write_l0;
  logic         get_next_instr;
  logic         full_l0;
  buffer_t      l0_space;
  // L0 data: [97:34]=predict_target, [33]=bp_taken, [32]=is_compressed, [31:0]=instruction
  logic [97:0]  l0_data_in;
  logic [97:0]  l0_data_out;

  // --- Redirect logic ---
  logic         redirect;        // any redirect (jump or BP)
  pc_t          redirect_addr;
  logic         jump;
  logic         clear_l0;        // clear L0 FIFO
  logic         clear_align;     // clear alignment state
  logic         instr_access_fault;

  // ================================================================
  // Redirect priority: execute jump > BP redirect
  // ================================================================
  assign jump         = fetch_req_i;
  assign redirect     = jump || align_redirect;
  assign redirect_addr = jump ? fetch_addr_i : align_redirect_addr;
  assign clear_l0     = jump || (~fetch_start_i);
  assign clear_align  = redirect || (~fetch_start_i);

  // ================================================================
  // Address path — issues 8-byte-aligned bus requests
  // ================================================================
  always_comb begin : addr_path
    // Write channel — unused for fetch
    instr_cb_mosi_o.wr_addr       = cb_addr_t'('0);
    instr_cb_mosi_o.wr_size       = cb_size_t'('0);
    instr_cb_mosi_o.wr_addr_valid = 1'b0;
    instr_cb_mosi_o.wr_data       = cb_data_t'('0);
    instr_cb_mosi_o.wr_strobe     = cb_strb_t'('0);
    instr_cb_mosi_o.wr_data_valid = 1'b0;
    instr_cb_mosi_o.wr_resp_ready = 1'b0;

    data_valid       = instr_cb_miso_i.rd_valid;
    addr_ready       = instr_cb_miso_i.rd_addr_ready;
    valid_addr       = 1'b0;
    next_fetch_addr  = fetch_addr_ff;
    next_fetch_addr_buf = fetch_addr_buf_ff;
    next_st          = st_ff;

    // Outstanding counter: +1 on request accepted, -1 on response received
    next_ot_cnt = ot_cnt_ff
                  + {2'b0, req_ff && addr_ready}
                  - {2'b0, data_valid && data_ready};

    case (st_ff)
      F_STP: begin
        next_st = fetch_start_i ? F_REQ : F_STP;
        if (req_ff && ~addr_ready) begin
          valid_addr = 1'b1;  // keep driving to complete pending txn
        end
      end

      F_REQ: begin
        if (req_ff && ~addr_ready) begin
          valid_addr = 1'b1;  // keep driving until accepted
        end

        if (req_ff && addr_ready) begin
          // Request accepted — advance to next 8-byte word
          next_fetch_addr = fetch_addr_ff + 'd8;
        end

        // Issue next request if:
        // - Previous request completed or no pending request
        // - Outstanding count within limit
        // - Word buffer has space or alignment engine is draining
        if ((req_ff && addr_ready) || ~req_ff) begin
          if (next_ot_cnt < 3'd2) begin  // limit outstanding to 2
            valid_addr = ~full_l0;
          end
        end

        // --- Redirect handling ---
        if (redirect) begin
          next_fetch_addr     = {redirect_addr[63:3], 3'b000};  // 8-byte aligned
          next_fetch_addr_buf = fetch_addr_ff;

          if (req_ff && ~addr_ready) begin
            // Address beat still pending — enter F_CLR to drain it
            next_st = F_CLR;
          end else begin
            // Address channel idle or completed this cycle
            valid_addr = 1'b1;  // issue redirect target immediately
          end
        end

        if (~fetch_start_i) begin
          next_st = F_STP;
        end
      end

      F_CLR: begin
        // Keep driving old address until AXI accepts it
        if (req_ff && ~addr_ready) begin
          valid_addr = 1'b1;
        end else begin
          next_st    = F_REQ;
          valid_addr = 1'b1;  // immediately issue redirect target
        end
      end

      default: valid_addr = 1'b0;
    endcase

    next_req = valid_addr;
    instr_cb_mosi_o.rd_addr_valid = req_ff;
    instr_cb_mosi_o.rd_addr       = req_ff ? ((st_ff == F_CLR) ? fetch_addr_buf_ff : fetch_addr_ff) : '0;
    instr_cb_mosi_o.rd_size       = req_ff ? cb_size_t'(CB_DWORD) : cb_size_t'('0);
  end : addr_path

  // ================================================================
  // Discard counter — tracks stale in-flight responses after redirect
  // ================================================================
  always_comb begin : discard_logic
    next_discard = discard_cnt_ff;

    if (redirect) begin
      // Compute how many future AXI responses will be stale:
      //   ot_cnt_ff         — all currently in-flight
      //   - data_consumed   — the response arriving THIS cycle is consumed via
      //                       data_ready=1 (jump keeps load_word=0); it leaves
      //                       ot automatically and won't arrive again, so we
      //                       must not count it in next_discard
      //   + req_stale       — address accepted this cycle (req_ff && addr_ready)
      //                       OR address pending (req_ff && ~addr_ready): its
      //                       response will arrive in the future as stale, UNLESS
      //                       it happens to be the same 8-byte word as the redirect
      //                       target (in which case the response is valid and will
      //                       be loaded normally after the redirect).
      // req_ff is stale unless it is already pointing at the redirect target word
      next_discard = ot_cnt_ff
                     - {2'b0, data_valid && data_ready}
                     + {2'b0, req_ff && ~(addr_ready &&
                                          (fetch_addr_ff == {redirect_addr[63:3], 3'b0}))};
    end else if (data_valid && data_ready && discard_cnt_ff > 0) begin
      next_discard = discard_cnt_ff - 3'd1;
    end
  end : discard_logic

  // ================================================================
  // Data path — bus response → word buffer
  // ================================================================
  always_comb begin : data_path
    // Accept bus data when:
    // - We need to discard (always accept to complete AXI handshake), OR
    // - Word buffer is empty and we can process
    // Use `jump` (not `redirect`) to avoid combinational loop:
    // load_word → next_word_valid → align_redirect → redirect → load_word
    // BP redirects are handled by clear_align on the same cycle.
    data_ready = (st_ff == F_REQ || st_ff == F_CLR) ?
                 ((discard_cnt_ff > 0) || ~word_valid_ff || jump) :
                 1'b1;  // F_STP: always accept (drain)
    instr_cb_mosi_o.rd_ready = data_ready;

    // Load word buffer when: data valid, data ready, not discarding, word buffer empty
    load_word = data_valid && data_ready && (discard_cnt_ff == 0) && ~word_valid_ff && ~jump;
  end : data_path

  // ================================================================
  // RVC Expander instance
  // ================================================================
  rvc_expander u_rvc_expander (
    .instr_i  (rvc_instr_in),
    .instr_o  (rvc_instr_out),
    .illegal_o(rvc_illegal)
  );

  // ================================================================
  // Alignment engine — extracts instructions from word buffer
  // ================================================================
  /* verilator lint_off UNUSEDSIGNAL */
  logic [15:0] cur_parcel;
  logic [31:0] cur_32bit;

  always_comb begin : alignment_engine
    align_produce    = 1'b0;
    align_instr      = 32'h0;
    align_compressed = 1'b0;
    align_redirect   = 1'b0;
    align_redirect_addr = '0;

    next_word_valid  = word_valid_ff;
    next_word_buf    = word_buf_ff;
    next_parcel_pos  = parcel_pos_ff;
    next_pending_valid = pending_valid_ff;
    next_pending_half  = pending_half_ff;
    next_instr_pc    = instr_pc_ff;
    rvc_instr_in     = '0;

    // Load word buffer from bus
    if (load_word) begin
      next_word_buf   = instr_cb_miso_i.rd_data;
      next_word_valid = 1'b1;
    end

    // Precompute current parcel and 32-bit slice from word buffer
    cur_parcel = next_word_buf[next_parcel_pos * 16 +: 16];
    cur_32bit  = (next_parcel_pos <= 2'd2) ? next_word_buf[next_parcel_pos * 16 +: 32] : 32'h0;

    // Extract instruction when word buffer valid and L0 FIFO has space
    // Use ~jump (not ~redirect) to avoid combinational loop with align_redirect.
    // BP redirect is self-generated here; clear_align handles cleanup.
    if (next_word_valid && ~full_l0 && ~jump && fetch_start_i) begin

      if (next_pending_valid) begin
        // === Completing a straddling 32-bit instruction ===
        // The second half is at parcel 0 of the new word
        align_instr   = {cur_parcel, next_pending_half};
        align_produce = 1'b1;
        align_compressed = 1'b0;
        next_pending_valid = 1'b0;
        next_parcel_pos = next_parcel_pos + 2'd1;
        next_instr_pc   = instr_pc_ff + 'd4;  // full 32-bit instruction
      end else if (cur_parcel[1:0] != 2'b11) begin
        // === Compressed instruction (16-bit) ===
        rvc_instr_in     = cur_parcel;
        align_instr      = rvc_instr_out;
        align_produce    = 1'b1;
        align_compressed = 1'b1;
        next_parcel_pos  = next_parcel_pos + 2'd1;
        next_instr_pc    = instr_pc_ff + 'd2;
      end else if (next_parcel_pos <= 2'd2) begin
        // === Full 32-bit instruction, both halves in same word ===
        align_instr      = cur_32bit;
        align_produce    = 1'b1;
        align_compressed = 1'b0;
        next_parcel_pos  = next_parcel_pos + 2'd2;
        next_instr_pc    = instr_pc_ff + 'd4;
      end else begin
        // === Straddling: 32-bit instruction at parcel 3, needs next word ===
        next_pending_half  = cur_parcel;
        next_pending_valid = 1'b1;
        // Mark word consumed — need next word
        next_word_valid = 1'b0;
        // Don't advance instr_pc — instruction not complete yet
        // parcel_pos will be 0 when next word loads
        next_parcel_pos = 2'd0;
      end

      // Check if word buffer is fully consumed
      if (next_parcel_pos == 2'd0 && align_produce) begin
        // Wrapped around — all 4 parcels consumed (or 2 consumed from pos 2)
        next_word_valid = 1'b0;
      end
      // Also check for parcel_pos overflow: if we advanced past parcel 3
      // This happens when: pos was 3 and compressed (+1 → wraps to 0)
      //                 or: pos was 2 and full (+2 → wraps to 0)

      // BP redirect: if we produced an instruction and BP says taken
      if (align_produce && predict_taken && ~jump) begin
        align_redirect      = 1'b1;
        align_redirect_addr = predict_target;
        // Discard remaining parcels in this word
        next_word_valid     = 1'b0;
        next_pending_valid  = 1'b0;
        // Update instruction PC to predicted target
        next_instr_pc       = predict_target;
        next_parcel_pos     = predict_target[2:1];
      end
    end

    // Clear alignment state on redirect or stop
    if (clear_align) begin
      next_word_valid    = 1'b0;
      next_pending_valid = 1'b0;
      next_instr_pc      = redirect ? redirect_addr : instr_pc_ff;
      next_parcel_pos    = redirect ? redirect_addr[2:1] : 2'd0;
    end
  end : alignment_engine
  /* verilator lint_on UNUSEDSIGNAL */

  // ================================================================
  // L0 FIFO write
  // ================================================================
  assign write_l0 = align_produce && ~full_l0 && ~jump;
  assign l0_data_in = {predict_target, predict_taken && ~jump, align_compressed, align_instr};

  // ================================================================
  // L0 FIFO read — instruction output to decode
  // ================================================================
  always_comb begin : fetch_output
    fetch_valid_o  = 'b0;
    fetch_instr_o  = 'd0;
    get_next_instr = 'b0;
    fetch_bp_taken_o          = 1'b0;
    fetch_bp_predict_target_o = '0;
    fetch_is_compressed_o     = 1'b0;

    if (fetch_start_i && ~fetch_req_i && (l0_space != 'd0)) begin
      fetch_valid_o  = 'b1;
      fetch_instr_o  = instr_raw_t'(l0_data_out[31:0]);
      fetch_is_compressed_o     = l0_data_out[32];
      fetch_bp_taken_o          = l0_data_out[33];
      fetch_bp_predict_target_o = l0_data_out[97:34];
      get_next_instr = fetch_ready_i;
    end
  end : fetch_output

  // ================================================================
  // Trap — instruction access fault
  // ================================================================
  always_comb begin : trap_control
    trap_info_o = s_trap_info_t'('0);
    instr_access_fault = instr_cb_miso_i.rd_valid &&
                         (instr_cb_miso_i.rd_resp != CB_OKAY);

    if (instr_access_fault) begin
      trap_info_o.active  = 'b1;
      trap_info_o.pc_addr = instr_pc_ff;
      trap_info_o.mtval   = instr_pc_ff;
    end
  end : trap_control

  // ================================================================
  // Debug: trace alignment engine (TEMPORARY)
  // ================================================================

  // ================================================================
  // Registered state
  // ================================================================
  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      fetch_addr_ff     <= {fetch_start_addr_i[63:3], 3'b000};
      fetch_addr_buf_ff <= {fetch_start_addr_i[63:3], 3'b000};
      instr_pc_ff       <= fetch_start_addr_i;
      st_ff             <= F_STP;
      req_ff            <= 1'b0;
      ot_cnt_ff         <= 3'd0;
      discard_cnt_ff    <= 3'd0;
      word_buf_ff       <= 64'd0;
      word_valid_ff     <= 1'b0;
      parcel_pos_ff     <= fetch_start_addr_i[2:1];
      pending_half_ff   <= 16'd0;
      pending_valid_ff  <= 1'b0;
    end
    else begin
      fetch_addr_ff     <= next_fetch_addr;
      fetch_addr_buf_ff <= next_fetch_addr_buf;
      instr_pc_ff       <= next_instr_pc;
      st_ff             <= next_st;
      req_ff            <= next_req;
      ot_cnt_ff         <= next_ot_cnt;
      discard_cnt_ff    <= next_discard;
      word_buf_ff       <= load_word ? instr_cb_miso_i.rd_data : word_buf_ff;
      word_valid_ff     <= next_word_valid;
      parcel_pos_ff     <= next_parcel_pos;
      pending_half_ff   <= next_pending_half;
      pending_valid_ff  <= next_pending_valid;
    end
  end

  // ================================================================
  // L0 Instruction FIFO
  // Width=98: [97:34]=predict_target, [33]=bp_taken, [32]=is_compressed, [31:0]=instruction
  // ================================================================
  fifo_nox #(
    .SLOTS    (L0_BUFFER_SIZE),
    .WIDTH    (98)
  ) u_fifo_l0 (
    .clk      (clk),
    .rst      (rst),
    .clear_i  (clear_l0),
    .write_i  (write_l0),
    .read_i   (get_next_instr),
    .data_i   (l0_data_in),
    .data_o   (l0_data_out),
    .error_o  (),
    .full_o   (full_l0),
    .empty_o  (),
    .ocup_o   (l0_space)
  );

  // ================================================================
  // Branch predictor — queried per instruction from alignment engine
  // ================================================================
  branch_predictor u_branch_predictor (
    .clk               (clk),
    .rst               (rst),
    .fetch_pc_i        (instr_pc_ff),
    .predict_taken_o   (predict_taken),
    .predict_target_o  (predict_target),
    .update_i          (bp_update_i),
    .update_pc_i       (bp_update_pc_i),
    .update_taken_i    (bp_update_taken_i),
    .update_target_i   (bp_update_target_i),
    .is_call_i         (bp_is_call_i),
    .call_ret_addr_i   (bp_call_ret_addr_i),
    .is_return_i       (bp_is_return_i)
  );

`ifdef SIMULATION
  always_ff @(posedge clk) begin
    // AXI address phase
    if (req_ff && addr_ready)
      $display("[FETCH] @%0t AXI_ADDR_ACCEPT addr=%h st=%0d ot=%0d disc=%0d",
               $time, instr_cb_mosi_o.rd_addr, st_ff, ot_cnt_ff, discard_cnt_ff);
    // AXI data (response) phase
    if (data_valid && data_ready)
      $display("[FETCH] @%0t AXI_DATA rsp=%0d disc=%0d load=%0b wbuf_valid=%0b",
               $time, instr_cb_miso_i.rd_resp, discard_cnt_ff, load_word, word_valid_ff);
    // Instruction produced into L0 FIFO
    if (write_l0)
      $display("[FETCH] @%0t L0_WRITE instr=%h pc=%h compressed=%0b",
               $time, align_instr, instr_pc_ff, align_compressed);
    // Redirect
    if (redirect)
      $display("[FETCH] @%0t REDIRECT to=%h jump=%0b st=%0d req=%0b ot=%0d disc=%0d",
               $time, redirect_addr, jump, st_ff, req_ff, ot_cnt_ff, discard_cnt_ff);
  end
`endif

`ifdef COCOTB_SIM
  `ifdef XCELIUM
    `DUMP_WAVES_XCELIUM
  `endif
`endif
endmodule
