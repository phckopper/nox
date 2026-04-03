/**
 * File              : nox.sv
 * License           : MIT license <Check LICENSE>
 * Author            : Anderson Ignacio da Silva (aignacio) <anderson@aignacio.com>
 * Date              : 16.10.2021
 * Last Modified Date: 2026-04-01 (Phase 2C: Sv39 MMU inserted between pipeline and buses)
 */
module nox
  import amba_axi_pkg::*;
  import amba_ahb_pkg::*;
  import nox_utils_pkg::*;
  import mmu_pkg::*;
#(
  parameter int SUPPORT_DEBUG         = 1,
  parameter int MTVEC_DEFAULT_VAL     = 'h1000, // 4KB
  parameter int L0_BUFFER_SIZE        = 4,      // Max instrs locally stored
  parameter int TRAP_ON_MIS_LSU_ADDR  = 1,      // Trap in case of misaligned addr on LSU
  parameter int TRAP_ON_LSU_ERROR     = 1,      // Trap in case of LSU error
  parameter int FETCH_IF_ID           = 0,
  parameter int LSU_IF_ID             = 1,
  parameter int unsigned M_HART_ID = `M_HART_ID
)(
  input                 clk,
  input                 arst,
  // Boot ctrl
  input                 start_fetch_i,
  input   pc_t          start_addr_i,
  // IRQs
  input   s_irq_t       irq_i,
`ifdef TARGET_IF_AXI
  // Read-only interface
  output  s_axi_mosi_t  instr_axi_mosi_o,
  input   s_axi_miso_t  instr_axi_miso_i,
  // Load-Store interface
  output  s_axi_mosi_t  lsu_axi_mosi_o,
  input   s_axi_miso_t  lsu_axi_miso_i
`else
  // Read-only interface
  output  s_ahb_mosi_t  instr_ahb_mosi_o,
  input   s_ahb_miso_t  instr_ahb_miso_i,
  // Load-Store interface
  output  s_ahb_mosi_t  lsu_ahb_mosi_o,
  input   s_ahb_miso_t  lsu_ahb_miso_i
`endif
);
  logic rst;

  // Bus signals between cb_to_axi/ahb and MMU
  s_cb_mosi_t       instr_cb_mosi, lsu_cb_mosi;
  s_cb_miso_t       instr_cb_miso, lsu_cb_miso;

  // Raw bus signals from fetch/LSU (VA, before MMU translation)
  s_cb_mosi_t       fetch_raw_mosi, lsu_raw_mosi;
  s_cb_miso_t       fetch_raw_miso, lsu_raw_miso;

  valid_t           fetch_valid;
  ready_t           fetch_ready;
  instr_raw_t       fetch_instr;
  logic             fetch_bp_taken;
  logic             fetch_is_compressed;
  s_id_ex_t         id_ex;
  rdata_t           rs1_data;
  rdata_t           rs2_data;
  valid_t           id_valid;
  ready_t           id_ready;
  s_ex_mem_wb_t     ex_mem_wb;
  s_lsu_op_t        lsu_op;
  logic             lsu_bp;
  rdata_t           lsu_rd_data;
  s_lsu_op_t        lsu_op_wb;
  logic             fetch_req;
  pc_t              fetch_addr;
  logic             decode_pc_update;
  pc_t              decode_pc_update_addr;
  logic             bp_update;
  pc_t              bp_update_pc;
  logic             bp_update_taken;
  pc_t              bp_update_target;
  logic             bp_is_call;
  pc_t              bp_call_ret_addr;
  logic             bp_is_return;
  pc_t              fetch_bp_predict_target;
  s_wb_t            wb_dec;
  logic             lsu_bp_data;
  s_trap_info_t     fetch_trap;
  s_trap_lsu_info_t lsu_trap;
  rdata_t           wb_fwd_load;
  logic             lock_wb;
  pc_t              lsu_pc;
  pc_t              lsu_ap_pc;
  logic [1:0]       priv_mode;

  // MMU control signals
  logic [63:0]      satp;
  logic             sum, mxr;
  mmu_fault_t       mmu_fault;
  logic             mmu_fault_valid;
  logic             kill_lsu;
  logic             sfence_vma;
  logic [63:0]      sfence_vaddr, sfence_asid;
  logic             sfence_rs1_x0, sfence_rs2_x0;

  // Register sfence signals by 1 cycle to break the combinational feedback
  // path through the MMU (sfence_vma_o → MMU → lsu_raw_miso → lsu_bp →
  // execute → sfence_vma_o). Functionally correct: the pipeline flush from
  // fetch_req_o fires the same cycle as sfence.vma, and TLB invalidation
  // on the following edge is safe because no new instructions are in flight.
  logic             sfence_vma_r;
  logic [63:0]      sfence_vaddr_r, sfence_asid_r;
  logic             sfence_rs1_x0_r, sfence_rs2_x0_r;
  `CLK_PROC(clk, rst) begin
    `RST_TYPE(rst) begin
      sfence_vma_r     <= 1'b0;
      sfence_vaddr_r   <= '0;
      sfence_asid_r    <= '0;
      sfence_rs1_x0_r  <= 1'b0;
      sfence_rs2_x0_r  <= 1'b0;
    end
    else begin
      sfence_vma_r     <= sfence_vma;
      sfence_vaddr_r   <= sfence_vaddr;
      sfence_asid_r    <= sfence_asid;
      sfence_rs1_x0_r  <= sfence_rs1_x0;
      sfence_rs2_x0_r  <= sfence_rs2_x0;
    end
  end

