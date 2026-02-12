`timescale 1ns/100ps

// Initialization Write
// Opcode: 0001
// data1: <OpCode 4bit><Valid Flit Count 4 bit><Flit 8bit><Flit 8bit><Flit 8bit>...
// data2: <Flit 8bit><Flit 8bit><Flit 8bit>...

// Initilization Read
// Stream Init
// Opcode: 0011
// data1: <OpCode 4bit><Valid Flit Count 4 bit><Flit 8bit><Flit 8bit><Flit 8bit>...
// data2: <Flit 8bit><Flit 8bit><Flit 8bit>...
// Stream Read
// Any

// Spike Write and Read
// Opcode: 0010
// data1: <OpCode 4bit><Valid Flit Count 4 bit><Flit 11bit><Flit 11bit><Flit 11bit>...
// data2: <Flit 11bit><Flit 11bit><Flit 11bit>...<End of Spike input bit, 1 if end else 0>
// data_out_reg: <Flit 11bit><Flit 11bit><Flit 11bit>...<Valid Flit Count 3 bit><End of spike output bit, 1 if end else 0>

module accelerator_controller #(
    parameter DATA_WIDTH = 64,
    parameter FLIT_SIZE = 8,
    parameter SPIKE_SIZE = 11,
    parameter FUNCT = 7
)
(
    input wire clk,
    input wire rst,

    output reg network_mode,  // Network mode (0: spike, 1: general)
    output reg time_step,  // Time step signal for the network
    output reg rst_potential,

    input wire fire,
    output reg ready,

    input [6:0] funct,

    input wire [DATA_WIDTH-1:0]data1,
    input wire [DATA_WIDTH-1:0]data2,
    output wire [DATA_WIDTH-1:0]data_out,

    // Spike NoC
    output reg [SPIKE_SIZE-1:0] main_fifo_din_in,  // Spike input from the network
    output reg main_fifo_wr_en_in,  // Write enable for the main FIFO
    input wire main_fifo_full_in,  // Main FIFO full signal

    output reg main_fifo_rd_en_out,  // Read enable for the main FIFO
    input wire main_fifo_empty_out,  // Main FIFO empty signal
    input wire [SPIKE_SIZE-1:0] main_fifo_dout_out,  // Spike output to the network
    input wire spike_done,

    // Initialization NoC
    output reg init_load_data_send,
    output reg [FLIT_SIZE-1:0] init_data_send,
    input wire init_ready_data_send,

    input wire [FLIT_SIZE-1:0] int_data_receive,
    input wire init_load_data_receive,
    output reg init_ready_data_receive,
    
    input wire init_receive_done
);

    // Opcodes for initialization and spike operations
    localparam INIT_WRITE_OPCODE = 4'h1;
    localparam INIT_READ_OPCODE = 4'h3;
    localparam SPIKE_WRITE_READ_OPCODE = 4'h2;

    // State machine
    localparam IDLE = 3'b000;
    localparam DECODE = 3'b011;
    localparam MESSAGE_INIT_TX = 3'b001;
    localparam MESSAGE_INIT_RX = 3'b010;
    localparam MESSAGE_SPIKE_TX_RX = 3'b100;
    localparam TIMESTEP_CHECK = 3'b101;
    localparam RST_POTENTIAL = 3'b110; 

    localparam MESSAGE_INIT_TX_SEND = 3'b000;
    localparam MESSAGE_INIT_TX_SEND_CHECK = 3'b001;

    localparam MESSAGE_INIT_RX_SEND = 3'b000;
    localparam MESSAGE_INIT_RX_SEND_CHECK = 3'b001;
    localparam MESSAGE_INIT_RX_READ = 3'b010;
    localparam MESSAGE_INIT_RX_READ_CHECK = 3'b011;
    
    localparam OUTPUT_REG_SPIKE_COUNT = DATA_WIDTH / SPIKE_SIZE; // Number of spikes that can be sent in one go
    localparam BITS_PER_COUNTS = $clog2((DATA_WIDTH*2) / 8); // Calculate bits needed for flit count
    localparam FLITS_IN_DATA_WIDTH = DATA_WIDTH / FLIT_SIZE; // Number of flits in a data width

    reg [DATA_WIDTH*2-1:0] data_buffer;
    reg [DATA_WIDTH-1:0] data_out_reg;
    reg [DATA_WIDTH-1:0] data_out_spike_reg;
    reg [2:0] state;
    reg [2:0] sub_state;  // Changed to 3 bits to match the sub-statrouter_packet_donee parameters
    reg [2:0] next_state;
    reg [2:0] next_sub_state;  // Changed to 3 bits to match the sub-state parameters

    reg [BITS_PER_COUNTS-1:0] valid_flit_count;
    reg [BITS_PER_COUNTS-1:0] flit_count;
    reg [BITS_PER_COUNTS-1:0] actual_data_out_count;
    reg [BITS_PER_COUNTS-1:0] spike_input_count; // Count of spikes sent out

    wire enable = (funct == FUNCT) ? 1'b1 : 1'b0; // Enable signal based on the function code
    reg init_spike_select; // 0 for init, 1 for spike
    reg write_read_select; // 0 write, 1 read

    reg send_done;
    reg recieve_done;
    reg data_done;
    reg read_done;
    reg end_of_spikes;
    reg end_of_input;
    reg spike_output_full;
    reg spike_input_packet_done;
    reg init_packet_done_reg;
    reg wait_for_data;

    reg [10:0] temp;
    
    // Wire to hold the selected 8-bit data based on flit_count
    reg [FLIT_SIZE-1:0] selected_init_data;
    reg [SPIKE_SIZE-1:0] selected_spike_data;

    assign data_out = (init_spike_select) ? {data_out_spike_reg[63:1], spike_done} : data_out_reg;

    // Function to select the appropriate 8-bit slice from data_buffer
    always @(*) begin
        if (init_spike_select) begin
            // Spike NoC
            case (spike_input_count)
                4'd0: selected_spike_data = data_buffer[119:109];
                4'd1: selected_spike_data = data_buffer[108:98];
                4'd2: selected_spike_data = data_buffer[97:87];
                4'd3: selected_spike_data = data_buffer[86:76];
                4'd4: selected_spike_data = data_buffer[75:65];
                4'd5: selected_spike_data = data_buffer[64:54];
                4'd6: selected_spike_data = data_buffer[53:43];
                4'd7: selected_spike_data = data_buffer[42:32];
                4'd8: selected_spike_data = data_buffer[31:21];
                4'd9: selected_spike_data = data_buffer[20:10];
                4'd10: selected_spike_data = data_buffer[9:0];
                default: selected_spike_data = 11'b0;
            endcase
        end else begin
            // Init NoC
            case (flit_count)
                4'd0:  selected_init_data = data_buffer[119:112];
                4'd1:  selected_init_data = data_buffer[111:104];
                4'd2:  selected_init_data = data_buffer[103:96];
                4'd3:  selected_init_data = data_buffer[95:88];
                4'd4:  selected_init_data = data_buffer[87:80];
                4'd5:  selected_init_data = data_buffer[79:72];
                4'd6:  selected_init_data = data_buffer[71:64];
                4'd7:  selected_init_data = data_buffer[63:56];
                4'd8:  selected_init_data = data_buffer[55:48];
                4'd9:  selected_init_data = data_buffer[47:40];
                4'd10: selected_init_data = data_buffer[39:32];
                4'd11: selected_init_data = data_buffer[31:24];
                4'd12: selected_init_data = data_buffer[23:16];
                4'd13: selected_init_data = data_buffer[15:8];
                4'd14: selected_init_data = data_buffer[7:0];
                default: selected_init_data = 8'h00;
            endcase
        end
        
    end

    always @(*) begin

        if (init_receive_done && init_packet_done_reg == 0)
            init_packet_done_reg = 1'b1;

        if (rst) begin
            next_state = IDLE;
            next_sub_state = MESSAGE_INIT_TX_SEND;
        end else begin
            case (state)
                IDLE: begin
                    if (fire) begin
                        next_state = DECODE;
                    end else begin
                        next_state = IDLE;
                    end

                    next_sub_state = MESSAGE_INIT_TX_SEND;
                    ready = 1'b0; 
                    init_packet_done_reg = 1'b0; 
                end

                DECODE: begin
                    if (enable) begin
                        if (init_spike_select) begin
                            next_state = MESSAGE_SPIKE_TX_RX;   
                        end else begin
                            if (write_read_select) begin
                                next_state = MESSAGE_INIT_RX;
                                next_sub_state = MESSAGE_INIT_RX_SEND;
                            end else begin
                                next_state = MESSAGE_INIT_TX;
                                next_sub_state = MESSAGE_INIT_TX_SEND;
                            end
                        end
                    end else begin
                        next_state = IDLE; // Stay in IDLE state if not enabled
                    end
                end

                MESSAGE_INIT_TX: begin
                    case(sub_state)

                        MESSAGE_INIT_TX_SEND: begin
                            if (send_done) begin
                                next_sub_state = MESSAGE_INIT_TX_SEND_CHECK;
                            end else begin
                                next_sub_state = MESSAGE_INIT_TX_SEND;
                            end
                        end

                        MESSAGE_INIT_TX_SEND_CHECK: begin
                            if(data_done) begin
                                ready = 1'b1; // Set ready signal to indicate completion
                                next_state = IDLE;
                            end else begin
                                next_sub_state = MESSAGE_INIT_TX_SEND;
                            end
                        end

                        default: begin
                            next_state = IDLE;
                        end
                    endcase
                end

                MESSAGE_INIT_RX: begin
                    case(sub_state)

                        MESSAGE_INIT_RX_SEND: begin
                            if (send_done) begin
                                next_sub_state = MESSAGE_INIT_RX_SEND_CHECK;
                            end else begin
                                next_sub_state = MESSAGE_INIT_RX_SEND;
                            end
                        end

                        MESSAGE_INIT_RX_SEND_CHECK: begin
                            if (data_done) begin
                                ready = 1'b1; // Set ready signal to indicate readiness for reading
                                next_sub_state = MESSAGE_INIT_RX_READ;
                            end else begin
                                next_sub_state = MESSAGE_INIT_RX_SEND;
                            end
                        end

                        MESSAGE_INIT_RX_READ: begin 
                            ready = 1'b0; // Reset ready signal during read operation
                            if (recieve_done) begin
                                next_sub_state = MESSAGE_INIT_RX_READ_CHECK;
                            end else begin
                                next_sub_state = MESSAGE_INIT_RX_READ;
                            end
                        end

                        MESSAGE_INIT_RX_READ_CHECK: begin
                            if (data_done) begin 
                                if (init_packet_done_reg) begin
                                    ready = 1'b1; // Set ready signal to indicate completion
                                    next_state = IDLE;
                                end else begin
                                    ready = 1'b1; // Set ready signal to indicate completion
                                    next_sub_state = MESSAGE_INIT_RX_READ;
                                end
                            end else begin 
                                if (read_done) begin 
                                    next_sub_state = MESSAGE_INIT_RX_READ_CHECK;
                                end else begin 
                                    next_sub_state = MESSAGE_INIT_RX_READ;
                                end
                            end
                        end

                        default: begin
                            next_state = IDLE;
                        end

                    endcase
                end

                MESSAGE_SPIKE_TX_RX: begin
                    if (spike_input_packet_done) begin
                        if (end_of_spikes) begin 
                            if (spike_done) begin 
                                if (wait_for_data == 1'b0) begin  
                                    if (end_of_input) begin 
                                        next_state = RST_POTENTIAL; 
                                    end else begin 
                                        next_state = TIMESTEP_CHECK; 
                                    end
                                end else begin 
                                    next_state = MESSAGE_SPIKE_TX_RX;
                                end
                            end else begin
                                if (wait_for_data == 1'b0) begin 
                                    if (main_fifo_empty_out == 1'b0) begin
                                        if (spike_output_full) begin
                                            next_state = IDLE;
                                            ready = 1'b1;  
                                        end else begin
                                            next_state = MESSAGE_SPIKE_TX_RX;
                                        end
                                    end else begin
                                        next_state = IDLE;
                                        ready = 1'b1; 
                                    end   
                                end else begin 
                                    next_state = MESSAGE_SPIKE_TX_RX;
                                end
                            end
                        end else begin 
                            if (wait_for_data) begin 
                                next_state = MESSAGE_SPIKE_TX_RX;
                            end else begin
                                next_state = IDLE;
                                ready = 1'b1; 
                            end
                        end
                    end else begin
                        next_state = MESSAGE_SPIKE_TX_RX;
                    end
                end

                RST_POTENTIAL: begin
                    next_state = TIMESTEP_CHECK; // Transition back to IDLE state after reset
                end

                TIMESTEP_CHECK: begin 
                    ready = 1'b1;
                    next_state = IDLE;
                end

                default: begin
                    next_state = IDLE;
                end

            endcase
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state <= IDLE;
            sub_state <= MESSAGE_INIT_TX_SEND;
            network_mode <= 1'b0; // Default to Spike NoC mode
        end else begin
            state <= next_state;
            sub_state <= next_sub_state;
        
            case (next_state)
                IDLE: begin
                    // Stay in IDLE state
                    data_buffer <= 128'b0;
                    valid_flit_count <= 4'b0;
                    init_spike_select <= 1'b0;
                    send_done <= 1'b0;
                    data_done <= 1'b0;
                    init_load_data_send <= 1'b0;
                    init_ready_data_receive <= 1'b0;
                    data_out_reg <= 64'b0;
                    data_out_spike_reg <= 64'b0;
                    flit_count <= 4'b0;
                    actual_data_out_count <= 4'b0;
                    init_data_send <= 8'b0; 
                    main_fifo_rd_en_out <= 1'b0;
                    write_read_select <= 1'b0; 
                    recieve_done <= 1'b0;
                    read_done <= 1'b0;
                    time_step <= 1'b0; // Reset time step signal
                    rst_potential <= 1'b0; // Reset potential signal
                    spike_output_full <= 1'b0;
                    wait_for_data <= 1'b0;
                end

                DECODE: begin
                    // Decode the incoming data
                    data_buffer <= {data1, data2};
                    valid_flit_count <= data1[59:56];  // Extract valid_flit_count from data1

                    case (data1[63:60])
                        INIT_WRITE_OPCODE: begin
                            // Initialization write operation
                            init_spike_select <= 1'b0;
                            write_read_select <= 1'b0; // Write operation
                            network_mode <= 1'b1; // Set to Init NoC mode
                            
                        end

                        INIT_READ_OPCODE: begin
                            // Init              ialization read operation
                            init_spike_select <= 1'b0;
                            write_read_select <= 1'b1; // Read operation
                            network_mode <= 1'b1; // Set to Init NoC mode
                        end

                        SPIKE_WRITE_READ_OPCODE: begin
                            // Spike write/read operation
                            init_spike_select <= 1'b1;
                            network_mode <= 1'b0; // Set to Spike NoC mode
                        end
                    endcase
                end

                MESSAGE_INIT_TX: begin
                    case (next_sub_state) 
                        MESSAGE_INIT_TX_SEND: begin 
                            if (init_ready_data_send) begin
                                init_load_data_send <= 1'b1;
                                init_data_send <= selected_init_data;
                                flit_count <= flit_count + 1'b1;
                                send_done <= 1'b1;
                            end else begin
                                init_load_data_send <= 1'b0;
                                send_done <= 1'b0;
                            end
                        end

                        MESSAGE_INIT_TX_SEND_CHECK: begin
                            init_load_data_send <= 1'b0;
                            if (flit_count >= valid_flit_count) begin
                                data_done <= 1'b1;
                            end else begin
                                send_done <= 1'b0;
                            end
                        end
                    endcase
                end
                
                MESSAGE_INIT_RX: begin
                    case (next_sub_state)
                        MESSAGE_INIT_RX_SEND: begin
                            if (init_ready_data_send) begin
                                init_load_data_send <= 1'b1;
                                init_data_send <= selected_init_data;
                                flit_count <= flit_count + 1'b1;
                                send_done <= 1'b1;
                            end else begin
                                init_load_data_send <= 1'b0;
                                send_done <= 1'b0;
                            end
                        end

                        MESSAGE_INIT_RX_SEND_CHECK: begin
                            init_load_data_send <= 1'b0;
                            if (flit_count >= valid_flit_count) begin
                                data_done <= 1'b1;
                                init_ready_data_receive <= 1'b1;
                                flit_count <= 4'b0;
                                valid_flit_count <= FLITS_IN_DATA_WIDTH;
                                recieve_done <= 1'b0;
                            end else begin
                                send_done <= 1'b0;
                            end
                        end

                        MESSAGE_INIT_RX_READ: begin
                            if (init_load_data_receive) begin 
                                case (flit_count)
                                    3'd0: data_out_reg[63:56] <= int_data_receive;
                                    3'd1: data_out_reg[55:48] <= int_data_receive;
                                    3'd2: data_out_reg[47:40] <= int_data_receive;
                                    3'd3: data_out_reg[39:32] <= int_data_receive;
                                    3'd4: data_out_reg[31:24] <= int_data_receive;
                                    3'd5: data_out_reg[23:16] <= int_data_receive;
                                    3'd6: data_out_reg[15:8]  <= int_data_receive;
                                    3'd7: data_out_reg[7:0]   <= int_data_receive;
                                endcase

                                flit_count <= flit_count + 1'b1;
                                init_ready_data_receive <= 1'b0;
                                recieve_done <= 1'b1;
                            end 
                            read_done <= 1'b0;
                            data_done <= 1'b0;
                        end

                        MESSAGE_INIT_RX_READ_CHECK: begin
                            recieve_done <= 1'b0;
                            if (init_packet_done_reg) begin
                                if (fire) begin 
                                    data_done <= 1'b1;
                                    init_ready_data_receive <= 1'b1;
                                    flit_count <= 4'b0;
                                end
                            end else begin
                                if (flit_count >= valid_flit_count) begin
                                    if (fire) begin 
                                        data_done <= 1'b1;
                                        init_ready_data_receive <= 1'b1;
                                        flit_count <= 4'b0;
                                    end
                                    read_done <= 1'b1;
                                end else begin
                                    init_ready_data_receive <= 1'b1;
                                end 
                            end
                        end

                    endcase
                end

                
                MESSAGE_SPIKE_TX_RX: begin

                    if (flit_count < OUTPUT_REG_SPIKE_COUNT) begin 
                        if (main_fifo_empty_out == 1'b0) begin
                            if (flit_count != OUTPUT_REG_SPIKE_COUNT -1)
                                main_fifo_rd_en_out <= 1'b1;
                            else
                                main_fifo_rd_en_out <= 1'b0; 
                        end else begin
                            main_fifo_rd_en_out <= 1'b0;
                        end

                        if (main_fifo_empty_out == 1'b0 && main_fifo_rd_en_out) begin 
                            flit_count <= flit_count + 1'b1;
                            wait_for_data <= 1'b1;
                        end 
                        else begin
                            wait_for_data <= 1'b0;
                        end

                        if (wait_for_data) begin 
                            case (actual_data_out_count)
                                4'd0: data_out_spike_reg[63:53] <= main_fifo_dout_out;
                                4'd1: data_out_spike_reg[52:42] <= main_fifo_dout_out;
                                4'd2: data_out_spike_reg[41:31] <= main_fifo_dout_out;
                                4'd3: data_out_spike_reg[30:20] <= main_fifo_dout_out;
                                4'd4: data_out_spike_reg[19:9] <= main_fifo_dout_out;
                            endcase
                            temp <= main_fifo_dout_out; 
                            actual_data_out_count <= actual_data_out_count + + 1'b1;
                            data_out_spike_reg[3:1] <= actual_data_out_count + 1'b1;
                        end
                    end else begin

                        if (main_fifo_rd_en_out) begin 
                            wait_for_data <= 1'b1;
                        end 
                        else begin
                            wait_for_data <= 1'b0;
                        end

                        if (wait_for_data) begin 
                            case (actual_data_out_count)
                                4'd0: data_out_spike_reg[63:53] <= main_fifo_dout_out;
                                4'd1: data_out_spike_reg[52:42] <= main_fifo_dout_out;
                                4'd2: data_out_spike_reg[41:31] <= main_fifo_dout_out;
                                4'd3: data_out_spike_reg[30:20] <= main_fifo_dout_out;
                                4'd4: data_out_spike_reg[19:9] <= main_fifo_dout_out;
                            endcase
                            temp <= main_fifo_dout_out; 
                            actual_data_out_count <= actual_data_out_count + + 1'b1;
                            data_out_spike_reg[3:1] <= actual_data_out_count + 1'b1;
                        end

                        if (actual_data_out_count >= OUTPUT_REG_SPIKE_COUNT - 1) begin
                            spike_output_full <= 1'b1;
                        end else begin
                            spike_output_full <= 1'b0; 
                        end
                    end
                end

                RST_POTENTIAL: begin 
                    rst_potential <= 1'b1;
                end

                TIMESTEP_CHECK: begin
                    rst_potential <= 1'b0; // Reset potential signal
                    time_step <= 1'b1; // Set time step signal
                end
                
            endcase
        end
    end


    always @(posedge clk) begin
        if (rst) begin
            end_of_spikes <= 1'b0;
            end_of_input <= 1'b0;
        end else begin
            case (next_state)
                IDLE: begin
                    spike_input_count <= 4'b0;
                    spike_input_packet_done <= 1'b0;
                    main_fifo_din_in <= 11'b0;
                    main_fifo_wr_en_in <= 1'b0;
                end

                MESSAGE_SPIKE_TX_RX: begin
                    if (spike_input_count < valid_flit_count) begin
                        if (main_fifo_full_in == 1'b0) begin
                            main_fifo_din_in <= selected_spike_data;
                            main_fifo_wr_en_in <= 1'b1;
                            spike_input_count <= spike_input_count + 1'b1;
                        end else begin
                            main_fifo_wr_en_in <= 1'b0;
                        end
                    end else begin
                        end_of_spikes <= data_buffer[0]; 

                        if (end_of_input == 1'b0) begin
                            end_of_input <= data_buffer[1];
                        end 
                        
                        spike_input_packet_done <= 1'b1;
                        main_fifo_wr_en_in <= 1'b0;
                    end 
                end

                RST_POTENTIAL: begin 
                    end_of_input <= 1'b0;
                end

                TIMESTEP_CHECK: begin
                    end_of_spikes <= 1'b0;
                end
            endcase
        end
    end
endmodule