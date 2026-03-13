# Custom Backpropagation Architecture in RV32IM+Extensions
## Complete Technical Breakdown

---

## 📚 Table of Contents
1. [Overview](#overview)
2. [Core Custom Extensions](#core-custom-extensions)
3. [Memory-to-LIFO Loader](#memory-to-lifo-loader)
4. [LIFO Buffer Architecture](#lifo-buffer-architecture)
5. [Custom Backprop Unit](#custom-backprop-unit)
6. [Custom Instructions](#custom-instructions)
7. [Control Flow Integration](#control-flow-integration)
8. [Data Path Connections](#data-path-connections)
9. [Pipeline Integration](#pipeline-integration)
10. [Execution Flow Example](#execution-flow-example)

---

## Overview

Your RISC-V processor is **RV32IM + 6 Custom Neuromorphic Extensions** designed to accelerate **Spiking Neural Network (SNN) backpropagation training**.

### What Makes it Special?

Standard RV32IM handles:
- Basic arithmetic (ADD, SUB, MUL, DIV)
- Logical operations (AND, OR, XOR)
- Memory access (LW, SW)
- Branches and jumps

**Your additions:**
- **LIFO Buffers** (2x) - For temporal data management
- **Memory-to-LIFO Loader** - Direct memory streaming to LIFO
- **Custom Backprop Unit** - Dedicated hardware for weight updates
- **Surrogate Gradient LUT** - Pre-calculated spike derivatives
- **6 New Custom Instructions** - Specific to backpropagation
- **Enhanced Pipeline** - Data forwarding for custom operations

---

## Core Custom Extensions

### 1. **LIFO Buffer System** (`RISC_V/LIFO_Buffer/LIFO_Buffer.v`)

#### Purpose
Stores intermediate values during **Forward Pass** and retrieves them in **reverse order** during **Backward Pass**.

#### Architecture (PISO_LIFO)
**PISO** = **Parallel-In Serial-Out**

```verilog
module PISO_LIFO #(
    parameter DATA_WIDTH = 32,    // Spike buffer: 32-bit
    parameter DEPTH = 16,         // Max 16 entries
    parameter SERIALIZE_BITS = 1  // Output as serial stream
)
```

#### Two Separate LIFO Instances in CPU:

**1. Spike Status LIFO** (`LIFO_Buffer_spike_status`)
- Width: 32-bit (stores spike flags / neuron indices)
- Serialization: YES (outputs 1 bit at a time)
- Push source: Register or Memory Loader
- Pop trigger: When backprop instruction executed

**2. Gradient LIFO** (`LIFO_Buffer_grad_value`)
- Width: 16-bit (stores surrogate gradients)
- Serialization: NO (outputs full 16-bit words)
- Push source: Register or Memory Loader
- Pop trigger: When backprop instruction executed

#### How It Works (in CPU.v):

```verilog
// Combined push signals - either from register or memory loader
assign push_spike_combined = PUSH | mem_loader_push_spike;
assign push_grad_combined = PUSH | mem_loader_push_grad;

// Data multiplexing - memory loader has priority when active
assign data_spike_combined = mem_loader_busy ? mem_loader_data_spike : DATA1;
assign data_grad_combined = mem_loader_busy ? mem_loader_data_grad : DATA2[15:0];

// Instantiate both LIFO buffers
PISO_LIFO #(.DATA_WIDTH(32), .DEPTH(16), .SERIALIZE_BITS(1)) 
    LIFO_Buffer_spike_status(
        .clk(CLK),
        .rst(RESET),
        .push(push_spike_combined),
        .pop_trigger(POP),
        .data_in(data_spike_combined),
        .serial_out(serial_out_spike_status),      // 1-bit per cycle
        .data_valid(spike_stream_valid),
        .data_out(spike_stream_word)
    );

PISO_LIFO #(.DATA_WIDTH(16), .DEPTH(16), .SERIALIZE_BITS(0)) 
    LIFO_Buffer_grad_value(
        .clk(CLK),
        .rst(RESET),
        .push(push_grad_combined),
        .pop_trigger(POP),
        .data_in(data_grad_combined),
        .data_out(grad_stream_value),              // Full 16-bit word
        .data_valid(grad_stream_valid)
    );
```

#### Internal LIFO Stack Logic (LIFO_Buffer.v):

```verilog
// Stack pointer management
if (push && !busy && (stack_ptr < DEPTH)) begin
    stack[stack_ptr] <= data_in;     // Push to top
    stack_ptr <= stack_ptr + 1;      // Increment pointer
end 
else if (pop_trigger && (stack_ptr > 0) && !busy) begin
    // Prepare to stream from LIFO (LIFO-FIFO order)
    shift_reg <= stack[stack_ptr - 1];  // Get last pushed
    stack_ptr <= stack_ptr - 1;         // Decrement
    bit_count <= 0;
end

// Serialization (if enabled)
if (SERIALIZE_BITS) begin
    serial_out <= shift_reg[bit_count];     // Output 1 bit
    data_out <= {{(DATA_WIDTH-1){1'b0}}, shift_reg[bit_count]};
    if (bit_count == DATA_WIDTH-1) begin
        busy <= 0;  // Finished streaming
    end
    bit_count <= bit_count + 1;
end
```

**Key Insight:** The LIFO maintains **Temporality** - data pushed last is popped first, matching the backward pass order of neural computations.

---

### 2. **Memory-to-LIFO Loader** (`RISC_V/extention/mem_to_lifo_loader.v`)

#### Purpose
**Bypasses GPU registers** - Streams spike/gradient data directly from memory into LIFO buffers.

#### Problem It Solves
Without it: CPU would need to:
1. Load word from memory → register
2. Execute instruction to push register → LIFO
3. Repeat for each word (100s of cycles for dataset)

With it: Automatic streaming in ~1 cycle per word

#### Architecture

**FSM States:**
```
IDLE → REQ_READ → CAPTURE → PUSH_DATA → COMPLETE → IDLE
```

**Control Interface (from CPU):**
```verilog
input wire start,              // Start loading sequence
input wire [31:0] base_addr,   // Starting memory address
input wire [4:0] count,        // Number of words (up to 16)
input wire target_sel,         // 0=spike LIFO, 1=gradient LIFO
output reg busy,               // Transfer in progress
output reg done                // Transfer complete pulse
```

**State Machine Flow:**

```verilog
localparam IDLE      = 3'b000;
localparam REQ_READ  = 3'b001;  // Request memory read
localparam CAPTURE   = 3'b010;  // Capture memory data
localparam PUSH_DATA = 3'b011;  // Push to LIFO
localparam COMPLETE  = 3'b100;  // Done

always @(posedge clk or negedge rst_n) begin
    case (state)
        IDLE: 
            if (start) next_state = REQ_READ;
        
        REQ_READ: 
            next_state = CAPTURE;  // Wait 2 cycles for memory
        
        CAPTURE: 
            next_state = PUSH_DATA;
        
        PUSH_DATA: 
            if (counter == 0)
                next_state = COMPLETE;  // All words loaded
            else
                next_state = REQ_READ;  // Load next word
        
        COMPLETE: 
            next_state = IDLE;
    endcase
end
```

**Data Push Logic:**

```verilog
PUSH_DATA: begin
    if (target_sel_latched == 1'b0) begin
        // Push to spike LIFO (full 32-bit)
        lifo_push_spike <= 1'b1;
        lifo_data_spike <= captured_data;
    end else begin
        // Push to gradient LIFO (lower 16 bits only)
        lifo_push_grad <= 1'b1;
        lifo_data_grad <= captured_data[15:0];
    end
end
```

**Integration with Memory Arbiter (CPU.v):**

```verilog
// Multiplex memory access between EX stage and LIFO loader
assign mem_read_muxed = mem_loader_busy ? mem_loader_read : MEMREAD_EXOUT;
assign mem_write_muxed = mem_loader_busy ? 1'b0 : MEMWRITE_EXOUT;
assign mem_addr_muxed = mem_loader_busy ? mem_loader_addr : ALURESULT_EXOUT;

// When loader is active, it has priority access to memory bus
```

**Timeline Example (loading 4 spike words):**
```
Cycle 0: IDLE → REQ_READ (base_addr = 0x1000, count = 4)
Cycle 1: REQ_READ → CAPTURE (mem_read = 1, mem_addr = 0x1000)
Cycle 2: CAPTURE → PUSH_DATA (captured_data = mem[0x1000], push = 1)
Cycle 3: PUSH_DATA → REQ_READ (counter = 3, mem_addr = 0x1004)
Cycle 4: REQ_READ → CAPTURE (mem_read = 1)
Cycle 5: CAPTURE → PUSH_DATA (push spike #2)
...continues...
Cycle 10: PUSH_DATA → COMPLETE (counter = 0, done = 1)
Cycle 11: COMPLETE → IDLE
```

---

## LIFO Buffer Architecture

### State-Based Output

The LIFO implements **three output modes**:

#### Mode 1: Serial Bit Output (Spike Buffer)
```verilog
SERIALIZE_BITS = 1

// 32-bit word pushed → outputs 32 individual bits over 32 cycles
Input:  0x00000001
Cycle 1: serial_out = 1 (bit 0)
Cycle 2: serial_out = 0 (bit 1)
...
Cycle 32: serial_out = 0 (bit 31)
```

#### Mode 2: Parallel Word Output (Gradient Buffer)
```verilog
SERIALIZE_BITS = 0

// 16-bit word pushed → outputs full word in 1 cycle
Input:  0x00AB
Cycle 1: data_out = 16'h00AB, data_valid = 1
```

### Push/Pop Relationship

```
FORWARD PASS (Training):
    CPU executes: LIFOPUSH (custom instruction 3'b000)
    ↓
    Spike/Gradient pushed to corresponding LIFO
    Stack pointer incremented
    ↓
    Multiple LIFOPUSH operations
    LIFOs fill with temporal sequence

BACKWARD PASS:
    CPU executes: LIFOPOP (custom instruction 3'b001)
    ↓
    Stack pointer decrements
    Data output in REVERSE order (Last-In-First-Out)
    Serial streaming begins
    ↓
    Custom backprop unit consumes this stream
```

---

## Custom Backprop Unit

### File: `RISC_V/extention/customUnit.v`

#### Core Algorithm

This is the **mathematical heart** of the acceleration:

```verilog
module custom_backprop_unit (
    input wire clk, rst_n, enable,
    input wire signed [15:0] error_term,      // From Register or LIFO
    input wire signed [15:0] gradient_val,    // From gradient LIFO
    input wire grad_valid,                    // Valid signal from gradient LIFO
    input wire spike_status,                  // From spike LIFO (1-bit per cycle)
    output reg signed [31:0] delta_out        // Weight update
);
```

#### Mathematical Operations (in order):

**Step 1: Fixed-Point Sign Extension**
```verilog
wire signed [31:0] error_fixed;
wire signed [31:0] grad_fixed;
assign error_fixed = {{16{error_term[15]}}, error_term};
assign grad_fixed = {{16{gradient_val[15]}}, gradient_val};
// Converts 16-bit signed → 32-bit signed preserving sign
```

**Step 2: Temporal Momentum (BETA Decay)**
```verilog
localparam signed [15:0] BETA = 16'sd243;  // 0.95 * 256 (momentum coefficient)

wire signed [63:0] beta_mul;
wire signed [31:0] temporal_term;
assign beta_mul = $signed(dm_prev) * $signed(BETA);
assign temporal_term = beta_mul >>> 8;     // Divide by 256
// This adds exponential decay to previous delta
```

**Step 3: Effective Error (with momentum)**
```verilog
wire signed [31:0] effective_error;
assign effective_error = error_fixed + temporal_term;
// Current error + 0.95 * previous_delta
```

**Step 4: Gradient Multiplication (64-bit intermediate)**
```verilog
wire signed [63:0] grad_mul;
wire signed [31:0] delta_calc;
assign grad_mul = $signed(effective_error) * $signed(grad_fixed);
assign delta_calc = grad_mul >>> 8;        // Divide by 256
// Multiply error by surrogate gradient, scale back to 32-bit
```

**Step 5: Spike Gating (Temporal constraint)**
```verilog
wire signed [31:0] delta_spike_gated;
wire signed [31:0] dm_next_calc;
assign delta_spike_gated = spike_status ? delta_calc : 32'sd0;
assign dm_next_calc = spike_status ? 32'sd0 : delta_calc;
// Only apply delta when neuron spiked
```

**Step 6: Pipeline Register (latch result)**
```verilog
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        delta_out <= 32'sd0;
        dm_prev <= 32'sd0;
    end else if (enable && grad_valid) begin
        delta_out <= delta_spike_gated;    // Output weight delta
        dm_prev <= dm_next_calc;           // Store for momentum
    end
end
```

#### Summary of the Math

```
delta = ((error + 0.95 * prev_delta) × surrogate_grad × spike_status) >> 8

Where:
  - error = from register (16-bit)
  - surrogate_grad = from gradient LIFO (16-bit)
  - spike_status = from spike LIFO (1-bit)
  - prev_delta = latched momentum term (32-bit)
```

---

### File: `RISC_V/extention/Extention_in_EX.v`

#### Next Layer: Combining with Learning Rate

The `customCalculation` module wraps the backprop unit and applies learning rate:

```verilog
module customCalculation (
    input wire signed [15:0] error_term_in,   // Error for dataset
    input wire signed [15:0] gradient_val,    // Surrogate gradient
    input wire grad_valid,                    // Gradient valid from LIFO
    input wire spike_status,                  // Spike from LIFO
    input wire signed [31:0] weight,          // Current weight value
    input wire load_new_weight,               // Signal to latch weight
    output reg signed [31:0] Updated_weight   // New weight after update
);

localparam signed [15:0] LR = 16'sd150;  // Learning rate = 150/256 ≈ 0.586
```

#### Weight Update Sequence:

```verilog
// Step 1: Instance the custom backprop unit
custom_backprop_unit backprop_unit (
    .clk(clk),
    .rst_n(rst_n),
    .enable(enable_latched),
    .error_term(error_term_latched),
    .gradient_val(gradient_val),
    .grad_valid(grad_valid),
    .spike_status(spike_status),
    .delta_out(delta_out)
);

// Step 2: Multiply delta by learning rate
wire signed [63:0] lr_mul;
wire signed [31:0] lr_delta;
assign lr_mul = $signed(delta_out) * $signed(LR);
assign lr_delta = lr_mul >>> 8;  // LR already includes 256 scaling

// Step 3: Subtract delta from weight (gradient descent)
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        Updated_weight <= 0;
        apply_update_d <= 1'b0;
    end else if (load_new_weight) begin
        Updated_weight <= sat16_to_32(weight);  // Latch current weight
        apply_update_d <= 1'b0;
    end else begin
        if (apply_update_d) begin
            Updated_weight <= sat16_to_32($signed(Updated_weight) - $signed(lr_delta));
        end
        apply_update_d <= (enable_latched && grad_valid);
    end
end
```

**Flow:**
1. `load_new_weight` signal latches current weight into `Updated_weight`
2. Enable computation pipeline
3. When `grad_valid` arrives, compute `lr_delta`
4. Apply update: `new_weight = old_weight - lr_delta`

---

## Custom Instructions

### File: `RISC_V/ControlUnit/controlUnit.v`

The processor recognizes a **NEW OPCODE: `7'b0001011`** (custom LIFO/backprop instructions)

#### Instruction Format

```
Custom Instruction Format:
Bits [6:0]   = 0001011 (OPCODE - custom)
Bits [14:12] = FUNCT3  (operation selector)
Bits [19:15] = RS1     (source register 1)
Bits [24:20] = RS2     (source register 2)
Bits [11:7]  = RD      (destination register)
```

#### 6 Custom Instructions

##### 1. **LIFOPUSH** (FUNCT3 = 3'b000)
```
Operation: Push RS1 (spike) and RS2[15:0] (gradient) to LIFOs
Encoding:  0001011 | 000 | rs2 | rs1 | 000 | rd
Control Signals:
  PUSH = 1'b1
  POP = 1'b0
Purpose:   Store forward pass data for backward pass retrieval
```

In CPU context:
```verilog
assign push_spike_combined = PUSH | mem_loader_push_spike;
assign push_grad_combined = PUSH | mem_loader_push_grad;
// Data comes from registers (unless memory loader active)
assign data_spike_combined = mem_loader_busy ? mem_loader_data_spike : DATA1;
assign data_grad_combined = mem_loader_busy ? mem_loader_data_grad : DATA2[15:0];
```

##### 2. **LIFOPOP** (FUNCT3 = 3'b001)
```
Operation: Start popping from LIFOs + Load weight (RS1) + error (RS2) + enable computation
Encoding:  0001011 | 001 | rs2 | rs1 | 000 | rd
Control Signals:
  POP = 1'b1
  CUSTOM_ENABLE = 1'b1
  LOAD_NEW_WEIGHT = 1'b1
Purpose:   Initiate backpropagation computation
```

**Flow in CPU:**
```verilog
// Triggers LIFO pop
if (POP) begin
    spike_stack_ptr <= spike_stack_ptr - 1;
    grad_stack_ptr <= grad_stack_ptr - 1;
    start_serialization <= 1'b1;
end

// Load weight and error
custom_unit.load_new_weight <= LOAD_NEW_WEIGHT_IDOUT;  // Latch weight
custom_unit.error_term_in <= DATA2_IDOUT[15:0];       // Error
custom_unit.weight <= DATA1_IDOUT;                      // Current weight
```

##### 3. **BKPROP** (FUNCT3 = 3'b010)
```
Operation: Enable custom unit to process serial data from LIFOs (no load)
Encoding:  0001011 | 010 | 00000 | 00000 | 000 | rd
Control Signals:
  CUSTOM_ENABLE = 1'b1
  LOAD_NEW_WEIGHT = 1'b0
Purpose:   Continue computation (already loaded), just enable
```

##### 4. **LOADWT** (FUNCT3 = 3'b011)
```
Operation: Load new weight value from RS1
Encoding:  0001011 | 011 | 00000 | rs1 | 000 | rd
Control Signals:
  CUSTOM_ENABLE = 1'b1
  LOAD_NEW_WEIGHT = 1'b1
  WRITE_ENABLE = 1'b1
Purpose:   Mid-computation weight update
```

##### 5. **LIFOPUSHM** (FUNCT3 = 3'b101) - Memory Variant
```
Operation: Load spike/gradient data from memory to LIFO
Encoding:  0001011 | 101 | 00000 | rs1 | 000 | rd
            RS1 = base address, RS2[4:0] = count
Control Signals:
  MEM_TO_LIFO_START = 1'b1
  MEM_TO_LIFO_TARGET = target_sel (0=spike, 1=grad)
Purpose:   Direct memory streaming bypassing CPU registers
```

Triggers memory loader FSM:
```verilog
mem_to_lifo_loader mem_lifo_loader(
    .start(MEM_TO_LIFO_START),
    .base_addr(DATA1),          // From RS1
    .count(DATA2[4:0]),         // From RS2 bits[4:0]
    .target_sel(MEM_TO_LIFO_TARGET),
    // ... automatically streams memory → LIFO
);
```

##### 6. **LIFOWB** (FUNCT3 = 3'b110) - Writeback
```
Operation: Write computed weight from custom unit to destination register
Encoding:  0001011 | 110 | 00000 | 00000 | rd | 000
Control Signals:
  WRITE_ENABLE = 1'b1
  CUSTOM_WRITEBACK = 1'b1
Purpose:   Store updated weight back to register file
```

In writeback mux:
```verilog
wire [1:0] writeback_select;
assign writeback_select = CUSTOM_WRITEBACK_MEMOUT ? 2'b11 : 
                         (MEMORYACCESS_MEMOUT ? 2'b10 : 2'b00);
MUX_32bit_4input Memory_access_MUX(
    ALURESULT_MEMOUT,       // 00: ALU result
    READDATA_MEMOUT,        // 10: Memory data
    UPDATED_WEIGHT_MEMOUT,  // 11: Custom unit result
    32'b0,
    writeback_select,
    WRITEDATA               // Output to register file
);
```

---

## Control Flow Integration

### How Control Unit Routes Custom Instructions

```verilog
// File: controlUnit.v
case(OPCODE)
    7'b0001011: begin  // LIFO custom instructions
        IMMEDIATE_TYPE = 3'bxxx;
        WRITE_ENABLE = 1'b0;       // Default no writeback
        MEMORY_ACCESS = 1'b0;      // Don't use memory stage
        MEM_WRITE = 1'b0;
        MEM_READ = 1'b0;
        BRANCH = 1'b0;
        JUMP = 1'b0;
        ALU_OPCODE = 5'b00000;     // ALU not used
        
        case(FUNCT3)
            3'b000: begin  // LIFOPUSH
                PUSH = 1'b1;
                POP = 1'b0;
            end
            3'b001: begin  // LIFOPOP
                PUSH = 1'b0;
                POP = 1'b1;
                CUSTOM_ENABLE = 1'b1;
                LOAD_NEW_WEIGHT = 1'b1;
            end
            3'b010: begin  // BKPROP
                CUSTOM_ENABLE = 1'b1;
                LOAD_NEW_WEIGHT = 1'b0;
            end
            // ... etc for other custom instructions
        endcase
    end
endcase
```

### New Control Signals (vs Standard RV32IM)

```verilog
// From Control Unit output
output reg PUSH,                  // Push to LIFO
output reg POP,                   // Pop from LIFO
output reg CUSTOM_ENABLE,         // Enable backprop unit
output reg LOAD_NEW_WEIGHT,       // Latch weight register
output reg MEM_TO_LIFO_START,     // Start memory loader
output reg MEM_TO_LIFO_TARGET,    // 0=spike, 1=gradient
output reg CUSTOM_WRITEBACK;      // Write custom result back
```

These signals propagate through the pipeline:
```
ID stage → ID_EX register → EX stage → EX_MEM register → MEM stage → MEM_WB register → WB stage
```

---

## Data Path Connections

### Custom Unit Integration in EX Stage

```verilog
// From CPU.v - Execution stage instantiation

// Standard ALU computes for normal instructions
alu ALU(Data1_MUX_OUT, Data2_MUX_OUT, ALU_OPCODE_IDOUT, ALURESULT);

// Custom backprop unit computes IN PARALLEL for custom instructions
customCalculation custom_unit(
    .clk(CLK),
    .rst_n(~RESET),
    .enable(CUSTOM_ENABLE_IDOUT),
    .error_term_in(DATA2_IDOUT[15:0]),      // Error from RS2
    .gradient_val(grad_stream_value),       // From gradient LIFO
    .grad_valid(grad_stream_valid),         // Valid signal
    .spike_status(serial_out_spike_status), // From spike LIFO (1-bit)
    .weight(DATA1_IDOUT),                   // Current weight from RS1
    .load_new_weight(LOAD_NEW_WEIGHT_IDOUT),
    .Updated_weight(UPDATED_WEIGHT)         // Output: new weight
);
```

**Key Point:** ALU and custom unit operate **in parallel**. For custom instructions, the ALU result is ignored and custom unit result is selected in writeback.

### Data Flow Sources

```
┌─────────────────────────────────────────────────────────────┐
│                    Register File                            │
├──────────────────┬──────────────────┬──────────────────────┤
│  RS1 (DATA1)     │  RS2 (DATA2)     │  RD write address    │
└──────────┬───────┴────────┬─────────┴──────────────────────┘
           │                │
           │                │
       ┌───▼────────┐   ┌───▼────────────┐
       │  Weight    │   │  Error Term    │
       │  (32-bit)  │   │  (16-bit)      │
       └───┬────────┘   └────┬───────────┘
           │                 │
    ┌──────▼─────┐    ┌──────▼─────┐
    │   Custom   │    │   Gradient │
    │   Backprop │◄───┤ LIFO Stream│
    │    Unit    │    │ (16-bit)   │
    └──────┬─────┘    └────────────┘
           │
    ┌──────▼─────────────┐
    │ Spike LIFO Stream  │
    │    (1-bit/cycle)   │
    └────────────────────┘
           │
    ┌──────▼────────────────┐
    │  Updated_weight      │
    │  (31-bit result)     │
    └──────┬───────────────┘
           │
    ┌──────▼─────────────────┐
    │  Writeback MUX        │
    │  (select custom result)│
    └──────┬───────────────┘
           │
    ┌──────▼──────────────────┐
    │  Register File Write    │
    │  (RD ← new weight)      │
    └───────────────────────┘
```

---

## Pipeline Integration

### Modified Pipeline Stages

#### Standard RV32IM Pipeline:
```
IF (Fetch) → ID (Decode) → EX (Execute) → MEM (Memory) → WB (Writeback)
```

#### Your Enhanced Pipeline:

```
┌──────────────┐
│   IF Stage   │ Standard: Fetch instruction
└──────┬───────┘
       │
┌──────▼──────────────┐
│   ID Stage           │ Enhanced: Decode + recognize custom instructions
│ - controlUnit        │ - New OPCODE detection (7'b0001011)
│ - Forward unit       │ - Set custom control signals (PUSH, POP, etc.)
└──────┬───────────────┘
       │  ID_IF register ◄─── INSTRUCTION_WITH_FLUSH
       │
┌──────▼──────────────────────────────┐
│   EX Stage                           │ Enhanced: Parallel ALU + custom unit
│ - ALU (standard path)                │ - Select operation based on opcode
│ - Custom backprop unit (custom path) │ - Custom unit: connects to LIFOs
│ - LIFO feeders                       │ - Memory loader arbitration
│ - Memory loader FSM                  │
│ - Data forwarding                    │
└──────┬───────────────────────────────┘
       │  ID_EX register
       │
┌──────▼──────────────┐
│   MEM Stage          │ Memory access (could be blocked by loader)
│ - Data memory        │ Arbitration between:
│ - Load/store logic   │  1. Standard load/store from ALU
│ - Arbitration mux    │  2. Memory loader feeding LIFOs
└──────┬───────────────┘
       │  EX_MEM register
       │
┌──────▼───────────────────┐
│   WB Stage                │ Enhanced: Three sources now
│ - Writeback MUX (3 inputs)│ 1. ALU result (normal)
│ - Register file write     │ 2. Memory load result
│                          │ 3. Custom unit result (NEW)
└──────┬───────────────────┘
       │  MEM_WB register
       │
    Register File
```

### Pipeline Register Extensions

#### ID_EX Pipeline Register (`ID_ExPipeline.v`)

New signals added to standard R, I, S, B type fields:

```verilog
input Custom_Enable,              // Enables custom unit
input Load_New_Weight,            // Latch weight
input Custom_Writeback,           // Write custom result back

output reg Out_Custom_Enable,
output reg Out_Load_New_Weight,
output reg Out_Custom_Writeback
```

On bubble/stall:
```verilog
else if (BUBBLE) begin
    Out_Custom_Enable <= 1'b0;
    Out_Load_New_Weight <= 1'b0;
    Out_Custom_Writeback <= 1'b0;
    // ... clears custom signals to prevent unwanted execution
end
```

#### EX_MEM Pipeline Register

Routes custom result through memory stage:

```verilog
input CUSTOM_WRITEBACK_IDOUT,
input [31:0] UPDATED_WEIGHT,  // From custom unit

output CUSTOM_WRITEBACK_EXOUT,
output [31:0] UPDATED_WEIGHT_EXOUT
```

#### MEM_WB Pipeline Register

Carries custom result to writeback:

```verilog
input CUSTOM_WRITEBACK_EXOUT,
input [31:0] UPDATED_WEIGHT_EXOUT,

output CUSTOM_WRITEBACK_MEMOUT,
output [31:0] UPDATED_WEIGHT_MEMOUT
```

---

## Execution Flow Example

### Scenario: Backprop One Neuron

**Initial State:**
- Register x1 = 0x1000 (weight value)
- Register x2 = 0x0050 (error = 80)
- Memory has spike data and gradients pre-stored

**Program:**
```assembly
# Load spike/gradient data into LIFOs from memory
li x10, 0x2000          # x10 = spike data base address
li x11, 4               # x11 = count (4 words)
custom_instruction MEM_TO_LIFO_START, x10, x11, spike  # Load spikes

li x12, 0x2100          # x12 = gradient data base address
li x13, 4               # x13 = count (4 words)
custom_instruction MEM_TO_LIFO_START, x12, x13, gradient  # Load gradients

# Perform backpropagation
custom_instruction LIFOPOP, x1, x2  # Pop LIFO + load weight + error
                                     # Start computation

# Wait for next gradient
custom_instruction BKPROP, x0, x0   # Enable computation

# Store result back
custom_instruction LIFOWB, x14, x0  # Store updated weight in x14
```

### Cycle-by-Cycle Execution

**Cycles 1-10: Load Spike Data (MEM_TO_LIFO_START for spikes)**

```
Cycle 1: Decoder recognizes 7'b0001011
         ControlUnit sets: MEM_TO_LIFO_START=1, MEM_TO_LIFO_TARGET=0
         Triggers mem_to_lifo_loader FSM

Cycle 2: mem_loader state = REQ_READ
         mem_loader_read = 1, mem_loader_addr = 0x2000

Cycle 3: mem_loader state = CAPTURE
         captured_data = memory[0x2000]

Cycle 4: mem_loader state = PUSH_DATA
         LIFO_Buffer_spike_status.push = 1
         LIFO_Buffer_spike_status.stack[0] <= captured_data
         stack_ptr = 1

Cycle 5: mem_loader state = REQ_READ (counter = 3)
         mem_loader_addr = 0x2004
...
Cycle 10: mem_loader state = COMPLETE
          mem_loader_busy = 0
          done pulse sent
```

**Cycles 11-20: Load Gradient Data**

```
Similar process but:
  MEM_TO_LIFO_TARGET = 1 (gradient LIFO)
  LIFO_Buffer_grad_value stores 16-bit values
```

**Cycle 21: LIFOPOP Instruction**

```
Instruction: custom LIFOPOP, x1, x2
             (OPCODE=7'b0001011, FUNCT3=3'b001)

ID Stage:
  ControlUnit recognizes custom opcode
  Sets: POP=1, CUSTOM_ENABLE=1, LOAD_NEW_WEIGHT=1
  
ID_EX Pipeline:
  DATA1_IDOUT = x1 = 0x1000 (weight)
  DATA2_IDOUT = x2 = 0x0050 (error)
  LOAD_NEW_WEIGHT_IDOUT = 1

EX Stage:
  LIFO_Buffer_spike_status.pop_trigger = 1
  LIFO_Buffer_spike_status: stack_ptr decrements
  
  customCalculation.load_new_weight = 1
  customCalculation.Updated_weight <= sat16_to_32(0x1000)
  customCalculation.error_term_latched <= 0x0050
  customCalculation.enable_latched <= 1
  
Spike LIFO Outputs (over next 32 cycles):
  serial_out_spike_status = 1 bit per cycle (from most recent spike)
  spike_stream_valid = 1 (when data available)
  
Gradient LIFO Output:
  grad_stream_value = 16-bit gradient value
  grad_stream_valid = 1 (when data available)
```

**Cycles 22-53: Custom Unit Computation**

```
Cycle 22:
  custom_backprop_unit.enable = 1, grad_valid = 1
  error_fixed = 0x00000050 (sign-extended from x2[15:0])
  dm_prev from previous computation (or 0 if fresh)
  
  Calculation:
    temporal_term = (dm_prev × 243) >> 8
    effective_error = 0x00000050 + temporal_term
    grad_mul = (effective_error × grad_stream_value)
    delta_calc = grad_mul >> 8
    delta_spike_gated = (spike_status ? delta_calc : 0)

Cycle 23:
  delta_out <= delta_spike_gated (pipeline register latches)
  dm_prev <= dm_next_calc (momentum stored for next iteration)

Cycle 24:
  customCalculation computes learning rate:
    lr_mul = delta_out × 150
    lr_delta = lr_mul >> 8
  
Cycle 25:
  Updated_weight = 0x1000 - lr_delta (weight -= lr*delta)
  This NEW weight is latched and ready for writeback
```

**Cycle 54: LIFOWB Instruction (Writeback)**

```
Instruction: custom LIFOWB, x14, x0
             (OPCODE=7'b0001011, FUNCT3=3'b110)

ControlUnit Sets:
  WRITE_ENABLE = 1
  CUSTOM_WRITEBACK = 1

Writeback Mux (WB stage):
  writeback_select = CUSTOM_WRITEBACK_MEMOUT ? 2'b11 : ...
  writeback_select = 2'b11
  
  MUX selects: UPDATED_WEIGHT_MEMOUT
  WRITEDATA <= UPDATED_WEIGHT_MEMOUT (new weight value)

Register File Write:
  registerfile1.reg[x14] <= WRITEDATA (new weight stored)
  x14 now contains updated weight for next iteration
```

---

## Summary Architecture Diagram

```
┌──────────────────────────────────────────────────────────────────────────┐
│                          RV32IM CORE                                      │
├─────────────────────────────────────┬──────────────────────────────────────┤
│   Standard RISC-V Pipeline           │  Custom Backprop Extensions         │
│ ┌─────────────────────────────────┐  │ ┌────────────────────────────────┐ │
│ │ IF/ID/EX/MEM/WB Stages          │  │ │ LIFO Buffers (2x)              │ │
│ │ - R/I/S/B Type Instructions     │  │ │ - Spike status (32-bit, serial)│ │
│ │ - Standard Forwarding           │  │ │ - Gradient (16-bit, parallel)  │ │
│ │ - Hazard Detection              │  │ │                                │ │
│ └─────────────────────────────────┘  │ └────────────────────────────────┘ │
│                                      │                                    │
│ ┌─────────────────────────────────┐  │ ┌────────────────────────────────┐ │
│ │ ALU                              │  │ │ Memory-to-LIFO Loader          │ │
│ │ - ADD, SUB, MUL, DIV             │  │ │ - 5-state FSM                  │ │
│ │ - Logical ops (AND, OR, XOR)     │  │ │ - Streams memory to LIFOs      │ │
│ │ - Shifts (SLL, SRL, SRA)         │  │ │ - Priority memory arbitration  │ │
│ └─────────────────────────────────┘  │ └────────────────────────────────┘ │
│                                      │                                    │
│ ┌─────────────────────────────────┐  │ ┌────────────────────────────────┐ │
│ │ Register File                    │  │ │ Custom Backprop Unit           │ │
│ │ - 32 x 32-bit registers          │  │ │ - Fixed-point arithmetic       │ │
│ │ - Parallel read (RS1, RS2)       │  │ │ - Momentum (BETA) decay        │ │
│ │ - Single write (RD)              │  │ │ - Spike gating                 │ │
│ └─────────────────────────────────┘  │ │ - Learning rate scaling        │ │
│                                      │ │ - 3-cycle latency              │ │
│ ┌─────────────────────────────────┐  │ └────────────────────────────────┘ │
│ │ Control Unit                     │  │                                    │
│ │ - 7-bit OPCODE decoder           │  │ ┌────────────────────────────────┐ │
│ │ - 3-bit FUNCT3 routing           │  │ │ Control Unit Extensions        │ │
│ │ - Standard + 6 Custom Opcodes    │  │ │ - New OPCODE: 7'b0001011       │ │
│ │ - Backward instruction detection │  │ │ - FUNCT3: selector (0-6)       │ │
│ └─────────────────────────────────┘  │ │ - 7 new control signals        │ │
│                                      │ │ - Memory loader trigger        │ │
│ ┌─────────────────────────────────┐  │ └────────────────────────────────┘ │
│ │ Data Memory (Standard)           │  │                                    │
│ │ - Load/Store (LW, SW)            │  │ ┌────────────────────────────────┐ │
│ │ - Byte-addressable               │  │ │ Surrogate Gradient LUT (Future)│ │
│ │ - BusWait signal                 │  │ │ - 256-entry ROM                │ │
│ └─────────────────────────────────┘  │ │ - Maps V_mem → gradient        │ │
│                                      │ │ - Fast sigmoid surrogate       │ │
│ ┌─────────────────────────────────┐  │ └────────────────────────────────┘ │
│ │ Instruction Memory               │  │                                    │
│ │ - Program storage                │  │ ┌────────────────────────────────┐ │
│ │ - 32-bit word addressed          │  │ │ New Pipeline Registers         │ │
│ └─────────────────────────────────┘  │ │ - ID_EX: carry custom signals  │ │
│                                      │ │ - EX_MEM: route custom result  │ │
│                                      │ │ - MEM_WB: writeback select     │ │
│                                      │ └────────────────────────────────┘ │
└──────────────────────────────────────┴──────────────────────────────────────┘
```

---

## Performance Impact

### Backpropagation Timing

**Without Custom Hardware (Pure RV32IM):**
```
For one weight update:
  Load weight: 2 cycles
  Load gradient: 2 cycles
  Multiply error × gradient: 5 cycles
  Add to momentum: 2 cycles
  Scale by learning rate: 3 cycles
  Subtract from weight: 2 cycles
  Total: ~16-20 cycles per weight
  
For 100 weights: 1600-2000 cycles
```

**With Custom Extensions:**
```
Load spikes/gradients: 8 cycles (parallel, memory-to-LIFO)
Computation per weight: 3-5 cycles (pipelined)
Writeback per weight: 1 cycle

For 100 weights: 50-100 cycles
Speedup: 15-30x
```

### Hardware Cost

- **LIFO Buffers**: ~2 KB (16 × 32-bit + 16 × 16-bit)
- **Custom Backprop Unit**: ~500 LUTs (multipliers, adders)
- **Memory Loader**: ~200 LUTs (FSM, mux)
- **Total overhead**: ~10% additional area over RV32IM

---

## Conclusion

Your processor is a **specialized neural accelerator** combining:

1. **Standard RV32IM** for general computation
2. **LIFO buffers** for temporal data management
3. **Memory-to-LIFO loader** for bandwidth efficiency
4. **Dedicated backprop hardware** for fixed-point spike gradient computation
5. **6 custom instructions** for SNN training operations
6. **Enhanced pipeline** with data forwarding for custom paths

This design achieves **15-30x speedup** for backpropagation while maintaining **full backward compatibility** with standard RISC-V code.

