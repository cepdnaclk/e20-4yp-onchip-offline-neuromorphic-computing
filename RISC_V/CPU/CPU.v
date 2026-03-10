`include "../MUX_32bit/MUX_32bit.v"
`include "../MUX_32bit/MUX_32bit_4input.v"
`include "../ALUunit/ALU.v"
`include "../ProgramCounter/pc.v"
`include "../Adder/adder.v"
`include "../BranchController/BranchController.v"
`include "../ControlUnit/controlUnit.v"
`include "../Data Memory/datamem.v"
`include "../EX_MEM_pipeline/EX_MEM_pipeline.v"
`include "../ID_EXPipeline/ID_ExPipeline.v"
`include "../ID_IF_pipeLIne/ID_IF_register.v"
`include "../ImidiateGenarator/imidiateGenarator.v"
`include "../InstructionMemory/instructionmem.v"
`include "../RegisterFile/registerfile.v"
`include "../MEM_WBPipline/Mem_WBPipeline.v"
`include "../HazardHandling/Forwarding.v"
`include "../HazardHandling/LoadUserHazard/load_use_hazard.v"
`include "../HazardHandling/LoadUserHazard/Forward_loaduse_comparator.v"
`include "../extention/extention_in_EX.v"
`include "../extention/mem_to_lifo_loader.v"
`include "../LIFO_Buffer/LIFO_buffer.v"

module CPU (CLK, RESET);
    input CLK, RESET;
    wire [31:0] INSTRUCTION;
    wire [31:0] PC, PC_PLUS_4,  WRITEDATA, DATA1, DATA2, ALURESULT, TARGETEDADDRESS,PC_MUX_OUT,PCOUT;
    wire PCADDRESSCONTROLLER, BRANCH, JUMP, MEMREAD, MEMWRITE, JUMPANDLINK, WRITEENABLE, MEMORYACCESS, PUSH, POP, CUSTOM_ENABLE, LOAD_NEW_WEIGHT, MEM_TO_LIFO_START, MEM_TO_LIFO_TARGET, CUSTOM_WRITEBACK;
    wire [1:0] ControlUnitIMMEDIATESELECT,ControlUnitOFFSETGENARATOR,IMMEDIATESELECT,OFFSETGENARATOR;
    
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
    //ID_IF pipeline out

    wire [31:0] INSTRUCTION_OUT, PC_OUT, PC_PLUS_4_OUT;

    //ID_EX pipeline out
    wire WRITEENABLE_IDOUT,MEMORYACCESS_IDOUT,MEMWRITE_IDOUT,MEMREAD_IDOUT,JAL_IDOUT,BRANCH_IDOUT,JUMP_IDOUT,FORWARD_MEMORY_IDOUT,CUSTOM_ENABLE_IDOUT,LOAD_NEW_WEIGHT_IDOUT,CUSTOM_WRITEBACK_IDOUT;
    wire[1:0] IMMEDIATESELECT_IDOUT,OFFSETGENARATOR_IDOUT;
    wire [4:0] ALU_OPCODE_IDOUT,WRITEADDRESS_IDOUT;
    wire [31:0] PC_IDOUT,PC_PLUS_4_IDOUT,DATA1_IDOUT,DATA2_IDOUT,IMMEDIATE_VALUE_IDOUT;
    wire [2:0] FUNCT3_IDOUT;

    // data muxes out
    wire [31:0] Data1_MUX_OUT, Data2_MUX_OUT;

    //JAL mux out 
    wire [31:0] JAL_MUX_OUT;

    //EX_MEM pipeline out
    wire WRITEENABLE_EXOUT,MEMORYACCESS_EXOUT,MEMWRITE_EXOUT,MEMREAD_EXOUT,FORWARD_MEMORY_EXOUT,CUSTOM_WRITEBACK_EXOUT;
    wire [31:0] ALURESULT_EXOUT,DATA2_EXOUT,UPDATED_WEIGHT_EXOUT;
    wire [4:0] WRITEADDRESS_EXOUT;
    wire [2:0] FUNCT3_EXOUT;

    //data memory out
    wire [31:0] DATA_OUT;

    //BUSYWAIT
    wire BUSYWAIT;

    //MEM_WB pipeline out
    wire WRITEENABLE_MEMOUT,MEMORYACCESS_MEMOUT,CUSTOM_WRITEBACK_MEMOUT;
    wire [31:0] ALURESULT_MEMOUT,READDATA_MEMOUT,UPDATED_WEIGHT_MEMOUT;
    wire [4:0] WRITEADDRESS_MEMOUT;

    // Data memory mux
    wire [31:0] DATA2_FORWARD;

    // load use hazard
    wire BUBBLE;
    wire [1:0] FRWD_RS1_WB, FRWD_RS2_WB;
    wire FORWARD_MEMORY;;

    // Forwarding
    wire [1:0] FORWARD_RS1, FORWARD_RS2;
    wire [1:0] Out_Load_Use_Hazard_RS1, Out_Load_Use_Hazard_RS2;
    wire [1:0] Branch_Forward_RS1_ID, Branch_Forward_RS2_ID, Branch_Forward_RS1_EXOUT, Branch_Forward_RS2_EXOUT; // New Wires
    
    wire [1:0] Load_Use_Hazard_RS1, Load_Use_Hazard_RS2;

    // LIFO Buffer
    wire serial_out_grad, serial_out_spike_status, busy_spike, busy_grad;
    wire [31:0] spike_stream_word;
    wire spike_stream_valid;
    wire [15:0] grad_stream_value;
    wire grad_stream_valid;

    // Custom backpropagation unit
    wire [31:0] UPDATED_WEIGHT;
    
    // Memory-to-LIFO loader
    wire mem_loader_busy, mem_loader_done;
    wire mem_loader_read;
    wire [31:0] mem_loader_addr;
    wire mem_loader_push_spike, mem_loader_push_grad;
    wire [31:0] mem_loader_data_spike;
    wire [15:0] mem_loader_data_grad;
    
    // Multiplexed memory interface
    wire mem_read_muxed, mem_write_muxed;
    wire [31:0] mem_addr_muxed;
    wire mem_ready;
    
    // Combined LIFO push signals
    wire push_spike_combined, push_grad_combined;
    wire [31:0] data_spike_combined;
    wire [15:0] data_grad_combined;

    // instruction fetch stage
    instruction_memory instructionmem1(RESET,PCOUT, INSTRUCTION);
    MUX_32bit PC_MUX(PC_PLUS_4, TARGETEDADDRESS, PCADDRESSCONTROLLER, PC_MUX_OUT);
    pc pc1(PC_MUX_OUT, RESET, CLK, PCOUT ,BUBBLE);
    adder pc_4_adder(PCOUT,PC_PLUS_4);
    ID_IF_register ID_IF_register1(CLK, INSTRUCTION_WITH_FLUSH,PCOUT,PC_PLUS_4,RESET,BUBBLE,INSTRUCTION_OUT,PC_OUT,PC_PLUS_4_OUT);

    // instruction decode stage
    controlUnit controlunit1(INSTRUCTION_OUT, WRITEENABLE, MEMORYACCESS, MEMWRITE, MEMREAD, JUMPANDLINK, ALU_OPCODE, ControlUnitIMMEDIATESELECT, ControlUnitOFFSETGENARATOR, BRANCH, JUMP, IMMEDIATE_TYPE, PUSH, POP, CUSTOM_ENABLE, LOAD_NEW_WEIGHT, MEM_TO_LIFO_START, MEM_TO_LIFO_TARGET, CUSTOM_WRITEBACK);
    
    Forward immForwarding(INSTRUCTION_OUT,ControlUnitIMMEDIATESELECT,ControlUnitOFFSETGENARATOR,WRITEADDRESS_IDOUT,WRITEADDRESS_EXOUT,WRITEENABLE_IDOUT,WRITEENABLE_EXOUT,IMMEDIATESELECT,OFFSETGENARATOR,Branch_Forward_RS1_ID,Branch_Forward_RS2_ID);
    
      load_use_hazard load_use_hazard1(MEMREAD_IDOUT,MEMWRITE,RS1,RS2,WRITEADDRESS_IDOUT,MEMREAD_EXOUT,WRITEADDRESS_EXOUT,FRWD_RS1_WB,FRWD_RS2_WB,BUBBLE,FORWARD_MEMORY);
    RegisterFile registerfile1(RS1,RS2,WRITEDATA,WRITEADDRESS_MEMOUT,WRITEENABLE_MEMOUT,RESET,CLK,DATA1,DATA2);
    imidiateGenarator imidiateGenarator1(INSTRUCTION_OUT,IMMEDIATE_TYPE,IMMEDIATE_VALUE);
    
    // Memory-to-LIFO Loader
    // Uses rs1 as base address, rs2[4:0] as count
    mem_to_lifo_loader mem_lifo_loader(
        .clk(CLK),
        .rst_n(~RESET),
        .start(MEM_TO_LIFO_START),
        .base_addr(DATA1),
        .count(DATA2[4:0]),
        .target_sel(MEM_TO_LIFO_TARGET),
        .busy(mem_loader_busy),
        .done(mem_loader_done),
        .mem_read(mem_loader_read),
        .mem_addr(mem_loader_addr),
        .mem_data(DATA_OUT),
        .mem_ready(mem_ready),
        .lifo_push_spike(mem_loader_push_spike),
        .lifo_push_grad(mem_loader_push_grad),
        .lifo_data_spike(mem_loader_data_spike),
        .lifo_data_grad(mem_loader_data_grad)
    );
    
    // Multiplex memory access between EX stage and LIFO loader
    assign mem_read_muxed = mem_loader_busy ? mem_loader_read : MEMREAD_EXOUT;
    assign mem_write_muxed = mem_loader_busy ? 1'b0 : MEMWRITE_EXOUT;
    assign mem_addr_muxed = mem_loader_busy ? mem_loader_addr : ALURESULT_EXOUT;
    assign mem_ready = ~BUSYWAIT;
    
    // Combine LIFO push signals (register-based PUSH or memory loader push)
    assign push_spike_combined = PUSH | mem_loader_push_spike;
    assign push_grad_combined = PUSH | mem_loader_push_grad;
    assign data_spike_combined = mem_loader_busy ? mem_loader_data_spike : DATA1;
    assign data_grad_combined = mem_loader_busy ? mem_loader_data_grad : DATA2[15:0];
    
    PISO_LIFO #(.DATA_WIDTH(32), .DEPTH(16), .SERIALIZE_BITS(1)) LIFO_Buffer_spike_status(
      .clk(CLK),
      .rst(RESET),
      .push(push_spike_combined),
      .pop_trigger(POP),
      .data_in(data_spike_combined),
      .serial_out(serial_out_spike_status),
      .busy(busy_spike),
      .data_out(spike_stream_word),
      .data_valid(spike_stream_valid)
    );

    PISO_LIFO #(.DATA_WIDTH(16), .DEPTH(16), .SERIALIZE_BITS(0)) LIFO_Buffer_grad_value(
      .clk(CLK),
      .rst(RESET),
      .push(push_grad_combined),
      .pop_trigger(POP),
      .data_in(data_grad_combined),
      .serial_out(serial_out_grad),
      .busy(busy_grad),
      .data_out(grad_stream_value),
      .data_valid(grad_stream_valid)
    );

    ID_ExPipeline ID_EXPipeline1(CLK,RESET,BUBBLE_FOR_ID_EX,WRITEENABLE,MEMORYACCESS,MEMWRITE,MEMREAD,JUMPANDLINK,ALU_OPCODE,IMMEDIATESELECT,OFFSETGENARATOR,BRANCH,JUMP,PC_OUT,PC_PLUS_4_OUT,DATA1,DATA2,INSTRUCTION_OUT,IMMEDIATE_VALUE,WRITEENABLE_IDOUT,MEMORYACCESS_IDOUT,MEMWRITE_IDOUT,MEMREAD_IDOUT,JAL_IDOUT,ALU_OPCODE_IDOUT,IMMEDIATESELECT_IDOUT,OFFSETGENARATOR_IDOUT,BRANCH_IDOUT,JUMP_IDOUT,PC_IDOUT,PC_PLUS_4_IDOUT,DATA1_IDOUT,DATA2_IDOUT,WRITEADDRESS_IDOUT,FUNCT3_IDOUT,IMMEDIATE_VALUE_IDOUT,Load_Use_Hazard_RS1,Load_Use_Hazard_RS2,Out_Load_Use_Hazard_RS1,Out_Load_Use_Hazard_RS2,FORWARD_MEMORY,FORWARD_MEMORY_IDOUT,Branch_Forward_RS1_ID,Branch_Forward_RS2_ID,Branch_Forward_RS1_EXOUT,Branch_Forward_RS2_EXOUT,CUSTOM_ENABLE,LOAD_NEW_WEIGHT,CUSTOM_ENABLE_IDOUT,LOAD_NEW_WEIGHT_IDOUT,CUSTOM_WRITEBACK,CUSTOM_WRITEBACK_IDOUT);

    // Execution stage
    LoadUseComparator LoadUseComparator1(OFFSETGENARATOR_IDOUT,IMMEDIATESELECT_IDOUT,Out_Load_Use_Hazard_RS1,Out_Load_Use_Hazard_RS2,FORWARD_RS1,FORWARD_RS2);
    MUX_32bit_4input Data1_MUX(DATA1_IDOUT,PC_IDOUT,ALURESULT_EXOUT,WRITEDATA,FORWARD_RS1,Data1_MUX_OUT);
    MUX_32bit_4input Data2_MUX(DATA2_IDOUT,IMMEDIATE_VALUE_IDOUT,ALURESULT_EXOUT,WRITEDATA,FORWARD_RS2,Data2_MUX_OUT);
    alu ALU(Data1_MUX_OUT,Data2_MUX_OUT,ALU_OPCODE_IDOUT,ALURESULT);
    MUX_32bit JAL_MUX(ALURESULT,PC_PLUS_4_IDOUT,JAL_IDOUT,JAL_MUX_OUT);
    
    // Custom backpropagation unit (serial inputs from LIFO + weight from ID_EX Data1)
    // DATA1_IDOUT is shared by ALU path and custom unit weight input.
    customCalculation custom_unit(
      .clk(CLK),
      .rst_n(~RESET),
      .enable(CUSTOM_ENABLE_IDOUT),
      .error_term_in(DATA2_IDOUT[15:0]),
      .gradient_val(grad_stream_value),
      .grad_valid(grad_stream_valid),
      .spike_status(serial_out_spike_status),
      .weight(DATA1_IDOUT),
      .load_new_weight(LOAD_NEW_WEIGHT_IDOUT),
      .Updated_weight(UPDATED_WEIGHT)
    );
    
    // Dedicated Branch Forwarding MUXes
    // Input 0/1: Original Data. Input 2: ALU Forward. Input 3: WB Forward.
    wire [31:0] BRANCH_DATA1, BRANCH_DATA2;
    MUX_32bit_4input Branch_Data1_MUX(DATA1_IDOUT,DATA1_IDOUT,ALURESULT_EXOUT,WRITEDATA,Branch_Forward_RS1_EXOUT,BRANCH_DATA1);
    MUX_32bit_4input Branch_Data2_MUX(DATA2_IDOUT,DATA2_IDOUT,ALURESULT_EXOUT,WRITEDATA,Branch_Forward_RS2_EXOUT,BRANCH_DATA2);
    
    BranchController BranchController1(BRANCH_DATA1,BRANCH_DATA2,FUNCT3_IDOUT,ALURESULT,BRANCH_IDOUT,JUMP_IDOUT,TARGETEDADDRESS,PCADDRESSCONTROLLER);
    EX_MEM_pipeline EX_MEM_pipeline1(CLK,RESET,WRITEENABLE_IDOUT,MEMORYACCESS_IDOUT,MEMWRITE_IDOUT,MEMREAD_IDOUT,JAL_MUX_OUT,WRITEADDRESS_IDOUT,FUNCT3_IDOUT,DATA2_IDOUT,WRITEENABLE_EXOUT,MEMORYACCESS_EXOUT,MEMWRITE_EXOUT,MEMREAD_EXOUT,ALURESULT_EXOUT,WRITEADDRESS_EXOUT,FUNCT3_EXOUT,DATA2_EXOUT,FORWARD_MEMORY_IDOUT,FORWARD_MEMORY_EXOUT,CUSTOM_WRITEBACK_IDOUT,CUSTOM_WRITEBACK_EXOUT,UPDATED_WEIGHT,UPDATED_WEIGHT_EXOUT);

    // Memory stage
    MUX_32bit_4input datamemory_MUX(DATA2_EXOUT,32'b0,WRITEDATA,32'b0,{FORWARD_MEMORY_EXOUT,FORWARD_MEMORY_EXOUT},DATA2_FORWARD);
    data_memory datamemory1(CLK,RESET,mem_read_muxed,FUNCT3_EXOUT,mem_write_muxed,mem_addr_muxed,DATA2_FORWARD,DATA_OUT,BUSYWAIT);
    Mem_WBPipeline  MEM_WBPipeline1(CLK,RESET,WRITEENABLE_EXOUT,MEMORYACCESS_EXOUT,DATA_OUT,ALURESULT_EXOUT,WRITEADDRESS_EXOUT,WRITEENABLE_MEMOUT,MEMORYACCESS_MEMOUT,READDATA_MEMOUT,ALURESULT_MEMOUT,WRITEADDRESS_MEMOUT,CUSTOM_WRITEBACK_EXOUT,CUSTOM_WRITEBACK_MEMOUT,UPDATED_WEIGHT_EXOUT,UPDATED_WEIGHT_MEMOUT);

    // write back stage
    // MUX select: 00=ALU result, 01=unused, 10=Memory data, 11=Custom unit result
    wire [1:0] writeback_select;
    assign writeback_select = CUSTOM_WRITEBACK_MEMOUT ? 2'b11 : (MEMORYACCESS_MEMOUT ? 2'b10 : 2'b00);
    MUX_32bit_4input Memory_access_MUX(ALURESULT_MEMOUT,READDATA_MEMOUT,UPDATED_WEIGHT_MEMOUT,32'b0,writeback_select,WRITEDATA);

endmodule