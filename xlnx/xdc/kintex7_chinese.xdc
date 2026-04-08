set_property BITSTREAM.General.UnconstrainedPins {Allow} [current_design]

# Pushbuttons
set_property -dict { PACKAGE_PIN C24   IOSTANDARD LVCMOS25 } [get_ports { rst_cpu }];
set_property -dict { PACKAGE_PIN AC16  IOSTANDARD LVCMOS15 } [get_ports { bootloader_i }];
#set_property -dict { PACKAGE_PIN A20  IOSTANDARD LVCMOS33 } [get_ports { rst_clk }];

########### LEDS ##########
set_property -dict { PACKAGE_PIN AA2  IOSTANDARD LVCMOS15 } [get_ports {csr_out[0]}]
set_property -dict { PACKAGE_PIN AD5  IOSTANDARD LVCMOS15 } [get_ports {csr_out[1]}]
set_property -dict { PACKAGE_PIN W10  IOSTANDARD LVCMOS15 } [get_ports {csr_out[2]}]
set_property -dict { PACKAGE_PIN Y10  IOSTANDARD LVCMOS15 } [get_ports {csr_out[3]}]
set_property -dict { PACKAGE_PIN AE10 IOSTANDARD LVCMOS15 } [get_ports {csr_out[4]}]
set_property -dict { PACKAGE_PIN W11  IOSTANDARD LVCMOS15 } [get_ports {csr_out[5]}]
set_property -dict { PACKAGE_PIN V11  IOSTANDARD LVCMOS15 } [get_ports {uart_irq_o}]
set_property -dict { PACKAGE_PIN Y12  IOSTANDARD LVCMOS15 } [get_ports {clk_locked_o}]

set_property -dict { PACKAGE_PIN L20  IOSTANDARD LVCMOS33 } [get_ports {uart_tx_o}]
set_property -dict { PACKAGE_PIN G20  IOSTANDARD LVCMOS33 } [get_ports {uart_rx_i}]

########### UNCONSTRAINED I/O STANDARDS ##########
# csr_out[6:7] — same bank as csr_out[0:5] (LVCMOS15)
set_property IOSTANDARD LVCMOS15 [get_ports {csr_out[6]}]
set_property IOSTANDARD LVCMOS15 [get_ports {csr_out[7]}]

# SPI interface
set_property IOSTANDARD LVCMOS33 [get_ports {spi_clk_o}]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_mosi_o}]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_miso_i}]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_csn_o}]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_gpio_o[0]}]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_gpio_o[1]}]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_gpio_o[2]}]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_gpio_o[3]}]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_gpio_o[4]}]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_gpio_o[5]}]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_gpio_o[6]}]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_gpio_o[7]}]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_gpio_o[8]}]
set_property IOSTANDARD LVCMOS33 [get_ports {spi_gpio_o[9]}]

# Misc
#set_property IOSTANDARD LVCMOS33 [get_ports {clk_locked_o}]
set_property IOSTANDARD LVCMOS33 [get_ports {rst_clk}]
set_property IOSTANDARD LVCMOS33 [get_ports {uart_tx_mirror_o}]

########### COMBINATORIAL LOOP WAIVER ##########
# The RTL-level loop (lsu_bp_o→lsu_bp_i→load_use_hazard→lsu_o.op_typ→
# lsu_i.op_typ→ap_txn→bp_addr→lsu_bp_o) was broken in execute.sv by removing
# ~lsu_bp_i from load_use_hazard and guarding the ex_mem_wb.lsu clear instead.
# The XDC waiver below is kept commented out; the previous net name was wrong
# and Vivado silently ignored it (Synth 8-689 "No nets matched").
#set_property ALLOW_COMBINATORIAL_LOOPS TRUE [get_nets {u_nox_wrapper/u_nox/u_decode/s_axi_aready_reg_reg}]

########### CLOCKS ##########
#set_property -dict { PACKAGE_PIN AB11 IOSTANDARD DIFF_SSTL15 } [get_ports sysclk_200_p]
#set_property -dict { PACKAGE_PIN AC11 IOSTANDARD DIFF_SSTL15 } [get_ports sysclk_200_n]
set_property -dict { PACKAGE_PIN F17  IOSTANDARD LVCMOS33    } [get_ports clk_in]
#set_property -dict { PACKAGE_PIN F6   IOSTANDARD DIFF_SSTL15 } [get_ports sysclk_150_p]
#set_property -dict { PACKAGE_PIN F5   IOSTANDARD DIFF_SSTL15 } [get_ports sysclk_150_n]
#set_property -dict { PACKAGE_PIN D6   IOSTANDARD DIFF_SSTL15 } [get_ports sysclk_156_p]
#set_property -dict { PACKAGE_PIN D5   IOSTANDARD DIFF_SSTL15 } [get_ports sysclk_156_n]

#create_clock -period  5.000 [get_ports sysclk_200_p]
create_clock -period 10.000 [get_ports clk_in]
#create_clock -period  6.667 [get_ports sysclk_150_p]
#create_clock -period  6.400 [get_ports sysclk_156_p]
