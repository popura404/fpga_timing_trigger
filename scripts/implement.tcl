# Registered OOC timing benchmark; no board I/O claim or bitstream.
# A generated register shell exercises every core input/output path. The BUFG
# location and outer 2.0/0.5 ns port budgets are benchmark assumptions only.
set root [file normalize [file join [file dirname [info script]] ..]]
set mode configurable
if {$argc > 0} {set mode [lindex $argv 0]}
if {$argc > 1 || $mode ni {configurable fixed}} {
    error "Usage: implement.tcl ?configurable|fixed?"
}
set output [file join $root build vivado $mode]
file mkdir $output
cd $output
set_param general.maxThreads 4
set part xc7z020clg400-2
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
set path_limit [expr {4 * [llength $registers]}]
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
set metrics [open metrics.txt w]
foreach {key value} [list mode $mode part $part vivado [version -short] \
    benchmark registered_ooc clock_period_ns 10.000 clock_uncertainty_ns 0.100 \
    benchmark_bufg_site BUFGCTRL_X0Y0 input_output_delay_max_ns 2.000 \
    input_output_delay_min_ns 0.500 core_slice_luts $core_luts \
    core_slice_registers $core_registers total_slice_luts $total_luts \
    total_slice_registers $total_registers reg_to_reg_wns_ns $wns reg_to_reg_whs_ns $whs \
    register_count [llength $registers] reg_to_reg_setup_paths [llength $setup_paths] \
    reg_to_reg_hold_paths [llength $hold_paths] pulse_width_slack_ns $wpws \
    pulse_width_failing_endpoints $pw_failing port_inclusive_estimate_wns_ns $port_wns \
    port_inclusive_estimate_whs_ns $port_whs port_timing_status ADVISORY_NOT_BOARD_VALIDATED \
    check_timing_issues $timing_issues drc_errors $drc_errors] {
    puts $metrics "$key=$value"
}
close $metrics
if {$wns < 0 || $whs < 0 || $wpws < 0 || $pw_failing != 0 ||
    $timing_issues != 0 || $drc_errors != 0} {
    error "Register benchmark failed: WNS=$wns WHS=$whs WPWS=$wpws timing_issues=$timing_issues DRC_errors=$drc_errors"
}
puts "PASS: $mode registered OOC benchmark: core LUT=$core_luts FF=$core_registers WNS=$wns WHS=$whs"
puts "ADVISORY: outer-port timing estimates WNS=$port_wns WHS=$port_whs; board/integration I/O timing is unverified"
