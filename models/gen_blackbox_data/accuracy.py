#!/usr/bin/env python3
"""
Neural Network Accuracy Calculator

This script compares predicted outputs with actual labels to calculate accuracy.
It reads spike outputs from one file and ground truth labels from another file.
"""

import argparse
import sys
from pathlib import Path


# Neuron mapping dictionary
NEURON_MAPPING = {
    0: 16, 1: 17, 2: 18, 3: 19, 4: 20, 5: 21, 6: 22, 7: 23,
    8: 24, 9: 25, 10: 26, 11: 27, 12: 28, 13: 29, 14: 30, 15: 31
}


def parse_spike_outputs(filename):
    """
    Parse the spike outputs file and extract the highest frequency number for each row.
    
    Args:
        filename (str): Path to the spike outputs file
        
    Returns:
        dict: Dictionary with input_id as key and (number, frequency) as value
    """
    results = {}
    
    try:
        with open(filename, 'r') as file:
            for line in file:
                line = line.strip()
                if not line:
                    continue
                
                # Parse line format: "input_id:number1,frequency1:number2,frequency2:..."
                parts = line.split(':')
                if len(parts) < 2:
                    continue
                    
                input_id = int(parts[0].strip())
                
                # Handle empty predictions
                if len(parts) == 1 or not parts[1].strip():
                    results[input_id] = (9999999, 0)
                    continue
                
                max_freq = 0
                max_index = 0
                
                # Process each number,frequency pair
                for part in parts[1:]:
                    if not part.strip():
                        continue
                        
                    try:
                        number_freq = part.split(',')
                        if len(number_freq) == 2:
                            number = int(number_freq[0].strip())
                            frequency = int(number_freq[1].strip())
                            
                            if frequency > max_freq:
                                max_freq = frequency
                                max_index = number
                    except (ValueError, IndexError):
                        print(f"Warning: Skipping malformed part: {part}")
                        continue
                
                results[input_id] = (max_index, max_freq)
                
    except FileNotFoundError:
        print(f"Error: Could not find spike outputs file: {filename}")
        sys.exit(1)
    except Exception as e:
        print(f"Error reading spike outputs file: {e}")
        sys.exit(1)
    
    return results


def read_labels(filename):
    """
    Read the labels file and return a list of ground truth labels.
    
    Args:
        filename (str): Path to the labels file
        
    Returns:
        list: List of integer labels
    """
    labels = []
    
    try:
        with open(filename, 'r') as file:
            for line in file:
                line = line.strip()
                if line:
                    try:
                        labels.append(int(line))
                    except ValueError:
                        print(f"Warning: Skipping invalid label: {line}")
                        
    except FileNotFoundError:
        print(f"Error: Could not find labels file: {filename}")
        sys.exit(1)
    except Exception as e:
        print(f"Error reading labels file: {e}")
        sys.exit(1)
    
    return labels


def calculate_accuracy(predictions, labels, verbose=False):
    """
    Compare predictions with ground truth labels and calculate accuracy.
    
    Args:
        predictions (dict): Dictionary of predictions from spike outputs
        labels (list): List of ground truth labels
        verbose (bool): Whether to print detailed comparison results
        
    Returns:
        tuple: (accuracy, comparison_results, matches, total)
    """
    matches = 0
    total = 0
    comparison_results = []
    
    for input_id in sorted(predictions.keys()):
        # Convert input_id to 0-based index for labels
        label_index = input_id - 1
        
        if label_index < len(labels):
            predicted_number, frequency = predictions[input_id]
            actual_label = labels[label_index]
            
            mapped_actual = (predicted_number & 0x1F) % 16
            is_match = actual_label == mapped_actual

            print(actual_label, mapped_actual, predicted_number, frequency)
            
            if verbose:
                print(f"Input {input_id}: Predicted={predicted_number}, "
                        f"Actual={mapped_actual} (label={actual_label}), "
                        f"Match={is_match}")
            
            if is_match:
                matches += 1
            
            comparison_results.append({
                'input_id': input_id,
                'predicted': predicted_number,
                'frequency': frequency,
                'actual_label': actual_label,
                'actual_mapped': mapped_actual,
                'match': is_match
            })
            
            total += 1
        else:
            print(f"Warning: Input ID {input_id} exceeds available labels")
    
    accuracy = (matches / total) * 100 if total > 0 else 0
    return accuracy, comparison_results, matches, total


