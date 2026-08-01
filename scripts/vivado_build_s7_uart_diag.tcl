set script_dir [file dirname [file normalize [info script]]]
set repo_root [file normalize [file join $script_dir ..]]

set use_core 0
if {[info exists ::env(UART_DIAG_USE_CORE_CLOCK)] && $::env(UART_DIAG_USE_CORE_CLOCK) ne ""} {
    set use_core [expr {$::env(UART_DIAG_USE_CORE_CLOCK) ? 1 : 0}]
}

set mode_name [expr {$use_core ? "core95" : "board100"}]
set build_dir [file join $repo_root vivado_build arty_s7_uart_diag_$mode_name]
file mkdir $build_dir

create_project -in_memory -part xc7s50csga324-1
set_property target_language Verilog [current_project]

set rtl [list \
    [file join $repo_root src io uart uart_rx.sv] \
    [file join $repo_root src io uart uart_tx.sv] \
    [file join $repo_root src io uart uart_rx32.sv] \
    [file join $repo_root src io uart uart_tx32.sv] \
    [file join $repo_root src io handlers uart_input_handler.sv] \
    [file join $repo_root fpga arty_s7_uart_diag_top.sv] \
]
add_files -fileset sources_1 -norecurse $rtl
add_files -fileset constrs_1 -norecurse [file join $repo_root constraints arty_s7_50.xdc]
set_property top arty_s7_uart_diag_top [get_filesets sources_1]

set top_generics [list \
    USE_CORE_UART_CLOCK=$use_core \
    CORE_CLKOUT_DIVIDE_F=10.500 \
    CORE_CLK_FREQ_HZ=95238095 \
]
set_property generic $top_generics [get_filesets sources_1]
puts "UART_DIAG mode=$mode_name generics=$top_generics"

synth_design -top arty_s7_uart_diag_top -part xc7s50csga324-1 -generic $top_generics
write_checkpoint -force [file join $build_dir synth.dcp]
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force [file join $build_dir routed.dcp]
report_timing_summary -delay_type min_max -max_paths 20 \
    -file [file join $build_dir timing_post_route.rpt]
report_utilization -file [file join $build_dir utilization.rpt]
report_drc -file [file join $build_dir drc_post_route.rpt]

set mmcm [get_cells -hier -filter {REF_NAME == MMCME2_BASE || REF_NAME == MMCME2_ADV}]
set audit [open [file join $build_dir clock_audit.txt] w]
puts $audit "mode=$mode_name"
puts $audit "uart_clock_hz=[expr {$use_core ? 95238095 : 100000000}]"
puts $audit "uart_clks_per_bit=[expr {($use_core ? 95238095 : 100000000) / 115200}]"
puts $audit "mmcm_clkout0_divide_f=[get_property CLKOUT0_DIVIDE_F $mmcm]"
foreach clock [get_clocks] {
    puts $audit "clock=$clock period_ns=[get_property PERIOD $clock]"
}
close $audit

write_bitstream -force [file join $build_dir arty_s7_uart_diag.bit]
puts "UART_DIAG bitstream=[file join $build_dir arty_s7_uart_diag.bit]"
exit 0
