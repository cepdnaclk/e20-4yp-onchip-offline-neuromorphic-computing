// EX_MEM Pipeline Register with Wishbone Stall Support
// Based on EX_MEM_pipeline.v — adds STALL input to freeze register when bus is busy

module EX_MEM_pipeline_wb (CLK,RESET,STALL,WRITE_ENABLE,MEM_ACCESS,MEM_WRITE,MEM_READ,ALU_OUTPUT,WRITE_ADDRESS,FUNCT3,DATA2,WRITE_ENABLE_OUT,MEM_ACCESS_OUT,MEM_WRITE_OUT,MEM_READ_OUT,ALU_OUTPUT_OUT,WRITE_ADDRESS_OUT,FUNCT3_OUT,DATA2_OUT,FORWARD_MEMORY,OUT_FORWARD_MEMORY);
    input CLK,RESET,STALL;
    input WRITE_ENABLE,MEM_ACCESS,MEM_WRITE,MEM_READ,FORWARD_MEMORY;
    input[31:0] ALU_OUTPUT,DATA2;
    input[4:0] WRITE_ADDRESS;
    input[2:0] FUNCT3;
    output reg WRITE_ENABLE_OUT,MEM_ACCESS_OUT,MEM_WRITE_OUT,MEM_READ_OUT,OUT_FORWARD_MEMORY;
    output reg[31:0] ALU_OUTPUT_OUT,DATA2_OUT;
    output reg[4:0] WRITE_ADDRESS_OUT;
    output reg[2:0] FUNCT3_OUT;

    always @(posedge CLK) begin
        if(RESET) begin
            #1
            WRITE_ENABLE_OUT <= 1'b0;
            MEM_ACCESS_OUT <= 1'b0;
            MEM_WRITE_OUT <= 1'b0;
            MEM_READ_OUT <= 1'b0;
            ALU_OUTPUT_OUT <= 32'b0;
            WRITE_ADDRESS_OUT <= 5'b0;
            FUNCT3_OUT <= 3'b0;
            DATA2_OUT <= 32'b0;
            OUT_FORWARD_MEMORY <= 1'b0;
        end
        else if (!STALL) begin
            #2
            WRITE_ENABLE_OUT <= WRITE_ENABLE;
            MEM_ACCESS_OUT <= MEM_ACCESS;
            MEM_WRITE_OUT <= MEM_WRITE;
            MEM_READ_OUT <= MEM_READ;
            ALU_OUTPUT_OUT <= ALU_OUTPUT;
            WRITE_ADDRESS_OUT <= WRITE_ADDRESS;
            FUNCT3_OUT <= FUNCT3;
            DATA2_OUT <= DATA2;
            OUT_FORWARD_MEMORY <= FORWARD_MEMORY;
        end
        // When STALL is high, hold all values (do nothing)
    end
    
endmodule
