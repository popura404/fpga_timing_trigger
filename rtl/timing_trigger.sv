`timescale 1ns/1ps
`default_nettype none
// All inputs are sampled in clk. The caller supplies one command per edge.
module timing_trigger #(
    parameter integer TIME_W = 32,
    parameter integer REPEAT_W = 16,
    parameter integer COUNT_W = 32
) (
    input  wire                     clk,
    input  wire                     rst,
    input  wire [2:0]               command,
    input  wire                     trigger,
    input  wire [3:0]               cfg_enable,
    input  wire [4*TIME_W-1:0]      cfg_delay,
    input  wire [4*TIME_W-1:0]      cfg_width,
    input  wire [TIME_W-1:0]        cfg_period,
    input  wire [REPEAT_W-1:0]      cfg_repeats,
    output reg  [3:0]               pulse,
    output wire                     busy,
    output wire                     armed,
    output reg                      done,
    output reg                      aborted,
    output reg                      command_error,
    output reg                      config_valid,
    output reg  [COUNT_W-1:0]       busy_trigger_count
);
    localparam [2:0] NOP = 0, COMMIT = 1, ARM = 2, CANCEL = 3, STOP = 4;
    localparam [1:0] IDLE = 0, ARMED = 1, RUN = 2;
    reg [1:0] state;
    reg [TIME_W-1:0] phase, last_phase;
    reg [REPEAT_W-1:0] repeats_active, repeats_left;
    reg [3:0] enable_active;
    reg [TIME_W-1:0] delay_active [0:3];
    reg [TIME_W-1:0] end_active [0:3];
    wire [TIME_W:0] cfg_end [0:3];
    wire [TIME_W-1:0] next_phase = phase + 1'b1;
    wire [3:0] cfg_lane_legal, first_pulse, next_pulse;
    wire cfg_legal = (cfg_period != 0 && cfg_repeats != 0) && (&cfg_lane_legal);
    integer i;

    assign busy = (state == RUN);
    assign armed = (state == ARMED);
    genvar ch;
    generate for (ch = 0; ch < 4; ch = ch + 1) begin : validate_end
        assign cfg_end[ch] = {1'b0, cfg_delay[ch*TIME_W +: TIME_W]}
                           + {1'b0, cfg_width[ch*TIME_W +: TIME_W]};
        assign cfg_lane_legal[ch] = !cfg_enable[ch] ||
                                   (cfg_width[ch*TIME_W +: TIME_W] != 0 &&
                                    cfg_end[ch] <= {1'b0, cfg_period});
        assign first_pulse[ch] = enable_active[ch] && (delay_active[ch] == 0);
        assign next_pulse[ch] = enable_active[ch] &&
                               (next_phase >= delay_active[ch]) && (next_phase < end_active[ch]);
    end endgenerate

    always @(posedge clk) begin
        if (rst) begin
            state <= IDLE;
            phase <= 0;
            last_phase <= 0;
            repeats_active <= 0;
            repeats_left <= 0;
            enable_active <= 0;
            for (i = 0; i < 4; i = i + 1) begin
                delay_active[i] <= 0;
                end_active[i] <= 0;
            end
            pulse <= 0;
            done <= 0;
            aborted <= 0;
            command_error <= 0;
            config_valid <= 0;
            busy_trigger_count <= 0;
        end else begin
            done <= 0;
            aborted <= 0;
            command_error <= 0;
            if (command == STOP) begin
                state <= IDLE;
                pulse <= 0;
                phase <= 0;
                repeats_left <= 0;
                aborted <= (state == RUN);
            end else begin
                // Command rejection never stalls the running schedule.
                case (command)
                    NOP: ;
                    COMMIT: begin
                        if (state == IDLE) begin
                            config_valid <= cfg_legal;
                            command_error <= !cfg_legal;
                            if (cfg_legal) begin
                                enable_active <= cfg_enable;
                                last_phase <= cfg_period - 1'b1;
                                repeats_active <= cfg_repeats;
                                for (i = 0; i < 4; i = i + 1) begin
                                    delay_active[i] <= cfg_delay[i*TIME_W +: TIME_W];
                                    end_active[i] <= cfg_end[i][TIME_W-1:0];
                                end
                            end
                        end else command_error <= 1;
                    end
                    ARM: begin
                        if (state == IDLE && config_valid) state <= ARMED;
                        else command_error <= 1;
                    end
                    CANCEL: begin
                        if (state == ARMED) state <= IDLE;
                        else command_error <= 1;
                    end
                    default: command_error <= 1;
                endcase

                if (state == ARMED && command != CANCEL && trigger) begin
                    state <= RUN;
                    phase <= 0;
                    repeats_left <= repeats_active;
                    pulse <= first_pulse;
                end else if (state == RUN) begin
                    if (trigger) busy_trigger_count <= busy_trigger_count + 1'b1;
                    if (phase == last_phase) begin
                        phase <= 0;
                        if (repeats_left == 1) begin
                            repeats_left <= 0;
                            state <= IDLE;
                            pulse <= 0;
                            done <= 1;
                        end else begin
                            repeats_left <= repeats_left - 1'b1;
                            pulse <= first_pulse;
                        end
                    end else begin
                        phase <= next_phase;
                        pulse <= next_pulse;
                    end
                end
            end
        end
    end
endmodule
`default_nettype wire
