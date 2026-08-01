if {$argc < 1} {
    puts "ERROR: usage: vivado -mode batch -source inspect_s7_clock.tcl -tclargs <routed.dcp>"
    exit 2
}

set checkpoint [file normalize [lindex $argv 0]]
if {![file exists $checkpoint]} {
    puts "ERROR: checkpoint does not exist: $checkpoint"
    exit 2
}

open_checkpoint $checkpoint

puts "CLOCK_AUDIT checkpoint=$checkpoint"
puts "CLOCK_AUDIT part=[get_property PART [current_design]]"

set mmcms [get_cells -hier -filter {REF_NAME == MMCME2_BASE || REF_NAME == MMCME2_ADV}]
if {[llength $mmcms] == 0} {
    puts "ERROR: no MMCME2 primitive found"
    exit 3
}

foreach mmcm $mmcms {
    puts "CLOCK_AUDIT mmcm=$mmcm ref=[get_property REF_NAME $mmcm]"
    foreach property {CLKIN1_PERIOD CLKFBOUT_MULT_F DIVCLK_DIVIDE CLKOUT0_DIVIDE_F} {
        puts "CLOCK_AUDIT $property=[get_property $property $mmcm]"
    }

    set output_pin [get_pins -quiet $mmcm/CLKOUT0]
    set output_clocks [get_clocks -quiet -of_objects $output_pin]
    foreach clock $output_clocks {
        puts "CLOCK_AUDIT mmcm_output_clock=$clock period_ns=[get_property PERIOD $clock]"
    }
}

foreach clock [get_clocks] {
    puts "CLOCK_AUDIT clock=$clock period_ns=[get_property PERIOD $clock] waveform=[get_property WAVEFORM $clock]"
}

set rx_sync_cells [get_cells -hier -regexp {.*rx_sync_ff_reg\[[01]\].*}]
foreach cell $rx_sync_cells {
    puts "CLOCK_AUDIT rx_sync_cell=$cell loc=[get_property LOC $cell] bel=[get_property BEL $cell] async_reg=[get_property ASYNC_REG $cell]"
}

set uart_debug_cells [get_cells -hier -regexp {.*u_uart.*(state_reg|clk_count_reg|bit_index_reg|rx_shift_reg|rx_valid|word_cnt_reg).*}]
foreach cell $uart_debug_cells {
    set q_pin [get_pins -quiet $cell/Q]
    set q_net [get_nets -quiet -of_objects $q_pin]
    if {[llength $q_net] > 0} {
        puts "CLOCK_AUDIT uart_debug_cell=$cell q_net=$q_net"
    }
}

set rx_stage0 [get_cells -hier -regexp {.*rx_sync_ff_reg\[0\].*}]
set rx_stage1 [get_cells -hier -regexp {.*rx_sync_ff_reg\[1\].*}]
if {[llength $rx_stage0] == 1 && [llength $rx_stage1] == 1} {
    puts "CLOCK_AUDIT uart_input_path_begin"
    report_timing -from [get_ports uart_txd_in] -to [get_pins $rx_stage0/D] \
        -delay_type max -max_paths 1
    puts "CLOCK_AUDIT uart_input_path_end"
    puts "CLOCK_AUDIT synchronizer_path_begin"
    report_timing -from [get_pins $rx_stage0/Q] -to [get_pins $rx_stage1/D] \
        -delay_type max -max_paths 1
    puts "CLOCK_AUDIT synchronizer_path_end"
}

puts "CLOCK_AUDIT clock_interaction_begin"
report_clock_interaction -delay_type min_max
puts "CLOCK_AUDIT clock_interaction_end"

close_design
exit 0
