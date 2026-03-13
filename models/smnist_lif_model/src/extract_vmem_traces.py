#!/usr/bin/env python3
"""
Extract V_mem and Spike Traces — Golden Reference Generator

This script loads a trained SNN model, runs the forward pass step-by-step,
and records every intermediate membrane potential (V_mem) and spike at every
timestep for every neuron in every layer. This produces the "golden reference"
that can be compared against hardware accelerator dumps.

Usage:
    python extract_vmem_traces.py --model-path ../outputs/spiking_mnist_h16_l1_t16.pth \
                                  --samples 10 --dt-steps 16 --seed 42 \
                                  --output-dir ../vmem_traces
"""

import torch
import torch.nn as nn
import torchvision
from torchvision import transforms
from torch.utils.data import DataLoader
import argparse
import sys
import os
import csv
import re
import numpy as np
from pathlib import Path
import traceback

# Robust path resolution for neuron_mapper module
_SCRIPT_DIR = Path(__file__).resolve().parent
_MODEL_COMPILER_PATH = _SCRIPT_DIR.parent.parent / "model_compiler"
if _MODEL_COMPILER_PATH.exists():
    sys.path.insert(0, str(_MODEL_COMPILER_PATH))
else:
    sys.path.append("../../model_compiler")

try:
    import snntorch as snn
except ImportError:
    print("Error: snntorch not available. Install with: pip install snntorch")
    sys.exit(1)


# =============================================================================
# CONSTANTS (must match smnist_train.py / smnist_convert_test.py)
# =============================================================================
DEFAULT_INPUT_NODES = 28 * 28       # 784
DEFAULT_OUTPUT_NEURONS = 10
DEFAULT_THRESHOLD = 1.0
DEFAULT_BETA = 0.9                  # snntorch beta (not Neuron_LIF constant)
MNIST_MEAN = 0.1307
MNIST_STD = 0.3081
CLUSTER_SIZE = 32
BASE_CLUSTER_ID = 32
NO_SPIKE_MARKER = "FFF"


# =============================================================================
# Model definition (must match training script exactly)
# =============================================================================
class SpikingMNISTClassifier(nn.Module):
    """Identical architecture to smnist_train.py / smnist_convert_test.py."""

    def __init__(self, input_nodes, hidden_neurons, num_hidden_layers, output_neurons,
                 beta=DEFAULT_BETA, threshold=DEFAULT_THRESHOLD):
        super().__init__()
        self.hidden_neurons = hidden_neurons
        self.num_hidden_layers = num_hidden_layers
        self.beta = beta
        self.threshold = threshold

        self.layers = nn.ModuleList()
        self.lif_neurons = nn.ModuleList()

        # Input -> first hidden
        self.layers.append(nn.Linear(input_nodes, hidden_neurons, bias=False))
        self.lif_neurons.append(snn.Leaky(beta=beta, threshold=threshold))

        # Hidden -> hidden
        for _ in range(num_hidden_layers - 1):
            self.layers.append(nn.Linear(hidden_neurons, hidden_neurons, bias=False))
            self.lif_neurons.append(snn.Leaky(beta=beta, threshold=threshold))

        # Last hidden -> output
        self.layers.append(nn.Linear(hidden_neurons, output_neurons, bias=False))
        self.lif_neurons.append(snn.Leaky(beta=beta, threshold=threshold))

    def forward(self, x):
        """Standard forward (not used for trace extraction)."""
        pass


# =============================================================================
# Rate encoding (deterministic with seed)
# =============================================================================
def rate_encode_poisson(inputs, num_steps, seed=None):
    """
    Convert normalized inputs to Poisson spike trains.
    Uses a fixed seed for reproducibility if provided.

    Args:
        inputs: [batch, features] normalized to ~[0, 1]
        num_steps: number of timesteps
        seed: optional random seed for reproducibility

    Returns:
        [num_steps, batch, features] binary spike trains (float)
    """
    if seed is not None:
        torch.manual_seed(seed)

    inputs_norm = torch.clamp(inputs, 0, 1)
    spike_prob = inputs_norm.unsqueeze(0).expand(num_steps, -1, -1)
    spikes = torch.rand_like(spike_prob) < spike_prob
    return spikes.float()


