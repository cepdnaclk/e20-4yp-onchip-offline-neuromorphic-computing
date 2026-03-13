#!/usr/bin/env python3
"""
prepare_mnist_data.py
=====================
Converts MNIST dataset to binary format for backpropD.C training.

Works WITHOUT PyTorch by reading raw MNIST binary files.
If PyTorch is installed, can also download fresh MNIST data.

Usage:
    python3 prepare_mnist_data.py [--train-count N] [--output FILE]

Output:
    mnist_full_train.bin  — Binary file with alternating labels and pixel arrays
    Format: [label (uint8)] [pixels[784] (uint8)] × N samples

This binary format is what backpropD.C reads with fread().
Default MNIST data location:
    ../../models/smnist_lif_model/src/data/MNIST/raw/
"""

import struct
import sys
import os
from pathlib import Path

try:
    from torchvision import datasets, transforms
    USE_TORCH = True
except ImportError:
    USE_TORCH = False
    print("[INFO] PyTorch not available, using raw MNIST files instead.")


def parse_mnist_labels(filename):
    """
    Parse MNIST label file (idx1-ubyte format).
    Returns list of integer labels.
    """
    with open(filename, 'rb') as f:
        magic, n = struct.unpack('>II', f.read(8))
        if magic != 2049:
            raise ValueError(f"Invalid label file magic: {magic}")
        labels = struct.unpack(f'>{n}B', f.read(n))
    return list(labels)


def parse_mnist_images(filename, max_count=None):
    """
    Parse MNIST image file (idx3-ubyte format).
    Returns list of image arrays, each 28×28 = 784 bytes.
    """
    with open(filename, 'rb') as f:
        magic, n, rows, cols = struct.unpack('>IIII', f.read(16))
        if magic != 2051:
            raise ValueError(f"Invalid image file magic: {magic}")
        if rows != 28 or cols != 28:
            raise ValueError(f"Expected 28×28, got {rows}×{cols}")
        
        if max_count is not None:
            n = min(n, max_count)
        
        images = []
        for i in range(n):
            img_bytes = f.read(784)
            if len(img_bytes) != 784:
                break
            images.append(img_bytes)
    
    return images


def create_mnist_binary_torch(output_file, train_count=60000):
    """Convert using torchvision (if available)."""
    print(f"Loading MNIST training data via PyTorch (first {train_count} samples)...")
    
    os.makedirs('./mnist_data', exist_ok=True)
    
    transform = transforms.ToTensor()
    mnist_train = datasets.MNIST(
        root='./mnist_data',
        train=True,
        download=True,
        transform=transform
    )
    
    if train_count > len(mnist_train):
        train_count = len(mnist_train)
        print(f"Note: dataset has only {len(mnist_train)} samples")
    
    print(f"Writing {train_count} samples to {output_file}...")
    with open(output_file, 'wb') as f:
        for idx in range(train_count):
            if idx % 10000 == 0:
                print(f"  {idx}/{train_count}...")
            
            img, label = mnist_train[idx]
            pixels = (img[0].numpy().flatten() * 255).astype('uint8')
            f.write(struct.pack('B', label))
            f.write(pixels.tobytes())


def create_mnist_binary_raw(output_file, train_count=60000):
    """Convert using raw MNIST files (no dependencies)."""
    # Find MNIST raw files
    possible_paths = [
        '../../models/smnist_lif_model/src/data/MNIST/raw',
        '../../../models/smnist_lif_model/src/data/MNIST/raw',
        '/home/e20439/e20-4yp-onchip-offline-neuromorphic-computing/models/smnist_lif_model/src/data/MNIST/raw',
    ]
    
    mnist_dir = None
    for p in possible_paths:
        if Path(p).exists():
            mnist_dir = p
            break
    
    if not mnist_dir:
        raise FileNotFoundError(
            "Cannot find MNIST raw data. Expected in:\n" +
            "\n".join([f"  {p}" for p in possible_paths])
        )
    
    label_file = Path(mnist_dir) / 'train-labels-idx1-ubyte'
    image_file = Path(mnist_dir) / 'train-images-idx3-ubyte'
    
    if not label_file.exists() or not image_file.exists():
        raise FileNotFoundError(
            f"MNIST files not found in {mnist_dir}:\n"
            f"  {label_file.exists() and '✓' or '✗'} {label_file}\n"
            f"  {image_file.exists() and '✓' or '✗'} {image_file}"
        )
    
    print(f"Loading MNIST from raw files...")
    print(f"  Labels: {label_file}")
    print(f"  Images: {image_file}")
    
    labels = parse_mnist_labels(str(label_file))
    images = parse_mnist_images(str(image_file), max_count=train_count)
    
    actual_count = min(len(labels), len(images), train_count)
    print(f"Writing {actual_count} samples to {output_file}...")
    
    with open(output_file, 'wb') as f:
        for idx in range(actual_count):
            if idx % 10000 == 0:
                print(f"  {idx}/{actual_count}...")
            f.write(struct.pack('B', labels[idx]))
            f.write(images[idx])
    
    return actual_count


def create_mnist_binary(output_file, train_count=60000):
    """Convert MNIST training set to binary format (use torch if available, else raw)."""
    if USE_TORCH:
        create_mnist_binary_torch(output_file, train_count)
    else:
        actual_count = create_mnist_binary_raw(output_file, train_count)
        train_count = actual_count
    
    file_size = Path(output_file).stat().st_size
    expected_size = train_count * (1 + 784)
    print(f"✓ Written {file_size} bytes (expected {expected_size})")
    if file_size != expected_size:
        print("WARNING: file size mismatch!")
    else:
        print(f"✓ Ready to run: cd ../../RISC_V/c_program && gcc -O2 -o backprop backpropD.C && ./backprop")


if __name__ == '__main__':
    import argparse
    parser = argparse.ArgumentParser(description='Prepare MNIST binary for backprop training')
    parser.add_argument('--train-count', type=int, default=60000,
                        help='Number of training samples (default: 60000, max: 60000)')
    parser.add_argument('--output', default='mnist_full_train.bin',
                        help='Output file (default: mnist_full_train.bin)')
    args = parser.parse_args()
    
    create_mnist_binary(args.output, args.train_count)
