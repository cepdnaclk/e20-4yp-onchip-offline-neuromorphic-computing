`ifdef WEIGHT_RES
`else 
    `include "weight_memory.v"
    `include "../FIFO/fifo.v"
`endif

// initializing memory
// <address_1:8><address_2:8><weight_flit_count:8>{<weights_flits>...}

module weight_resolver #(
    parameter max_weight_rows = 2048,
    parameter buffer_depth = 8,
    parameter neurons_per_cluster = 32
) (
    input clk,rst,
    // initialize weight memory
    input [7:0] data,
    input load_data,
    input chip_mode,

    // weight memory read
    input [4*$clog2(max_weight_rows)-1:0] buffer_addr_in,
    input [3:0] buffer_wr_en,
    output [4*($clog2(buffer_depth)+1)-1:0] buffer_count,
    output [4*32*neurons_per_cluster-1:0] weight_out,
    output [3:0] load_weight_out,
    output weight_resolver_done
);

    reg [15:0] weight_addr_init;
    reg [32*neurons_per_cluster-1:0] weight_in_mem;
    reg [1:0] state;
    reg [4*$clog2(neurons_per_cluster)-1:0] weight_flit_count, weight_flit_counter;
    reg load_weight_mem;

    wire [$clog2(max_weight_rows)-1:0] buffer_addr_out [3:0];
    wire [3:0] buffer_empty;
    wire [3:0] buffer_rd_en;
    wire [3:0] selected_buffer;
    reg [3:0] store_selected_buffer;

    wire [$clog2(max_weight_rows)-1:0] weight_addr_in_mem;
    wire [32*neurons_per_cluster-1:0] weight_out_mem;

    function integer onehot_to_index;
        input [3:0] onehot;
        integer idx;
        begin
            onehot_to_index = 0;
            if (|onehot == 0) begin
                onehot_to_index = -1; // no port selected
            end else begin
                // find the index of the onehot bit set
                for (idx = 0; idx <= 3; idx = idx + 1)
                    if (onehot[idx]) onehot_to_index = idx;
            end
        end
    endfunction

    weight_memory #(
        .max_weight_rows(max_weight_rows)
    ) weight_memory_inst (
        .clk(clk),
        .rst(rst),
        .weight_in(weight_in_mem),
        .load_weight(load_weight_mem),
        .weight_addr(weight_addr_in_mem),
        .weight_out(weight_out_mem)
    );

    genvar i;
    generate
        for (i = 0; i < 4; i = i + 1) begin : buffer_gen
            fifo #(
                .WIDTH($clog2(max_weight_rows)), // Width of the FIFO
                .DEPTH(8)
            ) buffer_inst (
                .clk(clk),
                .rst(rst),
                .wr_en(buffer_wr_en[i]),
                .din(buffer_addr_in[i*$clog2(max_weight_rows) +: $clog2(max_weight_rows)]), // Slice the address for each buffer
                .rd_en(buffer_rd_en[i]), // Read enable can be controlled externally
                .dout(buffer_addr_out[i]), // Output to the weight resolver
                .full(),
                .empty(buffer_empty[i]),
                .count(buffer_count[i*($clog2(buffer_depth)+1) +: ($clog2(buffer_depth)+1)]) // Count of items in the buffer
            );
        end
    endgenerate

    generate
        assign selected_buffer[0] = ~buffer_empty[0];
        for (i = 1; i < 4; i = i + 1) begin : select_buffer_gen
            assign selected_buffer[i] = ~buffer_empty[i] && &buffer_empty[i-1:0];
        end
    endgenerate

    assign buffer_rd_en = selected_buffer;

    assign weight_addr_in_mem = chip_mode ? weight_addr_init : |store_selected_buffer ? buffer_addr_out[onehot_to_index(store_selected_buffer)] : 0;

    assign weight_resolver_done = ~|selected_buffer && ~|store_selected_buffer;

   generate
        for (i = 0; i < 4; i = i + 1) begin : output_gen
            assign weight_out[i * 32 * neurons_per_cluster +: 32 * neurons_per_cluster] =
                (store_selected_buffer[i]) ? weight_out_mem : {32 * neurons_per_cluster{1'b0}};
            assign load_weight_out[i] = store_selected_buffer[i];
        end
    endgenerate

    always @(posedge clk) begin
        if (rst) begin
            weight_in_mem <= 0;
            store_selected_buffer <= 4'b0;
            state <= 0;
            load_weight_mem <= 0;
            weight_flit_counter <= 0;
            weight_flit_count <= 0;
            weight_addr_init <= 0;
        end else if(chip_mode && load_data) begin
            case (state)
                0: begin
                    weight_addr_init[7:0] <= data;
                    weight_flit_counter <= 0;
                    load_weight_mem <= 0;
                    weight_in_mem <= 0;
                    state <= 1;
                end 
                1: begin
                    weight_addr_init[15:8] <= data;
                    state <= 2;
                end
                2: begin
                    weight_flit_count <= data;
                    state <= 3;
                end
                3: begin
                    weight_in_mem[8*weight_flit_counter +: 8] <= data;
                    weight_flit_counter <= weight_flit_counter + 1;
                    if (weight_flit_counter == weight_flit_count - 1) begin
                        state <= 0;
                        load_weight_mem <= 1;
                    end
                end
                default: begin
                    state <= 0;
                    weight_in_mem <= 0;
                    weight_addr_init <= 0;
                    load_weight_mem <= 0;
                    weight_flit_counter <= 0;
                end
            endcase
        end else begin
            store_selected_buffer <= selected_buffer;
            load_weight_mem <= 0;
        end
    end
endmodule