# =============================================================================
# Core: Extract traces
# =============================================================================
def extract_traces(model, input_spikes, dt_steps):
    """
    Run the forward pass manually, recording V_mem and spikes at every timestep.

    Args:
        model: loaded SpikingMNISTClassifier
        input_spikes: [num_steps, batch, input_features] - the spike train
        dt_steps: number of timesteps to process

    Returns:
        dict with keys:
            'vmem_before': list of tensors [timesteps, batch, neurons] per layer
            'vmem_after':  list of tensors [timesteps, batch, neurons] per layer
            'spikes':      list of tensors [timesteps, batch, neurons] per layer
            'output_spike_sum': [batch, output_neurons] - accumulated output spikes
    """
    num_layers = len(model.layers)
    batch_size = input_spikes.shape[1]
    device = next(model.parameters()).device

    # Initialize membrane potentials
    # init_leaky() returns scalar tensor(0.) — we'll expand it on first use
    mem_states = [lif.init_leaky() for lif in model.lif_neurons]

    # Storage for traces
    vmem_before_all = [[] for _ in range(num_layers)]  # V_mem before spike decision
    vmem_after_all = [[] for _ in range(num_layers)]   # V_mem after spike/reset
    spikes_all = [[] for _ in range(num_layers)]       # spike output

    spike_sum = None

    model.eval()
    with torch.no_grad():
        for t in range(dt_steps):
            x_t = input_spikes[t].to(device)
            current_input = x_t

            for layer_idx in range(num_layers):
                # Linear transform: current = W * input
                current = model.layers[layer_idx](current_input)

                # Record the membrane state BEFORE the LIF update
                # On the first timestep, mem is scalar 0 from init_leaky(),
                # so we create a properly-shaped zero tensor instead
                mem_before = mem_states[layer_idx]
                if mem_before.dim() == 0 or mem_before.shape != current.shape:
                    # Scalar or wrong shape → create zeros with correct [batch, neurons] shape
                    mem_before = torch.zeros_like(current)
                vmem_before_all[layer_idx].append(mem_before.cpu().clone())

                # LIF neuron step: spike, new_mem = lif(current, mem)
                # Internally snntorch computes: v = beta * mem + current
                # Then: spike = (v >= threshold), mem_after = v * (1 - spike) (for reset-to-zero)
                spike_out, mem_states[layer_idx] = model.lif_neurons[layer_idx](
                    current, mem_states[layer_idx]
                )

                # Record V_mem AFTER spike decision (post-reset membrane)
                vmem_after_all[layer_idx].append(mem_states[layer_idx].cpu().clone())

                # Record spikes
                spikes_all[layer_idx].append(spike_out.cpu().clone())

                # Pass spikes to next layer
                current_input = spike_out

            # Accumulate output spikes
            if spike_sum is None:
                spike_sum = current_input.cpu().clone()
            else:
                spike_sum = spike_sum + current_input.cpu()

    # Stack into tensors: [timesteps, batch, neurons]
    result = {
        'vmem_before': [torch.stack(v, dim=0) for v in vmem_before_all],
        'vmem_after': [torch.stack(v, dim=0) for v in vmem_after_all],
        'spikes': [torch.stack(s, dim=0) for s in spikes_all],
        'output_spike_sum': spike_sum,
    }
    return result


# =============================================================================
# Save traces
# =============================================================================
def save_traces_csv(traces, output_dir, sample_indices, dt_steps):
    """
    Save per-sample CSV files with V_mem and spike traces for all layers.

    Each CSV row: timestep, layer, neuron, vmem_before, vmem_after, spike
    """
    os.makedirs(output_dir, exist_ok=True)
    num_layers = len(traces['vmem_before'])

    for batch_idx, sample_idx in enumerate(sample_indices):
        csv_path = os.path.join(output_dir, f"sample_{sample_idx:04d}_traces.csv")
        with open(csv_path, 'w', newline='') as f:
            writer = csv.writer(f)
            writer.writerow(['timestep', 'layer', 'neuron', 'vmem_before', 'vmem_after', 'spike'])

            for layer_idx in range(num_layers):
                num_neurons = traces['vmem_before'][layer_idx].shape[2]
                for t in range(dt_steps):
                    for n in range(num_neurons):
                        vmem_b = traces['vmem_before'][layer_idx][t, batch_idx, n].item()
                        vmem_a = traces['vmem_after'][layer_idx][t, batch_idx, n].item()
                        spike = int(traces['spikes'][layer_idx][t, batch_idx, n].item())
                        writer.writerow([t, layer_idx, n, f"{vmem_b:.8f}", f"{vmem_a:.8f}", spike])

    print(f"  CSV traces saved to {output_dir}/")


