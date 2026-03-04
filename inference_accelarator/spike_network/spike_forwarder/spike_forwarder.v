`ifdef SPIKE_FORWARDER
`else
`include "../../FIFO/fifo.v"
`endif

module spike_forwarder
#(
    parameter num_ports = 4,
    parameter data_width = 11,
    parameter fifo_depth = 8,
    parameter main_fifo_depth = 16
)
(
    input wire clk,
    input wire rst,
    input wire [num_ports-1:0] fifo_rd_en_out,
    input wire [num_ports-1:0] fifo_wr_en_in,
    input wire [num_ports*data_width-1:0] fifo_in_data_in,
    output wire [num_ports*data_width-1:0] fifo_out_data_out,
    output wire [num_ports-1:0] fifo_full_in,
    output wire [num_ports-1:0] fifo_empty_out,
    output wire [num_ports*($clog2(fifo_depth)+1)-1:0] fifo_count_in,

    // main port
    input wire [data_width-1:0] main_out_data_out,
    output reg [data_width-1:0] main_in_data_in,
    input wire main_fifo_full_in,
    input wire main_fifo_empty_out,
    input wire [$clog2(main_fifo_depth):0] main_fifo_count_in,
    output wire main_fifo_rd_en_out,
    output reg main_fifo_wr_en_in,

    // other ports
    input wire router_mode,
    input wire load_row,
    input wire [$clog2(num_ports):0] row_index,
    input wire [num_ports:0] forwarding_row,

    // done
    output wire done
);

    wire [num_ports-1:0] fifo_rd_en_in;
    reg [num_ports-1:0] fifo_wr_en_out;
    wire [num_ports*data_width-1:0] fifo_out_data_in;
    reg [num_ports*data_width-1:0] fifo_in_data_out;
    wire [num_ports-1:0] fifo_full_out;
    wire [num_ports-1:0] fifo_empty_in;
    wire [$clog2(fifo_depth):0] fifo_count_out [num_ports-1:0];

    // internal regs
    reg [num_ports:0] forwarding_map [num_ports:0];
    reg signed [$clog2(num_ports)+1:0] store_selected_port;
    reg signed [$clog2(num_ports)+1:0] forwarded_port;
    reg [1:0] inflight_count [num_ports:0];
    
    // FIXED: Add registered version of inflight_count to break combinational loop
    reg [1:0] inflight_count_reg [num_ports:0];

    wire [num_ports:0] fifo_space_available;
    wire [num_ports:0] eligible;
    wire [num_ports:0] selected_port;

    // FIXED: Add consistent selected port index
    wire signed [$clog2(num_ports):0] current_selected_port_index;

    wire [num_ports:0] zero_inflight_count;
    wire zero_inflight;

    function integer onehot_to_index;
        input [num_ports:0] onehot;
        integer idx;
        begin
            onehot_to_index = 0;
            if (|onehot == 0) begin
                onehot_to_index = -1; // no port selected
            end else begin
                // find the index of the onehot bit set
                for (idx = 0; idx <= num_ports; idx = idx + 1)
                    if (onehot[idx]) onehot_to_index = idx;
            end
        end
    endfunction

    // FIXED: Assign current selected port index once
    assign current_selected_port_index = onehot_to_index(selected_port);

    // DEBUG: Add debug variables for monitoring
    integer debug_cycle_count = 0;
    
    // Previous values for change detection
    reg [1:0] prev_inflight_count [num_ports:0];
    reg [num_ports:0] prev_zero_inflight_count;
    reg prev_zero_inflight;
    reg [num_ports:0] prev_selected_port;
    reg [num_ports:0] prev_eligible;
    reg prev_done;
    reg signed [$clog2(num_ports):0] prev_store_selected_port;
    reg signed [$clog2(num_ports):0] prev_forwarded_port;

    // FIFO instances
    genvar i;
    generate
        for (i = 0; i < num_ports; i = i + 1) begin : fifo_gen_in
            fifo #(
                .WIDTH(data_width),
                .DEPTH(fifo_depth)
            ) fifo_inst_in (
                .clk(clk),
                .rst(rst),
                .rd_en(fifo_rd_en_in[i]),
                .wr_en(fifo_wr_en_in[i]),
                .din(fifo_in_data_in[data_width*i +: data_width]),
                .dout(fifo_out_data_in[data_width*i +: data_width]),
                .empty(fifo_empty_in[i]),
                .full(fifo_full_in[i]),
                .count(fifo_count_in[($clog2(fifo_depth)+1)*i +: $clog2(fifo_depth)+1])
            );
        end
    endgenerate
    
    generate
        for (i = 0; i < num_ports; i = i + 1) begin : fifo_gen_out
            fifo #(
                .WIDTH(data_width),
                .DEPTH(fifo_depth)
            ) fifo_inst_out (
                .clk(clk),
                .rst(rst),
                .rd_en(fifo_rd_en_out[i]),
                .wr_en(fifo_wr_en_out[i]),
                .din(fifo_in_data_out[data_width*i +: data_width]),
                .dout(fifo_out_data_out[data_width*i +: data_width]),
                .empty(fifo_empty_out[i]),
                .full(fifo_full_out[i]),
                .count(fifo_count_out[i])
            );
        end
    endgenerate

    genvar j,k;
    // FIXED: FIFO space available - use registered inflight_count to break combinational loop
    generate
        assign fifo_space_available[0] = (main_fifo_count_in + inflight_count_reg[0]) < main_fifo_depth;
        for (j = 1; j < num_ports+1; j = j + 1) begin : fifo_space_available_gen
            assign fifo_space_available[j] = (fifo_count_out[j-1] + inflight_count_reg[j]) < fifo_depth;
        end
    endgenerate

    generate
        assign eligible[0] = !main_fifo_empty_out && ~|(forwarding_map[0] & ~fifo_space_available);
        for (j = 1; j < num_ports+1; j = j + 1) begin : eligible_gen
            assign eligible[j] = !fifo_empty_in[j-1] && ~|(forwarding_map[j] & ~fifo_space_available);
        end
    endgenerate

    generate
        assign selected_port[0] = eligible[0];
        for (k = 1; k < num_ports+1; k = k + 1) begin : selected_port_gen
            assign selected_port[k] = ~|eligible[k-1:0] & eligible[k];
        end
    endgenerate

    generate
        for (k = 0; k < num_ports+1; k = k + 1) begin : zero_inflight_count_gen
            assign zero_inflight_count[k] = ~|inflight_count[k];
        end
    endgenerate

    // done signal gen
    assign zero_inflight = &zero_inflight_count;
    assign done = &fifo_empty_in && &fifo_empty_out && zero_inflight;

    // first cycle
    assign fifo_rd_en_in = selected_port[num_ports:1];
    assign main_fifo_rd_en_out = selected_port[0];

    integer l=0;

    // Separate always block for updating previous values (for debug)
    always @(posedge clk) begin
        if (!rst) begin
            // Update previous values for change detection
            for (l = 0; l < num_ports+1; l = l + 1) begin
                prev_inflight_count[l] <= inflight_count[l];
            end
            prev_zero_inflight_count <= zero_inflight_count;
            prev_zero_inflight <= zero_inflight;
            prev_selected_port <= selected_port;
            prev_eligible <= eligible;
            prev_done <= done;
            prev_store_selected_port <= store_selected_port;
            prev_forwarded_port <= forwarded_port;
        end
    end

    always @(posedge clk) begin
        // DEBUG: Increment cycle counter
        debug_cycle_count <= rst ? 0 : debug_cycle_count + 1;
        
        // reset logic
        if (rst) begin
            main_fifo_wr_en_in <= 1'b0;
            main_in_data_in <= {data_width{1'b0}};
            fifo_in_data_out <= {num_ports*data_width{1'b0}};
            fifo_wr_en_out <= {num_ports{1'b0}};
            store_selected_port <= -1;
            forwarded_port <= -1;
            for (l = 0; l < num_ports+1; l = l + 1) begin
                forwarding_map[l] <= 0;
                inflight_count[l] <= 0;
                inflight_count_reg[l] <= 0;
            end
        end
        else if (router_mode && load_row) begin
            // load row logic
            forwarding_map[row_index] <= forwarding_row;
            // $display("DEBUG [Cycle %0d]: Loading forwarding_map[%0d] = %b", debug_cycle_count, row_index, forwarding_row);
        end else begin
            // Update registered inflight_count
            for (l = 0; l < num_ports+1; l = l + 1) begin
                inflight_count_reg[l] <= inflight_count[l];
            end
            
            // Pipeline stage 1: Store selected port
            store_selected_port <= current_selected_port_index;
            
            // Pipeline stage 2: Forward data and update inflight counts
            if (store_selected_port > -1) begin
                // to main port
                if (store_selected_port > 0) begin
                    main_in_data_in <= forwarding_map[store_selected_port][0] ? fifo_out_data_in[(store_selected_port-1)*data_width +: data_width] : 0;
                end else begin
                    main_in_data_in <= forwarding_map[0][0] ? main_out_data_out : 0;
                end
                main_fifo_wr_en_in <= forwarding_map[store_selected_port][0];

                // to other ports
                for (l=0; l<num_ports; l=l+1) begin
                    if (store_selected_port > 0) begin
                        fifo_in_data_out[l*data_width +: data_width] <= forwarding_map[store_selected_port][l+1] ? fifo_out_data_in[(store_selected_port-1)*data_width +: data_width] : 0;
                    end else begin
                        fifo_in_data_out[l*data_width +: data_width] <= forwarding_map[0][l+1] ? main_out_data_out : 0;
                    end
                    fifo_wr_en_out[l] <= forwarding_map[store_selected_port][l+1];
                end
            end else begin
                main_in_data_in <= 0;
                main_fifo_wr_en_in <= 0;
                fifo_in_data_out <= 0;
                fifo_wr_en_out <= 0;
            end 
            
            // Update forwarded port for next cycle
            forwarded_port <= store_selected_port;

            // FIXED: Update inflight counts with consistent selected port index
            for (l=0; l<num_ports+1; l=l+1) begin
                if (|selected_port && forwarding_map[current_selected_port_index][l] && 
                    forwarded_port > -1 && forwarding_map[forwarded_port][l]) begin
                    // Both increment and decrement cancel out
                    inflight_count[l] <= inflight_count[l];
                end else if (|selected_port && forwarding_map[current_selected_port_index][l]) begin
                    // Only increment
                    inflight_count[l] <= inflight_count[l] + 1;
                end else if (forwarded_port > -1 && forwarding_map[forwarded_port][l]) begin
                    // Only decrement - add bounds checking
                    inflight_count[l] <= (inflight_count[l] > 0) ? inflight_count[l] - 1 : 0;
                end
                // else: no change
            end
        end
    end

endmodule
