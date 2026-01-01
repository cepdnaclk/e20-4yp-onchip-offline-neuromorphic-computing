#!/usr/bin/env python3
"""
Model Weight Exporter for Neuron Accelerator
============================================
This script exports trained neural network weights from software models
(PyTorch/TensorFlow/NumPy) to hardware-compatible memory files for the
neuromorphic accelerator inference testing.

Usage:
    python export_weights_for_hardware.py --model model.pth --output data_mem.mem
"""

import argparse
import numpy as np
import sys
from pathlib import Path

# Fixed-point configuration
FRAC_BITS = 16  # Number of fractional bits for Q16.16 format
INT_BITS = 16   # Number of integer bits


def float_to_fixed_point(value, frac_bits=FRAC_BITS, int_bits=INT_BITS):
    """
    Convert floating-point value to fixed-point representation.
    
    Args:
        value: Float value to convert
        frac_bits: Number of fractional bits
        int_bits: Number of integer bits
        
    Returns:
        Fixed-point value as integer
    """
    # Scale and round
    scaled = int(round(value * (2 ** frac_bits)))
    
    # Clamp to prevent overflow
    max_val = (2 ** (int_bits + frac_bits - 1)) - 1
    min_val = -(2 ** (int_bits + frac_bits - 1))
    
    clamped = max(min_val, min(max_val, scaled))
    
    # Convert to unsigned representation (two's complement)
    if clamped < 0:
        clamped = (2 ** (int_bits + frac_bits)) + clamped
    
    return clamped


def export_numpy_weights(weights_dict, output_file):
    """
    Export weights from NumPy arrays to memory file.
    
    Args:
        weights_dict: Dictionary of layer_name -> weight_array
        output_file: Output file path
    """
    print(f"Exporting weights to {output_file}...")
    
    with open(output_file, 'w') as f:
        total_weights = 0
        
        for layer_name, weights in weights_dict.items():
            print(f"  Layer: {layer_name}, Shape: {weights.shape}")
            
            # Flatten weights
            flat_weights = weights.flatten()
            
            # Convert to fixed-point and write
            for w in flat_weights:
                fixed_val = float_to_fixed_point(w)
                # Write as 32-bit hex (8 hex digits)
                f.write(f"{fixed_val:08X}\n")
                total_weights += 1
        
        # Write end marker
        f.write("xx\n")
        
    print(f"✓ Exported {total_weights} weights to {output_file}")


def export_pytorch_model(model_path, output_file):
    """Export weights from PyTorch model."""
    try:
        import torch
    except ImportError:
        print("Error: PyTorch not installed. Install with: pip install torch")
        sys.exit(1)
    
    print(f"Loading PyTorch model from {model_path}...")
    
    # Load model
    model = torch.load(model_path, map_location='cpu')
    
    # Extract weights
    weights_dict = {}
    
    if isinstance(model, dict):
        # State dict format
        state_dict = model if 'state_dict' not in model else model['state_dict']
        for name, param in state_dict.items():
            if 'weight' in name:
                weights_dict[name] = param.detach().numpy()
    else:
        # Model object
        for name, param in model.state_dict().items():
            if 'weight' in name:
                weights_dict[name] = param.detach().numpy()
    
    export_numpy_weights(weights_dict, output_file)


def export_tensorflow_model(model_path, output_file):
    """Export weights from TensorFlow/Keras model."""
    try:
        import tensorflow as tf
    except ImportError:
        print("Error: TensorFlow not installed. Install with: pip install tensorflow")
        sys.exit(1)
    
    print(f"Loading TensorFlow model from {model_path}...")
    
    # Load model
    model = tf.keras.models.load_model(model_path)
    
    # Extract weights
    weights_dict = {}
    for layer in model.layers:
        if len(layer.get_weights()) > 0:
            weights_dict[layer.name] = layer.get_weights()[0]
    
    export_numpy_weights(weights_dict, output_file)


