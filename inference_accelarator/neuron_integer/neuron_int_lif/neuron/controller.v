`timescale 1ns/100ps

// Controller Working methodology
// 1. The controller is in the `MODE_SELECT` state, waiting for a command to be loaded.
// 2. When a command is received, the controller checks if it is a `WORK_MODE` or any other command.
// 3. If it is a `WORK_MODE`, the controller sets the all three components for appropriate working mode.
// 4. If it is any other command, the controller sets the init modes as per the command and sets the `buffer_mode` to `BUFFER_ADDRESS` or `BUFFER_VALUE` accordingly.
// 5. The controller then enters the `MODE_BUFFER` state, where it waits for the data to be loaded into the buffer.
// 6. Once the buffer is filled, it processes the data based on the `buffer_mode` and sets the `address` and `value` accordingly.
// 7. Finally, the controller returns to the `MODE_SELECT` state, ready for the next command.
// 8. The controller also handles the `END_PACKET` command, to set load signal to give signal to register to load the data.


module controller(
    input wire load_data,
    input wire [7:0] data,
    input wire clk, rst,
    output reg load,
    output reg adder_load,
    output reg [31:0] value,
    output reg [2:0] decay_mode,
    output reg [1:0] reset_mode
);

    reg [1:0] controller_status;
    reg [7:0] buffer [2:0];
    reg [1:0] buffer_status;

    wire [1:0] reset_mode_data;
    wire [3:0] work_mode_data;
    assign reset_mode_data = data[7:6];
    assign work_mode_data = data[3:0];

    always @(posedge clk) begin
        if (rst) begin
            load <= 0;
            value <= 0;
            decay_mode <= `IDLE;
            controller_status <= `MODE_SELECT;
            reset_mode <= `NO_RESET;
            buffer[0] <= 0;
            buffer[1] <= 0;
            buffer[2] <= 0;
            adder_load <= 0;
            buffer_status <= 0;
        end else if (load_data) begin
            case (controller_status)
                `MODE_SELECT: begin
                    if(data == `END_PACKET) begin
                        load <= 1;
                        controller_status <= `MODE_SELECT;
                    end else begin
                        load <= 0;
                        value <= 0;
                        if (data == `WORK_MODE) begin
                            controller_status <= `WORK_MODE_SELECT;
                            decay_mode <= `IDLE; 
                            adder_load <= 0;
                        end else begin
                            controller_status <= `MODE_BUFFER;
                            if (data == `DECAY_INIT) begin
                                decay_mode <= `INIT;
                                adder_load <= 0;
                            end else if (data == `ADDER_VT_INIT) begin
                                adder_load <= 1;
                                decay_mode <= `IDLE;
                            end
                        end
                    end
                end
                `MODE_BUFFER: begin
                    if(buffer_status == 3) begin
                        value <= {data, buffer[2], buffer[1], buffer[0]};
                        controller_status <= `MODE_SELECT;
                        buffer_status <= 0;
                    end else begin
                        buffer[buffer_status] <= data;
                        buffer_status <= buffer_status + 1;
                    end
                end
                `WORK_MODE_SELECT: begin
                    case (work_mode_data)
                        `LIF2_MODE: begin
                            decay_mode <= `LIF2;
                            reset_mode <= 0; // Reset mode for LIF2
                        end
                        `LIF4_MODE: begin
                            decay_mode <= `LIF4;
                            reset_mode <= 1; // Reset mode for LIF4
                        end
                        `LIF8_MODE: begin
                            decay_mode <= `LIF8;
                            reset_mode <= 2; // Reset mode for LIF8
                        end
                        `LIF24_MODE: begin
                            decay_mode <= `LIF24;
                            reset_mode <= 3; // Reset mode for LIF24
                        end
                        default: begin
                            decay_mode <= `IDLE;
                            reset_mode <= 0; // Default reset mode
                        end
                    endcase
                    reset_mode <= reset_mode_data;
                    controller_status <= `MODE_SELECT;
                end
                default: begin
                    controller_status <= `MODE_SELECT;
                end
            endcase
        end else begin
            load <= 0;
        end
    end

endmodule