`timescale 1ns/1ps
`include "../riscv/simple_riscv.v"
`include "../blackbox/blackbox.v" 
// Using blackbox.v's internal includes, but actually we should just instantiate the components we need or wrapper.
// The blackbox.v is a Rocket wrapper, which is too complex.
// We will instantiate structure similar to blackbox but mapped to our simple RISC-V.

module soc_top (
    input clk,
    input rst,
    output wire accelerator_done
);

    // ==========================================
    // Memory Map
    // 0x0000_0000 - 0x0001_0000 : RAM (64KB)
    // 0x8000_0000 : Accelerator Data1 (Write)
    // 0x8000_0008 : Accelerator Data2 (Write)
    // 0x8000_0010 : Accelerator Funct (Write & Fire)
    // 0x8000_0018 : Accelerator Status (Read)
    // 0x8000_0020 : Accelerator Data Out (Read)
    // ==========================================

    // RISC-V Signals
    wire [31:0] pc;
    wire [31:0] instr;
    wire [31:0] dmem_addr;
    wire [31:0] dmem_wdata;
    wire [31:0] dmem_rdata;
    wire dmem_wen;

    // RAM Signals
    reg [31:0] ram [0:16383]; // 64KB
    reg [31:0] ram_rdata;

    // Accelerator Signals
    reg [63:0] acc_data1;
    reg [63:0] acc_data2;
    reg [6:0] acc_funct;
    reg acc_fire;
    wire acc_ready;
    wire [63:0] acc_data_out;
    
    // Wire up RISC-V
    simple_riscv cpu (
        .clk(clk),
        .rst(rst),
        .pc(pc),
        .instr(ram[pc[15:2]]), // Byte address to Word index
        .dmem_addr(dmem_addr),
        .dmem_wdata(dmem_wdata),
        .dmem_rdata(dmem_rdata),
        .dmem_wen(dmem_wen)
    );

    // MMIO Logic
    wire is_mmio = (dmem_addr[31] == 1'b1); // High bit set = MMIO
    wire is_ram = ~is_mmio;

    // RAM Write
    always @(posedge clk) begin
        if (dmem_wen && is_ram) begin
            ram[dmem_addr[15:2]] <= dmem_wdata;
        end
    end
    
    // RAM Read (Async or Sync? Simple RISC-V expects Async for now or Sync with wait? 
    // Data rdata is async in simple_riscv for now, but RAM usually sync.
    // Let's make it async read for simplicity of simulation)
    assign dmem_rdata = is_mmio ? mmio_rdata : ram[dmem_addr[15:2]];

    // MMIO Registers
    reg [31:0] mmio_rdata;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            acc_data1 <= 0;
            acc_data2 <= 0;
            acc_funct <= 0;
            acc_fire <= 0;
        end else begin
            acc_fire <= 0; // Pulse fire only for one cycle
            
            if (dmem_wen && is_mmio) begin
                case (dmem_addr)
                    32'h80000000: acc_data1[31:0] <= dmem_wdata;
                    32'h80000004: acc_data1[63:32] <= dmem_wdata;
                    32'h80000008: acc_data2[31:0] <= dmem_wdata;
                    32'h8000000C: acc_data2[63:32] <= dmem_wdata;
                    32'h80000010: begin
                        acc_funct <= dmem_wdata[6:0];
                        acc_fire <= 1; // Trigger fire when funct is written
                    end
                endcase
            end
        end
    end

    // MMIO Read Mux
    always @(*) begin
        mmio_rdata = 0;
        if (is_mmio) begin
            case (dmem_addr)
                32'h80000018: mmio_rdata = {31'b0, acc_ready};
                32'h80000020: mmio_rdata = acc_data_out[31:0];
                32'h80000024: mmio_rdata = acc_data_out[63:32];
            endcase
        end
    end

    // ==========================================
    // Accelerator Instantiation
    // ==========================================
    
    // We need the internal signals that the accelerator controller produces to feed the neuron accelerator
    wire [10:0] main_fifo_din_in;
    wire main_fifo_wr_en_in;
    wire main_fifo_full_in;
    wire [10:0] main_fifo_dout_out;
    wire main_fifo_empty_out;
    wire main_fifo_rd_en_out;
    wire [7:0] init_data_send;
    wire init_load_data_send;
    wire init_ready_data_send;
    wire [7:0] int_data_receive;
    wire init_load_data_receive;
    wire init_ready_data_receive;
    wire network_mode;
    wire time_step;
    wire rst_potential;
    wire spike_done; 
    wire init_receive_done;

    accelerator_controller #(
        .DATA_WIDTH(64),
        .FLIT_SIZE(8),
        .SPIKE_SIZE(11),
        .FUNCT(7'b0000001)
    ) controller (
        .clk(clk),
        .rst(rst),
        .fire(acc_fire),
        .ready(acc_ready),
        .funct(acc_funct),
        .data1(acc_data1),
        .data2(acc_data2),
        .data_out(acc_data_out),
        
        // NoC Interfaces
        .main_fifo_din_in(main_fifo_din_in), // Spike In
        .main_fifo_wr_en_in(main_fifo_wr_en_in),
        .main_fifo_full_in(main_fifo_full_in),
        
        .main_fifo_dout_out(main_fifo_dout_out), // Spike Out
        .main_fifo_rd_en_out(main_fifo_rd_en_out),
        .main_fifo_empty_out(main_fifo_empty_out),
        .spike_done(spike_done),
        
        // Initialization NoC
        .init_load_data_send(init_load_data_send),
        .init_data_send(init_data_send),
        .init_ready_data_send(init_ready_data_send),
        
        .int_data_receive(int_data_receive),
        .init_load_data_receive(init_load_data_receive),
        .init_ready_data_receive(init_ready_data_receive),
        .init_receive_done(init_receive_done),

        // Controls
        .network_mode(network_mode),
        .time_step(time_step),
        .rst_potential(rst_potential)
    );

    neuron_accelerator #(
        .packet_width(11), 
        .main_fifo_depth(32),
        .forwarder_8_fifo_depth(16),
        .forwarder_4_fifo_depth(8),
        .number_of_clusters(64),
        .neurons_per_cluster(32),
        .incoming_weight_table_rows(32),
        .max_weight_table_rows(32),
        .flit_size(8),
        .cluster_group_count(2)
    ) accelerator (
        .clk(clk),
        .rst(rst),
        .network_mode(network_mode),
        .time_step(time_step),
        .rst_potential(rst_potential),
        
        // Config Interface
        .load_data_in(init_load_data_send),
        .data_in(init_data_send),
        .ready_in(init_ready_data_send),
        
        .data_out(int_data_receive),
        .load_data_out(init_load_data_receive),
        .ready_out(init_ready_data_receive),
        .data_out_done(init_receive_done),
        
        // Spike Interface
        .main_fifo_din_in(main_fifo_din_in),
        .main_fifo_wr_en_in(main_fifo_wr_en_in),
        .main_fifo_full_in(main_fifo_full_in),
        
        .main_fifo_rd_en_out(main_fifo_rd_en_out),
        .main_fifo_empty_out(main_fifo_empty_out),
        .main_fifo_dout_out(main_fifo_dout_out),
        
        .accelerator_done(accelerator_done)
    );

endmodule