def save_traces_npz(traces, output_dir, sample_indices, labels):
    """
    Save compact numpy archive with all traces for batch comparison.
    """
    os.makedirs(output_dir, exist_ok=True)
    npz_path = os.path.join(output_dir, "golden_reference.npz")

    save_dict = {
        'sample_indices': np.array(sample_indices),
        'labels': np.array(labels),
        'output_spike_sum': traces['output_spike_sum'].numpy(),
    }

    for layer_idx in range(len(traces['vmem_before'])):
        save_dict[f'vmem_before_layer{layer_idx}'] = traces['vmem_before'][layer_idx].numpy()
        save_dict[f'vmem_after_layer{layer_idx}'] = traces['vmem_after'][layer_idx].numpy()
        save_dict[f'spikes_layer{layer_idx}'] = traces['spikes'][layer_idx].numpy()

    np.savez_compressed(npz_path, **save_dict)
    print(f"  Compact golden reference saved to {npz_path}")


def save_input_spikes_for_hardware(input_spikes, output_dir, sample_indices, dt_steps):
    """
    Save the exact input spike patterns used, so hardware can replay them.
    Format: same as smnist_convert_test.py's test_values.txt
    """
    os.makedirs(output_dir, exist_ok=True)
    spike_file = os.path.join(output_dir, "golden_input_spikes.txt")

    with open(spike_file, 'w') as f:
        for batch_idx in range(input_spikes.shape[1]):
            for t in range(dt_steps):
                for pixel in range(input_spikes.shape[2]):
                    if input_spikes[t][batch_idx][pixel] > 0:
                        cluster_id = (pixel // CLUSTER_SIZE) + BASE_CLUSTER_ID
                        neuron_id = pixel % CLUSTER_SIZE
                        packet = (cluster_id << 5) | neuron_id
                        f.write(f"{packet:03X}\n")
                    else:
                        f.write(f"{NO_SPIKE_MARKER}\n")

    print(f"  Input spike patterns saved to {spike_file}")


# =============================================================================
# Filename parser (same as other scripts)
# =============================================================================
def parse_model_filename(model_path):
    """Parse h{neurons}_l{layers}_t{steps} from filename."""
    filename = Path(model_path).name
    patterns = [
        r'spiking_mnist_h(\d+)_l(\d+)_t(\d+)\.pth',
        r'h(\d+)_l(\d+)_t(\d+)',
    ]
    for pattern in patterns:
        match = re.search(pattern, filename)
        if match:
            return {
                'hidden_neurons': int(match.group(1)),
                'hidden_layers': int(match.group(2)),
                'dt_steps': int(match.group(3)),
            }
    return None


# =============================================================================
# Main
# =============================================================================
def main():
    parser = argparse.ArgumentParser(
        description='Extract V_mem and Spike traces from a trained SNN model (golden reference)',
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )

    parser.add_argument('--model-path', type=str, required=True,
                        help='Path to trained .pth model file')
    parser.add_argument('--samples', type=int, default=10,
                        help='Number of test samples to extract traces for')
    parser.add_argument('--dt-steps', type=int, default=None,
                        help='Override number of timesteps (default: auto-detect from filename)')
    parser.add_argument('--hidden-neurons', type=int, default=None,
                        help='Override hidden neurons (default: auto-detect)')
    parser.add_argument('--hidden-layers', type=int, default=None,
                        help='Override hidden layers (default: auto-detect)')
    parser.add_argument('--seed', type=int, default=42,
                        help='Random seed for reproducible spike encoding')
    parser.add_argument('--output-dir', type=str, default='../vmem_traces',
                        help='Output directory for trace files')
    parser.add_argument('--cpu', action='store_true',
                        help='Force CPU usage')
    parser.add_argument('--no-csv', action='store_true',
                        help='Skip saving per-sample CSV files (only save .npz)')

    args = parser.parse_args()

    # --- Parse model filename ---
    model_path = Path(args.model_path)
    if not model_path.exists():
        print(f"Error: Model file '{model_path}' not found!")
        sys.exit(1)

    parsed = parse_model_filename(model_path)
    if parsed:
        print(f"Auto-detected from filename: {parsed}")

    hidden_neurons = args.hidden_neurons or (parsed['hidden_neurons'] if parsed else 16)
    hidden_layers = args.hidden_layers or (parsed['hidden_layers'] if parsed else 1)
    dt_steps = args.dt_steps or (parsed['dt_steps'] if parsed else 16)

    device = 'cpu' if args.cpu or not torch.cuda.is_available() else 'cuda'

    print(f"\n{'='*60}")
    print(f"GOLDEN REFERENCE V_MEM TRACE EXTRACTION")
    print(f"{'='*60}")
    print(f"  Model:          {model_path}")
    print(f"  Hidden neurons: {hidden_neurons}")
    print(f"  Hidden layers:  {hidden_layers}")
    print(f"  Timesteps:      {dt_steps}")
    print(f"  Samples:        {args.samples}")
    print(f"  Seed:           {args.seed}")
    print(f"  Device:         {device}")
    print(f"  Output dir:     {args.output_dir}")
    print(f"{'='*60}\n")

    # --- Load model ---
    print("Loading model...")
    model = SpikingMNISTClassifier(
        input_nodes=DEFAULT_INPUT_NODES,
        hidden_neurons=hidden_neurons,
        num_hidden_layers=hidden_layers,
        output_neurons=DEFAULT_OUTPUT_NEURONS,
        beta=DEFAULT_BETA,
        threshold=DEFAULT_THRESHOLD,
    )

    state_dict = torch.load(model_path, map_location=device, weights_only=True)
    model.load_state_dict(state_dict)
    model.to(device)
    model.eval()

    total_params = sum(p.numel() for p in model.parameters())
    print(f"  Model loaded: {total_params:,} parameters, {len(model.layers)} layers")

    # --- Load MNIST test data ---
    print("Loading MNIST test data...")
    transform = transforms.Compose([
        transforms.ToTensor(),
        transforms.Normalize((MNIST_MEAN,), (MNIST_STD,)),
    ])
    test_dataset = torchvision.datasets.MNIST(
        root='./data', train=False, download=True, transform=transform,
    )

    # Collect the requested number of samples
    num_samples = min(args.samples, len(test_dataset))
    test_loader = DataLoader(test_dataset, batch_size=num_samples, shuffle=False)
    data_batch, labels_batch = next(iter(test_loader))

    data_flat = data_batch.view(num_samples, -1)  # [samples, 784]
    labels = labels_batch.numpy().tolist()
    sample_indices = list(range(num_samples))

    print(f"  Loaded {num_samples} samples, labels: {labels}")

    # --- Encode spikes (with fixed seed for reproducibility) ---
    print(f"Encoding input spikes (seed={args.seed})...")
    input_spikes = rate_encode_poisson(data_flat, dt_steps, seed=args.seed)
    print(f"  Input spike tensor: {input_spikes.shape}")

    # Count total input spikes
    total_input_spikes = int(input_spikes.sum().item())
    total_possible = input_spikes.numel()
    print(f"  Total input spikes: {total_input_spikes}/{total_possible} "
          f"({100*total_input_spikes/total_possible:.1f}%)")

    # --- Extract traces ---
    print("Extracting V_mem and spike traces...")
    traces = extract_traces(model, input_spikes, dt_steps)

    # --- Sanity check: verify classification output ---
    print("\nSanity check — classification results:")
    predictions = traces['output_spike_sum'].argmax(dim=1).numpy().tolist()
    correct = sum(1 for p, l in zip(predictions, labels) if p == l)
    print(f"  Predictions: {predictions}")
    print(f"  Labels:      {labels}")
    print(f"  Correct:     {correct}/{num_samples} ({100*correct/num_samples:.1f}%)")

    # --- Sanity check: V_mem ranges ---
    print("\nV_mem statistics per layer:")
    for layer_idx in range(len(traces['vmem_before'])):
        vb = traces['vmem_before'][layer_idx]
        va = traces['vmem_after'][layer_idx]
        spk = traces['spikes'][layer_idx]
        total_spikes = int(spk.sum().item())
        print(f"  Layer {layer_idx}: "
              f"V_mem_before [{vb.min():.4f}, {vb.max():.4f}], "
              f"V_mem_after [{va.min():.4f}, {va.max():.4f}], "
              f"spikes={total_spikes}")

        if torch.isnan(vb).any() or torch.isnan(va).any():
            print(f"    WARNING: NaN detected in layer {layer_idx}!")

    # --- Save outputs ---
    output_dir = Path(args.output_dir)
    print(f"\nSaving traces to {output_dir}/...")

    if not args.no_csv:
        save_traces_csv(traces, str(output_dir), sample_indices, dt_steps)

    save_traces_npz(traces, str(output_dir), sample_indices, labels)
    save_input_spikes_for_hardware(input_spikes, str(output_dir), sample_indices, dt_steps)

    # --- Final summary ---
    print(f"\n{'='*60}")
    print(f"EXTRACTION COMPLETE")
    print(f"{'='*60}")
    print(f"Output files:")
    for f in sorted(output_dir.iterdir()):
        size_kb = f.stat().st_size / 1024
        print(f"  {f.name:40s} {size_kb:8.1f} KB")
    print(f"\nTo compare with hardware:")
    print(f"  1. Feed golden_input_spikes.txt to the accelerator")
    print(f"  2. Dump V_mem from hardware at each timestep")
    print(f"  3. Compare against sample_XXXX_traces.csv or golden_reference.npz")
    print(f"{'='*60}")


if __name__ == "__main__":
    main()
