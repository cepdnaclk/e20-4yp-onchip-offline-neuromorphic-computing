`include "neuron_cluster.v"

// packet structure
// <opcode:8:ni><neuron_id:8:ni><flit_count:8:ni>{{<data:8:ni>}....}
// <opcode:8:lf><num_weights:8:lf>{{<row_index:8:lf><col_index:8:lf><weight_init:32:lf>}...}
// <opcode:8:if><row_index:8:if><cluster_id:8:if><layer:8,neuron_id:7:0:if><num_weights:8:if>{<index:8:if><weight_init:32:if>}...
// <opcode:8:oe><neuron_mask:32:oe>
// `define OPCODE_LOAD_NI 8'h01
// `define OPCODE_LOAD_LF 8'h02
// `define OPCODE_LOAD_IF 8'h03
// `define OPCODE_LOAD_OE 8'h04


module neuron_cluster_tb;
    parameter packet_width = 11; 
    parameter cluster_id = 6'b000000;
    parameter number_of_clusters = 64;
    parameter neurons_per_cluster = 32;
    parameter max_weight_table_rows = 32;

    reg clk;
    reg rst;
    reg time_step;
    reg chip_mode;
    wire [packet_width-1:0] packet_in;
    wire [packet_width-1:0] packet_out;
    reg [packet_width-1:0] fifo_incoming_din;
    wire [packet_width-1:0] fifo_outgoing_dout;
    wire fifo_incoming_empty;
    wire fifo_incoming_full;
    wire fifo_outgoing_full;
    wire fifo_outgoing_empty;
    wire fifo_incoming_rd_en;
    reg fifo_incoming_wr_en;
    wire fifo_outgoing_wr_en;
    wire fifo_outgoing_rd_en;
    wire [4:0] fifo_incoming_count;
    wire [4:0] fifo_outgoing_count;
    wire cluster_done;
    reg load_data;  // Pulse to load configuration data
    reg [7:0] data;  // Configuration data bus

    reg [7:0] data_mem [0:90];
    reg [11:0] data_mem_index; 

    neuron_cluster #(
        .packet_width(packet_width),
        .cluster_id(cluster_id),
        .number_of_clusters(number_of_clusters),
        .neurons_per_cluster(neurons_per_cluster),
        .max_weight_table_rows(max_weight_table_rows)
    ) uut (
        .clk(clk),
        .rst(rst),
        .time_step(time_step),
        .chip_mode(chip_mode),
        .packet_in(packet_in),
        .packet_out(packet_out),
        .fifo_empty(fifo_incoming_empty),
        .fifo_full(fifo_outgoing_full),
        .fifo_rd_en(fifo_incoming_rd_en),
        .fifo_wr_en(fifo_outgoing_wr_en),
        .load_data(load_data),
        .data(data),
        .cluster_done(cluster_done)
    );

    fifo #(
        .WIDTH(packet_width),
        .DEPTH(16)
    ) fifo_incoming (
        .clk(clk),
        .rst(rst),
        .wr_en(fifo_incoming_wr_en),
        .din(fifo_incoming_din),
        .rd_en(fifo_incoming_rd_en),
        .dout(packet_in),
        .full(fifo_incoming_full),
        .empty(fifo_incoming_empty),
        .count(fifo_incoming_count)
    );

    fifo #(
        .WIDTH(packet_width),
        .DEPTH(16)
    ) fifo_outgoing (
        .clk(clk),
        .rst(rst),
        .wr_en(fifo_outgoing_wr_en),
        .din(packet_out),
        .rd_en(fifo_outgoing_rd_en),
        .dout(fifo_outgoing_dout),
        .full(fifo_outgoing_full),
        .empty(fifo_outgoing_empty),
        .count(fifo_outgoing_count)
    );

    task send_packet;
        input [packet_width-1:0] packet_data;
        begin
            @(posedge clk);
            fifo_incoming_wr_en = 1;
            fifo_incoming_din = packet_data;
            #5;
            @(posedge clk);
            fifo_incoming_wr_en = 0;
            #5;
        end
    endtask

    always #5 clk = ~clk;  // Clock generation

    initial begin
        $dumpfile("neuron_cluster_tb.vcd");
        $dumpvars(0, neuron_cluster_tb);
        $readmemh("data_bytes.mem", data_mem);

        // Initialize signals
        clk = 0;
        rst = 1;
        time_step = 0;
        chip_mode = 0;
        load_data = 0;
        data = 8'b0;
        fifo_incoming_wr_en = 0;
        fifo_incoming_din = 0;
        data_mem_index = 0;

        // Release reset after some time
        #10 rst = 0;

        #10 chip_mode = 1;

        #5 load_data = 1;  // Begin loading data
        while (data_mem_index < 71) begin
            @(posedge clk);
            data = data_mem[data_mem_index];
            data_mem_index = data_mem_index + 1;
            #10;
        end
        @(posedge clk);  // one final cycle with last data held
        load_data = 0;   // Finish loading

        #10 chip_mode = 0;

        // Send a packet to the FIFO
        send_packet(11'b00000100000);
        send_packet(11'b00000100001);
        #100 time_step = 1;
        #10 time_step = 0;

        send_packet(11'b00000100000);
        send_packet(11'b00000100001);
        #380 time_step = 1;
        #10 time_step = 0;

        send_packet(11'b00000100000);
        send_packet(11'b00000100001);
        #380 time_step = 1;
        #10 time_step = 0;

        #10 send_packet(11'b00000100000);
        send_packet(11'b00000100001);
        #380 time_step = 1;
        #10 time_step = 0;

        #10send_packet(11'b00000100001);
        #350 time_step = 1;
        #10 time_step = 0;

        // Finish simulation after some time
        #350 $finish;
    end

endmodule