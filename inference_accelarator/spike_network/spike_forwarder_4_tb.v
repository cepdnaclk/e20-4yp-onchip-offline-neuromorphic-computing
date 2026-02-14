`timescale 1ns/1ps
`include "spike_forwarder_4.v"

module spike_forwarder_4_tb;

    parameter num_ports = 4;
    parameter data_width = 11;
    parameter fifo_depth = 8;

    reg clk;
    reg rst;
    
    reg [num_ports-1:0] fifo_rd_en_out;
    reg [num_ports-1:0] fifo_wr_en_in;
    reg [num_ports*data_width-1:0] fifo_in_data_in;
    wire [num_ports*data_width-1:0] fifo_out_data_out;
    wire [num_ports-1:0] fifo_full_in;
    wire [num_ports-1:0] fifo_empty_out;

    wire [data_width-1:0] main_in_data_in;
    reg [data_width-1:0] main_out_data_out;
    reg [$clog2(fifo_depth):0] main_fifo_count_in;
    reg main_fifo_full_in;
    reg main_fifo_empty_out;
    wire main_fifo_rd_en_out;
    wire main_fifo_wr_en_in;

    reg router_mode;
    reg load_data;
    reg [7:0] data_in;
    

    // Instantiate DUT
    spike_forwarder_4 #(
        .num_ports(num_ports),
        .data_width(data_width),
        .fifo_depth(fifo_depth)
    ) dut (
        .clk(clk),
        .rst(rst),
        .fifo_rd_en_out(fifo_rd_en_out),
        .fifo_wr_en_in(fifo_wr_en_in),
        .fifo_in_data_in(fifo_in_data_in),
        .fifo_out_data_out(fifo_out_data_out),
        .fifo_full_in(fifo_full_in),
        .fifo_empty_out(fifo_empty_out),
        .main_in_data_in(main_in_data_in),
        .main_out_data_out(main_out_data_out),
        .main_fifo_full_in(main_fifo_full_in),
        .main_fifo_empty_out(main_fifo_empty_out),
        .main_fifo_rd_en_out(main_fifo_rd_en_out),
        .main_fifo_wr_en_in(main_fifo_wr_en_in),
        .main_fifo_count_in(main_fifo_count_in),
        .router_mode(router_mode),
        .load_data(load_data),
        .data_in(data_in)
    );

    task load_fifo;
        input integer port_id;
        input [data_width-1:0] data;
        begin
            // Apply write enable and data to given port for 1 cycle
            @(posedge clk);
            fifo_wr_en_in = 1 << port_id;
            fifo_in_data_in = data << (port_id*data_width);
        end
    endtask


    // Clock generation
    initial clk = 1;
    always #5 clk = ~clk;  // 100 MHz clock

    integer i;
    integer debug_i;

    initial begin
        // Initialize inputs
        rst = 1;
        fifo_rd_en_out = 0;
        fifo_wr_en_in = 0;
        main_out_data_out = 0;
        main_fifo_full_in = 0;
        main_fifo_empty_out = 1;
        main_fifo_count_in = 0;
        router_mode = 0;
        load_data = 0;
        data_in = 0;
        fifo_in_data_in = 0;

        #20;
        rst = 0;

        // load forwarding map
        router_mode = 1;
        #10;
        load_data = 1;
        data_in = 8'b00010110;
        #10;
        data_in = 8'b00110101;
        #10;
        data_in = 8'b01010100;
        #10;
        data_in = 8'b01110111;
        #10;
        data_in = 8'b10010101;
        #10 load_data = 0;
        data_in = 8'b00000000;

        #10;

        $display("Forwarding Map:");
        for (debug_i = 0; debug_i < num_ports + 1; debug_i = debug_i + 1) begin
            $display("  [%0d] = %b", debug_i, dut.spike_forwarder_inst.forwarding_map[debug_i]);
        end

        // Disable router_mode, enable FIFOs with some data
        router_mode = 0;

        #10;
        load_fifo(1, 11'b00000000010);
        load_fifo(0, 11'b00000001010);
        load_fifo(1, 11'b00000000110);
        load_fifo(2, 11'b00000001110);
        load_fifo(1, 11'b00000000010);
        load_fifo(0, 11'b00000001010);
        load_fifo(1, 11'b00000000110);
        load_fifo(2, 11'b00000001110);
        
        @(posedge clk)
        fifo_wr_en_in = 0;

        load_fifo(1, 11'b00000000010);
        load_fifo(0, 11'b00000001010);
        load_fifo(1, 11'b00000000110);
        load_fifo(2, 11'b00000001110);
        load_fifo(1, 11'b00000000010);
        load_fifo(0, 11'b00000001010);
        load_fifo(1, 11'b00000000110);
        load_fifo(2, 11'b00000001110);
        
        @(posedge clk)
        fifo_wr_en_in = 0;
        #100;
        
        $finish;
    end

    task print_inflight;
        integer j;
        begin
            $write("time=%0t inflight_count = ", $time);
            for (j = 0; j < num_ports + 1; j = j + 1)
                $write("[%0d]=%0d ", j, dut.spike_forwarder_inst.inflight_count[j]);
            $write("\n");
            $write("time=%0t fifo_count = ", $time);
            for (j = 0; j < num_ports; j = j + 1)
                $write("[%0d]=%0d ", j, dut.spike_forwarder_inst.fifo_count_out[j]);
            $write("\n");
        end
    endtask

    always @(posedge clk) begin
        print_inflight();
    end


    // Optionally add monitors or waveform dumping
    initial begin
        $dumpfile("spike_forwarder_4_tb.vcd");
        $dumpvars(0, spike_forwarder_4_tb);
    end

endmodule