`ifdef TARGET_FPGA
  reset_sync#(
    .RST_MODE(`RST_MODE)
  ) u_reset_sync (
    .arst_i (arst),
    .clk    (clk),
    .rst_o  (rst)
  );
`else
  assign rst = arst;
`endif

`ifdef TARGET_IF_AXI
  cb_to_axi #(
    .AXI_ID                (FETCH_IF_ID)
  ) u_instr_cb_to_axi(
    .clk                   (clk),
    .cb_mosi_i             (instr_cb_mosi),
    .cb_miso_o             (instr_cb_miso),
    .axi_mosi_o            (instr_axi_mosi_o),
    .axi_miso_i            (instr_axi_miso_i)
  );

  cb_to_axi  #(
    .AXI_ID                (LSU_IF_ID)
  ) u_lsu_cb_to_axi(
    .clk                   (clk),
    .cb_mosi_i             (lsu_cb_mosi),
    .cb_miso_o             (lsu_cb_miso),
    .axi_mosi_o            (lsu_axi_mosi_o),
    .axi_miso_i            (lsu_axi_miso_i)
  );
`else
  cb_to_ahb u_instr_cb_to_ahb(
    .cb_mosi_i             (instr_cb_mosi),
    .cb_miso_o             (instr_cb_miso),
    .ahb_mosi_o            (instr_ahb_mosi_o),
    .ahb_miso_i            (instr_ahb_miso_i)
  );

  cb_to_ahb u_lsu_cb_to_ahb(
    .cb_mosi_i             (lsu_cb_mosi),
    .cb_miso_o             (lsu_cb_miso),
    .ahb_mosi_o            (lsu_ahb_mosi_o),
    .ahb_miso_i            (lsu_ahb_miso_i)
  );
