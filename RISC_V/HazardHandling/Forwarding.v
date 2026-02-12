module Forward (
    input [31:0] INSTRUCTION,
    input [1:0] ControlUnit_IMMEDIATE_SELECT,
    input [1:0] ControlUnit_OFFSET_GENARATOR,
    input [4:0] RD_imm_old, RD_old_old,
    input RegWrite_imm_old, RegWrite_old_old,
    output reg [1:0] Data2_ImmediateSelect,
    output reg [1:0] Data1_OffsetGenarator,
    output reg [1:0] Branch_Forward_RS1,
    output reg [1:0] Branch_Forward_RS2
);

    wire [6:0] OPCODE;
    wire [4:0] SR1, SR2, RD;
    
    assign OPCODE = INSTRUCTION[6:0];
    assign SR1 = INSTRUCTION[19:15];
    assign SR2 = INSTRUCTION[24:20];
    assign RD  = INSTRUCTION[11:7];
    
    reg [1:0] fwd1;
    reg [1:0] fwd2;

    always @(*) begin
        // Default assignment (No forwarding)
        Data1_OffsetGenarator = ControlUnit_OFFSET_GENARATOR;
        Data2_ImmediateSelect = ControlUnit_IMMEDIATE_SELECT;
        Branch_Forward_RS1 = 2'b00;
        Branch_Forward_RS2 = 2'b00;
        fwd1 = 2'b00;
        fwd2 = 2'b00;

        // RS1 Forwarding Logic
        if ((OPCODE == 7'b0110011) || (OPCODE == 7'b0100011) || (OPCODE == 7'b0010011) || (OPCODE == 7'b0000011) || (OPCODE == 7'b1100011) || (OPCODE == 7'b1100111)) begin
             // Calculate forwarding logic
             fwd1 = 2'b00;
             if (RegWrite_imm_old && (RD_imm_old != 0) && (SR1 == RD_imm_old)) 
                fwd1 = 2'b11;       // Forward from EX
             else if (RegWrite_old_old && (RD_old_old != 0) && (SR1 == RD_old_old)) 
                fwd1 = 2'b01;  // Forward from WB
             
             // Apply to specific outputs
             if (OPCODE == 7'b1100011) begin // Branch: Use dedicated output
                Branch_Forward_RS1 = fwd1;
             end else begin // Others: Use ALU Mux
                if (fwd1 != 2'b00) Data1_OffsetGenarator = fwd1;
             end
        end

        // RS2 Forwarding Logic
        if ((OPCODE == 7'b0110011) || (OPCODE == 7'b1100011)) begin
             // Calculate forwarding logic
             fwd2 = 2'b00;
             if (RegWrite_imm_old && (RD_imm_old != 0) && (SR2 == RD_imm_old)) 
                fwd2 = 2'b11;       // Forward from EX
             else if (RegWrite_old_old && (RD_old_old != 0) && (SR2 == RD_old_old)) 
                fwd2 = 2'b01;  // Forward from WB

             // Apply to specific outputs
             if (OPCODE == 7'b1100011) begin // Branch: Use dedicated output
                Branch_Forward_RS2 = fwd2;
             end else begin // Others: Use ALU Mux
                if (fwd2 != 2'b00) Data2_ImmediateSelect = fwd2;
             end
        end
    end 

endmodule
