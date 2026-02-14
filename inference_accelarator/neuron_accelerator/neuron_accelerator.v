`ifdef NEURON_ACCELERATOR
`else    
    `define NEURON_INCLUDE
    `define NEURON_CLUSTER
    `define SPIKE_FORWARDER_4
    `define SPIKE_FORWARDER_8
    `define SPIKE_FORWARDER
    `define WEIGHT_RES

    `include "../neuron_integer/neuron_int_lif/utils/encording.v"
    // `include "../neuron_integer/neuron_int_lif/utils/multiplier_32bit.v"
    `include "../neuron_integer/neuron_int_lif/decay/potential_decay.v"
    `include "../neuron_integer/neuron_int_lif/adder/potential_adder.v"
    `include "../neuron_integer/neuron_int_lif/accumulator/accumulator.v"
    `include "../neuron_integer/neuron_int_lif/neuron/controller.v"
    `include "../neuron_integer/neuron_int_lif/neuron/neuron.v"
    `include "../neuron_cluster/neuron_layer/neuron_layer.v"
    `include "../neuron_cluster/incoming_forwarder/incoming_forwarder.v"
    `include "../neuron_cluster/cluster_controller/cluster_controller.v"
    `include "../neuron_cluster/outgoing_enc/outgoing_enc.v"
    `include "../FIFO/fifo.v"

    `include "../neuron_cluster/neuron_cluster.v"
    `include "../spike_network/spike_forwarder/spike_forwarder.v"
    `include "../spike_network/spike_forwarder_controller/spike_forwarder_controller_4.v"
    `include "../spike_network/spike_forwarder_controller/spike_forwarder_controller_8.v"
    `include "../spike_network/spike_forwarder_4.v"
    `include "../spike_network/spike_forwarder_8.v"

    `include "../initialization_router/init_router.v"
    `include "../initialization_router/self_data_mng.v"

    `include "../weight_resolver/weight_resolver.v"
    `include "../weight_resolver/weight_memory.v"
