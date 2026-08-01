## Arty A7-100T (Rev. D/E master constraints pattern) - QMC-LSM top: arty_a7_option_pricer_top
## Reference: https://github.com/Digilent/digilent-xdc/blob/master/Arty-A7-100-Master.xdc
## Pins verified against the Digilent master XDC (2024-03 revision). If your board revision
## differs, update these pin assignments from your local Digilent master.

set_property -dict { PACKAGE_PIN E3 IOSTANDARD LVCMOS33 } [get_ports CLK100MHZ]
create_clock -add -name board_clk_100mhz -period 10.000 -waveform {0.000 5.000} [get_ports CLK100MHZ]

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