def print_summary(accuracy, matches, total, comparison_results, show_details=False):
    """
    Print accuracy summary and optionally detailed results.
    
    Args:
        accuracy (float): Calculated accuracy percentage
        matches (int): Number of correct predictions
        total (int): Total number of predictions
        comparison_results (list): Detailed comparison results
        show_details (bool): Whether to show detailed results
    """
    print(f"\n{'='*60}")
    print(f"ACCURACY SUMMARY")
    print(f"{'='*60}")
    print(f"Matches: {matches}/{total}")
    print(f"Accuracy: {accuracy:.2f}%")
    
    if show_details and comparison_results:
        print(f"\n{'='*60}")
        print(f"DETAILED RESULTS")
        print(f"{'='*60}")
        print(f"{'Input':<8} {'Predicted':<10} {'Freq':<6} {'Actual':<8} {'Label':<6} {'Match'}")
        print("-" * 60)
        
        for result in comparison_results[:20]:  # Show first 20 results
            print(f"{result['input_id']:<8} "
                  f"{result['predicted']:<10} "
                  f"{result['frequency']:<6} "
                  f"{result['actual_mapped']:<8} "
                  f"{result['actual_label']:<6} "
                  f"{'✓' if result['match'] else '✗'}")
        
        if len(comparison_results) > 20:
            print(f"... and {len(comparison_results) - 20} more results")


def main():
    """Main function to handle command-line arguments and execute the accuracy calculation."""
    parser = argparse.ArgumentParser(
        description="Calculate accuracy by comparing neural network predictions with ground truth labels",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter
    )
    
    parser.add_argument(
        "spike_outputs",
        help="Path to spike outputs file (predictions)"
    )
    
    parser.add_argument(
        "labels",
        help="Path to labels file (ground truth)"
    )
    
    parser.add_argument(
        "-v", "--verbose",
        action="store_true",
        help="Show detailed comparison for each prediction"
    )
    
    parser.add_argument(
        "-d", "--details",
        action="store_true",
        help="Show detailed results table in summary"
    )
    
    args = parser.parse_args()
    
    # Validate input files exist
    if not Path(args.spike_outputs).exists():
        print(f"Error: Spike outputs file '{args.spike_outputs}' does not exist")
        sys.exit(1)
    
    if not Path(args.labels).exists():
        print(f"Error: Labels file '{args.labels}' does not exist")
        sys.exit(1)
    
    print(f"Configuration:")
    print(f"  Spike outputs file: {args.spike_outputs}")
    print(f"  Labels file: {args.labels}")
    print(f"  Verbose mode: {args.verbose}")
    print("-" * 50)
    
    try:
        # Parse spike outputs file
        print("Parsing spike outputs file...")
        predictions = parse_spike_outputs(args.spike_outputs)
        print(f"Found {len(predictions)} predictions")
        
        # Read labels file
        print("Reading labels file...")
        labels = read_labels(args.labels)
        print(f"Found {len(labels)} labels")
        
        # Calculate accuracy
        print("Calculating accuracy...")
        accuracy, comparison_results, matches, total = calculate_accuracy(
            predictions, labels, args.verbose
        )
        
        # Print results
        print_summary(accuracy, matches, total, comparison_results, args.details)
        
    except KeyboardInterrupt:
        print("\nOperation cancelled by user")
        sys.exit(1)
    except Exception as e:
        print(f"Unexpected error: {e}")
        sys.exit(1)


if __name__ == "__main__":
    main()