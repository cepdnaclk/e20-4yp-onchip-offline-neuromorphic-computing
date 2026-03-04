// Decay modes
`define INIT 3'b000
`define LIF2 3'b001
`define LIF4 3'b010
`define LIF8 3'b011
`define LIF24 3'b100
`define IZHI 3'b101
`define QUAD 3'b110
`define IDLE 3'b111

// Adder model
`define LIF 2'b00
`define IZHI_AD 2'b01
`define QIF 2'b10
`define NONE 2'b11

// Adder init mode
`define DEFAULT 3'b000
`define A 3'b001
`define B 3'b010
`define C 3'b011
`define D 3'b100
`define VT 3'b101
`define U 3'b110
`define IDLE 3'b111

// controller working modes
`define END_PACKET 8'b11111111
`define DECAY_INIT 8'b11111110
`define ADDER_A_INIT 8'b11111101
`define ADDER_B_INIT 8'b11111100
`define ADDER_C_INIT 8'b11111011
`define ADDER_D_INIT 8'b11111010
`define ADDER_VT_INIT 8'b11111001
`define ADDER_U_INIT 8'b11111000
`define WORK_MODE 8'b11110111

// working methods
`define LIF2_MODE 8'b0001
`define LIF4_MODE 8'b0010
`define LIF8_MODE 8'b0011
`define LIF24_MODE 8'b0100
`define IZHI_MODE 8'b0101
`define QUAD_MODE 8'b0110

// controller status
`define MODE_SELECT 2'b00
`define MODE_BUFFER 2'b01
`define WORK_MODE_SELECT 2'b10

// buffer modes
`define BUFFER_IDLE 2'b00
`define BUFFER_ADDRESS 2'b01
`define BUFFER_VALUE 2'b10

// buffer status
`define ADDRESS_DONE 2'b01
`define VALUE_DONE 2'b11

// reset modes
`define NO_RESET 2'b01
`define RESET_ZERO 2'b10
`define RESET_VTD 2'b11