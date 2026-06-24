## Arty A7-100T (Rev. D/E master constraints pattern) — QMC-LSM top: arty_a7_option_pricer_top
## Reference: https://github.com/Digilent/digilent-xdc/blob/master/Arty-A7-100-Master.xdc
## Pins verified against the Digilent master XDC (2024-03 revision). If your board revision
## differs, update these pin assignments from your local Digilent master.

set ::A7_SYS_CLK_HALF_PERIOD_NS [expr {$::A7_SYS_CLK_PERIOD_NS / 2.0}]

set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports CLK100MHZ]
create_clock -add -name sys_clk -period $::A7_SYS_CLK_PERIOD_NS -waveform [list 0.000 $::A7_SYS_CLK_HALF_PERIOD_NS] [get_ports CLK100MHZ]
# Note: the Arty A7 board provides a physical 100 MHz clock on E3, but this design targets
# ~83 MHz (period 12 ns) for comfortable timing closure on xc7a100tcsg324-1. On real
# hardware an MMCM would derive 83.3 MHz from the 100 MHz input; for STA-only benchmarking
# the period here tells Vivado what fMAX to close to, and the cycle-count × period product
# is the reportable wall-clock.

set_property -dict { PACKAGE_PIN D9 IOSTANDARD LVCMOS33 } [get_ports btn0]

## USB-UART (Digilent net names are DTE-centric; uart_txd_in is FPGA RX, uart_rxd_out is FPGA TX)
set_property -dict { PACKAGE_PIN A9  IOSTANDARD LVCMOS33 } [get_ports uart_txd_in]
set_property -dict { PACKAGE_PIN D10 IOSTANDARD LVCMOS33 } [get_ports uart_rxd_out]

## Bitstream / config
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]
