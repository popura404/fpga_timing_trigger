`timescale 1ns/1ps
module tb_timing_trigger;
    reg clk = 0;
    always #5 clk = ~clk;
    reg rst, start;
    reg [31:0] delay_cycles, width_cycles, period_cycles;
    wire pulse, busy, done;
    timing_trigger dut (.*);
    integer fd, rc, row;
    reg ep, eb, ed;
    initial begin
        row = 0;
        fd = $fopen("vectors.txt", "r");
        if (!fd) $fatal(1, "Cannot open vectors.txt");
        while (!$feof(fd)) begin
            @(negedge clk);
            rc = $fscanf(fd, "%d %d %d %d %d %d %d %d\n",
                         rst, start, delay_cycles, width_cycles, period_cycles, ep, eb, ed);
            if (rc != 8) $fatal(1, "Malformed vector row %0d", row);
            @(posedge clk); #1;
            if ({pulse,busy,done} !== {ep,eb,ed})
                $fatal(1, "row %0d: got %b%b%b expected %b%b%b", row, pulse,busy,done,ep,eb,ed);
            row = row + 1;
        end
        $display("PASS: %0d cycle comparisons", row);
        $fclose(fd);
        $finish;
    end
endmodule
