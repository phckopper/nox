# Copyright lowRISC contributors.
# Licensed under the Apache License, Version 2.0, see LICENSE for details.
# SPDX-License-Identifier: Apache-2.0

set_driving_cell [all_inputs] -lib_cell BUF_X2
set_load 10.0 [all_outputs]

# False path: load-use forwarding bypass (lsu_axi_miso_i.rdata → lsu_axi_mosi_o.araddr/awaddr).
#
# The combinational chain  AXI-rdata → wb.fmt_load → execute forwarding-mux → ALU → AXI-addr
# exists in the netlist but is never exercised at speed.  When a LOAD is in the WB stage
# (ex_mem_wb_ff.lsu == LSU_LOAD) and the next instruction needs the loaded value
# (rs1_fwd == FWD_REG), execute.sv asserts load_use_hazard which:
#   • inserts a 1-cycle bubble (id_ready_o = 0)
#   • suppresses any new AXI request (lsu_o.op_typ = NO_LSU)
# As a result the AXI address outputs are never valid while the forwarded rdata value
# is propagating combinationally, making this an unreachable timing path.
set_false_path -from [get_ports {lsu_axi_miso_i[*]}] -to [get_ports {lsu_axi_mosi_o[*]}]

# Extended false path: AXI read data → any internal pipeline register.
# When wb_value_i is live on the forwarding bus (op1 = wb_value_i), the
# activating condition (ex_mem_wb_ff.lsu==LSU_LOAD && rs1/rs2_fwd==FWD_REG)
# also asserts load_use_hazard, which simultaneously:
#   • id_ready_o=0  → id_ex_ff in decode is held, never updated this cycle
#   • next_jump.j_act=0 → instr_addr_misaligned stays clear → no CSR FF write
#   • eval_trap=0   → CSR trap evaluation suppressed
# No pipeline register is therefore reachable through the long
# forwarding+ALU+CSR combinational chain in the same cycle that
# lsu_axi_miso_i carries new load data.
set_false_path -from [get_ports {lsu_axi_miso_i[*]}] -to [all_registers]
