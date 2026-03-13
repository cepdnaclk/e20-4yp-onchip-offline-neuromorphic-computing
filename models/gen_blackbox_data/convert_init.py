#!/usr/bin/env python3
"""
Convert hex data to Verilog memory file format.
Format: [OpCode=0001 4bit][Valid Flit Count 4bit][Flit data 120bit]
"""

import argparse
import sys
from pathlib import Path


def convert_hex_data_to_mem(input_file, output_file, width=128):
    """
    Convert hex data from input file to Verilog memory file format.
    
    Args:
        input_file (str): Path to input file containing hex data
        output_file (str): Path to output memory file
        width (int): Memory width in bits (default: 128)
    
    Returns:
        int: Number of memory entries created
    """
    # Validate input file exists
    if not Path(input_file).exists():
        raise FileNotFoundError(f"Input file not found: {input_file}")
    
    # Read and process hex data
    try:
        with open(input_file, 'r') as f:
            lines = f.readlines()
    except IOError as e:
        raise IOError(f"Error reading input file: {e}")
    
    # Extract hex bytes from all lines
    hex_data = []
    for line_num, line in enumerate(lines, 1):
        hex_bytes = line.strip().split()
        if hex_bytes:  # Skip empty lines
            # Validate hex format
            for byte_str in hex_bytes:
                try:
                    int(byte_str, 16)
                except ValueError:
                    print(f"Warning: Invalid hex value '{byte_str}' on line {line_num}, skipping")
                    continue
                hex_data.append(byte_str.upper())
    
    if not hex_data:
        raise ValueError("No valid hex data found in input file")
    
    # Calculate memory layout
    flit_data_bits = width - 8  # 8 bits for opcode and valid count
    bytes_per_entry = flit_data_bits // 8
    
    if bytes_per_entry <= 0:
        raise ValueError(f"Invalid width {width}: must be > 8 bits")
    
    # Process hex data into memory entries
    mem_entries = []
    opcode = 0x1  # Fixed opcode for initialization write
    
    for i in range(0, len(hex_data), bytes_per_entry):
        # Get bytes for this memory entry
        flit_bytes = hex_data[i:i + bytes_per_entry]
        original_count = len(flit_bytes)
        
        # Pad with zeros if needed
        while len(flit_bytes) < bytes_per_entry:
            flit_bytes.append("00")
        
        # Calculate valid flit count (limit to 4 bits max)
        valid_flit_count = min(original_count, 15)
        
        # Create header byte: [OpCode=0001][Valid Flit Count]
        first_byte = (opcode << 4) | (valid_flit_count & 0xF)
        first_byte_hex = f"{first_byte:02X}"
        
        # Create complete entry: [header][flit_data]
        complete_entry = [first_byte_hex] + flit_bytes
        hex_string = ''.join(complete_entry)
        
        mem_entries.append(hex_string)
    
    # Write memory file
    try:
        with open(output_file, 'w') as f:
            for entry in mem_entries:
                f.write(f"{entry}\n")
    except IOError as e:
        raise IOError(f"Error writing output file: {e}")
    
    return len(mem_entries)


def main():
    """Main function to handle command line arguments and execute conversion."""
    parser = argparse.ArgumentParser(
        description="Convert hex data to Verilog memory file format",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  %(prog)s neuron_mapping.txt
  %(prog)s neuron_mapping.txt -o custom_output.mem
  %(prog)s neuron_mapping.txt -o output.mem -w 256
        """
    )
    
    parser.add_argument(
        'input_file',
        help='Path to input file containing hex data'
    )
    
    parser.add_argument(
        '-o', '--output',
        default='data_mem.mem',
        help='Output memory file path (default: data_mem.mem)'
    )
    
    parser.add_argument(
        '-w', '--width',
        type=int,
        default=128,
        help='Memory width in bits (default: 128)'
    )
    
    parser.add_argument(
        '-v', '--verbose',
        action='store_true',
        help='Enable verbose output'
    )
    
    args = parser.parse_args()
    
    try:
        # Perform conversion
        if args.verbose:
            print(f"Converting: {args.input_file} -> {args.output}")
            print(f"Memory width: {args.width} bits")
        
        num_entries = convert_hex_data_to_mem(
            args.input_file,
            args.output,
            args.width
        )
        
        # Success message
        print(f"✓ Converted {Path(args.input_file).stat().st_size} bytes to {num_entries} memory entries")
        print(f"✓ Each entry: OpCode=0001, Valid flit count computed from actual data")
        print(f"✓ Output written to: {args.output}")
        
    except (FileNotFoundError, IOError, ValueError) as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)
    except KeyboardInterrupt:
        print("\nOperation cancelled by user", file=sys.stderr)
        sys.exit(1)


if __name__ == "__main__":
    main()