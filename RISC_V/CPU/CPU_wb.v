// =============================================================================
// CPU_wb.v — Custom RV32IM CPU with Wishbone Bus Interface
// =============================================================================
// Based on CPU.v — replaces internal instruction_memory and data_memory
// with external Wishbone master bus ports (ibus and dbus).
//
// Changes from original CPU.v:
//   1. Added ibus (instruction bus) and dbus (data bus) Wishbone master ports
//   2. Removed instruction_memory and data_memory instantiations
//   3. Added pipeline_stall logic for bus wait states
//   4. Uses EX_MEM_pipeline_wb and Mem_WBPipeline_wb (with STALL input)
//   5. Removes all #delay annotations for synthesizable code
// =============================================================================

// Include all submodules (same as original, except memories and pipeline regs)
`include "../MUX_32bit/MUX_32bit.v"
`include "../MUX_32bit/MUX_32bit_4input.v"
`include "../ALUunit/ALU.v"
`include "../ProgramCounter/pc.v"
`include "../Adder/adder.v"
`include "../BranchController/BranchController.v"
`include "../ControlUnit/controlUnit_wb.v"
// NOTE: instruction_memory and data_memory are NOT included (replaced by Wishbone)
`include "../EX_MEM_pipeline/EX_MEM_pipeline_wb.v"
`include "../ID_EXPipeline/ID_ExPipeline_wb.v"
// `include "../ID_EXPipeline/ID_ExPipeline.v"  // Replaced by ID_ExPipeline_wb.v
`include "../ID_IF_pipeLIne/ID_IF_register.v"
`include "../ImidiateGenarator/imidiateGenarator.v"
`include "../RegisterFile/registerfile.v"
`include "../MEM_WBPipline/Mem_WBPipeline_wb.v"
`include "../HazardHandling/Forwarding.v"
`include "../HazardHandling/LoadUserHazard/load_use_hazard.v"
`include "../HazardHandling/LoadUserHazard/Forward_loaduse_comparator.v"

module CPU_wb (
    input CLK, RESET,
    
    // =========================================================================
    // Instruction Wishbone Master (ibus) — IF stage fetches instructions here
    // =========================================================================
    output        ibus_cyc_o,   // Bus cycle active
    output        ibus_stb_o,   // Strobe (request valid)
    output [31:0] ibus_adr_o,   // Address (PC value)
    input  [31:0] ibus_dat_i,   // Read data (instruction)
    input         ibus_ack_i,   // Acknowledge

    // =========================================================================
    // Data Wishbone Master (dbus) — MEM stage does load/store here
    // =========================================================================
    output        dbus_cyc_o,   // Bus cycle active
    output        dbus_stb_o,   // Strobe (request valid)
    output        dbus_we_o,    // Write enable (0=read/load, 1=write/store)
    output [31:0] dbus_adr_o,   // Address (ALU result)
    output [31:0] dbus_dat_o,   // Write data (store value)
    output [3:0]  dbus_sel_o,   // Byte select (for SB/SH/SW)
    input  [31:0] dbus_dat_i,   // Read data (load value)
    input         dbus_ack_i    // Acknowledge
);

    // =========================================================================
    // Internal Wires (same as original CPU.v)
    // =========================================================================
    wire [31:0] INSTRUCTION;
    wire [31:0] PC, PC_PLUS_4, WRITEDATA, DATA1, DATA2, ALURESULT, TARGETEDADDRESS, PC_MUX_OUT, PCOUT;
    wire PCADDRESSCONTROLLER, BRANCH, JUMP, MEMREAD, MEMWRITE, JUMPANDLINK, WRITEENABLE, MEMORYACCESS;
    wire [1:0] ControlUnitIMMEDIATESELECT, ControlUnitOFFSETGENARATOR, IMMEDIATESELECT, OFFSETGENARATOR;
    
    // Flush signal
    wire FLUSH_TRIGGER;
    assign FLUSH_TRIGGER = PCADDRESSCONTROLLER;
    
    wire [31:0] INSTRUCTION_WITH_FLUSH;
    assign INSTRUCTION_WITH_FLUSH = (FLUSH_TRIGGER) ? 32'b0 : INSTRUCTION;
    
    wire BUBBLE_FOR_ID_EX;
    assign BUBBLE_FOR_ID_EX = BUBBLE | FLUSH_TRIGGER;
    
    wire [4:0] ALU_OPCODE;
    wire [2:0] IMMEDIATE_TYPE;
    wire [4:0] RS1, RS2;
    wire [31:0] IMMEDIATE_VALUE;
    assign RS1 = INSTRUCTION_OUT[19:15];
    assign RS2 = INSTRUCTION_OUT[24:20];

    // IF/ID pipeline out
    wire [31:0] INSTRUCTION_OUT, PC_OUT, PC_PLUS_4_OUT;

    // ID/EX pipeline out
    wire WRITEENABLE_IDOUT, MEMORYACCESS_IDOUT, MEMWRITE_IDOUT, MEMREAD_IDOUT, JAL_IDOUT, BRANCH_IDOUT, JUMP_IDOUT, FORWARD_MEMORY_IDOUT;
    wire [1:0] IMMEDIATESELECT_IDOUT, OFFSETGENARATOR_IDOUT;
    wire [4:0] ALU_OPCODE_IDOUT, WRITEADDRESS_IDOUT;
    wire [31:0] PC_IDOUT, PC_PLUS_4_IDOUT, DATA1_IDOUT, DATA2_IDOUT, IMMEDIATE_VALUE_IDOUT;
    wire [2:0] FUNCT3_IDOUT;

    // Data muxes out
    wire [31:0] Data1_MUX_OUT, Data2_MUX_OUT;

    // JAL mux out
    wire [31:0] JAL_MUX_OUT;

    // EX/MEM pipeline out
    wire WRITEENABLE_EXOUT, MEMORYACCESS_EXOUT, MEMWRITE_EXOUT, MEMREAD_EXOUT, FORWARD_MEMORY_EXOUT;
    wire [31:0] ALURESULT_EXOUT, DATA2_EXOUT;
    wire [4:0] WRITEADDRESS_EXOUT;
    wire [2:0] FUNCT3_EXOUT;

    // Data memory out (now comes from Wishbone bus)
    wire [31:0] DATA_OUT;

    // BUSYWAIT (no longer used, replaced by pipeline_stall)
    wire BUSYWAIT;
    assign BUSYWAIT = 1'b0; // Not used in Wishbone version

    // MEM/WB pipeline out
    wire WRITEENABLE_MEMOUT, MEMORYACCESS_MEMOUT;
    wire [31:0] ALURESULT_MEMOUT, READDATA_MEMOUT;
    wire [4:0] WRITEADDRESS_MEMOUT;

    // Data memory mux
    wire [31:0] DATA2_FORWARD;

    // Load-use hazard
    wire BUBBLE;
    wire [1:0] FRWD_RS1_WB, FRWD_RS2_WB;
    wire FORWARD_MEMORY;

    // Forwarding
    wire [1:0] FORWARD_RS1, FORWARD_RS2;
    wire [1:0] Out_Load_Use_Hazard_RS1, Out_Load_Use_Hazard_RS2;
    wire [1:0] Branch_Forward_RS1_ID, Branch_Forward_RS2_ID, Branch_Forward_RS1_EXOUT, Branch_Forward_RS2_EXOUT;
    wire [1:0] Load_Use_Hazard_RS1, Load_Use_Hazard_RS2;

    // =========================================================================
    // WISHBONE BUS LOGIC
    // =========================================================================

    // --- Instruction Bus (ibus) ---
    // The IF stage always requests the instruction at PCOUT
    // Yield Instruction Bus when a Data Bus request is active to allow Shared Bus Arbitration
    assign ibus_cyc_o = ~RESET & ~(MEMREAD_EXOUT | MEMWRITE_EXOUT);
    assign ibus_stb_o = ~RESET & ~(MEMREAD_EXOUT | MEMWRITE_EXOUT);
    assign ibus_adr_o = PCOUT;
    
    // Instruction comes from the bus
    assign INSTRUCTION = ibus_dat_i;
    
    // Stall when instruction bus hasn't acknowledged yet
    wire ibus_stall = ibus_stb_o & ~ibus_ack_i;

    // --- Data Bus (dbus) ---
    // The MEM stage issues load/store requests
    wire dbus_request = MEMREAD_EXOUT | MEMWRITE_EXOUT;
    assign dbus_cyc_o = dbus_request;
    assign dbus_stb_o = dbus_request;
    assign dbus_we_o  = MEMWRITE_EXOUT;
    assign dbus_adr_o = ALURESULT_EXOUT;
    assign dbus_dat_o = DATA2_FORWARD;

    // Byte select based on FUNCT3 (SB=1byte, SH=2bytes, SW=4bytes)
    // No byte-lane shifting — our CPU always puts data in the lowest bits
    assign dbus_sel_o = (FUNCT3_EXOUT[1:0] == 2'b00) ? 4'b0001 :  // SB
                        (FUNCT3_EXOUT[1:0] == 2'b01) ? 4'b0011 :  // SH
                                                        4'b1111;   // SW

    // Read data comes from the bus
    assign DATA_OUT = dbus_dat_i;

    // Stall when data bus hasn't acknowledged yet  
    wire dbus_stall = dbus_request & ~dbus_ack_i;

    // --- Combined Pipeline Stall ---
    wire pipeline_stall = ibus_stall | dbus_stall;

    // For PC and IF/ID: use BUBBLE OR STALL to freeze (both cause hold)
    wire BUBBLE_OR_STALL = BUBBLE | pipeline_stall;
    // For ID/EX: separate STALL (hold) from BUBBLE (insert NOP)
    // BUBBLE_FOR_ID_EX is the original hazard/flush bubble
    // pipeline_stall is the Wishbone stall (should hold, not bubble)

    // =========================================================================
    // INSTRUCTION FETCH STAGE
    // =========================================================================
    // No instruction_memory module — instructions come from ibus
    MUX_32bit PC_MUX(PC_PLUS_4, TARGETEDADDRESS, PCADDRESSCONTROLLER, PC_MUX_OUT);
    pc pc1(PC_MUX_OUT, RESET, CLK, PCOUT, BUBBLE_OR_STALL);  // Stall freezes PC
    adder pc_4_adder(PCOUT, PC_PLUS_4);
    ID_IF_register ID_IF_register1(CLK, INSTRUCTION_WITH_FLUSH, PCOUT, PC_PLUS_4, RESET, BUBBLE_OR_STALL, INSTRUCTION_OUT, PC_OUT, PC_PLUS_4_OUT);

    // =========================================================================
    // INSTRUCTION DECODE STAGE
    // =========================================================================
    controlUnit_wb controlunit1(INSTRUCTION_OUT, WRITEENABLE, MEMORYACCESS, MEMWRITE, MEMREAD, JUMPANDLINK, ALU_OPCODE, ControlUnitIMMEDIATESELECT, ControlUnitOFFSETGENARATOR, BRANCH, JUMP, IMMEDIATE_TYPE);
    
    Forward immForwarding(INSTRUCTION_OUT, ControlUnitIMMEDIATESELECT, ControlUnitOFFSETGENARATOR, WRITEADDRESS_IDOUT, WRITEADDRESS_EXOUT, WRITEENABLE_IDOUT, WRITEENABLE_EXOUT, IMMEDIATESELECT, OFFSETGENARATOR, Branch_Forward_RS1_ID, Branch_Forward_RS2_ID);
    
    load_use_hazard load_use_hazard1(MEMREAD_IDOUT, MEMWRITE, RS1, RS2, WRITEADDRESS_IDOUT, MEMREAD_EXOUT, WRITEADDRESS_EXOUT, FRWD_RS1_WB, FRWD_RS2_WB, BUBBLE, FORWARD_MEMORY);
    RegisterFile registerfile1(RS1, RS2, WRITEDATA, WRITEADDRESS_MEMOUT, WRITEENABLE_MEMOUT, RESET, CLK, DATA1, DATA2);
    imidiateGenarator imidiateGenarator1(INSTRUCTION_OUT, IMMEDIATE_TYPE, IMMEDIATE_VALUE);

    // ID/EX pipeline — uses _wb version with separate STALL (hold) and BUBBLE (NOP)
    ID_ExPipeline_wb ID_EXPipeline1(CLK, RESET, BUBBLE_FOR_ID_EX, pipeline_stall, WRITEENABLE, MEMORYACCESS, MEMWRITE, MEMREAD, JUMPANDLINK, ALU_OPCODE, IMMEDIATESELECT, OFFSETGENARATOR, BRANCH, JUMP, PC_OUT, PC_PLUS_4_OUT, DATA1, DATA2, INSTRUCTION_OUT, IMMEDIATE_VALUE, WRITEENABLE_IDOUT, MEMORYACCESS_IDOUT, MEMWRITE_IDOUT, MEMREAD_IDOUT, JAL_IDOUT, ALU_OPCODE_IDOUT, IMMEDIATESELECT_IDOUT, OFFSETGENARATOR_IDOUT, BRANCH_IDOUT, JUMP_IDOUT, PC_IDOUT, PC_PLUS_4_IDOUT, DATA1_IDOUT, DATA2_IDOUT, WRITEADDRESS_IDOUT, FUNCT3_IDOUT, IMMEDIATE_VALUE_IDOUT, Load_Use_Hazard_RS1, Load_Use_Hazard_RS2, Out_Load_Use_Hazard_RS1, Out_Load_Use_Hazard_RS2, FORWARD_MEMORY, FORWARD_MEMORY_IDOUT, Branch_Forward_RS1_ID, Branch_Forward_RS2_ID, Branch_Forward_RS1_EXOUT, Branch_Forward_RS2_EXOUT);

    // =========================================================================
    // EXECUTION STAGE
    // =========================================================================
    LoadUseComparator LoadUseComparator1(OFFSETGENARATOR_IDOUT, IMMEDIATESELECT_IDOUT, Out_Load_Use_Hazard_RS1, Out_Load_Use_Hazard_RS2, FORWARD_RS1, FORWARD_RS2);
    MUX_32bit_4input Data1_MUX(DATA1_IDOUT, PC_IDOUT, ALURESULT_EXOUT, WRITEDATA, FORWARD_RS1, Data1_MUX_OUT);
    MUX_32bit_4input Data2_MUX(DATA2_IDOUT, IMMEDIATE_VALUE_IDOUT, ALURESULT_EXOUT, WRITEDATA, FORWARD_RS2, Data2_MUX_OUT);
    alu ALU(Data1_MUX_OUT, Data2_MUX_OUT, ALU_OPCODE_IDOUT, ALURESULT);
    MUX_32bit JAL_MUX(ALURESULT, PC_PLUS_4_IDOUT, JAL_IDOUT, JAL_MUX_OUT);
    
    // Dedicated Branch Forwarding MUXes
    wire [31:0] BRANCH_DATA1, BRANCH_DATA2;
    MUX_32bit_4input Branch_Data1_MUX(DATA1_IDOUT, DATA1_IDOUT, ALURESULT_EXOUT, WRITEDATA, Branch_Forward_RS1_EXOUT, BRANCH_DATA1);
    MUX_32bit_4input Branch_Data2_MUX(DATA2_IDOUT, DATA2_IDOUT, ALURESULT_EXOUT, WRITEDATA, Branch_Forward_RS2_EXOUT, BRANCH_DATA2);
    
    BranchController BranchController1(BRANCH_DATA1, BRANCH_DATA2, FUNCT3_IDOUT, ALURESULT, BRANCH_IDOUT, JUMP_IDOUT, TARGETEDADDRESS, PCADDRESSCONTROLLER);
    
    // EX/MEM pipeline — uses _wb version with STALL
    EX_MEM_pipeline_wb EX_MEM_pipeline1(CLK, RESET, pipeline_stall, WRITEENABLE_IDOUT, MEMORYACCESS_IDOUT, MEMWRITE_IDOUT, MEMREAD_IDOUT, JAL_MUX_OUT, WRITEADDRESS_IDOUT, FUNCT3_IDOUT, DATA2_IDOUT, WRITEENABLE_EXOUT, MEMORYACCESS_EXOUT, MEMWRITE_EXOUT, MEMREAD_EXOUT, ALURESULT_EXOUT, WRITEADDRESS_EXOUT, FUNCT3_EXOUT, DATA2_EXOUT, FORWARD_MEMORY_IDOUT, FORWARD_MEMORY_EXOUT);

    // =========================================================================
    // MEMORY STAGE
    // =========================================================================
    // No data_memory module — load/store goes through dbus Wishbone
    MUX_32bit_4input datamemory_MUX(DATA2_EXOUT, 32'b0, WRITEDATA, 32'b0, {FORWARD_MEMORY_EXOUT, FORWARD_MEMORY_EXOUT}, DATA2_FORWARD);
    
    // MEM/WB pipeline — uses _wb version with STALL
    Mem_WBPipeline_wb MEM_WBPipeline1(CLK, RESET, pipeline_stall, WRITEENABLE_EXOUT, MEMORYACCESS_EXOUT, DATA_OUT, ALURESULT_EXOUT, WRITEADDRESS_EXOUT, WRITEENABLE_MEMOUT, MEMORYACCESS_MEMOUT, READDATA_MEMOUT, ALURESULT_MEMOUT, WRITEADDRESS_MEMOUT);

    // =========================================================================
    // WRITE BACK STAGE
    // =========================================================================
    MUX_32bit Memory_access_MUX(ALURESULT_MEMOUT, READDATA_MEMOUT, MEMORYACCESS_MEMOUT, WRITEDATA);

endmodule

