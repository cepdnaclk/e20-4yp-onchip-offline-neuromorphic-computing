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
    output reg [31:0] value,
    output reg [9:0] address,
    output reg [2:0] decay_mode,
    output reg [2:0] init_mode_adder,
    output reg [1:0] adder_model,
    output reg [1:0] reset_mode
);

    reg [1:0] controller_status;
    reg [7:0] buffer [2:0];
    reg [1:0] buffer_status;
    reg [1:0] buffer_mode;
    reg data_ready;

    wire [1:0] reset_mode_data;
    wire [3:0] work_mode_data;
    assign reset_mode_data = data[7:6];
    assign work_mode_data = data[3:0];

    always @(posedge clk) begin
        if (rst) begin
            load <= 0;
            address <= 0;
            value <= 0;
            decay_mode <= `IDLE;
            adder_model <= `NONE;
            init_mode_adder <= `IDLE;
            controller_status <= `MODE_SELECT;
            buffer[0] <= 0;
            buffer[1] <= 0;
            buffer[2] <= 0;
            buffer_status <= 0;
            buffer_mode <= `BUFFER_IDLE;
            reset_mode <= `NO_RESET;
        end else if (load_data) begin
            if (controller_status == `MODE_SELECT) begin
                if(data == `END_PACKET) begin
                    load <= 1;
                    controller_status <= `MODE_SELECT;
                end else begin
                    load <= 0;
                    address <= 0;
                    value <= 0;
                    if (data == `WORK_MODE) begin
                        controller_status <= `WORK_MODE_SELECT;
                    end else begin
                        controller_status <= `MODE_BUFFER;
                        if (data == `DECAY_INIT) begin
                            decay_mode <= `INIT;
                            adder_model <= `NONE;
                            init_mode_adder <= `IDLE;
                            buffer_mode <= `BUFFER_VALUE;
                        end else if (data == `ADDER_A_INIT) begin
                            init_mode_adder <= `A;
                            decay_mode <= `IDLE;
                            adder_model <= `NONE;
                            buffer_mode <= `BUFFER_VALUE;
                        end else if (data == `ADDER_B_INIT) begin
                            init_mode_adder <= `B;
                            decay_mode <= `IDLE;
                            adder_model <= `NONE;
                            buffer_mode <= `BUFFER_VALUE;
                        end else if (data == `ADDER_C_INIT) begin
                            init_mode_adder <= `C;
                            decay_mode <= `IDLE;
                            adder_model <= `NONE;
                            buffer_mode <= `BUFFER_VALUE;
                        end else if (data == `ADDER_D_INIT) begin
                            init_mode_adder <= `D;
                            decay_mode <= `IDLE;
                            adder_model <= `NONE;
                            buffer_mode <= `BUFFER_VALUE;
                        end else if (data == `ADDER_VT_INIT) begin
                            init_mode_adder <= `VT;
                            decay_mode <= `IDLE;
                            adder_model <= `NONE;
                            buffer_mode <= `BUFFER_VALUE;
                        end else if (data == `ADDER_U_INIT) begin
                            init_mode_adder <= `U;
                            decay_mode <= `IDLE;
                            adder_model <= `NONE;
                            buffer_mode <= `BUFFER_VALUE;
                        end 
                    end
                end
            end else if (controller_status == `MODE_BUFFER) begin
                buffer[buffer_status] <= data;
                buffer_status <= buffer_status + 1;
                if (buffer_mode == `BUFFER_ADDRESS) begin
                    if (buffer_status == `ADDRESS_DONE) begin
                        address <= {data[1:0], buffer[0][7:0]};
                        buffer_mode <= `BUFFER_VALUE;
                        buffer_status <= 0;
                    end
                end else if (buffer_mode == `BUFFER_VALUE) begin
                    if(buffer_status == `VALUE_DONE) begin
                        value <= {data, buffer[2], buffer[1], buffer[0]};
                        buffer_mode <= `BUFFER_IDLE;
                        controller_status <= `MODE_SELECT;
                        buffer_status <= 0;
                    end
                end
            end else if (controller_status == `WORK_MODE_SELECT) begin
                init_mode_adder <= `DEFAULT;
                if (work_mode_data == `LIF2_MODE) begin
                    decay_mode <= `LIF2;
                    adder_model <= `LIF;
                end else if (work_mode_data == `LIF4_MODE) begin
                    decay_mode <= `LIF4;
                    adder_model <= `LIF;
                end else if (work_mode_data == `LIF8_MODE) begin
                    decay_mode <= `LIF8;
                    adder_model <= `LIF;
                end else if (work_mode_data == `LIF24_MODE) begin
                    decay_mode <= `LIF24;
                    adder_model <= `LIF;
                end else if (work_mode_data == `IZHI_MODE) begin
                    decay_mode <= `IZHI;
                    adder_model <= `IZHI_AD;
                end else if (work_mode_data == `QUAD_MODE) begin
                    decay_mode <= `QUAD;
                    adder_model <= `QIF;
                end 
                reset_mode <= reset_mode_data;
            end
        end else begin
            load <= 0;
        end
    end

endmodule