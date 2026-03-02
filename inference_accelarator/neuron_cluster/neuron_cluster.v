`define NEURON_INCLUDE

`ifdef NEURON_CLUSTER
`else
    `include "../neuron_integer/neuron_int_all/utils/encording.v"
    `include "../neuron_integer/neuron_int_all/utils/multiplier_32bit.v"
    `include "../neuron_integer/neuron_int_all/utils/shifter_32bit.v"
    `include "../neuron_integer/neuron_int_all/decay/potential_decay.v"
    `include "../neuron_integer/neuron_int_all/adder/potential_adder.v"
    `include "../neuron_integer/neuron_int_all/accumulator/accumulator.v"
    `include "../neuron_integer/neuron_int_all/neuron/controller.v"
    `include "../neuron_integer/neuron_int_all/neuron/neuron.v"
    `include "./neuron_layer/neuron_layer.v"
    `include "./incoming_forwarder/incoming_forwarder.v"
    `include "./cluster_controller/cluster_controller.v"
    `include "./outgoing_enc/outgoing_enc.v"
    `include "../FIFO/fifo.v"
`endif

module neuron_cluster #(
    parameter packet_width = 11, 
    parameter cluster_id = 6'b000000,
    parameter number_of_clusters = 64,
    parameter neurons_per_cluster = 32,
    parameter incoming_weight_table_rows = 32,
    parameter max_weight_table_rows = 32,
    parameter address_buffer_depth = 8
)(
    input wire clk,
    input wire rst,
    input wire time_step,
    input wire chip_mode,
    input wire rst_potential,
    input wire [10:0] packet_in,
    output wire [10:0] packet_out,
    input wire fifo_empty,
    input wire fifo_full,
    output wire fifo_rd_en,
    output wire fifo_wr_en,
    output wire cluster_done,

    // ================= Dump Interface (Port B → Shared Memory) ================
    output wire [32*neurons_per_cluster-1:0] v_mem_out,      // V_mem for all neurons
    output wire [neurons_per_cluster-1:0]    spikes_out_raw,  // Raw spikes (pre-latch)
    output wire                              neurons_done_out, // High when all neurons computed V_mem

    // ================= Configuration Interface ================
    input wire load_data,  // Pulse to load configuration data
    input wire [7:0] data,  // Configuration data bus

    // ================= Weight Interface ================
    output wire [$clog2(max_weight_table_rows)-1:0] weight_address_out,
    output wire address_buffer_wr_en,
    input wire [32*neurons_per_cluster-1:0] weights_in,
    input wire load_weight_in,
    input wire [$clog2(address_buffer_depth)-1:0] address_buffer_count
);

    // ================ Internal Wires ================
    wire internal_clk;
    wire [neurons_per_cluster-1:0] spikes;
    wire spikes_done;
    wire incoming_forwarder_done;
    wire outgoing_enc_done;
    wire layer_load_data;

    // ================= Control wires ================
    wire [$clog2(neurons_per_cluster)-1:0] neuron_id;
    wire [7:0] neuron_data;
    wire neuron_load_data;
    wire [5:0] if_cluster_id;
    wire if_load_cluster_index;
    wire [15:0] if_base_weight_addr_init;
    wire if_load_addr_in;


    cluster_controller #(
        .number_of_clusters(number_of_clusters),
        .neurons_per_cluster(neurons_per_cluster),
        .max_weight_table_rows(max_weight_table_rows)
    ) controller (
        .clk(clk),
        .rst(rst),
        .load_data(load_data),
        .data(data),
        .internal_clk(internal_clk),
        .chip_mode(chip_mode),
        .neuron_id(neuron_id),
        .neuron_data(neuron_data),
        .neuron_load_data(neuron_load_data),
        .if_cluster_id(if_cluster_id),
        .if_load_cluster_index(if_load_cluster_index),
        .if_base_weight_addr_init(if_base_weight_addr_init),
        .if_load_addr_in(if_load_addr_in)
    );

    neuron_layer #(
        .neuron_bank_size(neurons_per_cluster)
    ) neuron_layer_inst (
        .clk(internal_clk),
        .rst(rst),
        .time_step(time_step),
        .chip_mode(chip_mode),
        .neuron_id(neuron_id),
        .load_data(layer_load_data),
        .data(neuron_data),
        .weight_in(weights_in),
        .rst_potential(rst_potential),
        .spikes_out(spikes),
        .neurons_done(spikes_done),
        .v_mem_out(v_mem_out)
    );

    incoming_forwarder #(
        .incoming_weight_table_rows(incoming_weight_table_rows),
        .max_weight_table_rows(max_weight_table_rows),
        .weight_address_buffer_depth(8)
    ) incoming_forwarder (
        .clk(internal_clk),
        .rst(rst),
        .packet(packet_in),
        .address_buffer_count(address_buffer_count),
        .weight_addr_out(weight_address_out),
        .address_buffer_wr_en(address_buffer_wr_en),
        .forwarder_done(incoming_forwarder_done),
        
        .forwarder_mode(chip_mode),
        .cluster_id(if_cluster_id),
        .load_cluster_index(if_load_cluster_index),
        .base_weight_addr(if_base_weight_addr_init),
        .load_addr_in(if_load_addr_in),

        .empty(fifo_empty),
        .rd_en(fifo_rd_en)
    );


    outgoing_enc #(
        .neurons_can_handle(neurons_per_cluster),
        .packet_width(packet_width),
        .cluster_id(cluster_id)
    ) outgoing_enc (
        .clk(internal_clk),
        .rst(rst),
        .spikes_done(spikes_done),
        .fifo_full(fifo_full),
        .spikes(spikes),
        .packet(packet_out),
        .wr_en(fifo_wr_en),
        .outgoing_enc_done(outgoing_enc_done)
    );


    assign layer_load_data = chip_mode ? neuron_load_data : load_weight_in;

    assign cluster_done = incoming_forwarder_done & outgoing_enc_done & spikes_done;

    // Raw spike output for dump (latched spikes_out already in neuron_layer)
    assign spikes_out_raw = spikes;

    // Fires as soon as all neurons finish computing for this timestep
    assign neurons_done_out = spikes_done;

endmodule