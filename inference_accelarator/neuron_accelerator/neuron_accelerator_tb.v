`include "neuron_accelerator.v"
`include "../../shared_memory/snn_shared_memory_wb.v"
`timescale 1ns / 100ps

module neuron_accelerator_tb;

    parameter packet_width = 11; 
    parameter main_fifo_depth = 32;
    parameter forwarder_8_fifo_depth = 16;
    parameter forwarder_4_fifo_depth = 8;
    parameter number_of_clusters = 64;
    parameter neurons_per_cluster = 32;
    parameter incoming_weight_table_rows = 1024;
    parameter max_weight_table_rows = 4096;
    parameter flit_size = 8;
    parameter cluster_group_count = 8;

    reg clk;
    reg rst;
    reg network_mode;
    reg time_step; 
    reg load_data_in;
    reg rst_potential;
    reg [flit_size-1:0] data_in;
    wire ready_in;
    wire [flit_size-1:0] data_out;
    wire load_data_out;
    reg ready_out;
    reg [packet_width-1:0] main_fifo_din_in;
    reg main_fifo_wr_en_in;
    wire main_fifo_full_in;
    wire [packet_width-1:0] main_fifo_dout_out;
    wire main_fifo_rd_en_out;
    wire main_fifo_empty_out;

    reg [7:0] init_mem [0:1000000];
    reg [10:0] spike_mem [0:100000000];
    reg [31:0] init_index;
    reg waiting_for_data = 0; // Flag to indicate if we are waiting for data

    wire accelerator_done;
    wire dbg_all_clusters_done;

    // ── Port B: Accelerator → Shared Memory ──
    wire [15:0] portb_addr;
    wire [31:0] portb_din;
    wire        portb_we;
    wire        portb_en;
    wire [31:0] portb_dout;     // shared memory read-back (for CPU sim)
    wire        collision_det;

    // ── Port A: Wishbone (CPU simulation for readback) ──
    reg  [31:0] wb_adr_i = 0;
    reg  [31:0] wb_dat_i = 0;
    wire [31:0] wb_dat_o;
    reg  [3:0]  wb_sel_i = 4'hF;
    reg         wb_we_i = 0, wb_stb_i = 0, wb_cyc_i = 0;
    wire        wb_ack_o;

    // Shared memory: 49152 words (192 KB)
    // vmem_base=0xA000, spike_base=0xB000, WB base=0x2000_0000
    localparam SMEM_WB_BASE  = 32'h2000_0000;
    localparam SMEM_DEPTH    = 49152;

    snn_shared_memory_wb #(
        .MEM_DEPTH(SMEM_DEPTH),
        .BASE_ADDR(SMEM_WB_BASE)
    ) shared_mem (
        .clk(clk), .rst(rst),
        // Port A: Wishbone (CPU)
        .wb_adr_i(wb_adr_i), .wb_dat_i(wb_dat_i),
        .wb_dat_o(wb_dat_o), .wb_sel_i(wb_sel_i),
        .wb_we_i(wb_we_i), .wb_stb_i(wb_stb_i),
        .wb_cyc_i(wb_cyc_i), .wb_ack_o(wb_ack_o),
        // Port B: Accelerator dump
        .portb_addr(portb_addr[14:2]),  // 13-bit word addr from 15:2 of 16-bit
        .portb_din(portb_din),
        .portb_dout(portb_dout),
        .portb_we(portb_we),
        .portb_en(portb_en),
        .collision_detect(collision_det)
    );

    reg start_init;
    reg init_done;

    // inferencing signals - configurable via runtime parameters
    parameter time_step_window = 5; // 5 timesteps to match simple test
    parameter input_neurons = 784;
    parameter nn_layers = 3;
    parameter input_count = 1;    // 1 sample
    
    // Runtime parameter values (overridden by +args)
    integer runtime_time_step_window;
    integer runtime_input_neurons;
    integer runtime_nn_layers;
    integer runtime_input_count;
    
    reg start_inf;
    reg [31:0] input_neuron_index;
    reg [31:0] time_step_index;
    reg [31:0] input_index;

    integer file;

    neuron_accelerator #(
        .packet_width(packet_width),
        .main_fifo_depth(main_fifo_depth),
        .forwarder_8_fifo_depth(forwarder_8_fifo_depth),
        .forwarder_4_fifo_depth(forwarder_4_fifo_depth),
        .number_of_clusters(number_of_clusters),
        .neurons_per_cluster(neurons_per_cluster),
        .incoming_weight_table_rows(incoming_weight_table_rows),
        .max_weight_table_rows(max_weight_table_rows),
        .cluster_group_count(cluster_group_count),
        .flit_size(flit_size)
    ) uut (
        .clk(clk),
        .rst(rst),
        .network_mode(network_mode),
        .time_step(time_step),
        .load_data_in(load_data_in),
        .rst_potential(rst_potential),
        .data_in(data_in),
        .ready_in(ready_in),
        .data_out(data_out),
        .load_data_out(load_data_out),
        .ready_out(ready_out),
        .main_fifo_din_in(main_fifo_din_in),
        .main_fifo_wr_en_in(main_fifo_wr_en_in),
        .main_fifo_full_in(main_fifo_full_in),
        .main_fifo_dout_out(main_fifo_dout_out),
        .main_fifo_rd_en_out(main_fifo_rd_en_out),
        .main_fifo_empty_out(main_fifo_empty_out),
        .accelerator_done(accelerator_done),
        .dbg_all_clusters_done(dbg_all_clusters_done),
        // Port B dump interface
        .portb_addr      (portb_addr),
        .portb_din       (portb_din),
        .portb_we        (portb_we),
        .portb_en        (portb_en),
        .vmem_base_addr  (16'hA000),
        .spike_base_addr (16'hB000),
        .current_timestep(time_step_index[3:0])
    );
    
    integer i=0;
    integer j=0;

    // ─── Dump Monitor: prints every real V_mem and spike written to memory ───
    integer dump_vmem_count = 0;
    integer dump_spike_count = 0;
    always @(posedge clk) begin
        if (portb_we && portb_en) begin
            if (portb_addr >= 16'hA000 && portb_addr < 16'hB000) begin
                $display("[T=%0d DUMP V_MEM] neuron=%0d  addr=0x%04h  v_mem=0x%08h",
                          time_step_index,
                          portb_addr - 16'hA000 - time_step_index*64*32,
                          portb_addr, portb_din);
                dump_vmem_count = dump_vmem_count + 1;
            end else if (portb_addr >= 16'hB000) begin
                $display("[T=%0d DUMP SPIKE] word=%0d   addr=0x%04h  spikes=0b%b",
                          time_step_index,
                          portb_addr - 16'hB000,
                          portb_addr, portb_din);
                dump_spike_count = dump_spike_count + 1;
            end
        end
    end

    always #5 clk = ~clk; // Clock generation
    initial begin
        // $dumpfile("neuron_accelerator_tb.vcd");
        // $dumpvars(0, neuron_accelerator_tb);
        $dumpfile("xor_test.vcd");
        $dumpvars(0, neuron_accelerator_tb);

        // Read runtime parameters (or use defaults)
        if (!$value$plusargs("time_step_window=%d", runtime_time_step_window))
            runtime_time_step_window = time_step_window;
        if (!$value$plusargs("input_neurons=%d", runtime_input_neurons))
            runtime_input_neurons = input_neurons;
        if (!$value$plusargs("nn_layers=%d", runtime_nn_layers))
            runtime_nn_layers = nn_layers;
        if (!$value$plusargs("input_count=%d", runtime_input_count))
            runtime_input_count = input_count;
        
        $display("==============================================");
        $display("Simulation Parameters:");
        $display("  time_step_window = %0d", runtime_time_step_window);
        $display("  input_neurons    = %0d", runtime_input_neurons);
        $display("  nn_layers        = %0d", runtime_nn_layers);
        $display("  input_count      = %0d", runtime_input_count);
        $display("==============================================");

        // Initialize signals
        clk = 0;
        rst = 1;
        network_mode = 0;
        load_data_in = 0;
        rst_potential = 0;
        data_in = 0;
        ready_out = 0;
        main_fifo_din_in = 0;
        main_fifo_wr_en_in = 0;
        time_step = 0;
        start_init = 0;
        init_done = 0;
        init_index = 0;
        start_inf = 0;
        input_index = 0;
        time_step_index = 0;
        input_neuron_index = 0;
        time_step_index = 0;

        // Reset the system
        #10 rst = 0;
        network_mode = 1; // Set to network mode

        // load mem file
        $readmemh("data_mem_simple.mem", init_mem);
        $readmemh("spike_mem_simple.mem", spike_mem);

        file = $fopen("output.txt", "w");
        if (!file) begin
            $display("Failed to open file.");
            $finish;
        end

        start_init = 1; // Start the initialization process
    end


    always @(posedge clk) begin
        if (start_init) begin
            if (init_index < 10000) begin   // enough for 8424-byte simple file
                if (init_mem[init_index] !== 8'bx) begin
                    if (ready_in && !load_data_in) begin
                        data_in <= init_mem[init_index];
                        load_data_in <= 1;
                        init_index <= init_index + 1;
                        $display("Loading init data: %d", init_index);
                    end else begin
                        load_data_in <= 0; // Stop loading data if not ready
                    end
                end else begin
                    load_data_in <= 0; // Stop loading data if not ready
                    if (ready_in && !load_data_in) begin
                        network_mode <= 0; // Stop loading data if we hit an undefined value
                        start_init <= 0; // Stop the initialization process
                        init_done <= 1; // Mark initialization as done
                        $display("Initialization data loading completed.");
                    end 
                end
            end 
        end else begin
            load_data_in <= 0; // Ensure load_data_in is low when not initializing
            if (init_done && accelerator_done) begin
                $display("Initialization completed.");
                start_inf <= 1; // Start the inference process after initialization
                init_done <= 0; // Reset init_done for next use
            end
        end
    end

    wire [31:0] spike_packet_index;
    assign spike_packet_index = input_neuron_index + time_step_index*runtime_input_neurons + input_index * runtime_time_step_window * runtime_input_neurons;

    always @(posedge clk) begin
        if (start_inf) begin
            if (time_step_index < runtime_time_step_window) begin
                if (input_neuron_index < runtime_input_neurons) begin
                    input_neuron_index <= input_neuron_index + 1;
                    if (spike_mem[spike_packet_index] != 11'h7FF) begin
                        main_fifo_din_in <= spike_mem[spike_packet_index];
                        main_fifo_wr_en_in <= 1; // Write to main FIFO
                        $display("Spike packet index: %d, value: %h", spike_packet_index, spike_mem[spike_packet_index]);
                    end else begin
                        main_fifo_din_in <= 0;
                        main_fifo_wr_en_in <= 0; 
                    end
                end else begin
                    main_fifo_din_in <= 0; // Clear FIFO input
                    main_fifo_wr_en_in <= 0; // Stop writing to main FIFO
                    if (accelerator_done) begin
                        input_neuron_index <= 0; // Reset input neuron index
                        time_step_index <= time_step_index + 1; // Move to next time step
                        $display("Time step %d, input index %d", time_step_index, input_index);
                        time_step <= 1; // Trigger time step
                    end
                end
            end else if(time_step_index < (runtime_time_step_window + runtime_nn_layers - 1)) begin
                // continue without inputs
                if (accelerator_done) begin
                    time_step_index <= time_step_index + 1; // Move to next time step
                    $display("Time step %d, no inputs", time_step_index);
                end
            end else begin
                if (accelerator_done) begin
                    time_step_index <= 0; // Reset time step count
                    input_index <= input_index + 1; // Move to next input index
                    rst_potential <= 1; // Reset potential for next input
                    start_inf <= 0; // Stop the inference process
                    $display("Inference completed for input index %d", input_index);
                end
            end
        end
    end

    assign main_fifo_rd_en_out = ~main_fifo_empty_out;

    always @(posedge clk) begin        
        if (main_fifo_rd_en_out) begin
            waiting_for_data <= 1;
        end else begin
            waiting_for_data <= 0;
        end

        if (waiting_for_data) begin
            $fwrite(file, "%d:%h \n", input_index, main_fifo_dout_out);
        end 
    end

    always @(posedge clk) begin
        if (time_step) time_step <= 0;
        if (rst_potential) begin
            rst_potential <= 0; // Reset potential signal
            start_inf <= 1; // Stop the inference process
        end
    end

    // ── Wishbone read helper ──
    reg [31:0] wb_rd_result;
    task cpu_read;
        input [31:0] baddr;
        begin
            @(posedge clk); #1;
            wb_adr_i = baddr; wb_we_i = 0;
            wb_stb_i = 1; wb_cyc_i = 1; wb_sel_i = 4'hF;
            @(posedge wb_ack_o); @(posedge clk); #1;
            wb_rd_result = wb_dat_o;
            wb_stb_i = 0; wb_cyc_i = 0;
        end
    endtask

    // ── After all inference completes: CPU reads back 8 V_mem + 2 spike words ──
    always @(posedge clk) begin
        if (input_index >= runtime_input_count) begin
            // Wait a few cycles for final dump to land
            repeat(50) @(posedge clk);
            $display("\n====== CPU READBACK FROM SHARED MEMORY (Port A Wishbone) ======");
            $display("  (vmem_base word=0xA000 → byte=0x2002_8000)");
            $display("  Reading first 8 neurons V_mem of timestep 0:");
            begin : readback
                integer k;
                for (k = 0; k < 8; k = k + 1) begin
                    cpu_read(SMEM_WB_BASE + (16'hA000 + k) * 4);
                    $display("  [WB CPU READ] vmem[%0d] @ 0x%08h = 0x%08h",
                             k, SMEM_WB_BASE + (16'hA000 + k) * 4, wb_rd_result);
                end
                $display("  Reading spike word 0 of timestep 0:");
                cpu_read(SMEM_WB_BASE + 16'hB000 * 4);
                $display("  [WB CPU READ] spike[0] @ 0x%08h = 0x%08h",
                         SMEM_WB_BASE + 16'hB000 * 4, wb_rd_result);
            end
            $display("  Total Port B V_mem writes : %0d", dump_vmem_count);
            $display("  Total Port B Spike writes : %0d", dump_spike_count);
            if (dump_vmem_count > 0 && dump_spike_count > 0)
                $display("  PASS: Accelerator dumped data into Shared Memory!");
            else
                $display("  FAIL: No dump detected!");
            $display("================================================================");
            $finish;
        end
    end

endmodule
