`include "accelerator_controller.v"
`include "../initialization_router/init_router.v"
`timescale 1ns/100ps

module accelerator_controller_init_top_tb;

    // Clock and reset
    reg clk;
    reg rst;
    
    // Control signals
    reg fire;
    wire ready;
    
    // Data interfaces
    reg [63:0] data1;
    reg [63:0] data2;
    
    // Initialization NoC - Direct controller to router connections
    wire init_load_data_send;
    wire init_ready_data_send;
    wire [7:0] init_data_send;
    
    wire [7:0] init_data_receive;
    wire init_load_data_receive;
    wire init_ready_data_receive;

    // Router connections to lower layer (simulated lower routers)
    reg [7:0] router_load_data_lower_in;
    wire [7:0] router_ready_data_lower_in;
    reg [63:0] router_data_lower_in;  // 8 ports * 8 bits
    
    wire [7:0] router_load_data_lower_out;
    reg [7:0] router_ready_data_lower_out;
    wire [63:0] router_data_lower_out;  // 8 ports * 8 bits
    
    // Instantiate DUT (Accelerator Controller)
    accelerator_controller dut (
        .clk(clk),
        .rst(rst),

        .fire(fire),
        .ready(ready),

        .data1(data1),
        .data2(data2),
        .data_out(),

        .init_load_data_send(init_load_data_send),
        .init_ready_data_send(init_ready_data_send),
        .init_data_send(init_data_send),

        .int_data_receive(init_data_receive),
        .init_load_data_receive(init_load_data_receive),
        .init_ready_data_receive(init_ready_data_receive),

        .init_receive_done()
    );

    // Instantiate Router - Direct connections to controller
    init_router #(
        .PORTS(8),
        .FLIT_SIZE(8),
        .ROUTER_ID(7'b1000000),
        .ROUTER_TYPE(1), // Upper layer
        .LOWER_LEVEL_ROUTERS(4)
    ) top_router (
        .clk(clk),
        .rst(rst),
        
        // Top side connections - Controller sends TO router via this interface
        .load_data_top_in(init_load_data_send),
        .ready_data_top_in(init_ready_data_send),
        .data_top_in(init_data_send),
        
        .load_data_top_out(init_load_data_receive),
        .ready_data_top_out(init_ready_data_receive),
        .data_top_out(init_data_receive),

        // Lower side connections
        .load_data_lower_in(router_load_data_lower_in),
        .ready_data_lower_in(router_ready_data_lower_in),
        .data_lower_in(router_data_lower_in),
        
        .load_data_lower_out(router_load_data_lower_out),
        .ready_data_lower_out(router_ready_data_lower_out),
        .data_lower_out(router_data_lower_out),

        // Local processor (unused)
        .load_data(),
        .ready_data(),
        .data()
    );
    
    // Clock generation
    always #5 clk = ~clk; // 100MHz clock
    
    // Task to initialize signals
    task initialize;
        begin
            clk = 0;
            rst = 1;
            fire = 0;
            data1 = 64'b0;
            data2 = 64'b0;
            
            // Initialize router simulation signals
            router_load_data_lower_in = 8'b0;
            router_data_lower_in = 64'b0;
            router_ready_data_lower_out = 8'hFF; // All lower ports ready
        end
    endtask
    
    // Task to apply reset
    task apply_reset;
        begin
            rst = 1;
            #20;
            rst = 0;
            #10;
        end
    endtask
    
    // Task to wait for ready signal
    task wait_for_ready;
        begin
            wait(ready == 1);
        end
    endtask
    
    // Task to test INIT opcode transmission through router
    task test_init_transmission_with_router;
        input [3:0] num_flits;
        input [119:0] payload;
        begin            
            // Prepare data: [opcode][valid_flits][payload]
            data1 = {4'h1, num_flits, payload[119:64]};
            data2 = payload[63:0];
        
            
            // Start transmission
            fire = 1;
            wait_for_ready();
            fire = 0;
        end
    endtask

    // Main test sequence
    initial begin
        initialize();
        apply_reset();
        
        test_init_transmission_with_router(4'd4, {8'h01, 8'h02,104'hDEADBEEFCADEADBEEFCAFEBABE});
        #50;
        test_init_transmission_with_router(4'd15, {8'h05, 8'd20,104'hDEADBEEFCADEADBEEFCAFEBABE});
        #50;
        test_init_transmission_with_router(4'd10, {120'hDEADBEEFCADEADBEEFCAFEBABEFEED});
        #50;
        
    
        #100;
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #20000;
        $finish;
    end

    // Optional: Dump waveform
    initial begin
        $dumpfile("accelerator_controller_init_top_tb.vcd");
        $dumpvars(0, accelerator_controller_init_top_tb);
    end

endmodule
