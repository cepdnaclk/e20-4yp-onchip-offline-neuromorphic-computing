`include "init_router.v"
`timescale 1ns/100ps

module init_router_layer2_tb();

    // Parameters
    parameter PORTS = 8;
    parameter FLIT_SIZE = 8;
    parameter ROUTER_ID = 7'b1000000;
    parameter ROUTER_TYPE = 1;
    parameter LOWER_LEVEL_ROUTERS = 4;

    // Signals
    reg clk;
    reg rst;

    reg load_data_top_in;
    wire ready_data_top_in;
    reg [FLIT_SIZE-1:0] data_top_in;
    wire load_data_top_out;
    reg ready_data_top_out;
    wire [FLIT_SIZE-1:0] data_top_out;

    reg [PORTS-1:0] load_data_lower_in;
    wire [PORTS-1:0] ready_data_lower_in;
    reg [PORTS*FLIT_SIZE-1:0] data_lower_in;
    wire [PORTS-1:0] load_data_lower_out;
    reg [PORTS-1:0] ready_data_lower_out;
    wire [PORTS*FLIT_SIZE-1:0] data_lower_out;

    // FSM state encoding
    parameter STATE_START     = 3'd0;
    parameter STATE_COUNT   = 3'd1;
    parameter STATE_PAYLOAD  = 3'd2;
    parameter STATE_DONE     = 3'd3;

    reg [2:0] state;
    reg [FLIT_SIZE-1:0] dest_id;
    reg [FLIT_SIZE-1:0] flit_count;
    integer payload_index;

    // Instantiate the router
    init_router #(
        .PORTS(PORTS),
        .FLIT_SIZE(FLIT_SIZE),
        .ROUTER_ID(ROUTER_ID),
        .ROUTER_TYPE(ROUTER_TYPE),
        .LOWER_LEVEL_ROUTERS(LOWER_LEVEL_ROUTERS)
    ) uut (
        .clk(clk),
        .rst(rst),
        .load_data_top_in(load_data_top_in),
        .ready_data_top_in(ready_data_top_in),
        .data_top_in(data_top_in),
        .load_data_top_out(load_data_top_out),
        .ready_data_top_out(ready_data_top_out),
        .data_top_out(data_top_out),
        .load_data_lower_in(load_data_lower_in),
        .ready_data_lower_in(ready_data_lower_in),
        .data_lower_in(data_lower_in),
        .load_data_lower_out(load_data_lower_out),
        .ready_data_lower_out(ready_data_lower_out),
        .data_lower_out(data_lower_out)
    );

    // Clock generation
    always #5 clk = ~clk;

    // FSM controlling packet send from top
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= STATE_START;
            load_data_top_in <= 0;
            data_top_in <= 0;
            payload_index <= 0;
        end else begin
            case (state)
                STATE_START: begin
                    if (ready_data_top_in) begin
                        $display("---- FSM: Starting Packet Send ----");
                        state <= STATE_COUNT;
                        load_data_top_in <= 1;
                        data_top_in <= 8'h04; // Destination ID
                    end 
                end

                STATE_COUNT: begin
                    if (ready_data_top_in) begin
                        load_data_top_in <= 1;
                        state <= STATE_PAYLOAD;
                        data_top_in <= 3; // Number of payload flits
                    end 
                end

                STATE_PAYLOAD: begin
                    if (ready_data_top_in) begin
                        load_data_top_in <= 1;
                        data_top_in <= $random % 256;
                        if (payload_index == 3) begin
                            state <= STATE_DONE;
                        end else begin
                            payload_index <= payload_index + 1;
                        end
                    end 
                end

                STATE_DONE: begin
                    load_data_top_in <= 0;
                    // Stay in DONE or restart test logic if needed
                end
            endcase
        end
    end

    // Initialization and reset
    initial begin
        clk = 0;
        rst = 1;
        load_data_top_in = 0;
        data_top_in = 0;
        ready_data_top_out = 1;
        load_data_lower_in = 0;
        data_lower_in = 0;
        ready_data_lower_out = {PORTS{1'b1}};

        #12 rst = 0;

        // Let simulation run
        repeat (100) @(posedge clk);

        $display("Testbench finished.");
        $finish;
    end

    // Optional: Dump waveform
    initial begin
        $dumpfile("init_router_layer2_tb.vcd");
        $dumpvars(0, init_router_layer2_tb);
    end

endmodule