def create_test_xor_weights(output_file):
    """
    Create simple XOR network weights for functional testing.
    Architecture: 2 -> 2 -> 1 (2 inputs, 2 hidden neurons, 1 output)
    """
    print("Creating XOR test network weights...")
    
    # XOR solution using 2 hidden neurons
    weights_dict = {
        'layer1': np.array([
            [20.0, 20.0],   # Input 1 to hidden layer
            [20.0, 20.0]    # Input 2 to hidden layer
        ]),
        'bias1': np.array([-10.0, -30.0]),  # Hidden layer biases
        'layer2': np.array([
            [20.0],   # Hidden neuron 1 to output
            [-20.0]   # Hidden neuron 2 to output
        ]),
        'bias2': np.array([-10.0])  # Output bias
    }
    
    export_numpy_weights(weights_dict, output_file)
    print("✓ XOR test weights created")


def create_random_weights(layers, neurons_per_layer, output_file):
    """
    Create random weights for testing (not trained).
    
    Args:
        layers: Number of layers
        neurons_per_layer: List of neuron counts per layer
        output_file: Output file path
    """
    print(f"Creating random weights for {layers} layers...")
    
    weights_dict = {}
    
    for i in range(layers - 1):
        layer_name = f"layer{i+1}"
        in_neurons = neurons_per_layer[i]
        out_neurons = neurons_per_layer[i+1]
        
        # Xavier initialization
        limit = np.sqrt(6.0 / (in_neurons + out_neurons))
        weights = np.random.uniform(-limit, limit, (in_neurons, out_neurons))
        
        weights_dict[layer_name] = weights
        
        # Add biases
        weights_dict[f"bias{i+1}"] = np.random.randn(out_neurons) * 0.1
    
    export_numpy_weights(weights_dict, output_file)
    print(f"✓ Random weights created")


def main():
    parser = argparse.ArgumentParser(
        description="Export neural network weights for hardware accelerator testing"
    )
    
    parser.add_argument(
        '--model',
        type=str,
        help='Path to trained model file (.pth for PyTorch, .h5 for TensorFlow)'
    )
    
    parser.add_argument(
        '--framework',
        type=str,
        choices=['pytorch', 'tensorflow', 'numpy'],
        help='Deep learning framework'
    )
    
    parser.add_argument(
        '--output',
        type=str,
        default='data_mem.mem',
        help='Output memory file (default: data_mem.mem)'
    )
    
    parser.add_argument(
        '--test-xor',
        action='store_true',
        help='Create simple XOR test network weights'
    )
    
    parser.add_argument(
        '--random',
        action='store_true',
        help='Create random weights for testing'
    )
    
    parser.add_argument(
        '--layers',
        type=int,
        nargs='+',
        default=[2, 4, 1],
        help='Layer configuration for random weights (e.g., 2 4 1 for 2->4->1)'
    )
    
    parser.add_argument(
        '--frac-bits',
        type=int,
        default=16,
        help='Number of fractional bits in fixed-point (default: 16)'
    )
    
    args = parser.parse_args()
    
    # Update global config
    global FRAC_BITS
    FRAC_BITS = args.frac_bits
    
    # Create output directory if needed
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    print("=" * 60)
    print("Weight Exporter for Neuron Accelerator")
    print("=" * 60)
    print(f"Fixed-point format: Q{INT_BITS}.{FRAC_BITS}")
    print(f"Output file: {args.output}")
    print()
    
    # Export weights based on mode
    if args.test_xor:
        create_test_xor_weights(args.output)
    elif args.random:
        create_random_weights(len(args.layers), args.layers, args.output)
    elif args.model:
        if args.framework == 'pytorch' or args.model.endswith('.pth'):
            export_pytorch_model(args.model, args.output)
        elif args.framework == 'tensorflow' or args.model.endswith('.h5'):
            export_tensorflow_model(args.model, args.output)
        else:
            print("Error: Could not determine framework. Use --framework flag.")
            sys.exit(1)
    else:
        print("Error: Specify either --model, --test-xor, or --random")
        parser.print_help()
        sys.exit(1)
    
    print()
    print("=" * 60)
    print("Next steps:")
    print("  1. Copy", args.output, "to rtl/neuron_accelerator/")
    print("  2. Run simulation: ./quick_test_setup.sh")
    print("  3. Check output.txt for results")
    print("=" * 60)


if __name__ == "__main__":
    main()
