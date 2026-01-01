
`define NEURON_INCLUDE 

`include "../utils/encording.v"
`include "../utils/multiplier_32bit.v"
`include "../utils/shifter_32bit.v"
`include "../decay/potential_decay.v"
`include "../adder/potential_adder.v"
`include "../accumulator/accumulator.v"
`include "controller.v"
`include "neuron.v"
`timescale 1ns/100ps

// Data input method
// 1. Load the data into the neuron module using the load_data signal
// 2. The data is 8 bits wide and can be used to set the address, value, or mode
// 3. The data is loaded into the appropriate register based on the current state of the controller
// 4. The controller will set the load signal to indicate that the data is ready to be processed
// 5. The data is then processed by the appropriate module (accumulator, potential decay, or adder) based on the current state of the controller
// 6. The output of the module is then used to update the state of the neuron module

// data order
// first flit will be mode selection
// second flit will be address lower half or value lower half
// third flit will be address upper half or value second part
// fourth flit will be value third part
// fifth flit will be value upper part
// sixth flit will be end of packet

// if we set work mode first flit will be `WORK_MODE`
// second flit will be work mode 

// structure of the data packet 
// 1. `DECAY_INIT` <DECAY_INIT><value lower part><value second part><value third part><value upper part><END_PACKET>
// 2. `ADDER_A_INIT` <ADDER_A_INIT><value lower part><value second part><value third part><value upper part><END_PACKET>
// 3. `ADDER_B_INIT` <ADDER_B_INIT><value lower part><value second part><value third part><value upper part><END_PACKET>
// 4. `ADDER_C_INIT` <ADDER_C_INIT><value lower part><value second part><value third part><value upper part><END_PACKET>
// 5. `ADDER_D_INIT` <ADDER_D_INIT><value lower part><value second part><value third part><value upper part><END_PACKET>
// 6. `ADDER_VT_INIT` <ADDER_VT_INIT><value lower part><value second part><value third part><value upper part><END_PACKET>
// 7. `ADDER_U_INIT` <ADDER_U_INIT><value lower part><value second part><value third part><value upper part><END_PACKET>
// 8. `WORK_MODE` <WORK_MODE><work mode>


module neuron_tb ();

    reg clk, rst, time_step, load_data, chip_mode;
    reg [7:0] data;
    reg [31:0] weight_in;
    wire spike, done;
    
    neuron neuron(
        .clk(clk),
        .rst(rst),
        .time_step(time_step),
        .chip_mode(chip_mode),
        .data(data),
        .load_data(load_data),
        .neuron_weight_in(weight_in),
        .spike(spike),
        .done(done)
    );

    always #5 clk = ~clk;

    initial begin
        $dumpfile("neuron_tb.vcd");
        $dumpvars(0, neuron_tb);

        clk = 0;
        rst = 0;
        time_step = 0;
        load_data = 0;
        data = 0;
        weight_in = 0;

        #10 rst = 1;
        #10 rst = 0;

        rst = 1;
        data = 0;
        #10 rst = 0;

        chip_mode = 1; // chip mode

        #10 data = `DECAY_INIT;
        load_data = 1;
        #10 data = 8'b00000000; // value lower part
        #10 data = 8'b00000000; // value second part
        #10 data = 8'b00111111; // value third part
        #10 data = 8'b11111111; // value upper part
        #10 data = `END_PACKET; // end of packet
        #10 load_data = 0;

        
        #10 data = `ADDER_A_INIT;
        load_data = 1;
        #10 data = 8'b00011110; // value lower part
        #10 data = 8'b00000101; // value second part
        #10 data = 8'b00000000; // value third part
        #10 data = 8'b00000000; // value upper part
        #10 data = `END_PACKET; // end of packet
        #10 load_data = 0;

        #10 data = `ADDER_B_INIT;
        load_data = 1;
        #10 data = 8'b00110011; // value lower part
        #10 data = 8'b00110011; // value second part
        #10 data = 8'b00000000; // value third part
        #10 load_data = 0;
        #10 data = 8'b00000000; // value upper part
        load_data = 1;
        #10 data = `END_PACKET; // end of packet
        #10 load_data = 0;

        #10 data = `ADDER_C_INIT;
        load_data = 1;
        #10 data = 8'b00000000; // value lower part
        #10 data = 8'b00000000; // value second part
        #10 data = 8'b10110110; // value third part
        #10 data = 8'b11111111; // value upper part
        #10 data = `END_PACKET; // end of packet
        #10 load_data = 0;

        #10 data = `ADDER_D_INIT;
        load_data = 1;
        #10 data = 8'b00000000; // value lower part
        #10 data = 8'b00000000; // value second part
        #10 data = 8'b00001000; // value third part
        #10 data = 8'b00000000; // value upper part
        #10 data = `END_PACKET; // end of packet
        #10 load_data = 0;

        #10 data = `ADDER_VT_INIT;
        load_data = 1;
        #10 data = 8'b00000000; // value lower part
        #10 data = 8'b00000000; // value second part
        #10 data = 8'b00001000; // value third part
        #10 data = 8'b00000000; // value upper part
        #10 data = `END_PACKET; // end of packet
        #10 load_data = 0;

        #10 data = `ADDER_U_INIT;
        load_data = 1;
        #10 data = 8'b00000000; // value lower part
        #10 data = 8'b00000000; // value second part
        #10 data = 8'b11110011; // value third part
        #10 data = 8'b11111111; // value upper part
        #10 data = `END_PACKET; // end of packet

        #10 data = `WORK_MODE;
        #10 data = `IZHI_MODE; // work mode
        #10 load_data = 0;

        #10 chip_mode = 0; // chip mode off

        #100;

        // give inputs
        weight_in = 32'h0001000;
        load_data = 1;
        #10 weight_in = 32'h0002000;
        #10 weight_in = 32'h0001000;
        #10 weight_in = 32'h0002000;
        #10 load_data = 0;

        // Time step
        #15 time_step = 1;
        #10 time_step = 0;

        #500

        // give inputs
        weight_in = 32'h0001000;
        load_data = 1;
        #10 weight_in = 32'h0002000;
        #10 weight_in = 32'h0001000;
        #10 weight_in = 32'h0002000;
        #10 load_data = 0;

        // Time step
        #15 time_step = 1;
        #10 time_step = 0;

        #500


        // give inputs
        weight_in = 32'h0001000;
        load_data = 1;
        #10 weight_in = 32'h0002000;
        #10 weight_in = 32'h0001000;
        #10 weight_in = 32'h0002000;
        #10 load_data = 0;

        // Time step
        #15 time_step = 1;
        #10 time_step = 0;

        #500


        // give inputs
        weight_in = 32'h0001000;
        load_data = 1;
        #10 weight_in = 32'h0002000;
        #10 weight_in = 32'h0001000;
        #10 weight_in = 32'h0002000;
        #10 load_data = 0;

        // Time step
        #15 time_step = 1;
        #10 time_step = 0;

        #500

        // give inputs
        weight_in = 32'h0001000;
        load_data = 1;
        #10 weight_in = 32'h0002000;
        #10 weight_in = 32'h0001000;
        #10 weight_in = 32'h0002000;
        #10 load_data = 0;

        // Time step
        #15 time_step = 1;
        #10 time_step = 0;

        #1000;

        #100;
        $finish;
    end

endmodule