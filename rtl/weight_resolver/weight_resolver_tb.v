`include "weight_resolver.v"
`timescale 1ns/1ps

module weight_resolver_tb;

    reg clk,rst;
    
    parameter max_weight_rows = 2048;
    parameter buffer_depth = 8;
    parameter neurons_per_cluster = 32;
    
    // initialize weight memory
    reg [7:0] data;
    reg load_data;
    reg chip_mode;

    // weight memory read
    reg [4*$clog2(max_weight_rows)-1:0] weight_addr;
    reg [3:0] buffer_wr_en;
    wire [4*($clog2(buffer_depth)+1)-1:0] buffer_count;
    wire [4*32*neurons_per_cluster-1:0] weight_out;
    wire [3:0] load_weight_out;
    wire weight_resolver_done;

    reg [7:0] init_data [0:1000];
    reg [9:0] flit_index;
    reg start_init, done_init;

    task load_fifo;
        input integer port_id;
        input [$clog2(max_weight_rows)-1:0] data;
        begin
            // Apply write enable and data to given port for 1 cycle
            @(posedge clk);
            buffer_wr_en = 1 << port_id;
            weight_addr = data << (port_id*$clog2(max_weight_rows));
            #5;

            @(posedge clk);
            // Clear write enable after 1 cycle
            buffer_wr_en = 0;
            weight_addr = 0;
        end
    endtask

    weight_resolver #(
        .max_weight_rows(max_weight_rows),
        .buffer_depth(buffer_depth),
        .neurons_per_cluster(neurons_per_cluster)
    ) weight_resolver_inst (
        .clk(clk),
        .rst(rst),
        .data(data),
        .load_data(load_data),
        .chip_mode(chip_mode),
        .buffer_addr_in(weight_addr),
        .buffer_wr_en(buffer_wr_en),
        .buffer_count(buffer_count),
        .weight_out(weight_out),
        .load_weight_out(load_weight_out),
        .weight_resolver_done(weight_resolver_done)
    );

    always #5 clk = ~clk;

    initial begin
        $readmemh("weight_init_mem.mem", init_data);

        $dumpfile("weight_resolver_tb.vcd");
        $dumpvars(0, weight_resolver_tb);

        clk = 0;
        rst = 0;
        load_data = 0;
        chip_mode = 0;
        start_init = 0;
        done_init = 0;
        flit_index = 0;
        weight_addr = 0;
        buffer_wr_en = 0;
        data = 8'h00;

        rst = 1;
        #10;

        rst = 0;
        chip_mode = 1;
        start_init = 1;

        #550;


        #10;
        chip_mode = 0;

        load_fifo(0, 16'h0000);
        load_fifo(1, 16'h0001);
        load_fifo(2, 16'h0002);
        load_fifo(3, 16'h0003);        

        #50
        $finish;
    end

    always @(posedge clk) begin
        if(start_init) begin
            if(init_data[flit_index] !== 8'hxx) begin
                data <= init_data[flit_index];
                flit_index <= flit_index + 1;
                load_data <= 1;
                $display("Loading weight flit: %d, data: %h", flit_index, data);
            end else begin
                done_init <= 0;
                load_data <= 0;
            end
        end
    end
    
endmodule