`endif

  // ---- MMU: Sv39 address translation shim ----
  mmu u_mmu (
    .clk              (clk),
    .rst              (rst),
    // Control
    .satp_i           (satp),
    .priv_i           (priv_mode),
    .mxr_i            (mxr),
    .sum_i            (sum),
    // SFENCE.VMA (registered to break combinational loop through MMU)
    .sfence_i         (sfence_vma_r),
    .sfence_vaddr_i   (sfence_vaddr_r),
    .sfence_asid_i    (sfence_asid_r),
    .sfence_rs1_x0_i  (sfence_rs1_x0_r),
    .sfence_rs2_x0_i  (sfence_rs2_x0_r),
    // Fetch path
    .fetch_mosi_i     (fetch_raw_mosi),
    .fetch_miso_o     (fetch_raw_miso),
    .instr_mosi_o     (instr_cb_mosi),
    .instr_miso_i     (instr_cb_miso),
    // Data path
    .lsu_mosi_i       (lsu_raw_mosi),
    .lsu_miso_o       (lsu_raw_miso),
    .data_mosi_o      (lsu_cb_mosi),
    .data_miso_i      (lsu_cb_miso),
    // Kill LSU + page fault
    .kill_lsu_o       (kill_lsu),
    .mmu_fault_o      (mmu_fault),
    .mmu_fault_valid_o (mmu_fault_valid)
  );

  fetch #(
    .SUPPORT_DEBUG         (SUPPORT_DEBUG),
    .L0_BUFFER_SIZE        (L0_BUFFER_SIZE)
  ) u_fetch (
    .clk                   (clk),
    .rst                   (rst),
    // Core bus fetch I/F (VA; MMU translates to PA)
    .instr_cb_mosi_o       (fetch_raw_mosi),
    .instr_cb_miso_i       (fetch_raw_miso),
    // Start I/F
    .fetch_start_i         (start_fetch_i),
    .fetch_start_addr_i    (start_addr_i),
    // From EXEC stage
    .fetch_req_i           (fetch_req),
    .fetch_addr_i          (fetch_addr),
    // Branch predictor update
    .bp_update_i           (bp_update),
    .bp_update_pc_i        (bp_update_pc),
    .bp_update_taken_i     (bp_update_taken),
    .bp_update_target_i    (bp_update_target),
    // P2: RAS call/return signals from execute
    .bp_is_call_i          (bp_is_call),
    .bp_call_ret_addr_i    (bp_call_ret_addr),
    .bp_is_return_i        (bp_is_return),
    // To DEC I/F
    .fetch_valid_o         (fetch_valid),
    .fetch_ready_i         (fetch_ready),
    .fetch_instr_o         (fetch_instr),
    .fetch_bp_taken_o      (fetch_bp_taken),
    .fetch_bp_predict_target_o (fetch_bp_predict_target),
    .fetch_is_compressed_o (fetch_is_compressed),
    // Trap error fetching
    .trap_info_o           (fetch_trap)
  );

  decode #(
    .SUPPORT_DEBUG         (SUPPORT_DEBUG)
  ) u_decode (
    .clk                   (clk),
    .rst                   (rst),
    // Control signals
    .jump_i                (fetch_req),
    .pc_jump_i             (fetch_addr),
    .pc_reset_i            (start_addr_i),
    // From FETCH stg I/F
    .fetch_valid_i         (fetch_valid),
    .fetch_ready_o         (fetch_ready),
    .fetch_instr_i         (fetch_instr),
    .fetch_bp_taken_i          (fetch_bp_taken),
    .fetch_bp_predict_target_i (fetch_bp_predict_target),
    .fetch_is_compressed_i (fetch_is_compressed),
    // From MEM/WB stg I/F
    .wb_dec_i              (wb_dec),
    // To EXEC stg I/F
    .id_ex_o               (id_ex),
    .rs1_data_o            (rs1_data),
    .rs2_data_o            (rs2_data),
    .id_valid_o            (id_valid),
    .id_ready_i            (id_ready),
    .decode_pc_update_i    (decode_pc_update),
    .decode_pc_update_addr_i (decode_pc_update_addr)
  );

  execute #(
    .SUPPORT_DEBUG         (SUPPORT_DEBUG),
    .MTVEC_DEFAULT_VAL     (MTVEC_DEFAULT_VAL),
    .M_HART_ID             (M_HART_ID)
  ) u_execute (
    .clk                   (clk),
    .rst                   (rst),
    // Control signals
    .wb_value_i            (wb_dec.rd_data),
    .wb_load_i             (wb_fwd_load),
    .lock_wb_i             (lock_wb),
    // From DEC stg I/F
    .id_ex_i               (id_ex),
    .rs1_data_i            (rs1_data),
    .rs2_data_i            (rs2_data),
    .id_valid_i            (id_valid),
    .id_ready_o            (id_ready),
    // To MEM/WB stg I/F
    .ex_mem_wb_o           (ex_mem_wb),
    // To/From LSU
    .lsu_o                 (lsu_op),
    .lsu_bp_i              (lsu_bp),
    .lsu_pc_i              (lsu_pc),
    .lsu_ap_pc_i           (lsu_ap_pc),
    // IRQs
    .irq_i                 (irq_i),
    // To FETCH stg
    .fetch_req_o           (fetch_req),
    .fetch_addr_o          (fetch_addr),
    // To DECODE stg
    .decode_pc_update_o    (decode_pc_update),
    .decode_pc_update_addr_o (decode_pc_update_addr),
    // Branch predictor update
    .bp_update_o           (bp_update),
    .bp_update_pc_o        (bp_update_pc),
    .bp_update_taken_o     (bp_update_taken),
    .bp_update_target_o    (bp_update_target),
    // P2: RAS call/return to fetch/branch_predictor
    .bp_is_call_o          (bp_is_call),
    .bp_call_ret_addr_o    (bp_call_ret_addr),
    .bp_is_return_o        (bp_is_return),
    // Trap signals
    .fetch_trap_i          (fetch_trap),
    .lsu_trap_i            (lsu_trap),
    // MMU fault
    .mmu_fault_i           (mmu_fault),
    .mmu_fault_valid_i     (mmu_fault_valid),
    // Privilege + MMU control
    .priv_mode_o           (priv_mode),
    .satp_o                (satp),
    .sum_o                 (sum),
    .mxr_o                 (mxr),
    // SFENCE.VMA to MMU
    .sfence_vma_o          (sfence_vma),
    .sfence_vaddr_o        (sfence_vaddr),
    .sfence_asid_o         (sfence_asid),
    .sfence_rs1_x0_o       (sfence_rs1_x0),
    .sfence_rs2_x0_o       (sfence_rs2_x0)
  );

  lsu #(
    .SUPPORT_DEBUG        (SUPPORT_DEBUG),
    .TRAP_ON_MIS_LSU_ADDR (TRAP_ON_MIS_LSU_ADDR),
    .TRAP_ON_LSU_ERROR    (TRAP_ON_LSU_ERROR)
  ) u_lsu (
    .clk                   (clk),
    .rst                   (rst),
    // From EXE stg
    .lsu_i                 (lsu_op),
    // To EXE stg
    .lsu_bp_o              (lsu_bp),
    .lsu_pc_o              (lsu_pc),
    .lsu_ap_pc_o           (lsu_ap_pc),
    // To write-back datapath
    .lsu_bp_data_o         (lsu_bp_data),
    .wb_lsu_o              (lsu_op_wb),
    .lsu_data_o            (lsu_rd_data),
    // Core data bus I/F (VA; MMU translates to PA)
    .data_cb_mosi_o        (lsu_raw_mosi),
    .data_cb_miso_i        (lsu_raw_miso),
    // Trap - MEM access fault or MEM misaligned addr
    .lsu_trap_o            (lsu_trap),
    // MMU kill (page fault drain)
    .kill_lsu_i            (kill_lsu)
  );

  wb u_wb(
    .clk                   (clk),
    .rst                   (rst),
    // From EXEC/WB
    .ex_mem_wb_i           (ex_mem_wb),
    // From LSU
    .wb_lsu_i              (lsu_op_wb),
    .lsu_rd_data_i         (lsu_rd_data),
    .lsu_bp_i              (lsu_bp),
    .lsu_bp_data_i         (lsu_bp_data),
    // MMU fault
    .mmu_fault_valid_i     (mmu_fault_valid),
    // To DEC stg
    .wb_dec_o              (wb_dec),
    // To EXE stg
    .wb_fwd_load_o         (wb_fwd_load),
    .lock_wb_o             (lock_wb)
  );
endmodule
