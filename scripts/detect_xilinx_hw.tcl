# List Xilinx JTAG devices visible to Vivado Hardware Manager.
# Run through scripts/detect_xilinx_hw.ps1 from the repo root.

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

set idx 0
foreach dev $devices {
    current_hw_device $dev
    refresh_hw_device -update_hw_probes false $dev

    set name [get_property NAME $dev]
    set part [get_property PART $dev]
    puts "DEVICE $idx: NAME=$name PART=$part"
    incr idx
}

close_hw_target
disconnect_hw_server
close_hw_manager
exit 0
