# Vivado batch-mode compile script for QMC-LSM-to-FPGA
# Run: vivado -mode batch -source scripts/run_xvlog.tcl
# Single Vivado session; xvlog runs inside it (avoids repeated slow startup).

set scriptDir [file dirname [info script]]
set projectRoot [file normalize [file join $scriptDir ..]]
cd $projectRoot

set sources [list \
    fpga/mem_paths_pkg.sv \
    src/fpga_cfg_pkg.sv \
    src/helpers/rv_skid_arr_gate.sv \
    src/helpers/event_align_fifo_arr.sv \
    src/math/fxMul.sv \
    src/math/fxDiv.sv \
    src/math/fxExpLUT.sv \
    src/math/fxLnLUT.sv \
    src/math/fxSqrt.sv \
    src/math/fxInvCDF_ZS.sv \
    src/steps/sobol.sv \
    src/steps/inverseCDF_fold.sv \
    src/steps/inverseCDF.sv \
    src/steps/GBM.sv \
    src/steps/accumulator.sv \
    src/steps/regression.sv \
    src/steps/lsm_decision.sv \
    src/io/uart/uart_rx.sv \
    src/io/uart/uart_tx.sv \
    src/io/uart/uart_rx32.sv \
    src/io/uart/uart_tx32.sv \
    src/io/handlers/uart_input_handler.sv \
    src/top/top_option_pricer.sv \
]

set xvlogArgs [list -nolog -sv]
foreach f $sources {
    lappend xvlogArgs $f
}

puts "Running xvlog (compile)..."
if {[catch {eval exec xvlog {*}$xvlogArgs} result]} {
    puts "ERROR: xvlog failed"
    puts $result
    exit 1
}
puts "xvlog completed successfully."
exit 0
