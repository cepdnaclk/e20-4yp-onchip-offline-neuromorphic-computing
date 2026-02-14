// opcodes
`define OPCODE_LOAD_NI 8'h01
`define OPCODE_LOAD_IF_BASE 8'h02
`define OPCODE_LOAD_IF_ADDR 8'h03

// packet structure
// <opcode:8:ni><neuron_id:8:ni><flit_count:8:ni>{{<data:8:ni>}....}
// <opcode:8:if><row_index_1:8:if><row_index_2:8:if><cluster_id:8:if><neuron_id:8:if><mem_address_1:8:if><mem_address_2:8:if>


module cluster_controller
#(
    parameter number_of_clusters = 64,
    parameter neurons_per_cluster = 32,
    parameter max_weight_table_rows = 32
)
(
    input wire clk,
    input wire rst,
    input wire load_data,
    input wire [7:0] data,
    input wire chip_mode, 
    output wire internal_clk,
    output reg [$clog2(neurons_per_cluster)-1:0] neuron_id,
    output reg [7:0] neuron_data,
    output reg neuron_load_data,
    output reg [$clog2(number_of_clusters)-1:0] if_cluster_id,
    output reg if_load_cluster_index,
    output reg [15:0] if_base_weight_addr_init,
    output reg if_load_addr_in
);

    reg [7:0] flit_count;
    reg [7:0] flit_counter;
    reg [7:0] work_mode;
    reg [3:0] state;
    reg [7:0] buffer_index;   
    reg cluster_en;

    assign internal_clk = chip_mode ? clk : clk & cluster_en;

    always @(posedge clk) begin
        if(rst) begin
            cluster_en <= 0;
            neuron_data <= 0;
            neuron_load_data <= 0;
            if_cluster_id <= 0;
            if_load_cluster_index <= 0;
            if_base_weight_addr_init <= 0;
            if_load_addr_in <= 0;
            flit_count <= 0;
            flit_counter <= 0;
            work_mode <= 0;
            state <= 0;
            buffer_index <= 0;
        end else if(load_data) begin
            case (work_mode)
                `OPCODE_LOAD_NI: begin
                    // Neuron Init
                    case (state)
                        1: begin
                            neuron_id <= data;
                            state <= 2;
                        end
                        2: begin
                            flit_count <= data;
                            state <= 3;
                        end
                        3: begin
                            neuron_load_data <= 1;
                            if (flit_counter < flit_count) begin
                                neuron_data <= data;
                                flit_counter <= flit_counter + 1;
                            end 
                            if (flit_count - 1 == flit_counter) begin
                                flit_counter <= 0;
                                work_mode <= 0;
                                state <= 0;
                            end
                        end
                        default: begin
                            neuron_load_data <= 0;
                            state <= 0;
                        end
                    endcase
                end
                `OPCODE_LOAD_IF_ADDR: begin
                    case (state)
                        1: begin
                            if_cluster_id <= data;
                            if_load_cluster_index <= 1;
                            work_mode <= 0;
                            state <= 0;
                        end
                        default: begin
                            if_load_cluster_index <= 0;
                            state <= 0;
                        end
                    endcase
                end
                `OPCODE_LOAD_IF_BASE: begin
                    case (state)
                        1: begin
                            if_base_weight_addr_init[7:0] <= data;
                            state <= 2;
                        end
                        2: begin
                            if_base_weight_addr_init[15:8] <= data;
                            if_load_addr_in <= 1;
                            work_mode <= 0;
                            state <= 0;
                        end
                        default: begin
                            if_load_addr_in <= 0;
                            state <= 0;
                        end
                    endcase
                end
                default: begin
                    cluster_en <= 1;
                    work_mode <= data;
                    neuron_load_data <= 0;
                    if_load_cluster_index <= 0;
                    if_load_addr_in <= 0;
                    neuron_data <= 0;
                    state <= 1;
                end
            endcase
        end else begin
            neuron_load_data <= 0;
            if_load_addr_in <= 0;
            if_load_cluster_index <= 0;
        end
    end

endmodule
