#!/usr/bin/env python3
"""
Spike Input Generator for Neuron Accelerator
============================================
Generate spike-encoded input data for hardware testing.

Supports:
- Rate coding (spike frequency encodes value)
- Temporal coding (spike timing encodes value)
- Binary encoding (spike = 1, no spike = 0)
"""

import argparse
import numpy as np
from pathlib import Path


def rate_encoding(values, timesteps, max_rate=20):
    """
    Rate encoding: Higher values = more spikes
    
    Args:
        values: Input values (normalized 0-1)
        timesteps: Number of time steps
        max_rate: Maximum spike rate (spikes per timestep window)
        
    Returns:
        List of spike times for each neuron
    """
    spikes = []
    
    for neuron_id, value in enumerate(values):
        neuron_spikes = []
        spike_rate = int(value * max_rate)
        
        # Generate spikes at regular intervals
        if spike_rate > 0:
            interval = timesteps / spike_rate
            for i in range(spike_rate):
                spike_time = int(i * interval)
                if spike_time < timesteps:
                    neuron_spikes.append((neuron_id, spike_time))
        
        spikes.extend(neuron_spikes)
    
    return sorted(spikes, key=lambda x: (x[1], x[0]))


def temporal_encoding(values, timesteps):
    """
    Temporal encoding: Spike timing encodes value
    Higher values spike earlier
    
    Args:
        values: Input values (normalized 0-1)
        timesteps: Number of time steps
        
    Returns:
        List of spike times for each neuron
    """
    spikes = []
    
    for neuron_id, value in enumerate(values):
        if value > 0.01:  # Threshold to avoid very late spikes
            # Higher values spike earlier
            spike_time = int((1.0 - value) * (timesteps - 1))
            spikes.append((neuron_id, spike_time))
    
    return sorted(spikes, key=lambda x: (x[1], x[0]))


def binary_encoding(values, timestep=0):
    """
    Binary encoding: Spike if value > threshold
    
    Args:
        values: Input values (normalized 0-1)
        timestep: Single timestep for all spikes
        
    Returns:
        List of spike times for each neuron
    """
    spikes = []
    
    for neuron_id, value in enumerate(values):
        if value > 0.5:  # Threshold
            spikes.append((neuron_id, timestep))
    
    return spikes


def encode_spike_packet(neuron_id, timestep=0, packet_width=11):
    """
    Encode spike packet in hardware format.
    Format: [neuron_id (6 bits) | timestep (5 bits)]
    
    Args:
        neuron_id: Neuron identifier
        timestep: Time of spike
        packet_width: Packet width in bits
        
    Returns:
        Hex string for spike packet
    """
    # Simple encoding: just neuron ID (can be extended)
    packet = (neuron_id & 0x7FF)  # 11-bit packet
    return f"{packet:03X}"


def generate_spike_mem_file(input_samples, timesteps, output_file, encoding='rate'):
    """
    Generate spike_mem.mem file for hardware simulation.
    
    Args:
        input_samples: List of input vectors (each sample is a list of values)
        timesteps: Number of timesteps per sample
        output_file: Output file path
        encoding: Encoding scheme ('rate', 'temporal', 'binary')
    """
    print(f"Generating spike memory file: {output_file}")
    print(f"  Encoding: {encoding}")
    print(f"  Samples: {len(input_samples)}")
    print(f"  Timesteps: {timesteps}")
    
    with open(output_file, 'w') as f:
        for sample_idx, sample in enumerate(input_samples):
            # Normalize input
            sample_normalized = np.array(sample) / (np.max(sample) + 1e-10)
            
            # Encode to spikes
            if encoding == 'rate':
                spikes = rate_encoding(sample_normalized, timesteps)
            elif encoding == 'temporal':
                spikes = temporal_encoding(sample_normalized, timesteps)
            elif encoding == 'binary':
                spikes = binary_encoding(sample_normalized)
            else:
                raise ValueError(f"Unknown encoding: {encoding}")
            
            # Write spikes for this sample
            for neuron_id, spike_time in spikes:
                packet = encode_spike_packet(neuron_id, spike_time)
                f.write(f"{packet}\n")
            
            # End marker for this sample
            f.write("7FF\n")
            
            if (sample_idx + 1) % 100 == 0:
                print(f"  Generated {sample_idx + 1} samples...")
        
        # Final end marker
        f.write("7FF\n")
    
    print(f"✓ Spike memory file created: {output_file}")