`endif


module neuron_accelerator #(
    parameter packet_width = 11, 
    parameter main_fifo_depth = 32,
    parameter forwarder_8_fifo_depth = 16,
    parameter forwarder_4_fifo_depth = 8,
    parameter number_of_clusters = 64,
    parameter neurons_per_cluster = 32,
    parameter incoming_weight_table_rows = 32,
    parameter max_weight_table_rows = 32,
    parameter flit_size = 8,
    parameter cluster_group_count = 2
)(
    // ================== Clock and Reset ================
    input wire clk,  // System clock
    input wire rst,  // System reset
    input wire network_mode,  // Network mode (0: spike, 1: general)
    input wire time_step,  // Time step signal for the network
    input wire rst_potential,

    // ================= Configuration Interface ================
    input wire load_data_in,  // Pulse to load configuration data
    input wire [7:0] data_in,  // Configuration data bus
    output wire ready_in,  // Data output valid signal

    output wire [7:0] data_out,  // Configuration data output
    output wire load_data_out,  // Pulse to load configuration data
    input wire ready_out,  // Data output valid signal
    output wire data_out_done,  // Signal indicating that data output is done

    // ================== Spike Network Interface ================
    // Main FIFO In Interface
    input wire [packet_width-1:0] main_fifo_din_in,  // Spike input from the network
    input wire main_fifo_wr_en_in,  // Write enable for the main FIFO
    output wire main_fifo_full_in,  // Main FIFO full signal

    // Main FIFO Out Interface
    input wire main_fifo_rd_en_out,  // Read enable for the main FIFO
    output wire main_fifo_empty_out,  // Main FIFO empty signal
    output wire [packet_width-1:0] main_fifo_dout_out,  // Spike output to the network

    // accelerator done
    output wire accelerator_done
);

    // ================== Parameters ================
    localparam forwarder_8_count_width = $clog2(forwarder_8_fifo_depth)+1;  // Width for forwarder 8 FIFO count
    localparam forwarder_4_count_width = $clog2(forwarder_4_fifo_depth)+1;  // Width for forwarder 4 FIFO count
    localparam main_fifo_count_width = $clog2(main_fifo_depth)+1;  // Width for main FIFO count

    // ================== Main FIFO Interface ================
    wire main_fifo_empty_in;  // Main FIFO empty signal
    wire main_fifo_rd_en_in;  // Read enable for the spike forwarder
    wire [packet_width-1:0] main_fifo_dout_in;  // Spike input to the main FIFO
    wire [main_fifo_count_width-1:0] main_fifo_count_in;  // Count of elements in the main FIFO
    wire main_fifo_wr_en_out;  // Write enable for the main FIFO
    wire main_fifo_full_out;  // Main FIFO full signal
    wire [packet_width-1:0] main_fifo_din_out;  // Spike output from the main FIFO
    wire [main_fifo_count_width-1:0] main_fifo_count_out;  // count of elements in the main FIFO

    // ================== Spike Forwarder 8 ================
    wire [7:0] forwarder_8_fifo_rd_en_out;
    wire [7:0] forwarder_8_fifo_wr_en_in;
    wire [8*packet_width-1:0] forwarder_8_fifo_in_data_in;
    wire [8*packet_width-1:0] forwarder_8_fifo_out_data_out;
    wire [7:0] forwarder_8_fifo_full_in;
    wire [7:0] forwarder_8_fifo_empty_out;
    wire [8*forwarder_8_count_width-1:0] forwarder_8_fifo_count_in;
    // Spike Forwarder 8 Interface
    wire [flit_size-1:0] data_in_forwarder_8; // Data input for the spike forwarder 8
    wire load_data_forwarder_8; // Load data signal for the spike forwarder 8
    // done

    // ================== Upper Layer Router ================
    wire [7:0] load_data_lower_in;  // Load data signal for the lower layer router
    wire [8*flit_size-1:0] data_lower_in;  // Data input for the lower layer router
    wire [7:0] load_data_lower_out;  // Load data signal for the lower layer router
    wire [8*flit_size-1:0] data_lower_out;  // Data output for the lower layer router
    wire [7:0] ready_data_lower_in;  // Ready signal for the lower layer router
    wire [7:0] ready_data_lower_out;  // Ready signal for the lower layer router

    // done signals
    wire [7:0] cluster_4_done;
    wire all_clusters_done;
    wire [7:0] forwarder_4_done;
    wire all_forwarders_done;
    wire forwarder_8_done;
    wire [7:0] weight_resolver_done;
    wire resolvers_done;

    wire [7:0] done_mask = (8'b11111111 << cluster_group_count);  // Mask for done signals

    // signal gen
    assign all_clusters_done = &(cluster_4_done | done_mask);
    assign all_forwarders_done = &(forwarder_4_done | done_mask) && forwarder_8_done;
    assign resolvers_done = &(weight_resolver_done | done_mask);
    assign accelerator_done = all_clusters_done & all_forwarders_done & main_fifo_empty_in & main_fifo_empty_out & resolvers_done;

    // ================== Main Spike In FIFO ================
    fifo #(
        .WIDTH(packet_width),
        .DEPTH(main_fifo_depth)
    ) main_fifo_in (
        .clk(clk),
        .rst(rst),
        .wr_en(main_fifo_wr_en_in),
        .rd_en(main_fifo_rd_en_in),
        .din(main_fifo_din_in),
        .dout(main_fifo_dout_in),
        .full(main_fifo_full_in),
        .empty(main_fifo_empty_in),
        .count(main_fifo_count_in)
    );

    // ================== Main Spike Out FIFO ================
    fifo #(
        .WIDTH(packet_width),
        .DEPTH(main_fifo_depth)
    ) main_fifo_out (
        .clk(clk),
        .rst(rst),
        .wr_en(main_fifo_wr_en_out),
        .rd_en(main_fifo_rd_en_out),
        .din(main_fifo_din_out),
        .dout(main_fifo_dout_out),
        .full(main_fifo_full_out),
        .empty(main_fifo_empty_out),
        .count(main_fifo_count_out)
    );

    // ================== Main Spike Forwarder ================
    spike_forwarder_8 #(
        .data_width(packet_width),
        .fifo_depth(forwarder_8_fifo_depth), 
        .main_fifo_depth(main_fifo_depth)
    ) spike_forwarder (
        .clk(clk),
        .rst(rst),

        // Main FIFO Interface
        .main_out_data_out(main_fifo_dout_in),
        .main_in_data_in(main_fifo_din_out),
        .main_fifo_full_in(main_fifo_full_out),
        .main_fifo_empty_out(main_fifo_empty_in),
        .main_fifo_count_in(main_fifo_count_out),
        .main_fifo_rd_en_out(main_fifo_rd_en_in),
        .main_fifo_wr_en_in(main_fifo_wr_en_out),

        // Ports Interface
        .fifo_rd_en_out(forwarder_8_fifo_rd_en_out),
        .fifo_wr_en_in(forwarder_8_fifo_wr_en_in),
        .fifo_in_data_in(forwarder_8_fifo_in_data_in),
        .fifo_out_data_out(forwarder_8_fifo_out_data_out),
        .fifo_full_in(forwarder_8_fifo_full_in),
        .fifo_empty_out(forwarder_8_fifo_empty_out),
        .fifo_count_in(forwarder_8_fifo_count_in),

        // Other Ports
        .router_mode(network_mode),
        .load_data(load_data_forwarder_8),
        .data_in(data_in_forwarder_8),

        // done
        .done(forwarder_8_done)
    );

    // ================== Main router ======================
    init_router #(
        .PORTS(8),
        .FLIT_SIZE(flit_size),
        .ROUTER_ID(8'b10100000),
        .ROUTER_TYPE(1),
        .LOWER_LEVEL_ROUTERS(4)
    ) init_router_upper (
        .clk(clk),
        .rst(rst),

        // Top side
        .load_data_top_in(load_data_in),
        .ready_data_top_in(ready_in),
        .data_top_in(data_in),
        
        .load_data_top_out(load_data_out),
        .ready_data_top_out(ready_out),
        .data_top_out(data_out),
        .data_out_done(data_out_done),

        // Lower side
        .load_data_lower_in(load_data_lower_in),
        .ready_data_lower_in(ready_data_lower_in),
        .data_lower_in(data_lower_in),
        
        .load_data_lower_out(load_data_lower_out),
        .ready_data_lower_out(ready_data_lower_out),
        .data_lower_out(data_lower_out),

        // this router
        .load_data(load_data_forwarder_8),
        .ready_data(1'b1),
        .data(data_in_forwarder_8)
    );

    // ================== Spike Forwarders 4 ================
    genvar i, j;
    generate
        for (i = 0; i < cluster_group_count; i = i + 1) begin : gen_spike_forwarder_4
            wire [3:0] forwarder_4_fifo_rd_en_out;
            wire [3:0] forwarder_4_fifo_wr_en_in;
            wire [4*packet_width-1:0] forwarder_4_fifo_in_data_in;
            wire [4*packet_width-1:0] forwarder_4_fifo_out_data_out;
            wire [3:0] forwarder_4_fifo_full_in;
            wire [3:0] forwarder_4_fifo_empty_out;
            wire [4*forwarder_4_count_width-1:0] forwarder_4_fifo_count_in;

            // Cluster wires data
            wire [3:0] load_data_cluster_in;  // Load data signal for the lower layer router
            wire [4*flit_size-1:0] data_cluster_in;  // Data input for the lower layer router
            wire [3:0] load_data_cluster_out;  // Load data signal for the lower layer router
            wire [4*flit_size-1:0] data_cluster_out;  // Data output for the lower layer router
            wire [3:0] ready_data_cluster_in;  // Ready signal for the lower layer router
            wire [3:0] ready_data_cluster_out;  // Ready signal for the lower layer router

            // self data management
            wire [7:0] data_out_router_4;
            wire load_data_out_router_4;
            wire [7:0] data_in_forwarder_4;
            wire load_data_forwarder_4;
            wire [7:0] data_in_resolver_4;
            wire load_data_resolver_4;

            // weight resolver wires
            wire [4*$clog2(max_weight_table_rows)-1:0] resolver_buffer_addr_in;
            wire [3:0] resolver_buffer_wr_en;
            wire [4*($clog2(forwarder_4_fifo_depth)+1)-1:0] resolver_buffer_count;
            wire [4*32*neurons_per_cluster-1:0] resolver_weight_out;
            wire [3:0] resolver_load_weight_out;

            // cluster done
            wire [3:0] cluster_done;

            // signal gen
            assign cluster_4_done[i] = &cluster_done;

            // Lower Router
            init_router #(
                .PORTS(4),
                .FLIT_SIZE(flit_size),
                .ROUTER_ID((i * 4) + 8'b10000000),
                .ROUTER_TYPE(0),
                .LOWER_LEVEL_ROUTERS(4)
            ) init_router_lower (
                .clk(clk),
                .rst(rst),

                // Top side
                .load_data_top_in(load_data_lower_out[i]),
                .ready_data_top_in(ready_data_lower_out[i]),
                .data_top_in(data_lower_out[i*flit_size +: flit_size]),

                .load_data_top_out(load_data_lower_in[i]),
                .ready_data_top_out(ready_data_lower_in[i]),
                .data_top_out(data_lower_in[i*flit_size +: flit_size]),

                // Lower side
                .load_data_lower_in(load_data_cluster_out),
                .ready_data_lower_in(ready_data_cluster_out),
                .data_lower_in(data_cluster_out),

                .load_data_lower_out(load_data_cluster_in),
                .ready_data_lower_out(ready_data_cluster_in | 4'b1111),
                .data_lower_out(data_cluster_in),

                // this router
                .load_data(load_data_out_router_4),
                .ready_data(1'b1),
                .data(data_out_router_4)
            );

            spike_forwarder_4 #(
                .data_width(packet_width),
                .fifo_depth(forwarder_4_fifo_depth),
                .main_fifo_depth(forwarder_8_fifo_depth)
            ) spike_forwarder_4_inst (
                .clk(clk),
                .rst(rst),

                // Main FIFO Interface
                .main_out_data_out(forwarder_8_fifo_out_data_out[i*packet_width +: packet_width]),
                .main_in_data_in(forwarder_8_fifo_in_data_in[i*packet_width +: packet_width]),
                .main_fifo_full_in(forwarder_8_fifo_full_in[i]),
                .main_fifo_empty_out(forwarder_8_fifo_empty_out[i]),
                .main_fifo_count_in(forwarder_8_fifo_count_in[i*forwarder_8_count_width +: forwarder_8_count_width]),
                .main_fifo_rd_en_out(forwarder_8_fifo_rd_en_out[i]),
                .main_fifo_wr_en_in(forwarder_8_fifo_wr_en_in[i]),

                // Ports Interface
                .fifo_rd_en_out(forwarder_4_fifo_rd_en_out),
                .fifo_wr_en_in(forwarder_4_fifo_wr_en_in),
                .fifo_in_data_in(forwarder_4_fifo_in_data_in),
                .fifo_out_data_out(forwarder_4_fifo_out_data_out),
                .fifo_full_in(forwarder_4_fifo_full_in),
                .fifo_empty_out(forwarder_4_fifo_empty_out),
                .fifo_count_in(forwarder_4_fifo_count_in),

                // Other Ports
                .router_mode(network_mode),
                .load_data(load_data_forwarder_4),
                .data_in(data_in_forwarder_4),

                // done
                .done(forwarder_4_done[i])
            );

            // Self Data Management for Forwarder 4
            self_data_mng self_data_mng_forwarder_4 (
                .clk(clk),
                .rst(rst),
                .data_in(data_out_router_4),
                .load_data_in(load_data_out_router_4),
                .data_out_forwarder(data_in_forwarder_4),
                .data_out_resolver(data_in_resolver_4),
                .load_data_out_forwarder(load_data_forwarder_4),
                .load_data_out_resolver(load_data_resolver_4)
            );

            // Instantiate weight resolver
            weight_resolver #(
                .max_weight_rows(max_weight_table_rows),
                .buffer_depth(forwarder_4_fifo_depth),
                .neurons_per_cluster(neurons_per_cluster)
            ) weight_resolver_inst (
                .clk(clk),
                .rst(rst),
                // initialize weight memory
                .data(data_in_resolver_4),
                .load_data(load_data_resolver_4),
                .chip_mode(network_mode),

                // weight memory read
                .buffer_addr_in(resolver_buffer_addr_in),
                .buffer_wr_en(resolver_buffer_wr_en),
                .buffer_count(resolver_buffer_count),
                .weight_out(resolver_weight_out),
                .load_weight_out(resolver_load_weight_out),
                .weight_resolver_done(weight_resolver_done[i])
            );

            for (j = 0; j < 4; j = j + 1) begin : gen_neuron_cluster
                // Cluster ID
                localparam [7:0] cluster_id_bin = i*4 + j; 
            
                // Instantiate neuron cluster
                neuron_cluster #(
                    .packet_width(packet_width), 
                    .cluster_id(cluster_id_bin),
                    .number_of_clusters(number_of_clusters),
                    .neurons_per_cluster(neurons_per_cluster),
                    .incoming_weight_table_rows(incoming_weight_table_rows),
                    .max_weight_table_rows(max_weight_table_rows)
                ) neuron_cluster_inst (
                    .clk(clk),
                    .rst(rst),
                    .time_step(time_step),
                    .rst_potential(rst_potential),
                    .chip_mode(network_mode),
                    .packet_in(forwarder_4_fifo_out_data_out[j*packet_width +: packet_width]),
                    .packet_out(forwarder_4_fifo_in_data_in[j*packet_width +: packet_width]),
                    .fifo_empty(forwarder_4_fifo_empty_out[j]),
                    .fifo_full(forwarder_4_fifo_full_in[j]),
                    .fifo_rd_en(forwarder_4_fifo_rd_en_out[j]),
                    .fifo_wr_en(forwarder_4_fifo_wr_en_in[j]),

                    // Configuration Interface
                    .load_data(load_data_cluster_in[j]),  
                    .data(data_cluster_in[j*flit_size +: flit_size]),

                    // weight resolver
                    .weight_address_out(resolver_buffer_addr_in[j*$clog2(max_weight_table_rows) +: $clog2(max_weight_table_rows)]),
                    .address_buffer_wr_en(resolver_buffer_wr_en[j]),
                    .weights_in(resolver_weight_out[j*32*neurons_per_cluster +: 32*neurons_per_cluster]),
                    .load_weight_in(resolver_load_weight_out[j]),
                    .address_buffer_count(
                        resolver_buffer_count[j*($clog2(forwarder_4_fifo_depth)) +: ($clog2(forwarder_4_fifo_depth))]
                    ),

                    // cluster done
                    .cluster_done(cluster_done[j])
                );
            end
        end
    endgenerate
endmodule