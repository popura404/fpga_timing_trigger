# Registered OOC timing benchmark; no board I/O claim or bitstream.
# A generated register shell exercises every core input/output path. The BUFG
# location and outer 2.0/0.5 ns port budgets are benchmark assumptions only.
set root [file normalize [file join [file dirname [info script]] ..]]
set mode configurable
set action build
if {$argc > 0} {set mode [lindex $argv 0]}
if {$argc > 1} {set action [lindex $argv 1]}
if {$argc > 2 || $mode ni {configurable fixed} || $action ni {build report}} {
    error "Usage: implement.tcl ?configurable|fixed? ?build|report?"
}
set output [file join $root build vivado $mode]
file mkdir $output
cd $output
set_param general.maxThreads 4
set part xc7z020clg400-2
if {$action eq "report"} {
    if {![file isfile routed.dcp]} {error "No checkpoint: $output/routed.dcp; run build first"}
    open_checkpoint routed.dcp
} else {
read_verilog -sv [file join $root rtl timing_trigger.sv]

if {$mode eq "fixed"} {
    # Core-only constant baseline retained as a generated simulation input.
    set wrapper [open fixed_top.sv w]
    puts $wrapper {`timescale 1ns/1ps
module fixed_top (
    input wire clk, rst,
    input wire [2:0] command,
    input wire trigger,
    output wire [3:0] pulse,
    output wire busy, armed, done, aborted, command_error, config_valid,
    output wire [31:0] busy_trigger_count
);
    timing_trigger dut (
        .clk(clk), .rst(rst), .command(command), .trigger(trigger),
        .cfg_enable(4'hf),
        .cfg_delay({32'd6, 32'd4, 32'd2, 32'd0}),
        .cfg_width({32'd2, 32'd2, 32'd2, 32'd2}),
        .cfg_period(32'd12), .cfg_repeats(16'd3),
        .pulse(pulse), .busy(busy), .armed(armed), .done(done),
        .aborted(aborted), .command_error(command_error),
        .config_valid(config_valid), .busy_trigger_count(busy_trigger_count)
    );
endmodule}
    close $wrapper
}

# Generate the same register-shell convention for both modes. Constants in the
# fixed case go straight into core, allowing its unused configurability to fold.
set input_signals {{rst 1} {command 3} {trigger 1}}
if {$mode eq "configurable"} {
    lappend input_signals {cfg_enable 4} {cfg_delay 128} {cfg_width 128} \
                         {cfg_period 32} {cfg_repeats 16}
}
set output_signals {{pulse 4} {busy 1} {armed 1} {done 1} {aborted 1} \
                    {command_error 1} {config_valid 1} {busy_trigger_count 32}}
proc width_range {width} {
    if {$width == 1} {return ""}
    return [format {[%d:0]} [expr {$width - 1}]]
}
set declarations {"input wire clk"}
foreach signal $input_signals {
    lassign $signal name width
    lappend declarations "input wire [width_range $width] $name"
}
foreach signal $output_signals {
    lassign $signal name width
    lappend declarations "output reg [width_range $width] $name"
}
set wrapper [open timing_benchmark.sv w]
puts $wrapper {`timescale 1ns/1ps}
puts $wrapper "module timing_benchmark (\n    [join $declarations ",\n    "]\n);"
puts $wrapper {wire core_clk;
BUFG benchmark_clock (.I(clk), .O(core_clk));}
foreach signal $input_signals {
    lassign $signal name width
    puts $wrapper "reg [width_range $width] ${name}_q;"
}
foreach signal $output_signals {
    lassign $signal name width
    puts $wrapper "wire [width_range $width] ${name}_core;"
}
puts $wrapper {always @(posedge core_clk) begin}
foreach signal $input_signals {
    set name [lindex $signal 0]
    puts $wrapper "    ${name}_q <= $name;"
}
foreach signal $output_signals {
    set name [lindex $signal 0]
    puts $wrapper "    $name <= ${name}_core;"
}
puts $wrapper {end}
set connections {".clk(core_clk)"}
foreach signal $input_signals {
    set name [lindex $signal 0]
    lappend connections ".$name\(${name}_q\)"
}
if {$mode eq "fixed"} {
    lappend connections {.cfg_enable(4'hf)} \
        {.cfg_delay({32'd6, 32'd4, 32'd2, 32'd0})} \
        {.cfg_width({32'd2, 32'd2, 32'd2, 32'd2})} \
        {.cfg_period(32'd12)} {.cfg_repeats(16'd3)}
}
foreach signal $output_signals {
    set name [lindex $signal 0]
    lappend connections ".$name\(${name}_core\)"
}
puts $wrapper "timing_trigger core (\n    [join $connections ",\n    "]\n);\nendmodule"
close $wrapper
read_verilog -sv timing_benchmark.sv

# Read before synthesis, so synthesis and implementation share the same target.
set constraints [open benchmark.xdc w]
puts $constraints {create_clock -name clk -period 10.000 [get_ports clk]
set_clock_uncertainty 0.100 [get_clocks clk]
set_property LOC BUFGCTRL_X0Y0 [get_cells benchmark_clock]
set inputs [get_ports -filter {DIRECTION == IN && NAME != clk}]
set_input_delay -clock clk -max 2.000 $inputs
set_input_delay -clock clk -min 0.500 $inputs
set_output_delay -clock clk -max 2.000 [all_outputs]
set_output_delay -clock clk -min 0.500 [all_outputs]}
close $constraints
read_xdc benchmark.xdc
synth_design -top timing_benchmark -part $part -mode out_of_context -flatten_hierarchy none
report_utilization -file utilization_synth.rpt
opt_design
place_design
phys_opt_design
route_design
write_checkpoint -force routed.dcp
write_xdc -force implemented.xdc
}

# Report the loaded design, which may have been built outside this script.
# Export active constraints without changing them or overwriting the build XDC.
set part [get_property PART [current_design]]
set clock [get_clocks -quiet clk]
if {[llength $clock] != 1} {error "Expected one clock named clk"}
set clock_period [get_property PERIOD $clock]
set bufg_site [get_property LOC [get_cells benchmark_clock]]
write_xdc -force timing_constraints.xdc
set core_cell [get_cells -quiet core]
if {[llength $core_cell] != 1} {error "Expected preserved core instance"}
set utilization [report_utilization -return_string]
set core_utilization [report_utilization -cells $core_cell -return_string]
foreach {filename contents} [list utilization_routed.rpt $utilization \
                                 utilization_core.rpt $core_utilization] {
    set report [open $filename w]
    puts $report $contents
    close $report
}
set timing_summary [report_timing_summary -delay_type min_max -report_unconstrained \
                    -max_paths 10 -return_string]
set timing_checks [check_timing -verbose -return_string]
foreach {filename contents} [list timing_summary.rpt $timing_summary \
                                 check_timing.rpt $timing_checks] {
    set report [open $filename w]
    puts $report $contents
    close $report
}
report_route_status -file route_status.rpt
report_drc -file drc.rpt

# Include shell launch/capture registers: configuration validation is part of
# the timed cone. Outer port paths are retained and reported, not false-pathed.
set registers [all_registers]
set inputs [get_ports -filter {DIRECTION == IN && NAME != clk}]
set outputs [all_outputs]
set path_limit [expr {4 * [llength $registers] + [llength [get_ports]]}]
set setup_paths [get_timing_paths -from $registers -to $registers -delay_type max \
                 -max_paths $path_limit -nworst 1]
set hold_paths [get_timing_paths -from $registers -to $registers -delay_type min \
                -max_paths $path_limit -nworst 1]
if {[llength $setup_paths] == 0 || [llength $hold_paths] == 0} {
    error "Missing register setup/hold paths; inspect reports in $output"
}
set wns [get_property SLACK [lindex $setup_paths 0]]
set whs [get_property SLACK [lindex $hold_paths 0]]
report_timing -from $registers -to $registers -delay_type min_max -max_paths 10 \
    -file timing_register_paths.rpt
set port_wns [get_property SLACK [get_timing_paths -delay_type max -max_paths 1]]
set port_whs [get_property SLACK [get_timing_paths -delay_type min -max_paths 1]]

# Inspect the boundary without changing its constraints or timing exceptions.
# Count unique endpoints; -nworst 1 retains their worst path in each group.
proc path_stats {paths} {
    if {[llength $paths] == 0} {error "Expected timing paths in every benchmark group"}
    set failed {}
    foreach path $paths {
        if {[get_property SLACK $path] < 0} {lappend failed [get_property ENDPOINT_PIN $path]}
    }
    return [list [llength [lsort -unique [get_property ENDPOINT_PIN $paths]]] \
                 [get_property SLACK [lindex $paths 0]] [llength [lsort -unique $failed]]]
}
set boundary [open timing_boundary.rpt w]
puts $boundary "Boundary timing uses loaded design constraints in timing_constraints.xdc; no board I/O validation."
puts $boundary "Group Analysis Endpoints Worst_slack_ns Failing_endpoints"
set group_stats [dict create]
foreach {group from to detail_file} [list input_to_register $inputs $registers timing_input_paths.rpt \
                                        register_to_output $registers $outputs timing_output_paths.rpt \
                                        register_to_register $registers $registers ""] {
    foreach delay {max min} {
        set paths [get_timing_paths -from $from -to $to -delay_type $delay \
                   -max_paths $path_limit -nworst 1]
        if {[llength $paths] >= $path_limit} {error "Timing path limit reached; report may be incomplete"}
        set stats [path_stats $paths]
        dict set group_stats $group $delay $stats
        puts $boundary "$group $delay [join $stats { }]"
        if {$group eq "input_to_register" && $delay eq "min"} {
            set worst_input [lindex $paths 0]
        }
    }
    if {$detail_file ne ""} {
        report_timing -from $from -to $to -delay_type min_max -max_paths 10 \
            -path_type full_clock_expanded -file $detail_file
    }
}
set input_port [get_ports [get_property STARTPOINT_PIN $worst_input]]
set input_net [get_nets -of_objects $input_port]
puts $boundary "\nWorst input net: $input_net ROUTE_STATUS=[get_property ROUTE_STATUS $input_net] ROUTE=[get_property ROUTE $input_net]"
puts $boundary "Input port HD.PARTPIN_LOCS=[get_property HD.PARTPIN_LOCS $input_port]"
puts $boundary "Internal clock core_clk ROUTE_STATUS=[get_property ROUTE_STATUS [get_nets core_clk]]"

# Classify EVERY globally failing endpoint, not only the ten detailed paths.
# Input violations must terminate at shell launch registers, not inside core.
set register_names [get_property NAME $registers]
set input_names [get_property NAME $inputs]
set output_names [get_property NAME $outputs]
set all_fail_counts [dict create]
set unclassified_failures 0
set direct_core_failures 0
puts $boundary "\nAll failing endpoint paths: Analysis Class Slack_ns Startpoint Endpoint"
foreach delay {max min} {
    set failures [get_timing_paths -delay_type $delay -slack_lesser_than 0 \
                  -max_paths $path_limit -nworst 1]
    if {[llength $failures] >= $path_limit} {error "Failing endpoint report truncated"}
    set failing_endpoints {}
    foreach path $failures {
        set start [get_property STARTPOINT_PIN $path]
        set end [get_property ENDPOINT_PIN $path]
        lappend failing_endpoints $end
        set start_cell ""
        set end_cell ""
        regexp {^(.*)/[^/]+$} $start -> start_cell
        regexp {^(.*)/[^/]+$} $end -> end_cell
        set class UNCLASSIFIED
        if {$start in $input_names && $end_cell in $register_names} {
            set class input_to_shell
            if {![regexp {^(rst|command|trigger|cfg_enable|cfg_delay|cfg_width|cfg_period|cfg_repeats)_q_reg(\[[0-9]+\])?$} $end_cell]} {
                set class DIRECT_CORE_OR_UNEXPECTED_INPUT
                incr direct_core_failures
            }
        } elseif {$start_cell in $register_names && $end in $output_names} {
            set class shell_to_output
            if {![regexp {^(pulse|busy|armed|done|aborted|command_error|config_valid|busy_trigger_count)_reg(\[[0-9]+\])?$} $start_cell]} {
                set class DIRECT_CORE_OR_UNEXPECTED_OUTPUT
                incr direct_core_failures
            }
        } elseif {$start_cell in $register_names && $end_cell in $register_names} {
            set class register_to_register
        } else {incr unclassified_failures}
        puts $boundary "$delay $class [get_property SLACK $path] $start $end"
    }
    dict set all_fail_counts $delay [llength [lsort -unique $failing_endpoints]]
}
puts $boundary "\nUnclassified failing paths: $unclassified_failures"
puts $boundary "Direct-core/unexpected boundary failing paths: $direct_core_failures"
close $boundary

# Parse the design-level pulse-width summary, which applies to actual clocked
# cells even though top-level interface data timing remains only an estimate.
set summary_lines [split $timing_summary "\n"]
set wpws ""
set pw_failing ""
for {set line 0} {$line < [llength $summary_lines]} {incr line} {
    set text [lindex $summary_lines $line]
    if {[string first "WNS(ns)" $text] >= 0 && [string first "WPWS(ns)" $text] >= 0} {
        set values [regexp -all -inline {\S+} [lindex $summary_lines [expr {$line + 2}]]]
        if {[llength $values] == 12} {
            set wpws [lindex $values 8]
            set pw_failing [lindex $values 10]
        }
        break
    }
}
if {![string is double -strict $wpws] || ![string is integer -strict $pw_failing]} {
    error "Cannot read pulse-width summary; inspect timing_summary.rpt"
}
set checks [regexp -all -inline {checking\s+\S+\s+\(([0-9]+)\)} $timing_checks]
if {[llength $checks] == 0} {error "Cannot read check_timing counts"}
# Each category appears in both table of contents and details; count once.
set categories [dict create]
foreach {heading count} $checks {dict set categories $heading $count}
set timing_issues 0
foreach count [dict values $categories] {incr timing_issues $count}
set drc_errors [llength [get_drc_violations -quiet -filter {SEVERITY == Error}]]
proc resource_counts {report} {
    if {![regexp {\|\s*Slice LUTs\s*\|\s*([0-9]+)} $report -> luts] ||
        ![regexp {\|\s*Slice Registers\s*\|\s*([0-9]+)} $report -> registers]} {
        error "Cannot read LUT/register utilization"
    }
    return [list $luts $registers]
}
lassign [resource_counts $utilization] total_luts total_registers
lassign [resource_counts $core_utilization] core_luts core_registers
set register_ok [expr {$wns >= 0 && $whs >= 0 && $wpws >= 0 && $pw_failing == 0 &&
                      $timing_issues == 0 && $drc_errors == 0 &&
                      $unclassified_failures == 0 && $direct_core_failures == 0}]
set full_ok [expr {$register_ok && $port_wns >= 0 && $port_whs >= 0 &&
                  $unclassified_failures == 0 && $direct_core_failures == 0 &&
                  [dict get $all_fail_counts max] == 0 && [dict get $all_fail_counts min] == 0}]
set register_status [expr {$register_ok ? "PASS" : "FAIL"}]
set full_status [expr {$full_ok ? "PASS" : "FAIL"}]
set metrics [open metrics.txt w]
foreach {key value} [list mode $mode part $part vivado [version -short] \
    benchmark registered_ooc clock_period_ns $clock_period \
    benchmark_bufg_site $bufg_site constraints_snapshot timing_constraints.xdc \
    build_default_clock_uncertainty_ns 0.100 build_default_input_output_delay_max_ns 2.000 \
    build_default_input_output_delay_min_ns 0.500 core_slice_luts $core_luts \
    core_slice_registers $core_registers total_slice_luts $total_luts \
    total_slice_registers $total_registers reg_to_reg_wns_ns $wns reg_to_reg_whs_ns $whs \
    register_count [llength $registers] reg_to_reg_setup_paths [llength $setup_paths] \
    reg_to_reg_hold_paths [llength $hold_paths] pulse_width_slack_ns $wpws \
    pulse_width_failing_endpoints $pw_failing port_inclusive_estimate_wns_ns $port_wns \
    port_inclusive_estimate_whs_ns $port_whs port_timing_status ADVISORY_NOT_BOARD_VALIDATED \
    check_timing_issues $timing_issues drc_errors $drc_errors \
    register_benchmark_status $register_status full_design_timing_status $full_status \
    input_setup_worst_slack_ns [lindex [dict get $group_stats input_to_register max] 1] \
    input_hold_worst_slack_ns [lindex [dict get $group_stats input_to_register min] 1] \
    output_setup_worst_slack_ns [lindex [dict get $group_stats register_to_output max] 1] \
    output_hold_worst_slack_ns [lindex [dict get $group_stats register_to_output min] 1] \
    input_hold_failing_endpoints [lindex [dict get $group_stats input_to_register min] 2] \
    output_hold_failing_endpoints [lindex [dict get $group_stats register_to_output min] 2] \
    all_setup_failing_endpoints [dict get $all_fail_counts max] \
    all_hold_failing_endpoints [dict get $all_fail_counts min] \
    unclassified_failing_paths $unclassified_failures \
    direct_core_boundary_failing_paths $direct_core_failures] {
    puts $metrics "$key=$value"
}
close $metrics
if {$register_ok} {
    puts "PASS: $mode registered OOC benchmark: core LUT=$core_luts FF=$core_registers WNS=$wns WHS=$whs"
} else {
    puts "REGISTER_BENCHMARK_FAIL: WNS=$wns WHS=$whs WPWS=$wpws timing_issues=$timing_issues DRC_errors=$drc_errors"
}
puts "ADVISORY: outer-port timing estimates WNS=$port_wns WHS=$port_whs; board/integration I/O timing is unverified"
if {!$full_ok} {
    puts "FULL_TIMING_FAIL: all setup/hold failing endpoints=[dict get $all_fail_counts max]/[dict get $all_fail_counts min]; unclassified=$unclassified_failures direct_core_boundary=$direct_core_failures"
    error "Full-design timing/checks failed; see metrics.txt and timing_boundary.rpt"
}
puts "PASS: full benchmark timing/checks under the stated assumptions; board timing remains unverified"
