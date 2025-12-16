`timescale 1ns/1ps
// Expected behavior comes from Python absolute intervals. Three explicitly
// guarded white-box phase deposits test 32-bit endpoint arithmetic only.
module tb_timing_trigger #(
    parameter TIME_W = 32,
    parameter REPEAT_W = 16,
    parameter COUNT_W = 32
);
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst, trigger;
    reg [2:0] command;
    reg [3:0] cfg_enable;
    reg [4*TIME_W-1:0] cfg_delay, cfg_width;
    reg [TIME_W-1:0] cfg_period;
    reg [REPEAT_W-1:0] cfg_repeats;
    wire [3:0] pulse;
    wire busy, armed, done, aborted, command_error, config_valid;
    wire [COUNT_W-1:0] busy_trigger_count;
`ifdef FIXED_BASELINE
    fixed_top dut (
        .clk(clk), .rst(rst), .command(command), .trigger(trigger),
        .pulse(pulse), .busy(busy), .armed(armed), .done(done),
        .aborted(aborted), .command_error(command_error),
        .config_valid(config_valid), .busy_trigger_count(busy_trigger_count)
    );
`else
    timing_trigger #(.TIME_W(TIME_W), .REPEAT_W(REPEAT_W), .COUNT_W(COUNT_W)) dut (.*);
`endif
    integer fd, rc, row;
    reg [3:0] expected_pulse;
    reg expected_busy, expected_armed, expected_done, expected_aborted;
    reg expected_error, expected_valid;
    reg [COUNT_W-1:0] expected_count;
    reg [1023:0] context_name;
    reg phase_probe;
    reg [TIME_W-1:0] target_phase;
    initial begin
        row = 0;
        fd = $fopen("vectors.txt", "r");
        if (!fd) $fatal(1, "Cannot open vectors.txt");
        while (!$feof(fd)) begin
            @(negedge clk);
            rc = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %s\n",
                         rst, command, trigger, cfg_enable, cfg_delay, cfg_width,
                         cfg_period, cfg_repeats, expected_pulse, expected_busy,
                         expected_armed, expected_done, expected_aborted,
                         expected_error, expected_valid, expected_count, phase_probe, target_phase, context_name);
            if (rc != 19) $fatal(1, "Malformed vector row %0d", row);
            if (phase_probe) begin
`ifndef FIXED_BASELINE
                if (TIME_W != 32 || busy !== 1'b1 || rst || trigger || command != 0 ||
                    dut.repeats_left !== dut.repeats_active || dut.repeats_active != 1 ||
                    target_phase == 0 || target_phase > dut.last_phase ||
                    target_phase - 1'b1 <= dut.phase)
                    $fatal(1, "Invalid arithmetic probe row %0d %0s", row, context_name);
                // Next rising edge enters target_phase through normal RTL.
                dut.phase = target_phase - 1'b1;
`else
                $fatal(1, "Arithmetic probes are disabled for fixed baseline");
`endif
            end
            @(posedge clk); #1;
            if ({pulse, busy, armed, done, aborted, command_error, config_valid, busy_trigger_count}
                !== {expected_pulse, expected_busy, expected_armed, expected_done,
                     expected_aborted, expected_error, expected_valid, expected_count}) begin
                $display("row=%0d %0s cmd=%0d trigger=%b enable=%h D=%h W=%h P=%h R=%h",
                         row, context_name, command, trigger, cfg_enable, cfg_delay,
                         cfg_width, cfg_period, cfg_repeats);
                $display("got pulse/busy/armed/done/aborted/error/valid/count: %h %b %b %b %b %b %b %h",
                         pulse, busy, armed, done, aborted, command_error, config_valid, busy_trigger_count);
                $display("exp pulse/busy/armed/done/aborted/error/valid/count: %h %b %b %b %b %b %b %h",
                         expected_pulse, expected_busy, expected_armed, expected_done,
                         expected_aborted, expected_error, expected_valid, expected_count);
                $fatal(1, "Cycle comparison failed");
            end
            row = row + 1;
        end
        $display("PASS: %0d cycle comparisons TIME_W=%0d REPEAT_W=%0d COUNT_W=%0d",
                 row, TIME_W, REPEAT_W, COUNT_W);
        $fclose(fd);
        $finish;
    end
endmodule
