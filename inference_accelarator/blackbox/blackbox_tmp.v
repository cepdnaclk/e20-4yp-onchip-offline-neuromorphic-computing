`define NEURON_ACCELERATOR
`define NEURON_INCLUDE
`define NEURON_CLUSTER
`define SPIKE_FORWARDER_4
`define SPIKE_FORWARDER_8
`define SPIKE_FORWARDER
`timescale 1ns/100ps

`include "../neuron_integer/neuron_int_lif/utils/encording.v"
// `include "../neuron_integer/neuron_int_lif/utils/multiplier_32bit.v"
// `include "../neuron_integer/neuron_int_lif/utils/shifter_32bit.v"
`include "../neuron_integer/neuron_int_lif/decay/potential_decay.v"
`include "../neuron_integer/neuron_int_lif/adder/potential_adder.v"
`include "../neuron_integer/neuron_int_lif/accumulator/accumulator.v"
`include "../neuron_integer/neuron_int_lif/neuron/controller.v"
`include "../neuron_integer/neuron_int_lif/neuron/neuron.v"
`include "../neuron_cluster/neuron_layer/neuron_layer.v"
`include "../neuron_cluster/local_forwarder/local_forwarder.v"
`include "../neuron_cluster/incoming_forwarder/incoming_forwarder.v"
`include "../neuron_cluster/cluster_controller/cluster_controller.v"
`include "../neuron_cluster/outgoing_enc/outgoing_enc.v"
`include "../FIFO/fifo.v"

`include "../neuron_cluster/neuron_cluster.v"
`include "../spike_network/spike_forwarder/spike_forwarder.v"
`include "../spike_network/spike_forwarder_controller/spike_forwarder_controller_4.v"
`include "../spike_network/spike_forwarder_controller/spike_forwarder_controller_8.v"
`include "../spike_network/spike_forwarder_4.v"
`include "../spike_network/spike_forwarder_8.v"

`include "../initialization_router/init_router.v"
`include "../accelerator_controller/accelerator_controller.v"
`include "../neuron_accelerator/neuron_accelerator.v"

