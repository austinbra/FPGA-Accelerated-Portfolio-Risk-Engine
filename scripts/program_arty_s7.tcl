# Program the Digilent Arty S7-50 over Xilinx JTAG.
# Usage:
#   vivado -mode batch -source scripts/program_arty_s7.tcl -tclargs <bit_file>
#
# The script checks that the detected device is an XC7S50 by default. That
# makes any "measured on Spartan-7" claim traceable to the physical JTAG part.

set script_dir [file normalize [file dirname [info script]]]
set repo_root  [file normalize [file join $script_dir ..]]
set default_bit [file join $repo_root "vivado_build" "arty_s7_50_multi_lanes2_10p5ns_rowopt" "arty_s7_qmc_multi.bit"]

set bit_file $default_bit
set allow_part_mismatch 0

if {$argc >= 1} {
    set bit_file [lindex $argv 0]
}
for {set i 0} {$i < $argc} {incr i} {
    if {[lindex $argv $i] eq "--allow-part-mismatch"} {
        set allow_part_mismatch 1
    }
}

if {![file exists $bit_file]} {
    puts "ERROR: Bitstream not found: $bit_file"
    puts "       Run scripts/run_vivado_build_arty_s7.ps1 first."
    exit 1
}

puts "Programming Arty S7-50 with: $bit_file"

open_hw_manager
connect_hw_server -url TCP:localhost:3121 -cs_url TCP:localhost:3042
if {[catch {get_hw_targets} targets]} {
    puts "ERROR: No hardware targets detected. Check board power, USB data cable, FTDI/Digilent drivers, and jumper settings."
    disconnect_hw_server
    close_hw_manager
    exit 2
}
if {[llength $targets] == 0} {
    puts "ERROR: No hardware targets detected. Check board power, USB data cable, FTDI/Digilent drivers, and jumper settings."
    disconnect_hw_server
    close_hw_manager
    exit 2
}

open_hw_target [lindex $targets 0]

set devices [get_hw_devices]
if {[llength $devices] == 0} {
    puts "ERROR: Hardware target opened, but no FPGA devices were detected in the JTAG chain."
    close_hw_target
    disconnect_hw_server
    close_hw_manager
    exit 3
}

set dev [lindex $devices 0]
current_hw_device $dev
refresh_hw_device -update_hw_probes false $dev

set detected_part [string tolower [get_property PART $dev]]
puts "Detected hardware PART=$detected_part"
if {!$allow_part_mismatch && [string first "xc7s50" $detected_part] < 0} {
    puts "ERROR: Expected an XC7S50 device for the Arty S7-50 bitstream."
    puts "       Detected PART=$detected_part instead."
    puts "       Do not use this route as S7-50 evidence unless the physical part matches."
    puts "       Pass --allow-part-mismatch only for intentional debug, not for claim evidence."
    close_hw_target
    disconnect_hw_server
    close_hw_manager
    exit 4
}

set_property PROGRAM.FILE $bit_file $dev
program_hw_devices $dev
refresh_hw_device $dev

puts "Arty S7-50 programmed OK: [get_property PART $dev]"

close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
