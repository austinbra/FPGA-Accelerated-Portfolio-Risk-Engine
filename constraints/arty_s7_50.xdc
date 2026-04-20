## Arty S7-50 (Rev. E master constraints pattern) — QMC-LSM top: arty_s7_option_pricer_top
## Reference: https://github.com/Digilent/digilent-xdc/blob/master/Arty-S7-50-Master.xdc

set_property -dict { PACKAGE_PIN R2 IOSTANDARD SSTL135 } [get_ports CLK100MHZ]
create_clock -add -name sys_clk -period 10.000 -waveform {0.000 5.000} [get_ports CLK100MHZ]

set_property -dict { PACKAGE_PIN G15 IOSTANDARD LVCMOS33 } [get_ports btn0]

## USB-UART (Digilent net names are DTE-centric; see rules.md / FPGA_BUILD.md)
set_property -dict { PACKAGE_PIN V12 IOSTANDARD LVCMOS33 } [get_ports uart_txd_in]
set_property -dict { PACKAGE_PIN R12 IOSTANDARD LVCMOS33 } [get_ports uart_rxd_out]

## Bitstream / config (same as Digilent master template)
set_property BITSTREAM.CONFIG.CONFIGRATE 50 [current_design]
set_property CONFIG_VOLTAGE 3.3 [current_design]
set_property CFGBVS VCCO [current_design]
set_property BITSTREAM.CONFIG.SPI_BUSWIDTH 4 [current_design]
set_property CONFIG_MODE SPIx4 [current_design]

## Bank 34 (DDR clock bank): internal VREF so SW3 / M5 does not define VREF
set_property INTERNAL_VREF 0.675 [get_iobanks 34]