module blackbox #(
//     parameter DATA_WIDTH = 64
    // Params defined by RoCC interface 
    parameter xLen = 64, // data path size
    PRV_SZ = 2, // privilege management
    coreMaxAddrBits = 40,
    dcacheReqTagBits = 9,
    M_SZ = 5,
    mem_req_bits_size_width = 2,
    coreDataBits = 64,
    coreDataBytes = 8, // byte level ops
    paddrBits = 32,
    vaddrBitsExtended = 40,
    FPConstants_RM_SZ = 3,
    fLen = 64,
    FPConstants_FLAGS_SZ  = 5
)
(
//     input wire clk,
//     input wire rst,
//     input wire fire,
//     output wire ready,
//     input wire [DATA_WIDTH-1:0]data1,
//     input wire [DATA_WIDTH-1:0]data2,
//     output wire [DATA_WIDTH-1:0]data
    // RoCCIO
    input clock,
    input reset,
    output rocc_cmd_ready,
    input rocc_cmd_valid,
    input [6:0] rocc_cmd_bits_inst_funct,
    input [4:0] rocc_cmd_bits_inst_rs2,
    input [4:0] rocc_cmd_bits_inst_rs1,
    input rocc_cmd_bits_inst_xd,
    input rocc_cmd_bits_inst_xs1,
    input rocc_cmd_bits_inst_xs2,
    input [4:0] rocc_cmd_bits_inst_rd,
    input [6:0] rocc_cmd_bits_inst_opcode,
    input [xLen-1:0] rocc_cmd_bits_rs1,
    input [xLen-1:0] rocc_cmd_bits_rs2,
    input rocc_cmd_bits_status_debug,
    input rocc_cmd_bits_status_cease,
    input rocc_cmd_bits_status_wfi,
    input [31:0] rocc_cmd_bits_status_isa,
    input [PRV_SZ-1:0] rocc_cmd_bits_status_dprv,
    input rocc_cmd_bits_status_dv,
    input [PRV_SZ-1:0] rocc_cmd_bits_status_prv,
    input rocc_cmd_bits_status_v,
    input rocc_cmd_bits_status_sd,
    input [22:0] rocc_cmd_bits_status_zero2,
    input rocc_cmd_bits_status_mpv,
    input rocc_cmd_bits_status_gva,
    input rocc_cmd_bits_status_mbe,
    input rocc_cmd_bits_status_sbe,
    input [1:0] rocc_cmd_bits_status_sxl,
    input [1:0] rocc_cmd_bits_status_uxl,
    input rocc_cmd_bits_status_sd_rv32,
    input [7:0] rocc_cmd_bits_status_zero1,
    input rocc_cmd_bits_status_tsr,
    input rocc_cmd_bits_status_tw,
    input rocc_cmd_bits_status_tvm,
    input rocc_cmd_bits_status_mxr,
    input rocc_cmd_bits_status_sum,
    input rocc_cmd_bits_status_mprv,
    input [1:0] rocc_cmd_bits_status_xs,
    input [1:0] rocc_cmd_bits_status_fs,
    input [1:0] rocc_cmd_bits_status_vs,
    input [1:0] rocc_cmd_bits_status_mpp,
    input [0:0] rocc_cmd_bits_status_spp,
    input rocc_cmd_bits_status_mpie,
    input rocc_cmd_bits_status_ube,
    input rocc_cmd_bits_status_spie,
    input rocc_cmd_bits_status_upie,
    input rocc_cmd_bits_status_mie,
    input rocc_cmd_bits_status_hie,
    input rocc_cmd_bits_status_sie,
    input rocc_cmd_bits_status_uie,
    input rocc_resp_ready,
    output rocc_resp_valid,
    output [4:0] rocc_resp_bits_rd,
    output [xLen-1:0] rocc_resp_bits_data,
    input rocc_mem_req_ready,
    output rocc_mem_req_valid,
    output [coreMaxAddrBits-1:0] rocc_mem_req_bits_addr,
    output [dcacheReqTagBits-1:0] rocc_mem_req_bits_tag,
    output [M_SZ-1:0] rocc_mem_req_bits_cmd,
    output [mem_req_bits_size_width-1:0] rocc_mem_req_bits_size,
    output rocc_mem_req_bits_signed,
    output rocc_mem_req_bits_phys,
    output rocc_mem_req_bits_no_alloc,
    output rocc_mem_req_bits_no_xcpt,
    output [1:0] rocc_mem_req_bits_dprv,
    output rocc_mem_req_bits_dv,
    output [coreDataBits-1:0] rocc_mem_req_bits_data,
    output [coreDataBytes-1:0] rocc_mem_req_bits_mask,
    output rocc_mem_s1_kill,
    output [coreDataBits-1:0] rocc_mem_s1_data_data,
    output [coreDataBytes-1:0] rocc_mem_s1_data_mask,
    input rocc_mem_s2_nack,
    input rocc_mem_s2_nack_cause_raw,
    output rocc_mem_s2_kill,
    input rocc_mem_s2_uncached,
    input [paddrBits-1:0] rocc_mem_s2_paddr,
    input [vaddrBitsExtended-1:0] rocc_mem_s2_gpa,
    input rocc_mem_s2_gpa_is_pte,
    input rocc_mem_resp_valid,
    input [coreMaxAddrBits-1:0] rocc_mem_resp_bits_addr,
    input [dcacheReqTagBits-1:0] rocc_mem_resp_bits_tag,
    input [M_SZ-1:0] rocc_mem_resp_bits_cmd,
    input [mem_req_bits_size_width-1:0] rocc_mem_resp_bits_size,
    input rocc_mem_resp_bits_signed,
    input [coreDataBits-1:0] rocc_mem_resp_bits_data,
    input [coreDataBytes-1:0] rocc_mem_resp_bits_mask,
    input rocc_mem_resp_bits_replay,
    input rocc_mem_resp_bits_has_data,
    input [coreDataBits-1:0] rocc_mem_resp_bits_data_word_bypass,
    input [coreDataBits-1:0] rocc_mem_resp_bits_data_raw,
    input [coreDataBits-1:0] rocc_mem_resp_bits_store_data,
    input [1:0] rocc_mem_resp_bits_dprv,
    input rocc_mem_resp_bits_dv,
    input rocc_mem_replay_next,
    input rocc_mem_s2_xcpt_ma_ld,
    input rocc_mem_s2_xcpt_ma_st,
    input rocc_mem_s2_xcpt_pf_ld,
    input rocc_mem_s2_xcpt_pf_st,
    input rocc_mem_s2_xcpt_gf_ld,
    input rocc_mem_s2_xcpt_gf_st,
    input rocc_mem_s2_xcpt_ae_ld,
    input rocc_mem_s2_xcpt_ae_st,
    input rocc_mem_ordered,
    input rocc_mem_perf_acquire,
    input rocc_mem_perf_release,
    input rocc_mem_perf_grant,
    input rocc_mem_perf_tlbMiss,
    input rocc_mem_perf_blocked,
    input rocc_mem_perf_canAcceptStoreThenLoad,
    input rocc_mem_perf_canAcceptStoreThenRMW,
    input rocc_mem_perf_canAcceptLoadThenLoad,
    input rocc_mem_perf_storeBufferEmptyAfterLoad,
    input rocc_mem_perf_storeBufferEmptyAfterStore,
    output rocc_mem_keep_clock_enabled,
    input rocc_mem_clock_enabled,
    output rocc_busy,
    output rocc_interrupt,
    input rocc_exception,
    input rocc_fpu_req_ready,
    output rocc_fpu_req_valid,
    output rocc_fpu_req_bits_ldst,
    output rocc_fpu_req_bits_wen,
    output rocc_fpu_req_bits_ren1,
    output rocc_fpu_req_bits_ren2,
    output rocc_fpu_req_bits_ren3,
    output rocc_fpu_req_bits_swap12,
    output rocc_fpu_req_bits_swap23,
    output [1:0] rocc_fpu_req_bits_typeTagIn,
    output [1:0] rocc_fpu_req_bits_typeTagOut,
    output rocc_fpu_req_bits_fromint,
    output rocc_fpu_req_bits_toint,
    output rocc_fpu_req_bits_fastpipe,
    output rocc_fpu_req_bits_fma,
    output rocc_fpu_req_bits_div,
    output rocc_fpu_req_bits_sqrt,
    output rocc_fpu_req_bits_wflags,
    output [FPConstants_RM_SZ-1:0] rocc_fpu_req_bits_rm,
    output [1:0] rocc_fpu_req_bits_fmaCmd,
    output [1:0] rocc_fpu_req_bits_typ,
    output [1:0] rocc_fpu_req_bits_fmt,
    output [fLen:0] rocc_fpu_req_bits_in1,
    output [fLen:0] rocc_fpu_req_bits_in2,
    output [fLen:0] rocc_fpu_req_bits_in3,
    output rocc_fpu_resp_ready,
    input rocc_fpu_resp_valid,
    input [fLen:0] rocc_fpu_resp_bits_data,
    input [FPConstants_FLAGS_SZ-1:0] rocc_fpu_resp_bits_exc
);

    localparam PACKET_WIDTH             = 11; 
    localparam FLIT_SIZE                = 8;
    localparam MAIN_FIFO_DEPTH          = 32;
    localparam FORWARDER_8_FIFO_DEPTH   = 16;
    localparam FORWARDER_4_FIFO_DEPTH   = 8;
    localparam NUMBER_OF_CLUSTERS       = 64;
    localparam NEURONS_PER_CLUSTER      = 32;
    localparam NEURONS_PER_LAYER        = 16;
    localparam MAX_WEIGHT_TABLE_ROWS    = 800;

    wire [PACKET_WIDTH-1:0] main_fifo_din_in;
    wire main_fifo_wr_en_in;
    wire main_fifo_full_in;
    wire [PACKET_WIDTH-1:0] main_fifo_dout_out;
    wire main_fifo_empty_out;
    wire main_fifo_rd_en_out;

    wire [FLIT_SIZE-1:0] data_in;
    wire ready_in;
    wire load_data_in;

    wire [FLIT_SIZE-1:0] data_out;
    wire load_data_out;
    wire ready_out;

    wire network_mode;
    wire time_step;
    wire rst_potential;
    wire spike_done; 
    wire init_receive_done;

    //Deassert unused signals
    assign rocc_mem_req_valid = 1'b0;
    assign rocc_mem_s1_kill = 1'b0;
    assign rocc_mem_s2_kill = 1'b0;
    assign rocc_busy = 1'b0;
    assign rocc_interrupt = 1'b0;
    assign rocc_fpu_req_valid = 1'b0;
    assign rocc_fpu_resp_ready = 1'b1;

    // accelerator_controller #(
    //     .DATA_WIDTH(xLen),
    //     .FLIT_SIZE(FLIT_SIZE),
    //     .SPIKE_SIZE(PACKET_WIDTH),
    //     .FUNCT(7'b0000001)
    // ) accc (
    //     .clk(clock),
    //     .rst(reset),
    //     .fire(rocc_cmd_valid),
    //     .ready(rocc_cmd_ready),
    //     .funct(rocc_cmd_bits_inst_funct),
    //     .data1(rocc_cmd_bits_rs1),
    //     .data2(rocc_cmd_bits_rs2),
    //     .data_out(rocc_resp_bits_data),
    //     .main_fifo_din_in(main_fifo_din_in),
    //     .main_fifo_wr_en_in(main_fifo_wr_en_in),
    //     .main_fifo_full_in(main_fifo_full_in),
    //     .main_fifo_dout_out(main_fifo_dout_out),
    //     .main_fifo_empty_out(main_fifo_empty_out),
    //     .main_fifo_rd_en_out(main_fifo_rd_en_out),
    //     .init_load_data_send(load_data_in),
    //     .init_data_send(data_in),
    //     .init_ready_data_send(ready_in),
    //     .int_data_receive(data_out),
    //     .init_load_data_receive(load_data_out),
    //     .init_ready_data_receive(ready_out),
    //     .network_mode(network_mode),
    //     .time_step(time_step),
    //     .rst_potential(rst_potential),
    //     .spike_done(spike_done),
    //     .init_receive_done(init_receive_done)
    // );

    // neuron_accelerator #(
    //     .packet_width(PACKET_WIDTH),
    //     .main_fifo_depth(MAIN_FIFO_DEPTH),
    //     .forwarder_8_fifo_depth(FORWARDER_8_FIFO_DEPTH),
    //     .forwarder_4_fifo_depth(FORWARDER_4_FIFO_DEPTH),
    //     .number_of_clusters(NUMBER_OF_CLUSTERS),
    //     .neurons_per_cluster(NEURONS_PER_CLUSTER),
    //     .neurons_per_layer(NEURONS_PER_LAYER),
    //     .max_weight_table_rows(MAX_WEIGHT_TABLE_ROWS),
    //     .flit_size(FLIT_SIZE)
    // ) uut (
    //     .clk(clock),
    //     .rst(reset),
    //     .network_mode(network_mode),
    //     .time_step(time_step),
    //     .rst_potential(rst_potential),
    //     .load_data_in(load_data_in),
    //     .data_in(data_in),
    //     .ready_in(ready_in),
    //     .data_out(data_out),
    //     .load_data_out(load_data_out),
    //     .ready_out(ready_out),
    //     .data_out_done(init_receive_done),
    //     .main_fifo_din_in(main_fifo_din_in),
    //     .main_fifo_wr_en_in(main_fifo_wr_en_in),
    //     .main_fifo_full_in(main_fifo_full_in),
    //     .main_fifo_dout_out(main_fifo_dout_out),
    //     .main_fifo_rd_en_out(main_fifo_rd_en_out),
    //     .main_fifo_empty_out(main_fifo_empty_out),
    //     .accelerator_done(spike_done)
    // );


    /* Accumulate rs1 and rs2 into an accumulator */
    reg [xLen-1:0] acc;
    reg doResp;
    reg [4:0] rocc_cmd_bits_inst_rd_d;
    reg ready;

    // FSM states
    parameter IDLE = 2'b00;
    parameter ACCUMULATE = 2'b01;
    parameter ADD_ONE = 2'b10;

    reg [1:0] current_state, next_state;

    always @ (posedge clock) begin
        ready <= 1'b0;
        
        if (reset) begin
            acc <= {xLen{1'b0}};
            doResp <= 1'b0;
            rocc_cmd_bits_inst_rd_d <= 5'b0;
            current_state <= IDLE;
        end
        else begin
            current_state <= next_state;
            
            case (current_state)
                IDLE: begin
                    doResp <= 1'b0;
                    if (rocc_cmd_valid) begin
                        rocc_cmd_bits_inst_rd_d <= rocc_cmd_bits_inst_rd;
                        acc <= acc + rocc_cmd_bits_rs1 + rocc_cmd_bits_rs2;
                    end
                end
                
                ACCUMULATE: begin
                    // Accumulation is done, move to next stage
                    acc <= acc + 1'b1;  // Add 1 in the second stage
                end
                
                ADD_ONE: begin
                    doResp <= rocc_cmd_bits_inst_xd;
                    ready <= 1'b1;
                end
                
                default: begin
                    // Should not reach here
                end
            endcase
        end
    end

    // Next state logic
    always @ (*) begin
        next_state = current_state;
        
        case (current_state)
            IDLE: begin
                if (rocc_cmd_valid) begin
                    next_state = ACCUMULATE;
                end
            end
            
            ACCUMULATE: begin
                next_state = ADD_ONE;
            end
            
            ADD_ONE: begin
                next_state = IDLE;
            end
            
            default: begin
                next_state = IDLE;
            end
        endcase
    end

    assign rocc_resp_valid = doResp;
    assign rocc_resp_bits_rd = rocc_cmd_bits_inst_rd_d;
    assign rocc_resp_bits_data = acc;
    assign rocc_cmd_ready = ready;
endmodule
