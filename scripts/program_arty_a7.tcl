# Program the Arty A7-100T over Xilinx JTAG (USB-JTAG FT2232H).
# Usage (from PowerShell wrapper):
#   vivado -mode batch -source scripts/program_arty_a7.tcl -tclargs <bit_file>
#
# If <bit_file> is omitted, use the validated 4-lane, 100 MHz build.
# relative to the script's repo root.

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]

set default_bit [file join $repo_root "vivado_build" "arty_a7_100_multi_lanes4_9p5ns_rowopt" "arty_a7_qmc_multi.bit"]
if {$argc >= 1} {
    set bit_file [lindex $argv 0]
} else {
    set bit_file $default_bit
}

if {![file exists $bit_file]} {
    puts "ERROR: Bitstream not found: $bit_file"
    puts "       Run scripts/run_vivado_build_arty_a7.ps1 first."
    exit 1
}

puts "Programming Arty A7-100T with: $bit_file"

open_hw_manager
connect_hw_server -url TCP:localhost:3121 -cs_url TCP:localhost:3042
open_hw_target

# Pick first Xilinx device on the scan chain.
set devices [get_hw_devices]
if {[llength $devices] == 0} {
    puts "ERROR: No hardware devices detected. Is the board powered / USB connected?"
    close_hw_target
    disconnect_hw_server
    close_hw_manager
    exit 2
}

set dev [lindex $devices 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set_property PROGRAM.FILE $bit_file $dev
program_hw_devices $dev
refresh_hw_device $dev

puts "Arty A7-100T programmed OK: [get_property PART $dev]"

close_hw_target
disconnect_hw_server
close_hw_manager
