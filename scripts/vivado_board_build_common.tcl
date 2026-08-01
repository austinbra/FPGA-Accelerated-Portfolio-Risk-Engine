# Shared helpers for physically valid 7-series board builds.
#
# The board oscillator is always constrained at its real 100 MHz rate. A board
# wrapper MMCM generates the requested core period, and implementation starts
# from the complete in-process synthesis checkpoint so the GUI and batch flows
# use exactly the same netlist.

proc normalize_7series_core_clock {requested_period_ns} {
    if {[catch {expr {double($requested_period_ns)}} requested]} {
        error "core clock period must be numeric (got $requested_period_ns)"
    }
    if {$requested < 2.0 || $requested > 128.0} {
        error "core clock period must be between 2.0 and 128.0 ns"
    }

    set divide_eighths [expr {round($requested * 8.0)}]
    set normalized [expr {$divide_eighths / 8.0}]
    if {abs($requested - $normalized) > 0.0005} {
        error [format \
            "core clock period must be a multiple of 0.125 ns; requested %.6f ns, nearest legal value %.3f ns" \
            $requested $normalized]
    }

    set literal [format "%.3f" $normalized]
    set tag $literal
    regsub {0+$} $tag {} tag
    regsub {\.$} $tag {} tag
    set tag [string map {. p} $tag]

    return [dict create \
        period_ns $normalized \
        literal $literal \
        frequency_hz [expr {round(1000000000.0 / $normalized)}] \
        tag $tag]
}

proc create_verified_post_synth_project {
    build_dir project_name part_name top_name build_xdc opt_directive
} {
    set build_dir [file normalize $build_dir]
    set synth_dcp [file join $build_dir synth.dcp]
    set build_xdc [file normalize $build_xdc]
    set project_dir [file join $build_dir gui_post_synth]
    set project_path [file join $project_dir "${project_name}.xpr"]

    foreach required_file [list $synth_dcp $build_xdc] {
        if {![file exists $required_file]} {
            error "Missing required post-synthesis project input: $required_file"
        }
    }

    if {[llength [get_designs -quiet]] > 0} {
        close_design
    }
    if {[llength [get_projects -quiet]] > 0} {
        close_project
    }
    if {[file exists $project_dir]} {
        file delete -force $project_dir
    }

    create_project $project_name $project_dir -part $part_name
    set_property target_language Verilog [current_project]
    set_property default_lib work [current_project]

    set sources [current_fileset]
    set_property design_mode GateLvl $sources
    add_files -norecurse $synth_dcp
    add_files -fileset constrs_1 -norecurse $build_xdc
    set_property top $top_name $sources

    set impl_run [get_runs impl_1]
    set_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE $opt_directive $impl_run
    set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE Explore $impl_run
    set_property STEPS.PHYS_OPT_DESIGN.IS_ENABLED true $impl_run
    set_property STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE Explore $impl_run
    set_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE Explore $impl_run
    set_property -dict [list \
        {STEPS.ROUTE_DESIGN.ARGS.MORE OPTIONS} {-tns_cleanup} \
    ] $impl_run

    puts "INFO: Created canonical gate-level implementation project."
    puts "INFO: project       = $project_path"
    puts "INFO: source DCP    = $synth_dcp"
    puts "INFO: constraint    = $build_xdc"
    puts "INFO: part          = [get_property PART [current_project]]"
    puts "INFO: opt directive = [get_property STEPS.OPT_DESIGN.ARGS.DIRECTIVE $impl_run]"
    puts "INFO: place direct. = [get_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE $impl_run]"
    puts "INFO: route direct. = [get_property STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE $impl_run]"

    return $project_path
}

proc run_verified_post_synth_implementation {
    build_dir top_name canonical_bit_name opt_directive
} {
    set build_dir [file normalize $build_dir]
    set synth_dcp [file join $build_dir synth.dcp]

    # Keep implementation in this Vivado process. Project-mode launch_runs
    # spawns a JavaScript run worker on Windows, which can be denied by locked-
    # down hosts even though opt/place/route themselves are fully available.
    open_checkpoint $synth_dcp
    if {[llength [get_clocks -quiet]] == 0} {
        error "Synthesis checkpoint has no timing clock constraints"
    }
    opt_design -directive $opt_directive
    place_design -directive Explore
    phys_opt_design -directive Explore
    route_design -directive Explore -tns_cleanup

    puts "INFO: in-process route completed"
    write_checkpoint -force [file join $build_dir routed.dcp]
    report_timing_summary -delay_type min_max -report_unconstrained \
        -check_timing_verbose -max_paths 10 \
        -file [file join $build_dir timing_post_route.rpt]
    report_utilization -file [file join $build_dir utilization.rpt]
    report_route_status -file [file join $build_dir route_status.rpt]
    report_drc -file [file join $build_dir drc_post_route.rpt]

    set setup_paths [get_timing_paths -delay_type max -max_paths 1]
    set hold_paths [get_timing_paths -delay_type min -max_paths 1]
    if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {
        error "Implemented design has no setup or hold timing paths"
    }
    set wns [get_property SLACK [lindex $setup_paths 0]]
    set whs [get_property SLACK [lindex $hold_paths 0]]
    puts "INFO: post-route WNS = $wns ns"
    puts "INFO: post-route WHS = $whs ns"
    if {$wns < 0.0 || $whs < 0.0} {
        error "Post-route timing failed (WNS=$wns ns, WHS=$whs ns); bitstream suppressed"
    }

    set canonical_bit [file join $build_dir $canonical_bit_name]
    write_bitstream -force $canonical_bit
    if {![file exists $canonical_bit]} {
        error "Expected generated bitstream was not found: $canonical_bit"
    }
    puts "INFO: canonical bitstream = $canonical_bit"

    return [dict create \
        status Complete \
        wns_ns $wns \
        whs_ns $whs \
        canonical_bit $canonical_bit]
}

proc write_board_build_manifest {
    build_dir board part top mode lanes period_ns frequency_hz implementation_result
} {
    set manifest [file join [file normalize $build_dir] build_manifest.json]
    set fh [open $manifest w]
    puts $fh "{"
    puts $fh "  \"schema_version\": 1,"
    puts $fh "  \"board\": \"$board\","
    puts $fh "  \"part\": \"$part\","
    puts $fh "  \"top\": \"$top\","
    puts $fh "  \"exercise_mode\": \"$mode\","
    puts $fh "  \"num_lanes\": $lanes,"
    puts $fh [format "  \"core_period_ns\": %.3f," $period_ns]
    puts $fh "  \"core_frequency_hz\": $frequency_hz,"
    puts $fh [format "  \"wns_ns\": %.3f," [dict get $implementation_result wns_ns]]
    puts $fh [format "  \"whs_ns\": %.3f," [dict get $implementation_result whs_ns]]
    puts $fh "  \"tns_ns\": 0.000,"
    puts $fh "  \"ths_ns\": 0.000,"
    puts $fh "  \"divider_packet\": \"quotient_79_32_remainder_31_0\","
    puts $fh "  \"timing_report\": \"timing_post_route.rpt\","
    puts $fh "  \"utilization_report\": \"utilization.rpt\","
    puts $fh "  \"route_report\": \"route_status.rpt\","
    puts $fh "  \"drc_report\": \"drc_post_route.rpt\","
    puts $fh "  \"bitstream\": \"[file tail [dict get $implementation_result canonical_bit]]\""
    puts $fh "}"
    close $fh
    puts "INFO: build manifest = $manifest"
}
