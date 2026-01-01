`define SPIKE_FORWARDER

`ifdef SPIKE_FORWARDER_8
`else
`include "../FIFO/fifo.v"
`include "./spike_forwarder/spike_forwarder.v"
`include "./spike_forwarder_controller/spike_forwarder_controller_8.v"
`endif


module spike_forwarder_8
#(
    parameter data_width = 11,
    parameter fifo_depth = 8,
    parameter main_fifo_depth = 32,
    parameter num_ports = 8
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
    output wire [data_width-1:0] main_in_data_in,
    input wire main_fifo_full_in,
    input wire main_fifo_empty_out,
    input wire [$clog2(main_fifo_depth):0] main_fifo_count_in,
    output wire main_fifo_rd_en_out,
    output wire main_fifo_wr_en_in,

    // other ports
    input wire router_mode,
    input wire [7:0] data_in,
    input wire load_data,

    // done
    output wire done
);

    wire load_row;
    wire [3:0] row_index;
    wire [8:0] forwarding_row;

    spike_forwarder #(
        .num_ports(num_ports),
        .data_width(data_width),
        .fifo_depth(fifo_depth),
        .main_fifo_depth(main_fifo_depth)
    ) spike_forwarder_inst (
        .clk(clk),
        .rst(rst),
        .fifo_rd_en_out(fifo_rd_en_out),
        .fifo_wr_en_in(fifo_wr_en_in),
        .fifo_in_data_in(fifo_in_data_in),
        .fifo_out_data_out(fifo_out_data_out),
        .fifo_full_in(fifo_full_in),
        .fifo_empty_out(fifo_empty_out),
        .fifo_count_in(fifo_count_in),

        // main port
        .main_out_data_out(main_out_data_out),
        .main_in_data_in(main_in_data_in),
        .main_fifo_full_in(main_fifo_full_in),
        .main_fifo_empty_out(main_fifo_empty_out),
        .main_fifo_count_in(main_fifo_count_in),
        .main_fifo_rd_en_out(main_fifo_rd_en_out),
        .main_fifo_wr_en_in(main_fifo_wr_en_in),

        // other ports
        .router_mode(router_mode),
        .load_row(load_row),
        .row_index(row_index),
        .forwarding_row(forwarding_row),

        // done
        .done(done)
    );

    spike_forwarder_controller_8 spike_forwarder_controller_inst (
        .clk(clk),
        .rst(rst),
        .data_in(data_in),
        .load_data(load_data),
        .load_row(load_row),
        .row_index(row_index),
        .forwarding_row(forwarding_row)
    );

endmodule
