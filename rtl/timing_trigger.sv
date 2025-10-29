`timescale 1ns/1ps
`default_nettype none
module timing_trigger #(
    parameter integer TIME_W = 32
) (
    input  wire              clk,
    input  wire              rst,
    input  wire              start,
    input  wire [TIME_W-1:0]  delay_cycles,
    input  wire [TIME_W-1:0]  width_cycles,
    input  wire [TIME_W-1:0]  period_cycles,
    output reg               pulse,
    output reg               busy,
    output reg               done
);
    reg [TIME_W-1:0] phase;
    reg [TIME_W-1:0] delay_active, end_active, last_phase;
    wire [TIME_W-1:0] next_phase = phase + 1'b1;

    always @(posedge clk) begin
        if (rst) begin
            phase <= 0;
            delay_active <= 0;
            end_active <= 0;
            last_phase <= 0;
            pulse <= 0;
            busy <= 0;
            done <= 0;
        end else begin
            done <= 0;
            if (!busy && start) begin
                delay_active <= delay_cycles;
                end_active <= delay_cycles + width_cycles;
                last_phase <= period_cycles - 1'b1;
                phase <= 0;
                pulse <= (delay_cycles == 0);
                busy <= 1;
            end else if (busy) begin
                if (phase == last_phase) begin
                    pulse <= 0;
                    busy <= 0;
                    done <= 1;
                end else begin
                    phase <= next_phase;
                    pulse <= (next_phase >= delay_active && next_phase < end_active);
                end
            end
        end
    end
endmodule
`default_nettype wire
