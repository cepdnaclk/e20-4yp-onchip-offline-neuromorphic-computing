`include "init_router.v"
`timescale 1ns/100ps

module init_router_layer1_tb();

    // Parameters
    parameter PORTS = 4;
    parameter FLIT_SIZE = 8;
    parameter ROUTER_ID = 7'b1000000;
    parameter ROUTER_TYPE = 0; // 0 = lower layer
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

    // FSM state encoding for top-to-lower test
    parameter STATE_START     = 3'd0;
    parameter STATE_COUNT     = 3'd1;
    parameter STATE_PAYLOAD   = 3'd2;
    parameter STATE_DONE      = 3'd3;
    
    // FSM state encoding for lower-to-top test
    parameter LOWER_START     = 3'd0;
    parameter LOWER_COUNT     = 3'd1;
    parameter LOWER_PAYLOAD   = 3'd2;
    parameter LOWER_DONE      = 3'd3;

    // Test modes
    parameter TEST_TOP_TO_LOWER = 1'd0;
    parameter TEST_LOWER_TO_TOP = 1'd1;
    
    reg test_mode;
    reg [2:0] state;
    reg [2:0] lower_state;
    reg [FLIT_SIZE-1:0] dest_id;
    reg [FLIT_SIZE-1:0] flit_count;
    integer payload_index;
    integer source_port;  // Which lower port is sending data
    
    // Counters to track received flits
    integer received_flits_top;
    integer received_flits_lower[0:PORTS-1];

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
        end else if (test_mode == TEST_TOP_TO_LOWER) begin
            case (state)
                STATE_START: begin
                    if (ready_data_top_in) begin
                        $display("---- FSM: Starting Top-to-Lower Packet Send ----");
                        state <= STATE_COUNT;
                        load_data_top_in <= 1;
                        data_top_in <= 8'h02; // Destination ID
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
                    // Stay in DONE until reset or next test
                end
            endcase
        end
    end
    
    // FSM controlling packet send from lower level
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            lower_state <= LOWER_START;
            load_data_lower_in <= 0;
            data_lower_in <= 0;
            payload_index <= 0;
        end else if (test_mode == TEST_LOWER_TO_TOP) begin
            case (lower_state)
                LOWER_START: begin
                    if (ready_data_lower_in[source_port]) begin
                        $display("---- FSM: Starting Lower-to-Top Packet Send from Port %0d ----", source_port);
                        lower_state <= LOWER_COUNT;
                        load_data_lower_in[source_port] <= 1;
                        
                        // Set data for this specific port, leave others unchanged
                        data_lower_in[source_port*FLIT_SIZE +: FLIT_SIZE] <= ROUTER_ID; // Destination is this router
                    end 
                end

                LOWER_COUNT: begin
                    if (ready_data_lower_in[source_port]) begin
                        load_data_lower_in[source_port] <= 1;
                        lower_state <= LOWER_PAYLOAD;
                        data_lower_in[source_port*FLIT_SIZE +: FLIT_SIZE] <= 3; // Number of payload flits
                    end 
                end

                LOWER_PAYLOAD: begin
                    if (ready_data_lower_in[source_port]) begin
                        load_data_lower_in[source_port] <= 1;
                        data_lower_in[source_port*FLIT_SIZE +: FLIT_SIZE] <= 8'hA0 + payload_index; // Deterministic data pattern
                        if (payload_index == 3) begin
                            lower_state <= LOWER_DONE;
                        end else begin
                            payload_index <= payload_index + 1;
                        end
                    end 
                end

                LOWER_DONE: begin
                    load_data_lower_in <= 0;
                    // Stay in DONE until reset or next test
                end
            endcase
        end
    end

    // Monitor for top output data
    always @(posedge clk) begin
        if (load_data_top_out) begin
            $display("Time %0t: Received data at TOP: %h", $time, data_top_out);
            received_flits_top <= received_flits_top + 1;
        end
    end
    
    // Monitor for lower output data
    genvar i;
    generate
        for (i = 0; i < PORTS; i = i + 1) begin : lower_monitors
            always @(posedge clk) begin
                if (load_data_lower_out[i]) begin
                    $display("Time %0t: Received data at LOWER port %0d: %h", 
                             $time, i, data_lower_out[i*FLIT_SIZE +: FLIT_SIZE]);
                    received_flits_lower[i] <= received_flits_lower[i] + 1;
                end
            end
        end
    endgenerate

    integer j, port;
    // Initialization and reset
    initial begin
        clk = 0;
        rst = 1;
        test_mode = TEST_TOP_TO_LOWER;
        
        // Initialize signals
        load_data_top_in = 0;
        data_top_in = 0;
        ready_data_top_out = 1;
        load_data_lower_in = 0;
        data_lower_in = 0;
        ready_data_lower_out = {PORTS{1'b1}};
        
        // Initialize counters
        received_flits_top = 0;
        for (j = 0; j < PORTS; j = j+1) begin
            received_flits_lower[j] = 0;
        end
        
        source_port = 1; // Port 1 will be the source for lower-to-top test
        
        // Reset release
        #12 rst = 0;

        // First test: Top to Lower (existing test)
        test_mode = TEST_TOP_TO_LOWER;
        $display("\n==== STARTING TOP TO LOWER TEST ====\n");
        
        // Let top-to-lower test run
        repeat (50) @(posedge clk);
        
        // Check results for top-to-lower test
        $display("\n==== TOP TO LOWER TEST RESULTS ====");
        for (port = 0; port < PORTS; port = port + 1) begin
            $display("Lower port %0d received %0d flits", port, received_flits_lower[port]);
        end
        
        // Reset for next test
        rst = 1;
        #10 rst = 0;
        
        // Reset counters
        received_flits_top = 0;
        for (j = 0; j < PORTS; j = j+1) begin
            received_flits_lower[j] = 0;
        end
        
        // Second test: Lower to Top
        test_mode = TEST_LOWER_TO_TOP;
        $display("\n==== STARTING LOWER TO TOP TEST ====\n");
        
        // Let lower-to-top test run
        repeat (50) @(posedge clk);
        
        // Check results for lower-to-top test
        $display("\n==== LOWER TO TOP TEST RESULTS ====");
        $display("Top received %0d flits", received_flits_top);

        $display("\nTestbench finished.");
        $finish;
    end

    // Optional: Dump waveform
    initial begin
        $dumpfile("init_router_layer1_tb.vcd");
        $dumpvars(0, init_router_layer1_tb);
    end

endmodule