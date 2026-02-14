`include "../utils/encording.v"
`include "controller.v"
`timescale 1ns/100ps

module controller_tb();
    reg clk, rst;
    reg [7:0] data;
    reg load_data;
    wire load;
    wire [31:0] value;
    wire [9:0] address;
    wire [2:0] decay_mode;
    wire [2:0] init_mode_adder;
    wire [1:0] adder_model;
    wire init_mode_acc;

    controller controller(
        .data(data),
        .clk(clk),
        .rst(rst),
        .load_data(load_data),
        .load(load),
        .value(value),
        .address(address),
        .decay_mode(decay_mode),
        .init_mode_adder(init_mode_adder),
        .adder_model(adder_model),
        .init_mode_acc(init_mode_acc)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("controller_tb.vcd");
        $dumpvars(0, controller_tb);

        clk = 0;
        rst = 1;
        data = 0;
        load_data = 0;
        #10 rst = 0;

        #10 data = `DECAY_INIT;
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000001; // value lower part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value second part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value third part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value upper part
        load_data = 1;
        #10 load_data = 0;
        #10 data = `END_PACKET; // end of packet
        load_data = 1;
        #10 load_data = 0;

        
        #10 data = `ADDER_A_INIT;
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000001; // value lower part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value second part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value third part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value upper part
        load_data = 1;
        #10 load_data = 0;
        #10 data = `END_PACKET; // end of packet
        load_data = 1;
        #10 load_data = 0;

        #10 data = `ADDER_B_INIT;
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000001; // value lower part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value second part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value third part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value upper part
        load_data = 1;
        #10 load_data = 0;
        #10 data = `END_PACKET; // end of packet
        load_data = 1;
        #10 load_data = 0;

        #10 data = `ADDER_C_INIT;
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000001; // value lower part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value second part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value third part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value upper part
        load_data = 1;
        #10 load_data = 0;
        #10 data = `END_PACKET; // end of packet
        load_data = 1;
        #10 load_data = 0;

        #10 data = `ADDER_D_INIT;
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000001; // value lower part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value second part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value third part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value upper part
        load_data = 1;
        #10 load_data = 0;
        #10 data = `END_PACKET; // end of packet
        load_data = 1;
        #10 load_data = 0;

        #10 data = `ADDER_VT_INIT;
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000001; // value lower part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value second part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value third part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value upper part
        load_data = 1;
        #10 load_data = 0;
        #10 data = `END_PACKET; // end of packet
        load_data = 1;
        #10 load_data = 0;

        #10 data = `ADDER_U_INIT;
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000001; // value lower part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value second part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value third part
        load_data = 1;
        #10 load_data = 0;
        #10 data = 8'b00000000; // value upper part
        load_data = 1;
        #10 load_data = 0;
        #10 data = `END_PACKET; // end of packet
        load_data = 1;
        #10 load_data = 0;

        #10 data = `WORK_MODE;
        load_data = 1;
        #10 load_data = 0;
        #10 data = `LIF2_MODE;
        load_data = 1;
        #10 load_data = 0;

        #100
        $finish;
    end

endmodule