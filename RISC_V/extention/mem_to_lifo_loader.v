// Memory-to-LIFO Loader
// Streams data from memory directly into spike/gradient LIFO buffers
// Avoids GPR bottleneck for large dataset loading

module mem_to_lifo_loader (
    input wire clk,
    input wire rst_n,
    
    // Control interface
    input wire start,              // Start loading sequence
    input wire [31:0] base_addr,   // Starting memory address
    input wire [4:0] count,        // Number of words to transfer (up to 16)
    input wire target_sel,         // 0=spike LIFO, 1=gradient LIFO
    output reg busy,               // Transfer in progress
    output reg done,               // Transfer complete pulse
    
    // Memory read interface (connects to data memory)
    output reg mem_read,
    output reg [31:0] mem_addr,
    input wire [31:0] mem_data,
    input wire mem_ready,          // Unused for this memory type
    
    // LIFO push interface
    output reg lifo_push_spike,
    output reg lifo_push_grad,
    output reg [31:0] lifo_data_spike,
    output reg [15:0] lifo_data_grad
);

    // FSM states
localparam IDLE      = 3'b000;
    localparam REQ_READ  = 3'b001;
    localparam CAPTURE   = 3'b010;
    localparam PUSH_DATA = 3'b011;
    localparam COMPLETE  = 3'b100;
    
    reg [2:0] state, next_state;
    reg [4:0] counter;             // Current transfer count
    reg [31:0] current_addr;       // Current memory address
    reg target_sel_latched;        // Latched target selection
    reg [31:0] captured_data;      // Captured memory data
    reg [1:0] wait_cycles;         // Cycle counter for memory access
    
    // State register
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE;
        end else begin
            state <= next_state;
        end
    end
    
    // Next state logic
    always @(*) begin
        next_state = state;
        case (state)
            IDLE: begin
                if (start)
                    next_state = REQ_READ;
            end
            
            REQ_READ: begin
                // Wait 2 cycles for memory read (accounts for #1 delay)
                next_state = CAPTURE;
            end
            
            CAPTURE: begin
                next_state = PUSH_DATA;
            end
            
            PUSH_DATA: begin
                if (counter == 5'd0)
                    next_state = COMPLETE;
                else
                    next_state = REQ_READ;
            end
            
            COMPLETE: begin
                next_state = IDLE;
            end
            
            default: next_state = IDLE;
        endcase
    end
    
    // Counter and address management
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            counter <= 5'd0;
            current_addr <= 32'd0;
            target_sel_latched <= 1'b0;
            captured_data <= 32'd0;
        end else begin
            case (state)
                IDLE: begin
                    if (start) begin
                        counter <= count;
                        current_addr <= base_addr;
                        target_sel_latched <= target_sel;
                    end
                end
                
                CAPTURE: begin
                    // Capture memory data
                    captured_data <= mem_data;
                end
                
                PUSH_DATA: begin
                    if (counter > 5'd0) begin
                        counter <= counter - 5'd1;
                        current_addr <= current_addr + 32'd4; // Word-aligned
                    end
                end
            endcase
        end
    end
    
    // Output generation
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            busy <= 1'b0;
            done <= 1'b0;
            mem_read <= 1'b0;
            mem_addr <= 32'd0;
            lifo_push_spike <= 1'b0;
            lifo_push_grad <= 1'b0;
            lifo_data_spike <= 32'd0;
            lifo_data_grad <= 16'd0;
        end else begin
            // Default: clear pulses
            done <= 1'b0;
            lifo_push_spike <= 1'b0;
            lifo_push_grad <= 1'b0;
            
            case (state)
                IDLE: begin
                    busy <= 1'b0;
                    mem_read <= 1'b0;
                end
                
                REQ_READ: begin
                    busy <= 1'b1;
                    mem_read <= 1'b1;
                    mem_addr <= current_addr;
                end
                
                CAPTURE: begin
                    mem_read <= 1'b0; // Deassert read to clear BUSYWAIT
                end
                
                PUSH_DATA: begin
                    mem_read <= 1'b0;
                    
                    if (target_sel_latched == 1'b0) begin
                        // Push to spike LIFO (full 32-bit word)
                        lifo_push_spike <= 1'b1;
                        lifo_data_spike <= captured_data;
                    end else begin
                        // Push to gradient LIFO (lower 16 bits)
                        lifo_push_grad <= 1'b1;
                        lifo_data_grad <= captured_data[15:0];
                    end
                end
                
                COMPLETE: begin
                    busy <= 1'b0;
                    done <= 1'b1;
                end
            endcase
        end
    end

endmodule
