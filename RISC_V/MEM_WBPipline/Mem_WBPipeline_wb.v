// MEM_WB Pipeline Register with Wishbone Stall Support
// Based on Mem_WBPipeline.v — adds STALL input to freeze register when bus is busy

module Mem_WBPipeline_wb (CLK,Reset,STALL,Write_enable,Memory_access,Memory_Data,ALU_Output,Write_Address,Write_Enable_Out,Memory_access_Out,Memory_Data_Out,ALU_Output_Out,Write_Address_out);
    input Write_enable,Memory_access;
    input [31:0] Memory_Data,ALU_Output;
    input [4:0] Write_Address;
    input CLK, Reset, STALL;

    output reg Write_Enable_Out,Memory_access_Out;
    output reg [31:0] Memory_Data_Out,ALU_Output_Out;
    output reg [4:0] Write_Address_out;

    always @(posedge CLK) begin
        if (Reset == 1) begin
           #1 
            Write_Enable_Out <= 1'b0;
            Memory_access_Out <= 1'b0;
            Memory_Data_Out <= 32'b0;
            ALU_Output_Out <= 32'b0;
            Write_Address_out <= 5'b0;
        end 
        else if (!STALL) begin
            #2
            Write_Enable_Out <= Write_enable;
            Memory_access_Out <= Memory_access;
            Memory_Data_Out <= Memory_Data;
            ALU_Output_Out <= ALU_Output;
            Write_Address_out <= Write_Address;
        end
        // When STALL is high, hold all values (do nothing)
    end

endmodule 
