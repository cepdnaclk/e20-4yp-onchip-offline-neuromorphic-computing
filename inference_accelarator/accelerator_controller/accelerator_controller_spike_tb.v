`include "accelerator_controller.v"
`timescale 1ns/100ps

module accelerator_controller_spike_tb;

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
    
    // Initialization NoC interfaces (unused for spike tests)
    wire init_load_data_send;
    reg init_ready_data_send;
    wire [7:0] init_data_send;
    
    reg [7:0] int_data_receive;
    reg init_load_data_receive;
    wire init_ready_data_receive;
    reg init_receive_done;
    
    // Spike done signal
    reg spike_done;
    
    // Test control variables
    integer i;
    
    // Instantiate DUT
    accelerator_controller #(
        .FUNCT(7'b0000001)
    ) dut (
        .clk(clk),
        .rst(rst),
        .fire(fire),
        .ready(ready),
        .data1(data1),
        .data2(data2),
        .data_out(data_out),
        .funct(7'b0000001),
        
        // Spike NoC
        .main_fifo_din_in(main_fifo_din_in),
        .main_fifo_wr_en_in(main_fifo_wr_en_in),
        .main_fifo_full_in(main_fifo_full_in),
        .main_fifo_rd_en_out(main_fifo_rd_en_out),
        .main_fifo_empty_out(main_fifo_empty_out),
        .main_fifo_dout_out(main_fifo_dout_out),
        
        .spike_done(spike_done),
        
        // Initialization NoC (connected but unused)
        .init_load_data_send(init_load_data_send),
        .init_ready_data_send(init_ready_data_send),
        .init_data_send(init_data_send),
        .int_data_receive(int_data_receive),
        .init_load_data_receive(init_load_data_receive),
        .init_ready_data_receive(init_ready_data_receive),
        .init_receive_done(init_receive_done)
    );
    
    // Clock generation - 100MHz
    always #5 clk = ~clk;
    
    // Task to initialize all signals
    task initialize;
        begin
            clk = 0;
            rst = 1;
            fire = 0;
            data1 = 64'b0;
            data2 = 64'b0;
            main_fifo_full_in = 0;
            main_fifo_empty_out = 1;
            main_fifo_dout_out = 11'b0;
            spike_done = 0;
            
            // Init NoC signals (unused but need to be driven)
            init_ready_data_send = 0;
            int_data_receive = 8'b0;
            init_load_data_receive = 0;
            init_receive_done = 0;
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
            @(posedge clk);
            // #10;
        end
    endtask
    
    // Task to test spike write operation
    task test_spike_write;
        input [3:0] num_spikes;
        input [119:0] spike_payload;
        input end_of_spikes_flag;
        begin
            // Prepare spike data: [SPIKE_OPCODE][num_spikes][payload][end_flag]
            data1 = {4'h2, num_spikes, spike_payload[119:64]};
            data2 = {spike_payload[63:1], end_of_spikes_flag};
            
            // Start spike transmission
            fire = 1;
            @(posedge clk);

            // Wait for transmission to complete
            wait_for_ready();
            fire = 0;
        end
    endtask
    
    // Task to simulate spike output data availability
    task provide_spike_output_data;
        input [10:0] spike_data;
        begin
            main_fifo_empty_out = 0;
            wait(main_fifo_rd_en_out == 1);
            @(posedge clk);
            // @(posedge clk);
            #1
            main_fifo_dout_out = spike_data;

            main_fifo_empty_out = 1;
        end
    endtask
    
    // Task to simulate multiple spike outputs
    task provide_multiple_spike_outputs;
        input integer num_outputs;
        begin
            for (i = 0; i < num_outputs; i = i + 1) begin
                provide_spike_output_data(11'h101 + i); 
                // #20;
            end
        end
    endtask
    
    // Task to simulate spike processing completion
    task signal_spike_done;
        begin
            // #100; // Simulate processing time
            spike_done = 1;
            #10;
            spike_done = 0;
        end
    endtask
    
    // Main test sequence
    initial begin
        initialize();
        apply_reset();
        
        // Test 1: Single spike packet with few spikes
        test_spike_write(4'd3, 120'h223456789ABCDEF0123456789ABCD, 1'b0);
        #40;
        
        fork
            begin
                provide_multiple_spike_outputs(3);
            end
            begin
                #20
                test_spike_write(4'd8, 120'hDEADBEEFCAFEBABE0123456789AB, 1'b0);
            end
        join
        #50;
        
        // Test 3: Large spike packet
        fork
            begin
                provide_multiple_spike_outputs(10);
            end
            begin
                test_spike_write(4'd5, 120'hDEADBEEFCAFEBABE0123456789AB, 1'b0);
                #20
                test_spike_write(4'd5, 120'hDEADBEEFCAFEBABE0123456789AB, 1'b0);
                #20
                test_spike_write(4'd5, 120'hDEADBEEFCAFEBABE0123456789AB, 1'b0);
                #20
                test_spike_write(4'd5, 120'hDEADBEEFCAFEBABE0123456789AB, 1'b0);
            end
        join
        #50;
        
        // Test 3: Large spike packet
        fork
            begin
                provide_multiple_spike_outputs(19);
                signal_spike_done();
            end
            begin
                test_spike_write(4'd2, 120'hDEADBEEFCAFEBABE0123456789AB, 1'b0);
                #20
                test_spike_write(4'd2, 120'hDEADBEEFCAFEBABE0123456789AB, 1'b0);
                #20
                test_spike_write(4'd2, 120'hDEADBEEFCAFEBABE0123456789AB, 1'b1);
                #20
                test_spike_write(4'd2, 120'hDEADBEEFCAFEBABE0123456789A1, 1'b1);
                #20
                test_spike_write(4'd2, 120'hDEADBEEFCAFEBABE0123456789AB, 1'b1);
                #20
                test_spike_write(4'd2, 120'hDEADBEEFCAFEBABE0123456789AB, 1'b1);
            end
        join
        
        // Simulate spike processing and outputs
        
        wait_for_ready();
        #50;
        
        // // Test 5: Back-to-back spike operations
        // test_spike_write(4'd4, 120'hAABBCCDDEEFF001122334455667, 1'b0);
        // #30;
        // test_spike_write(4'd6, 120'h111122223333444455556666777, 1'b1);
        
        // // Simulate more spike processing
        // fork
        //     begin
        //         #80;
        //         provide_multiple_spike_outputs(5);
        //     end
        //     begin
        //         signal_spike_done();
        //     end
        // join
        
        // wait_for_ready();
        // #50;
        
        // // Test 6: Maximum spike count
        // test_spike_write(4'd15, 120'hFFFFFFFFFFFFFFFFFFFFFFFFFFFFF, 1'b0);
        // #100;
        
        // // Test 7: FIFO full condition simulation
        // main_fifo_full_in = 1;
        // test_spike_write(4'd3, 120'h123456789ABCDEF012345678ABC, 1'b0);
        // #50;
        // main_fifo_full_in = 0; // Release FIFO full
        // wait_for_ready();
        // #50;
        
        // // Test 8: Continuous spike output reading
        // fork
        //     begin
        //         test_spike_write(4'd2, 120'hABCDEF0123456789ABCDEF01234, 1'b1);
        //     end
        //     begin
        //         #50;
        //         provide_multiple_spike_outputs(8);
        //     end
        //     begin
        //         signal_spike_done();
        //     end
        // join
        
        // wait_for_ready();
        #100;
        
        $finish;
    end
    
    // Timeout watchdog
    initial begin
        #10000; // 1000ns timeout
        $finish;
    end
    
    // Waveform dump
    initial begin
        $dumpfile("accelerator_controller_spike_tb.vcd");
        $dumpvars(0, accelerator_controller_spike_tb);
    end

endmodule