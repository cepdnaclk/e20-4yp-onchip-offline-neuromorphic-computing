#!/usr/bin/env python3
"""
prepare_mnist_data.py — Create mnist_full_train.bin from raw MNIST IDX files.
Format: [label_byte | 784_pixel_bytes] × 60000 samples.
"""
import struct, sys, os, gzip

def read_idx_images(path):
    opener = gzip.open if path.endswith('.gz') else open
    with opener(path, 'rb') as f:
        magic, n, rows, cols = struct.unpack('>IIII', f.read(16))
        return n, rows * cols, f.read()

def read_idx_labels(path):
    opener = gzip.open if path.endswith('.gz') else open
    with opener(path, 'rb') as f:
        magic, n = struct.unpack('>II', f.read(8))
        return n, f.read()

def main():
    raw_dir = os.path.join(os.path.dirname(__file__), '..', 'models',
                           'smnist_lif_model', 'src', 'data', 'MNIST', 'raw')
    out = os.path.join(os.path.dirname(__file__), '..', 'RISC_V', 'c_program',
                       'mnist_full_train.bin')

    for img_name, lbl_name in [
        ('train-images-idx3-ubyte', 'train-labels-idx1-ubyte'),
        ('train-images-idx3-ubyte.gz', 'train-labels-idx1-ubyte.gz'),
    ]:
        img_path = os.path.join(raw_dir, img_name)
        lbl_path = os.path.join(raw_dir, lbl_name)
        if os.path.exists(img_path) and os.path.exists(lbl_path):
            break
    else:
        sys.exit(f"ERROR: no MNIST files found in {raw_dir}")

    n_img, pix, img_data = read_idx_images(img_path)
    n_lbl, lbl_data = read_idx_labels(lbl_path)
    n = min(n_img, n_lbl)
    print(f"Writing {n} samples ({pix} pixels each) to {out}")

    with open(out, 'wb') as f:
        for i in range(n):
            f.write(bytes([lbl_data[i]]))
            f.write(img_data[i * pix:(i + 1) * pix])

    print(f"Done: {os.path.getsize(out)} bytes")

if __name__ == '__main__':
    main()
