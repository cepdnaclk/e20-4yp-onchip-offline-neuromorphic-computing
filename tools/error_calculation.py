"""Layer-wise blame (error) calculation helpers for a simple feed-forward network.

Conventions used:
- Output layer blame: all neurons receive the same scalar blame
  blame_out[j] = expected_value - actual_value
- Hidden/Input layer blame:
  blame_curr[i] = sum_j(weights_to_next[i][j] * blame_next[j])

This module returns Python lists so it can be used easily with your existing
tooling or converted to fixed-point values for hardware flows.
"""

from typing import List, Sequence


def weights_to_matrix(
    flat_weights: Sequence[float],
    num_rows: int,
    num_cols: int,
) -> List[List[float]]:
    """Convert a flat weight list stored as w[0,0],w[0,1],...,w[n-1,m-1]
    into a 2D matrix shaped [num_rows][num_cols].

    Args:
        flat_weights: flat list of weights in row-major order.
        num_rows:     number of neurons in the current layer (e.g. N_hidden).
        num_cols:     number of neurons in the next layer   (e.g. N_output).

    Returns:
        matrix[i][j] = weight from neuron i in current layer to neuron j in next layer.
    """
    expected = num_rows * num_cols
    if len(flat_weights) != expected:
        raise ValueError(
            f"Expected {expected} weights ({num_rows} x {num_cols}), "
            f"got {len(flat_weights)}"
        )

    return [
        list(flat_weights[i * num_cols : (i + 1) * num_cols])
        for i in range(num_rows)
    ]


def output_layer_blame(
	expected_value: float,
	actual_value: float,
	num_output_neurons: int,
) -> List[float]:
	"""Return output-layer blame values.

	All output neurons get the same blame value as requested:
	expected - actual
	"""
	if num_output_neurons <= 0:
		raise ValueError("num_output_neurons must be > 0")

	shared_error = expected_value - actual_value
	return [shared_error] * num_output_neurons


def hidden_layer_blame(
	next_layer_blame: Sequence[float],
	weights_hidden_to_output: Sequence[Sequence[float]],
) -> List[float]:
	"""Backpropagate blame from output layer to hidden layer.

	Args:
		next_layer_blame: blame values for output neurons, length = N_out.
		weights_hidden_to_output: matrix shaped [N_hidden][N_out].

	Returns:
		blame values for hidden neurons, length = N_hidden.
	"""
	return _backpropagate_blame(next_layer_blame, weights_hidden_to_output)


def input_layer_blame(
	next_layer_blame: Sequence[float],
	weights_input_to_hidden: Sequence[Sequence[float]],
) -> List[float]:
	"""Backpropagate blame from hidden layer to input layer.

	Args:
		next_layer_blame: blame values for hidden neurons, length = N_hidden.
		weights_input_to_hidden: matrix shaped [N_input][N_hidden].

	Returns:
		blame values for input neurons, length = N_input.
	"""
	return _backpropagate_blame(next_layer_blame, weights_input_to_hidden)


def _backpropagate_blame(
	next_layer_blame: Sequence[float],
	weights_to_next: Sequence[Sequence[float]],
) -> List[float]:
	"""Generic blame propagation helper.

	Each current neuron i aggregates weighted blame from all neurons j in the
	next layer.
	"""
	if not next_layer_blame:
		raise ValueError("next_layer_blame must not be empty")
	if not weights_to_next:
		raise ValueError("weights_to_next must not be empty")

	next_size = len(next_layer_blame)
	result: List[float] = []

	for row in weights_to_next:
		if len(row) != next_size:
			raise ValueError(
				"weights_to_next row size must match len(next_layer_blame)"
			)

		blame_value = 0.0
		for weight, blame in zip(row, next_layer_blame):
			blame_value += weight * blame
		result.append(blame_value)

	return result


if __name__ == "__main__":
    # ── Network shape ──────────────────────────────────────────────
    # input: 3 neurons  →  hidden: 4 neurons  →  output: 2 neurons
    # ──────────────────────────────────────────────────────────────

    print("=== Layer-wise Blame Test ===\n")

    # 1. Output layer blame
    expected = 1.0
    actual   = 0.72
    blame_out = output_layer_blame(expected, actual, num_output_neurons=2)
    print(f"Expected={expected}, Actual={actual}")
    print(f"Output blame  : {blame_out}\n")   # should be [0.28, 0.28]

    # 2. Hidden layer blame
    # Flat weights stored as w[0,0],w[0,1], w[1,0],w[1,1], ... (4 hidden × 2 output)
    flat_h_to_o = [0.5, -0.3,
                   0.8,  0.1,
                  -0.2,  0.4,
                   0.6,  0.9]
    weights_h_to_o = weights_to_matrix(flat_h_to_o, num_rows=4, num_cols=2)
    print(f"weights_hidden_to_output matrix:")
    for i, row in enumerate(weights_h_to_o):
        print(f"  hidden[{i}] -> {row}")

    blame_hidden = hidden_layer_blame(blame_out, weights_h_to_o)
    print(f"\nHidden blame  : {[round(v,4) for v in blame_hidden]}\n")

    # 3. Input layer blame
    # Flat weights (3 input × 4 hidden)
    flat_i_to_h = [ 0.1, -0.5,  0.3,  0.7,
                    0.4,  0.2, -0.1,  0.0,
                   -0.3,  0.6,  0.8, -0.2]
    weights_i_to_h = weights_to_matrix(flat_i_to_h, num_rows=3, num_cols=4)
    print(f"weights_input_to_hidden matrix:")
    for i, row in enumerate(weights_i_to_h):
        print(f"  input[{i}] -> {row}")

    blame_input = input_layer_blame(blame_hidden, weights_i_to_h)
    print(f"\nInput blame   : {[round(v,4) for v in blame_input]}")
    # Expected: [0.1904, 0.0672, 0.0952]

    print("\n=== Test complete ===")
