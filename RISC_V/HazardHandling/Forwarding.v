module Forward (
    input [31:0] INSTRUCTION,
    input [1:0] ControlUnit_IMMEDIATE_SELECT,
    input [1:0] ControlUnit_OFFSET_GENARATOR,
    input [4:0] RD_imm_old, RD_old_old,
    input RegWrite_imm_old, RegWrite_old_old,
    output reg [1:0] Data2_ImmediateSelect,
    output reg [1:0] Data1_OffsetGenarator
);

    wire [6:0] OPCODE;
    wire [4:0] SR1, SR2, RD;
    
    assign OPCODE = INSTRUCTION[6:0];
    assign SR1 = INSTRUCTION[19:15];
    assign SR2 = INSTRUCTION[24:20];
    assign RD  = INSTRUCTION[11:7];

    always @(*) begin
        // Default assignment (No forwarding)
        Data1_OffsetGenarator = ControlUnit_OFFSET_GENARATOR;
        Data2_ImmediateSelect = ControlUnit_IMMEDIATE_SELECT;

        // RS1 Forwarding (Used by R-Type, I-Type, SW, LW, Branch, JALR)
        if ((OPCODE == 7'b0110011) || (OPCODE == 7'b0100011) || (OPCODE == 7'b0010011) || (OPCODE == 7'b0000011) || (OPCODE == 7'b1100011) || (OPCODE == 7'b1100111)) begin
             if (RegWrite_imm_old && (RD_imm_old != 0) && (SR1 == RD_imm_old)) 
                Data1_OffsetGenarator = 2'b11;       // Forward from EX
             else if (RegWrite_old_old && (RD_old_old != 0) && (SR1 == RD_old_old)) 
                Data1_OffsetGenarator = 2'b01;  // Forward from WB
        end

        // RS2 Forwarding (Used by R-Type, Branch)
        if ((OPCODE == 7'b0110011) || (OPCODE == 7'b1100011)) begin
             if (RegWrite_imm_old && (RD_imm_old != 0) && (SR2 == RD_imm_old)) 
                Data2_ImmediateSelect = 2'b11;       // Forward from EX
             else if (RegWrite_old_old && (RD_old_old != 0) && (SR2 == RD_old_old)) 
                Data2_ImmediateSelect = 2'b01;  // Forward from WB
        end
    end 

endmodule
