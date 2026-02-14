`timescale 1ns/100ps

`ifdef NEURON_INCLUDE

`else
    `include "../utils/encording.v"
    `include "../decay/potential_decay.v"
    `include "../adder/potential_adder.v"
    `include "../accumulator/accumulator.v"
    `include "controller.v"
`endif

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
// 6. `ADDER_VT_INIT` <ADDER_VT_INIT><value lower part><value second part><value third part><value upper part><END_PACKET>
// 8. `WORK_MODE` <WORK_MODE><1:0|reset_mode, 3:0|work_mode>

module neuron (
    input wire clk, rst, time_step, chip_mode,
    input wire [7:0] data,
    input wire load_data,
    input wire [31:0] neuron_weight_in,
    input wire rst_potential,
    output wire spike,
    output wire done
);
    wire load;
    wire [9:0] address;
    wire [31:0] value;
    wire [2:0] decay_mode;
    wire [1:0] reset_mode;

    wire [31:0] new_potential, final_potential;
    wire [31:0] output_potential_decay;
    wire [31:0] accumulated_out;
    wire [31:0] input_weight; 
    wire [31:0] decayed_potential;
    wire acc_load, adder_load, adder_done, decay_load, adder_load_en;
    wire [31:0] weight_in;

    controller controller (
        .load_data(load_data),
        .data(data),
        .clk(clk),
        .rst(rst),
        .load(load),
        .adder_load(adder_load_en),
        .value(value),
        .decay_mode(decay_mode),
        .reset_mode(reset_mode)
    );

    accumulator acc (
        .clk(clk),
        .rst(rst),
        .time_step(time_step),
        .load(acc_load),
        .weight_in(weight_in),
        .accumulated_out(accumulated_out)
    );

    potential_decay decay (
        .clk(clk),
        .rst(rst),
        .load(decay_load),
        .time_step(time_step),
        .rst_potential(rst_potential),
        .mode(decay_mode),
        .new_potential(new_potential),
        .output_potential_decay(output_potential_decay)
    );

    potential_adder adder (
        .clk(clk),
        .rst(rst),
        .time_step(time_step),
        .load(adder_load),
        .input_weight(input_weight),
        .reset_mode(reset_mode),
        .decayed_potential(decayed_potential),
        .final_potential(final_potential),
        .done(adder_done),
        .spike(spike)
    );

    assign acc_load = chip_mode ? 0 : load_data;
    assign weight_in = neuron_weight_in;

    assign decay_load = (decay_mode == `INIT) ? load : chip_mode ? 0 : adder_done;
    assign new_potential = (decay_mode == `INIT) ? value : chip_mode ? 0 : final_potential;

    assign adder_load = chip_mode && adder_load_en ? load : 0;
    assign input_weight = chip_mode ? value : accumulated_out;
    assign decayed_potential = output_potential_decay;

    assign done = adder_done;

endmodule
