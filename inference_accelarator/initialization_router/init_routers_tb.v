`include "init_router.v"
`timescale 1ns/100ps

module init_routers_tb();

    // Parameters
    parameter PORTS = 4;
    parameter HIGHER_PORT = 8;
    parameter FLIT_SIZE = 8;
    parameter LOWER_LEVEL_ROUTERS = 4;
    parameter DATA_COUNT = 5;
    
    // Router IDs
    parameter UPPER_ROUTER_ID = 7'b1000000;
    parameter LOWER_ROUTER_ID_0 = 7'b1000000;
    parameter LOWER_ROUTER_ID_1 = 7'b1000001;
    parameter LOWER_ROUTER_ID_2 = 7'b1000010;
    parameter LOWER_ROUTER_ID_3 = 7'b1000011;

    // Upper router signals
    reg clk;
    reg rst;

    reg load_data_upper_top_in;
    wire ready_data_upper_top_in;
    reg [FLIT_SIZE-1:0] data_upper_top_in;
    wire load_data_upper_top_out;
    reg ready_data_upper_top_out;
    wire [FLIT_SIZE-1:0] data_upper_top_out;

    wire [HIGHER_PORT-1:0] load_data_upper_lower_in;
    wire [HIGHER_PORT-1:0] ready_data_upper_lower_in;
    wire [HIGHER_PORT*FLIT_SIZE-1:0] data_upper_lower_in;
    wire [HIGHER_PORT-1:0] load_data_upper_lower_out;
    wire [HIGHER_PORT-1:0] ready_data_upper_lower_out;
    wire [HIGHER_PORT*FLIT_SIZE-1:0] data_upper_lower_out;

    // Lower router signals (array for multiple routers)
    reg [PORTS-1:0] load_data_lower_top_in;
    wire [PORTS-1:0] ready_data_lower_top_in;
    reg [PORTS*FLIT_SIZE-1:0] data_lower_top_in;
    wire [PORTS-1:0] load_data_lower_top_out;
    reg [PORTS-1:0] ready_data_lower_top_out;
    wire [PORTS*FLIT_SIZE-1:0] data_lower_top_out;

    // For simplicity, we won't connect all lower level ports to external devices
    // Just one example lower router's downward connections
    reg [PORTS-1:0] load_data_router0_lower_in;
    wire [PORTS-1:0] ready_data_router0_lower_in;
    reg [PORTS*FLIT_SIZE-1:0] data_router0_lower_in;
    wire [PORTS-1:0] load_data_router0_lower_out;
    reg [PORTS-1:0] ready_data_router0_lower_out;
    wire [PORTS*FLIT_SIZE-1:0] data_router0_lower_out;

    // FSM state encoding for top-down test (upper router to lower router)
    parameter STATE_START     = 3'd0;
    parameter STATE_COUNT     = 3'd1;
    parameter STATE_PAYLOAD   = 3'd2;
    parameter STATE_DONE      = 3'd3;
    
    // FSM state encoding for bottom-up test (lower router to upper router)
    parameter LOWER_START     = 3'd0;
    parameter LOWER_COUNT     = 3'd1;
    parameter LOWER_PAYLOAD   = 3'd2;
    parameter LOWER_DONE      = 3'd3;

    // Test modes
    parameter TEST_TOP_DOWN = 1'd0;
    parameter TEST_BOTTOM_UP = 1'd1;
    
    reg test_mode;
    reg [2:0] state;
    reg [2:0] lower_state;
    reg [FLIT_SIZE-1:0] dest_id;
    reg [FLIT_SIZE-1:0] flit_count;
    integer payload_index;
    integer target_router;  // Which lower router is the destination
    integer source_port;    // Which port on lower router is sending data
    
    // Counters to track received flits
    integer received_flits_top;
    integer received_flits_lower[0:PORTS-1];

    // Instantiate the upper layer router
    init_router #(
        .PORTS(HIGHER_PORT),
        .FLIT_SIZE(FLIT_SIZE),
        .ROUTER_ID(UPPER_ROUTER_ID),
        .ROUTER_TYPE(1), // Upper layer
        .LOWER_LEVEL_ROUTERS(LOWER_LEVEL_ROUTERS)
    ) upper_router (
        .clk(clk),
        .rst(rst),

        .load_data_top_in(load_data_upper_top_in),
        .ready_data_top_in(ready_data_upper_top_in),
        .data_top_in(data_upper_top_in),
        .load_data_top_out(load_data_upper_top_out),
        .ready_data_top_out(ready_data_upper_top_out),
        .data_top_out(data_upper_top_out),

        .load_data_lower_in(load_data_upper_lower_in),
        .ready_data_lower_in(ready_data_upper_lower_in),
        .data_lower_in(data_upper_lower_in),
        .load_data_lower_out(load_data_upper_lower_out),
        .ready_data_lower_out(ready_data_upper_lower_out),
        .data_lower_out(data_upper_lower_out)
    );

    // Generate 4 lower layer routers
    genvar i;
    generate
        for (i = 0; i < HIGHER_PORT; i = i + 1) begin : lower_routers
            // Each router needs its own ID
            localparam ROUTER_ID = (i == 0) ? LOWER_ROUTER_ID_0 :
                                  (i == 1) ? LOWER_ROUTER_ID_1 :
                                  (i == 2) ? LOWER_ROUTER_ID_2 :
                                             LOWER_ROUTER_ID_3;
            
            // Lower ports for router 0 are connected to testbench
            // For other routers, we'll keep them unconnected for simplicity
            wire [PORTS-1:0] load_data_this_lower_in;
            wire [PORTS-1:0] ready_data_this_lower_in;
            wire [PORTS*FLIT_SIZE-1:0] data_this_lower_in;
            wire [PORTS-1:0] load_data_this_lower_out;
            wire [PORTS-1:0] ready_data_this_lower_out;
            wire [PORTS*FLIT_SIZE-1:0] data_this_lower_out;
            
            if (i == 0) begin
                // Router 0 connects to testbench signals
                assign load_data_this_lower_in = load_data_router0_lower_in;
                assign ready_data_router0_lower_in = ready_data_this_lower_in;
                assign data_this_lower_in = data_router0_lower_in;
                assign load_data_router0_lower_out = load_data_this_lower_out;
                assign ready_data_this_lower_out = ready_data_router0_lower_out;
                assign data_router0_lower_out = data_this_lower_out;
            end else begin
                // Other routers have inactive lower connections
                assign load_data_this_lower_in = {PORTS{1'b0}};
                assign ready_data_this_lower_out = {PORTS{1'b1}};
                assign data_this_lower_in = {PORTS*FLIT_SIZE{1'b0}};
            end
            
            init_router #(
                .PORTS(PORTS),
                .FLIT_SIZE(FLIT_SIZE),
                .ROUTER_ID(ROUTER_ID),
                .ROUTER_TYPE(0), // Lower layer
                .LOWER_LEVEL_ROUTERS(LOWER_LEVEL_ROUTERS)
            ) lower_router (
                .clk(clk),
                .rst(rst),

                .load_data_top_in(load_data_upper_lower_out[i]),
                .ready_data_top_in(ready_data_upper_lower_out[i]),
                .data_top_in(data_upper_lower_out[i*FLIT_SIZE +: FLIT_SIZE]),
                .load_data_top_out(load_data_upper_lower_in[i]),
                .ready_data_top_out(ready_data_upper_lower_in[i]),
                .data_top_out(data_upper_lower_in[i*FLIT_SIZE +: FLIT_SIZE]),

                .load_data_lower_in(load_data_this_lower_in),
                .ready_data_lower_in(ready_data_this_lower_in),
                .data_lower_in(data_this_lower_in),
                .load_data_lower_out(load_data_this_lower_out),
                .ready_data_lower_out(ready_data_this_lower_out),
                .data_lower_out(data_this_lower_out)
            );
        end
    endgenerate

    // Clock generation
    always #5 clk = ~clk;

    // FSM controlling packet send from top (upper router's top)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= STATE_START;
            load_data_upper_top_in <= 0;
            data_upper_top_in <= 0;
            payload_index <= 0;
        end else if (test_mode == TEST_TOP_DOWN) begin
            case (state)
                STATE_START: begin
                    if (ready_data_upper_top_in) begin
                        $display("---- FSM: Starting Top-Down Packet Send to Lower Router %0d ----", target_router);
                        state <= STATE_COUNT;
                        load_data_upper_top_in <= 1;
                        data_upper_top_in <= 8'b00010011;
                    end 
                end

                STATE_COUNT: begin
                    if (ready_data_upper_top_in) begin
                        load_data_upper_top_in <= 1;
                        state <= STATE_PAYLOAD;
                        data_upper_top_in <= DATA_COUNT; // Number of payload flits
                    end 
                end

                STATE_PAYLOAD: begin
                    if (ready_data_upper_top_in) begin
                        load_data_upper_top_in <= 1;
                        data_upper_top_in <= 8'hF0 + payload_index; // Deterministic data pattern
                        if (payload_index == DATA_COUNT) begin
                            state <= STATE_DONE;
                        end else begin
                            payload_index <= payload_index + 1;
                        end
                    end 
                end

                STATE_DONE: begin
                    load_data_upper_top_in <= 0;
                    state <= STATE_START;
                    load_data_upper_top_in <= 0;
                    data_upper_top_in <= 0;
                    payload_index <= 0;
                    // Stay in DONE until reset or next test
                end
            endcase
        end
    end
    
    // FSM controlling packet send from lower level (router 0's bottom)
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            lower_state <= LOWER_START;
            load_data_router0_lower_in <= 0;
            data_router0_lower_in <= 0;
            payload_index <= 0;
        end else if (test_mode == TEST_BOTTOM_UP) begin
            case (lower_state)
                LOWER_START: begin
                    if (ready_data_router0_lower_in[source_port]) begin
                        $display("---- FSM: Starting Bottom-Up Packet Send from Router 0, Port %0d ----", source_port);
                        lower_state <= LOWER_COUNT;
                        load_data_router0_lower_in[source_port] <= 1;
                        
                        // Send to upper router
                        data_router0_lower_in[source_port*FLIT_SIZE +: FLIT_SIZE] <= UPPER_ROUTER_ID;
                    end 
                end

                LOWER_COUNT: begin
                    if (ready_data_router0_lower_in[source_port]) begin
                        load_data_router0_lower_in[source_port] <= 1;
                        lower_state <= LOWER_PAYLOAD;
                        data_router0_lower_in[source_port*FLIT_SIZE +: FLIT_SIZE] <= DATA_COUNT; // Number of payload flits
                    end 
                end

                LOWER_PAYLOAD: begin
                    if (ready_data_router0_lower_in[source_port]) begin
                        load_data_router0_lower_in[source_port] <= 1;
                        data_router0_lower_in[source_port*FLIT_SIZE +: FLIT_SIZE] <= 8'hA0 + payload_index; // Deterministic data pattern
                        if (payload_index == DATA_COUNT) begin
                            lower_state <= LOWER_DONE;
                        end else begin
                            payload_index <= payload_index + 1;
                        end
                    end 
                end

                LOWER_DONE: begin
                    load_data_router0_lower_in <= 0;
                    // Stay in DONE until reset or next test
                end
            endcase
        end
    end


    integer k, port;
    // Initialization and reset
    initial begin
        clk = 0;
        rst = 1;
        test_mode = TEST_TOP_DOWN;
        
        // Initialize upper router signals
        load_data_upper_top_in = 0;
        data_upper_top_in = 0;
        ready_data_upper_top_out = 1;
        
        // Initialize router 0 lower signals
        load_data_router0_lower_in = 0;
        data_router0_lower_in = 0;
        ready_data_router0_lower_out = {PORTS{1'b1}};
        
        // Initialize counters
        received_flits_top = 0;
        for (k = 0; k < PORTS; k = k+1) begin
            received_flits_lower[k] = 0;
        end
        
        target_router = 0;  // Target lower router 0 for top-down test
        source_port = 1;    // Source port 1 for bottom-up test
        
        // Reset release
        #12 rst = 0;

        // First test: Top-Down (upper router to lower router 0)
        test_mode = TEST_TOP_DOWN;
        $display("\n==== STARTING TOP-DOWN TEST (Upper -> Lower Router %0d) ====\n", target_router);
        
        // Let top-down test run
        repeat (110) @(posedge clk);
        // Reset for next test
        rst = 1;
        #10 rst = 0;
        
        // Reset counters
        received_flits_top = 0;
        for (k = 0; k < PORTS; k = k+1) begin
            received_flits_lower[k] = 0;
        end
        
        // Second test: Bottom-Up (lower router 0 to upper router)
        test_mode = TEST_BOTTOM_UP;
        $display("\n==== STARTING BOTTOM-UP TEST (Lower Router 0 -> Upper) ====\n");
        
        // Let bottom-up test run
        repeat (100) @(posedge clk);

        $display("\nTestbench finished.");
        $finish;
    end

    // Optional: Dump waveform
    initial begin
        $dumpfile("init_routers_tb.vcd");
        $dumpvars(0, init_routers_tb);
    end

endmodule