`timescale 1ns/1ps

module simple_riscv (
    input clk,
    input rst,
    output reg [31:0] pc,
    input [31:0] instr,
    output [31:0] dmem_addr,
    output [31:0] dmem_wdata,
    input [31:0] dmem_rdata,
    output dmem_wen
);

    // Registers
    reg [31:0] regs [0:31];
    
    // Internal Signals
    wire [6:0] opcode = instr[6:0];
    wire [2:0] funct3 = instr[14:12];
    wire [6:0] funct7 = instr[31:25];
    wire [4:0] rd = instr[11:7];
    wire [4:0] rs1 = instr[19:15];
    wire [4:0] rs2 = instr[24:20];
    
    // Immediates
    wire [31:0] imm_i = {{20{instr[31]}}, instr[31:20]};
    wire [31:0] imm_s = {{20{instr[31]}}, instr[31:25], instr[11:7]};
    wire [31:0] imm_b = {{20{instr[31]}}, instr[7], instr[30:25], instr[11:8], 1'b0};
    wire [31:0] imm_j = {{12{instr[31]}}, instr[19:12], instr[20], instr[30:21], 1'b0};
    wire [31:0] imm_u = {instr[31:12], 12'b0};

    // ALU Signals
    wire [31:0] rdata1 = (rs1 == 0) ? 0 : regs[rs1];
    wire [31:0] rdata2 = (rs2 == 0) ? 0 : regs[rs2];
    reg [31:0] alu_in2;
    reg [31:0] alu_result;
    
    // Control Signals
    reg [2:0] imm_type; // 0: I, 1: S, 2: B, 3: J, 4: U
    reg reg_write;
    reg mem_write;
    reg [1:0] alu_src; // 0: reg, 1: imm
    reg branch;
    reg jump;
    reg jalr; // New control signal for JALR

    assign dmem_addr = alu_result;
    assign dmem_wdata = rdata2;
    assign dmem_wen = mem_write;
    
    always @(*) begin
        // Default Control
        reg_write = 0;
        mem_write = 0;
        alu_src = 0;
        branch = 0;
        jump = 0;
        jalr = 0;
        
        case (opcode)
            7'b0110011: begin // R-Type (ADD, SUB, XOR, OR, AND, SLL, SRL, SRA)
                reg_write = 1;
                alu_src = 0;
            end
            7'b0010011: begin // I-Type (ADDI, XORI, ORI, ANDI, SLLI, SRLI, SRAI)
                reg_write = 1;
                alu_src = 1;
            end
            7'b0000011: begin // Load (LW)
                reg_write = 1;
                alu_src = 1;
            end
            7'b0100011: begin // Store (SW)
                mem_write = 1;
                alu_src = 1;
            end
            7'b1100011: begin // Branch (BEQ, BNE, BLT, BGE, BLTU, BGEU)
                branch = 1;
                alu_src = 0;
            end
            7'b1101111: begin // JAL
                jump = 1;
                reg_write = 1;
            end
             7'b1100111: begin // JALR
                jump = 1;
                jalr = 1;
                reg_write = 1;
                alu_src = 1;
            end
            7'b0110111: begin // LUI
                reg_write = 1;
            end
        endcase
    end

    // ALU Mux
    always @(*) begin
        if (opcode == 7'b0010011 || opcode == 7'b0000011 || opcode == 7'b0100011 || opcode == 7'b1100111) // I-Type, Load, Store, JALR
            alu_in2 = imm_i;
        else if (opcode == 7'b0100011) // S-Type
            alu_in2 = imm_s;
        else
            alu_in2 = rdata2;
    end

    // ALU Operation
    always @(*) begin
        if (opcode == 7'b0110111) begin // LUI
            alu_result = imm_u;
        end else begin
            case (funct3)
                3'b000: // ADD, SUB, ADDI
                    if (opcode == 7'b0110011 && funct7 == 7'b0100000)
                        alu_result = rdata1 - alu_in2;
                    else
                        alu_result = rdata1 + alu_in2;
                3'b111: // AND, ANDI
                     alu_result = rdata1 & alu_in2;
                3'b100: // XOR, XORI
                     alu_result = rdata1 ^ alu_in2;
                 3'b110: // OR, ORI
                     alu_result = rdata1 | alu_in2;
                 3'b001: // SLL, SLLI
                     alu_result = rdata1 << alu_in2[4:0];
                 3'b101: // SRL, SRLI, SRA, SRAI
                     if (funct7 == 7'b0100000)
                         alu_result = $signed(rdata1) >>> alu_in2[4:0];
                     else
                         alu_result = rdata1 >> alu_in2[4:0];
                 3'b010: // SLT, SLTI (Set Less Than)
                     alu_result = ($signed(rdata1) < $signed(alu_in2)) ? 1 : 0;
                 3'b011: // SLTU, SLTIU
                     alu_result = (rdata1 < alu_in2) ? 1 : 0;
                default: alu_result = 0;
            endcase
            
            // For Store/Load, ALU computes address = rs1 + imm
             if (opcode == 7'b0000011 || opcode == 7'b0100011) 
                 alu_result = rdata1 + ((opcode == 7'b0100011) ? imm_s : imm_i);
        end
    end

    // Branch Logic
    reg take_branch;
    always @(*) begin
        take_branch = 0;
        case (funct3)
            3'b000: take_branch = (rdata1 == rdata2); // BEQ
            3'b001: take_branch = (rdata1 != rdata2); // BNE
            3'b100: take_branch = ($signed(rdata1) < $signed(rdata2)); // BLT
            3'b101: take_branch = ($signed(rdata1) >= $signed(rdata2)); // BGE
            3'b110: take_branch = (rdata1 < rdata2); // BLTU
            3'b111: take_branch = (rdata1 >= rdata2); // BGEU
        endcase
    end
    
    // PC Update & Write Back
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pc <= 0;
        end else begin
            if (jump) begin
                if (jalr)
                    pc <= (rdata1 + imm_i) & ~1;
                else
                    pc <= pc + imm_j;
            end else if (branch && take_branch) begin
                pc <= pc + imm_b;
            end else begin
                pc <= pc + 4;
            end
            
            if (reg_write && rd != 0) begin
                if (jump) // JAL/JALR store PC+4
                    regs[rd] <= pc + 4;
                else if (opcode == 7'b0000011) // Load
                    regs[rd] <= dmem_rdata;
                else
                    regs[rd] <= alu_result;
            end
        end
    end

endmodule
