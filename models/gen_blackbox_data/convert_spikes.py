#!/usr/bin/env python3
import argparse
import sys
from pathlib import Path


def read_and_convert_data_packetss(lines, input_layer_count):
    # Parse status codes (skip FFF values)
    count = 0
    data_packetss = []
    
    for line in lines:
        line = line.strip()
        if count == input_layer_count:
            count = 0  # Reset count after every input_layer_count lines
            data_packetss.append('FFF')  # Add FFF for every input_layer_count lines
        count += 1
        
        if line and line != 'FFF':  # Skip empty lines and FFF values
            try:
                # Parse as hexadecimal and mask to 11 bits
                hex_value = int(line, 16)
                data_packets = hex_value & 0x7FF  # Mask to 11 bits (0x7FF = 2047 = 2^11 - 1)
                data_packetss.append(data_packets)
            except ValueError:
                print(f"Warning: Skipping invalid line: {line}")
    
    # Group status codes into chunks
    inputs = []
    temp = []
    
    for code in data_packetss:
        if code == 'FFF':
            inputs.append(temp)
            temp = []
        else:
            temp.append(code)
    
    # Don't forget the last group if it doesn't end with 'FFF'
    if temp:
        inputs.append(temp)
    
    return convert_to_instructions(inputs)


def convert_to_instructions(inputs):
    """
    Convert grouped status codes to 128-bit instructions.
    
    Args:
        inputs (list): List of status code groups
    
    Returns:
        list: List of hex instruction strings
    """
    max_flits = 10
    all_instructions = []
    flag = True
    
    for single_time in inputs:
        instructions = []
        
        # Handle empty input
        if len(single_time) == 0:
            all_instructions.append("2" + "0" * 30 + "1")
            continue
        
        # Split single_time into chunks of max_flits
        for i in range(0, len(single_time), max_flits):
            chunk = single_time[i:i + max_flits]
            instructions.append(chunk)
        
        # Convert each chunk to a 128-bit instruction
        for idx, chunk in enumerate(instructions):
            instruction_bits = build_instruction(chunk, flag, idx == len(instructions) - 1)
            
            # Set flag to False after first instruction
            if flag:
                flag = False
            
            # Convert to hex string (128 bits = 32 hex characters)
            hex_instruction = f"{instruction_bits:032X}"
            all_instructions.append(hex_instruction)
    
    return all_instructions


def build_instruction(chunk, is_first, is_last):
    """
    Build a 128-bit instruction from a chunk of status codes.
    
    Args:
        chunk (list): List of status codes
        is_first (bool): Whether this is the first instruction in the group
        is_last (bool): Whether this is the last instruction in the group
    
    Returns:
        int: 128-bit instruction as integer
    """
    # Build 128-bit instruction
    opcode = 0b0010  # 4 bits
    valid_count = len(chunk)  # 4 bits
    
    # Start with opcode and valid count
    instruction_bits = (opcode << 124) | (valid_count << 120)
    
    # Add flits (11 bits each)
    for i, flit_value in enumerate(chunk):
        # Ensure flit fits in 11 bits
        flit_11bit = flit_value & 0x7FF
        bit_position = 120 - (i + 1) * 11
        instruction_bits |= (flit_11bit << bit_position)
    
    # Set the 2nd bit from right (bit position 1) to 1 for the first instruction
    if is_first:
        instruction_bits |= (1 << 1)
    
    # Set the last bit to 1 for the last instruction in this group
    if is_last:
        instruction_bits |= (1 << 0)
    
    return instruction_bits


def process_file(input_file, time_step_window = 50, input_layer_count = 784, output_file = "spike_mem.mem"):	
    """
    Process the input file and generate instructions.
    
    Args:
        input_file (str): Path to input file
        time_step_window (int): Time step window size
        input_layer_count (int): Number of input layers
        output_file (str): Path to output file
    """
    # Read input file
    try:
        with open(input_file, 'r') as f:
            lines = f.readlines()
    except FileNotFoundError:
        print(f"Error: Could not find input file: {input_file}")
        sys.exit(1)
    except Exception as e:
        print(f"Error reading input file: {e}")
        sys.exit(1)
    
    print(f"Total lines in input file: {len(lines)}")
    
    # Calculate number of inputs
    lines_per_input = time_step_window * input_layer_count
    num_inputs = len(lines) // lines_per_input
    
    if num_inputs == 0:
        print("Error: Not enough lines in input file for even one input")
        sys.exit(1)
    
    print(f"Total inputs: {num_inputs}")
    print(f"Lines per input: {lines_per_input}\n")
    
    all_results = []
    
    # Process each input
    for input_i in range(num_inputs):
        start_idx = input_i * lines_per_input
        end_idx = (input_i + 1) * lines_per_input
        input_lines = lines[start_idx:end_idx]
        
        instructions = read_and_convert_data_packetss(input_lines, input_layer_count)
        all_results.append(instructions)
        print(f"Input {input_i + 1}: Generated {len(instructions)} instructions")
    
    # Write results to output file
    write_output(all_results, output_file)


def write_output(all_results, output_file):
    """
    Write all instructions to the output file.
    
    Args:
        all_results (list): List of instruction lists
        output_file (str): Path to output file
    """
    try:
        with open(output_file, 'w') as f:
            for instructions in all_results:
                f.write(f"{len(instructions):05X}\n")
                for instruction in instructions:
                    f.write(f"{instruction}\n")
        
        total_instructions = sum(len(instructions) for instructions in all_results)
        print(f"\nTotal instructions generated: {total_instructions}")
        print(f"Results written to: {output_file}")
        
    except Exception as e:
        print(f"Error writing to output file: {e}")
        sys.exit(1)


def main():
    """Main function to handle command-line arguments and execute the conversion."""
    parser = argparse.ArgumentParser(
        description="Convert HTTP status codes to 128-bit instructions",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    
    parser.add_argument(
        "input_file",
        help="Path to input file containing status codes"
    )
    
    parser.add_argument(
        "-t", "--time-step-window",
        type=int,
        default=50,
        help="Time step window size"
    )
    
    parser.add_argument(
        "-l", "--input-layer-count",
        type=int,
        default=784,
        help="Number of input layers"
    )
    
    parser.add_argument(
        "-o", "--output-file",
        default="spike_mem.mem",
        help="Output file path"
    )
    
    args = parser.parse_args()
    
    # Validate input file exists
    if not Path(args.input_file).exists():
        print(f"Error: Input file '{args.input_file}' does not exist")
        sys.exit(1)
    
    # Validate positive integers
    if args.time_step_window <= 0:
        print("Error: Time step window must be a positive integer")
        sys.exit(1)
    
    if args.input_layer_count <= 0:
        print("Error: Input layer count must be a positive integer")
        sys.exit(1)
    
    print(f"Configuration:")
    print(f"  Input file: {args.input_file}")
    print(f"  Time step window: {args.time_step_window}")
    print(f"  Input layer count: {args.input_layer_count}")
    print(f"  Output file: {args.output_file}")
    print("-" * 50)
    
    # Process the file
    process_file(
        args.input_file,
        args.time_step_window,
        args.input_layer_count,
        args.output_file
    )


if __name__ == "__main__":
    main()