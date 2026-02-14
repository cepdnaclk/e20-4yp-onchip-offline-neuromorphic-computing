`include "../../neuron_integer/neuron_int_all/utils/encording.v"
`include "../../neuron_integer/neuron_int_all/utils/multiplier_32bit.v"
`include "../../neuron_integer/neuron_int_all/neuron/neuron.v"
`include "../../neuron_integer/neuron_int_all/neuron/controller.v"
`include "../../neuron_integer/neuron_int_all/decay/potential_decay.v"
`include "../../neuron_integer/neuron_int_all/adder/potential_adder.v"
`include "../../neuron_integer/neuron_int_all/accumulator/accumulator.v"
`include "neuron_layer.v"

module neuron_bank_tb ();
    parameter NEURON_COUNT = 16;  // Parameterized neuron count
    
    reg clk, rst, time_step, load_data, chip_mode;
    reg [3:0] neuron_id;  // Sized based on neuron count
    reg [7:0] data;
    reg [32*NEURON_COUNT-1:0] weight_in;  // Sized based on neuron count
    wire [NEURON_COUNT-1:0] spikes_out;   // Sized based on neuron count
    wire neurons_done;

    neuron_layer #(
        .neuron_bank_size(NEURON_COUNT)  // Using parameter instead of fixed value
    ) neuron_layer_inst (
        .clk(clk),
        .rst(rst),
        .time_step(time_step),
        .neuron_id(neuron_id),
        .load_data(load_data),
        .chip_mode(chip_mode),
        .data(data),
        .weight_in(weight_in),
        .spikes_out(spikes_out),
        .neurons_done(neurons_done)
    );

    always #5 clk = ~clk;

    integer i;  // Declare the loop variable outside the initial block

    initial begin
        $dumpfile("neuron_bank_tb.vcd");
        $dumpvars(0, neuron_bank_tb);

        clk = 0;
        rst = 1;
        time_step = 0;
        load_data = 0;
        neuron_id = 0;
        data = 0;
        weight_in = 0;
        
        #10 rst = 0;

        #10 chip_mode = 1; // Set chip mode

        for (i = 0; i < NEURON_COUNT; i = i + 1) begin  // Using parameter
            #10 neuron_id = i; // neuron id
            data = `DECAY_INIT;
            load_data = 1;
            #10 load_data = 0;
            #10 data = 8'b00000000; // value lower part
            load_data = 1;
            #10 load_data = 0;
            #10 data = 8'b00000000; // value second part
            load_data = 1;
            #10 load_data = 0;
            #10 data = 8'b00000011; // value third part
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
            #10 data = 8'b00000000; // value lower part
            load_data = 1;
            #10 load_data = 0;
            #10 data = 8'b00000000; // value second part
            load_data = 1;
            #10 load_data = 0;
            #10 data = (8'b00001000 << (i % 3)); // value third part
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
            #10 data = `LIF2; // work mode
            load_data = 1;
            #10 load_data = 0;
        end

        #10 chip_mode = 0; // Set chip mode to 0

        #100

        // Input weights
        weight_in = 0;
        for (i = 0; i < NEURON_COUNT; i = i + 1) begin
            weight_in[i*32 +: 32] = (32'h0000F000 << (i % 4)); // Example weight
        end
        #10 load_data = 1;
        #10 load_data = 0;

        // Add some testing sequence after initialization
        #100;
        time_step = 1;
        #10 time_step = 0;
        
        // Monitor the outputs
        $monitor("At time %0t: spikes_out = %b, neurons_done = %b", $time, spikes_out, neurons_done);
        
        #1000 $finish;
    end

endmodule