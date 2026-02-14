// Decay modes
`define INIT 3'b000
`define LIF2 3'b001
`define LIF4 3'b010
`define LIF8 3'b011
`define LIF24 3'b100
`define IDLE 3'b111

// controller working modes
`define DECAY_INIT 8'b11111110
`define ADDER_VT_INIT 8'b11111001
`define WORK_MODE 8'b11110111
`define END_PACKET 8'b11111111

// working methods
`define LIF2_MODE 8'b0001
`define LIF4_MODE 8'b0010
`define LIF8_MODE 8'b0011
`define LIF24_MODE 8'b0100

// reset modes
`define NO_RESET 2'b01
`define RESET_ZERO 2'b10
`define RESET_VTD 2'b11

// controller status
`define MODE_SELECT 2'b00
`define MODE_BUFFER 2'b01
`define WORK_MODE_SELECT 2'b10

