`include "accelerator_controller.v"
`timescale 1ns/100ps

module accelerator_controller_tb;

    // Clock and reset
    reg clk;
    reg rst;
    
    // Control signals
    reg fire;
    wire ready;
    
    // Data interfaces
    reg [63:0] data1;
    reg [63:0] data2;
    wire [63:0] data_out;
    
    // Spike NoC interfaces
    wire [10:0] main_fifo_din_in;
    wire main_fifo_wr_en_in;
    reg main_fifo_full_in;
    
    wire main_fifo_rd_en_out;
    reg main_fifo_empty_out;
    reg [10:0] main_fifo_dout_out;
    
    // Initialization NoC interfaces
    wire init_load_data_send;
    reg init_ready_data_send;
    wire [7:0] init_data_send;
    
    reg [7:0] int_data_receive;
    reg init_load_data_receive;
    wire init_ready_data_receive;
    reg init_receive_done;
    
    // Test variables
    reg [7:0] expected_data [0:15];
    reg [7:0] received_data [0:15];
    reg [63:0] expected_read_data;
    integer i, j;
    integer error_count;
    integer read_flit_count;
    
    // Instantiate DUT
    accelerator_controller dut (
        .clk(clk),
        .rst(rst),
        .fire(fire),
        .ready(ready),
        .data1(data1),
        .data2(data2),
        .data_out(data_out),
        
        // Spike NoC
        .main_fifo_din_in(main_fifo_din_in),
        .main_fifo_wr_en_in(main_fifo_wr_en_in),
        .main_fifo_full_in(main_fifo_full_in),
        .main_fifo_rd_en_out(main_fifo_rd_en_out),
        .main_fifo_empty_out(main_fifo_empty_out),
        .main_fifo_dout_out(main_fifo_dout_out),
        
        // Initialization NoC
        .init_load_data_send(init_load_data_send),
        .init_ready_data_send(init_ready_data_send),
        .init_data_send(init_data_send),

        .int_data_receive(int_data_receive),
        .init_load_data_receive(init_load_data_receive),
        .init_ready_data_receive(init_ready_data_receive),
        .init_receive_done(init_receive_done)
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
            init_ready_data_send = 0;
            int_data_receive = 8'b0;
            init_load_data_receive = 0;
            init_receive_done = 0;
            main_fifo_empty_out = 1;
            main_fifo_dout_out = 11'b0;
            error_count = 0;
            read_flit_count = 0;
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
    
    // Task to test INIT opcode transmission (write)
    task test_init_transmission;
        input [3:0] num_flits;
        input [119:0] payload;
        begin
            // Prepare data: [opcode][valid_flits][payload]
            data1 = {4'h1, num_flits, payload[119:64]};  // INIT_WRITE_OPCODE = 4'h1
            data2 = payload[63:0];
            
            // Start transmission
            fire = 1;
            #10;
            fire = 0;
            
            // Monitor init NoC interface
            init_ready_data_send = 1; // NoC is ready to receive
            
            i = 0;
            while (i < num_flits) begin
                @(posedge clk);
                if (init_load_data_send) begin
                    i = i + 1;
                    init_ready_data_send = 0; // Simulate NoC busy
                    #10;
                    init_ready_data_send = 1; // NoC ready again
                end
            end
            
            wait_for_ready();
        end
    endtask
    
    // Task to test SPIKE opcode transmission (write)
    task test_spike_transmission;
        input [3:0] num_flits;
        input [119:0] payload;
        begin
            // Prepare data: [opcode][valid_flits][payload]
            data1 = {4'h2, num_flits, payload[119:64]};  // SPIKE_WRITE_OPCODE = 4'h2
            data2 = payload[63:0];
            
            // Start transmission
            fire = 1;
            #10;
            fire = 0;
            
            // Simulate FIFO not full
            assign main_fifo_full_in = 0;
            
            i = 0;
            while (i < num_flits) begin
                @(posedge clk);
                if (main_fifo_wr_en_in) begin
                    i = i + 1;
                end
            end
            
            wait_for_ready();
        end
    endtask
    
    // Task to test INIT read operation
    task test_init_read;
        input [3:0] num_flits;
        input [119:0] payload;
        input [63:0] expected_response;
        begin
            // Prepare read command: [opcode][valid_flits][payload]
            data1 = {4'h3, num_flits, payload[119:64]};  // INIT_READ_OPCODE = 4'h3
            data2 = payload[63:0];
            expected_read_data = expected_response;
            
            // Start read operation
            fire = 1;
            #10;
            
            // Phase 1: Send read request
            init_ready_data_send = 1;
            
            // Wait for all request flits to be sent
            i = 0;
            while (i < num_flits) begin
                @(posedge clk);
                if (init_load_data_send) begin
                    i = i + 1;
                    init_ready_data_send = 0;
                    #10;
                    init_ready_data_send = 1;
                end
            end
            
            wait_for_ready();
            #1 fire = 0; // End of request phase
            #20;
            fire = 1; // End of request phase

            // Simulate network sending response data
            for (j = 0; j < 8; j = j + 1) begin // Assume 8-byte response for testing
                #30; // Simulate network delay
                wait(init_ready_data_receive == 1);
                int_data_receive = expected_response[63-j*8 -: 8] + 2;
                init_load_data_receive = 1;
                // if (j == 15)
                //     init_receive_done = 1; // Signal that all data has been received
                @(posedge clk);
                #1;
                init_load_data_receive = 0;
                init_receive_done = 0; // Signal that all data has been received
                #10;
            end

            wait_for_ready();
            #1 fire = 0; // End of request phase
            #40;
            fire = 1; // End of request phase

            // Simulate network sending response data
            for (j = 0; j < 8; j = j + 1) begin // Assume 8-byte response for testing
                #30; // Simulate network delay
                wait(init_ready_data_receive == 1);
                int_data_receive = expected_response[63-j*8 -: 8];
                init_load_data_receive = 1;
                if (j == 7)
                    init_receive_done = 1; // Signal that all data has been received
                @(posedge clk);
                #1;
                init_load_data_receive = 0;
                init_receive_done = 0; // Signal that all data has been received
                #10;
            end

            wait_for_ready();
            #1 fire = 0; // End of request phase

        end
    endtask
    
    
    // Main test sequence
    initial begin        
        initialize();
        apply_reset();
        
        // Test 1: INIT write transmission with different flit counts
        test_init_transmission(4'd1, 120'hDEADBEEFCADEADBEEFCAFEBABEFEED);
        #50;
        test_init_transmission(4'd4, 120'hDEADBEEFCADEADBEEFCAFEBABEFEED);
        #50;
        test_init_transmission(4'd8, 120'hDEADBEEFCADEADBEEFCAFEBABEFEED);
        #50;
        
        // // Test 2: SPIKE write transmission with different flit counts
        // test_spike_transmission(4'd2, 120'hDEADBEEFCADEADBEEFCAFEBABEFEED);
        // #50;
        // test_spike_transmission(4'd6, 120'hDEADBEEFCADEADBEEFCAFEBABEFEED);
        // #50;
        
        // Test 3: INIT read operations
        test_init_read(4'd2, 120'hDEADBEEFCADEADBEEFCAFEBABEFEED, 64'hCAFEBABEDEADBEEF);
        #100;
        test_init_read(4'd4, 120'hDEADBEEFCADEADBEEFCAFEBABEFEED, 64'hCAFEBABEDEADBEEF);
        #100;
        test_init_read(4'd1, 120'hDEADBEEFCADEADBEEFCAFEBABEFEED, 64'hCAFEBABEDEADBEEF);
        #100;
        
        // Test 4: Back-to-back transactions
        test_init_transmission(4'd2, 120'hDEADBEEFCADEADBEEFCAFEBABEFEED);
        #10;
        test_init_read(4'd2, 120'hDEADBEEFCADEADBEEFCAFEBABEFEED, 64'hCAFEBABEDEADBEEF);
        #50;
        
        // Test 5: Mixed operations
        test_spike_transmission(4'd3, 120'hDEADBEEFCADEADBEEFCAFEBABEFEED);
        #20;
        test_init_read(4'd3, 120'hDEADBEEFCADEADBEEFCAFEBABEFEED, 64'hCAFEBABEDEADBEEF);
        #50;
        
        
        // Test 7: Maximum flit count
        test_init_transmission(4'd15, 120'hDEADBEEFCADEADBEEFCAFEBABEFEED);
        #100;
        
        #100;
        $finish;
    end
    
    // Monitor key signals
    initial begin
        $monitor("Time %0t: State=%0d, SubState=%0d, Ready=%b, Fire=%b, InitReady=%b", 
                 $time, dut.state, dut.sub_state, ready, fire, init_ready_data_receive);
    end
    
    // Timeout watchdog
    initial begin
        #50000; // 50us timeout
        $finish;
    end

    // Optional: Dump waveform
    initial begin
        $dumpfile("accelerator_controller_tb.vcd");
        $dumpvars(0, accelerator_controller_tb);
    end

endmodule