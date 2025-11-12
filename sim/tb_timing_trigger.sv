`timescale 1ns/1ps
// Vector driver only: all expected behavior comes from the Python time table.
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
    timing_trigger #(.TIME_W(TIME_W), .REPEAT_W(REPEAT_W), .COUNT_W(COUNT_W)) dut (.*);
    integer fd, rc, row;
    reg [3:0] expected_pulse;
    reg expected_busy, expected_armed, expected_done, expected_aborted;
    reg expected_error, expected_valid;
    reg [COUNT_W-1:0] expected_count;
    reg [1023:0] context_name;
    initial begin
        row = 0;
        fd = $fopen("vectors.txt", "r");
        if (!fd) $fatal(1, "Cannot open vectors.txt");
        while (!$feof(fd)) begin
            @(negedge clk);
            rc = $fscanf(fd, "%h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %h %s\n",
                         rst, command, trigger, cfg_enable, cfg_delay, cfg_width,
                         cfg_period, cfg_repeats, expected_pulse, expected_busy,
                         expected_armed, expected_done, expected_aborted,
                         expected_error, expected_valid, expected_count, context_name);
            if (rc != 17) $fatal(1, "Malformed vector row %0d", row);
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