def load_mnist_data(dataset_path, num_samples=100):
    """Load MNIST dataset (if available)."""
    try:
        import tensorflow as tf
        
        print("Loading MNIST dataset...")
        (x_train, y_train), (x_test, y_test) = tf.keras.datasets.mnist.load_data()
        
        # Flatten and normalize
        x_test_flat = x_test[:num_samples].reshape(num_samples, -1) / 255.0
        
        return x_test_flat.tolist(), y_test[:num_samples].tolist()
    except ImportError:
        print("TensorFlow not installed. Install with: pip install tensorflow")
        return None, None


def create_xor_data():
    """Create simple XOR test data."""
    inputs = [
        [0, 0],
        [0, 1],
        [1, 0],
        [1, 1]
    ]
    labels = [0, 1, 1, 0]
    
    return inputs, labels


def create_random_data(num_samples, input_size):
    """Create random test data."""
    inputs = np.random.rand(num_samples, input_size).tolist()
    labels = np.random.randint(0, 10, num_samples).tolist()
    
    return inputs, labels


def main():
    parser = argparse.ArgumentParser(
        description="Generate spike-encoded input data for hardware accelerator"
    )
    
    parser.add_argument(
        '--output',
        type=str,
        default='spike_mem.mem',
        help='Output spike memory file (default: spike_mem.mem)'
    )
    
    parser.add_argument(
        '--encoding',
        type=str,
        choices=['rate', 'temporal', 'binary'],
        default='rate',
        help='Spike encoding scheme (default: rate)'
    )
    
    parser.add_argument(
        '--timesteps',
        type=int,
        default=20,
        help='Number of timesteps (default: 20)'
    )
    
    parser.add_argument(
        '--dataset',
        type=str,
        choices=['xor', 'mnist', 'random'],
        default='xor',
        help='Dataset to use (default: xor)'
    )
    
    parser.add_argument(
        '--samples',
        type=int,
        default=100,
        help='Number of samples for MNIST/random (default: 100)'
    )
    
    parser.add_argument(
        '--input-size',
        type=int,
        default=784,
        help='Input size for random data (default: 784)'
    )
    
    parser.add_argument(
        '--labels-output',
        type=str,
        help='Optional: Save labels to file'
    )
    
    args = parser.parse_args()
    
    print("=" * 60)
    print("Spike Input Generator")
    print("=" * 60)
    
    # Load or create data
    if args.dataset == 'xor':
        inputs, labels = create_xor_data()
        print("Using XOR dataset (4 samples)")
    elif args.dataset == 'mnist':
        inputs, labels = load_mnist_data(None, args.samples)
        if inputs is None:
            print("Failed to load MNIST. Using random data instead.")
            inputs, labels = create_random_data(args.samples, args.input_size)
    else:  # random
        inputs, labels = create_random_data(args.samples, args.input_size)
        print(f"Generated random dataset ({args.samples} samples, {args.input_size} inputs)")
    
    # Generate spike memory file
    output_path = Path(args.output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    generate_spike_mem_file(inputs, args.timesteps, args.output, args.encoding)
    
    # Save labels if requested
    if args.labels_output:
        labels_path = Path(args.labels_output)
        labels_path.parent.mkdir(parents=True, exist_ok=True)
        
        with open(args.labels_output, 'w') as f:
            for label in labels:
                f.write(f"{label}\n")
        print(f"✓ Labels saved to: {args.labels_output}")
    
    print()
    print("=" * 60)
    print("Next steps:")
    print(f"  1. Copy {args.output} to rtl/neuron_accelerator/")
    print("  2. Ensure data_mem.mem exists (use export_weights_for_hardware.py)")
    print("  3. Run simulation")
    print("=" * 60)


if __name__ == "__main__":
    main()
