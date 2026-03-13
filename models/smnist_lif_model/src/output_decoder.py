#!/usr/bin/env python3
"""
Hardware Output Decoder for Neuromorphic Accelerator
=====================================================
Decodes hardware simulation output and compares with expected test labels.
Calculates classification accuracy based on spike count voting.

Usage:
    python output_decoder.py [--output-file PATH] [--labels-file PATH]
"""

import argparse
import sys
from pathlib import Path

# =============================================================================
# DEFAULT CONFIGURATION PARAMETERS
# =============================================================================
# Input Files
DEFAULT_OUTPUT_FILE = "output.txt"          # Hardware simulation output
DEFAULT_LABELS_FILE = "test_labels.txt"     # Expected ground truth labels

# Output Configuration
DEFAULT_SHOW_DETAILS = True                 # Show per-sample details
DEFAULT_SHOW_SUMMARY = True                 # Show summary statistics

# Processing Parameters
NO_OUTPUT_MARKER = -1                       # Value assigned when no output detected

# =============================================================================


def decode_hardware_output(output_file_path, labels_file_path, show_details=True, show_summary=True):
    """
    Decode hardware output and compare with expected labels.
    
    Args:
        output_file_path: Path to hardware output file
        labels_file_path: Path to expected labels file
        show_details: Whether to print per-sample details
        show_summary: Whether to print summary statistics
        
    Returns:
        tuple: (accuracy, correct_count, total_count)
    """
    # Read files
    try:
        with open(output_file_path, 'r') as f:
            output_file = f.read()
    except FileNotFoundError:
        print(f"Error: Output file '{output_file_path}' not found!")
        sys.exit(1)
    
    try:
        with open(labels_file_path, 'r') as f:
            expected_output_file = f.read()
    except FileNotFoundError:
        print(f"Error: Labels file '{labels_file_path}' not found!")
        sys.exit(1)
    
    # Parse expected output (ground truth labels)
    expected_output = []
    for line in expected_output_file.splitlines():
        if line.strip():  # Check if the line is not empty
            expected_output.append(int(line.strip()))
    
    # Parse hardware output
    output = {}
    for line in output_file.splitlines():
        if line.strip() and ":" in line:  # Check if the line is not empty
            index, value = line.strip().split(":")
            if index not in output.keys():
                output[index] = {}
            if value not in output[index].keys():
                output[index][value] = 0
            output[index][value] += 1
    
    # Decode output using spike count voting
    output_array = []
    
    if show_details:
        print("\n" + "="*60)
        print("HARDWARE OUTPUT DECODING")
        print("="*60)
    
    for index in range(len(expected_output)):
        values = output.get(str(index), {})
        
        # Get max count value (winner-takes-all)
        if not values:
            if show_details:
                print(f"Sample {index:3d}: No output detected")
            output_array.append(NO_OUTPUT_MARKER)
            continue
        
        max_value = max(values, key=values.get)
        max_count = values[max_value]
        predicted_class = int(max_value[-1])
        
        if show_details:
            correct_marker = "✓" if predicted_class == expected_output[index] else "✗"
            print(f"Sample {index:3d}: Predicted={predicted_class}, Expected={expected_output[index]}, "
                  f"Spikes={max_count:4d} {correct_marker}")
        
        output_array.append(predicted_class)
    
    # Calculate accuracy
    correct = sum(1 for i in range(len(expected_output)) 
                  if output_array[i] == expected_output[i])
    total = len(expected_output)
    accuracy = 100 * correct / total
    
    if show_summary:
        print("\n" + "="*60)
        print("ACCURACY SUMMARY")
        print("="*60)
        print(f"Correct Predictions:  {correct}/{total}")
        print(f"Test Accuracy:        {accuracy:.2f}%")
        print(f"Error Rate:           {100 - accuracy:.2f}%")
        print("="*60 + "\n")
    
    return accuracy, correct, total


def print_usage_examples():
    """Print usage examples and exit."""
    print("\n" + "="*60)
    print("HARDWARE OUTPUT DECODER - USAGE EXAMPLES")
    print("="*60)
    print()
    
    print("BASIC USAGE:")
    print("  python output_decoder.py")
    print("    # Uses default files: output.txt and test_labels.txt")
    print()
    
    print("CUSTOM FILES:")
    print("  python output_decoder.py --output-file results/sim_output.txt \\")
    print("                           --labels-file ../test_labels.txt")
    print()
    
    print("QUIET MODE (only accuracy):")
    print("  python output_decoder.py --no-details")
    print()
    
    print("FULL OUTPUT:")
    print("  python output_decoder.py --show-details --show-summary")
    print()
    
    print("="*60)
    print()
    
    print("FILE FORMATS:")
    print()
    print("output.txt (Hardware simulation output):")
    print("  0:output_8")
    print("  0:output_8")
    print("  1:output_3")
    print("  ...")
    print()
    print("test_labels.txt (Ground truth labels):")
    print("  8")
    print("  3")
    print("  7")
    print("  ...")
    print()
    print("="*60 + "\n")


def main():
    """Main execution function."""
    parser = argparse.ArgumentParser(
        description='Decode hardware output and calculate accuracy',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
        epilog="For more examples, run with --examples flag"
    )
    
    # File paths
    file_group = parser.add_argument_group('File Paths')
    file_group.add_argument(
        '--output-file', type=str, default=DEFAULT_OUTPUT_FILE,
        help=f'Path to hardware output file (default: {DEFAULT_OUTPUT_FILE})'
    )
    file_group.add_argument(
        '--labels-file', type=str, default=DEFAULT_LABELS_FILE,
        help=f'Path to expected labels file (default: {DEFAULT_LABELS_FILE})'
    )
    
    # Output control
    output_group = parser.add_argument_group('Output Control')
    output_group.add_argument(
        '--show-details', action='store_true', default=DEFAULT_SHOW_DETAILS,
        help='Show per-sample decoding details'
    )
    output_group.add_argument(
        '--no-details', action='store_true',
        help='Hide per-sample details (only show summary)'
    )
    output_group.add_argument(
        '--show-summary', action='store_true', default=DEFAULT_SHOW_SUMMARY,
        help='Show accuracy summary'
    )
    
    # Help
    help_group = parser.add_argument_group('Help')
    help_group.add_argument(
        '--examples', action='store_true',
        help='Show usage examples and exit'
    )
    
    args = parser.parse_args()
    
    # Show examples if requested
    if args.examples:
        print_usage_examples()
        return
    
    # Handle detail flags
    show_details = args.show_details and not args.no_details
    
    # Print configuration
    print("\n" + "="*60)
    print("HARDWARE OUTPUT DECODER")
    print("="*60)
    print(f"Output file:      {args.output_file}")
    print(f"Labels file:      {args.labels_file}")
    print(f"Show details:     {show_details}")
    print(f"Show summary:     {args.show_summary}")
    print("="*60)
    
    # Decode output
    try:
        accuracy, correct, total = decode_hardware_output(
            args.output_file,
            args.labels_file,
            show_details=show_details,
            show_summary=args.show_summary
        )
        
        # Exit with success
        sys.exit(0)
        
    except Exception as e:
        print(f"\nERROR: Decoding failed: {e}")
        import traceback
        traceback.print_exc()
        sys.exit(1)


if __name__ == "__main__":
    main()
