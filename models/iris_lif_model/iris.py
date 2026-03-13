import torch
import snntorch as snn
from matplotlib import pyplot as plt

from sklearn import datasets
from sklearn.model_selection import train_test_split
from torch import nn

import sys
sys.path.append(f"../model_compiler")
from neuron_mapper import Neuron_Mapper, Neuron_LIF


# --- Configurations ---
CUT_TRAINING_SHORT = False
TRAINING_CUTOFF = 1

device = 'cuda' if torch.cuda.is_available() else 'cpu'
dtype = torch.float32

input_nodes = 4       # Sepal length, sepal width, petal length, petal width
hidden_neurons = 16  # Arbitrary hidden layer size
output_neurons = 3    # Setosa, Virginica, Versicolor

threshold = 1      # LIF neuron threshold
reset_mode = Neuron_LIF.RESET_MODE_ZERO  # Reset mode for LIF neuron
beta = Neuron_LIF.DECAY_MODE_LIF_2       # LIF neuron decay rate
dt_steps = 50         # Time steps (rate coding duration)
epochs = 1000          # Training epochs

# --- Load and Prepare Data ---
iris = datasets.load_iris()
X = iris.data
y = iris.target

X_train, X_test, y_train, y_test = train_test_split(X, y,
                                                    test_size=0.2,
                                                    random_state=0)

# Normalize and convert to torch tensors
X_train_tensor = torch.tensor(X_train, dtype=dtype)
X_test_tensor = torch.tensor(X_test, dtype=dtype)

X_train_tensor /= X_train_tensor.max()
X_test_tensor /= X_test_tensor.max()

def rate_encode_poisson(inputs, num_steps):
    """
    inputs: [batch, features] — normalized to [0, 1]
    num_steps: number of time steps
    returns: [num_steps, batch, features] — binary spikes
    """
    # Normalize input to [0, 1]
    max_vals = inputs.max(dim=0, keepdim=True).values
    inputs_norm = inputs / max_vals.clamp(min=1e-6)

    # Generate spikes with probability = input value
    spike_prob = inputs_norm.unsqueeze(0).expand(num_steps, -1, -1)
    spikes = torch.rand_like(spike_prob) < spike_prob
    return spikes.float()


# Poisson encode to spike trains over time
train_encoded = rate_encode_poisson(X_train_tensor, dt_steps).to(device)
test_encoded = rate_encode_poisson(X_test_tensor, dt_steps).to(device)

# --- Define Spiking Model ---
class SpikingIrisClassifier(nn.Module):
    def __init__(self):
        super().__init__()
        self.input = nn.Linear(input_nodes, hidden_neurons, bias=False)   # No bias here
        self.lif1 = snn.Leaky(beta=beta, threshold=threshold)
        self.transfer1 = nn.Linear(hidden_neurons, output_neurons, bias=False)  # No bias here
        self.output = snn.Leaky(beta=beta, threshold=threshold)

    def forward(self, x_spike_seq):  # x_spike_seq: [time, batch, input]
        mem1 = self.lif1.init_leaky()
        mem2 = self.output.init_leaky()

        spike_record = []

        for t in range(dt_steps):
            x_t = x_spike_seq[t]
            cur1 = self.input(x_t)
            spk1, mem1 = self.lif1(cur1, mem1)

            cur2 = self.transfer1(spk1)
            spk2, mem2 = self.output(cur2, mem2)

            spike_record.append(spk2)

        # Accumulate spikes across time
        spike_sum = torch.stack(spike_record, dim=0).sum(dim=0)  # [batch, output_neurons]
        return spike_sum


# --- Training Function ---
def train_classifier(classifier, loss_function, optimizer, inputs, targets):
    print("Training started...\n")
    loss_history = []

    targets = torch.LongTensor(targets).to(device)

    for epoch in range(epochs):
        classifier.train()
        optimizer.zero_grad()

        outputs = classifier(inputs)
        loss = loss_function(outputs, targets)

        loss.backward()
        optimizer.step()

        loss_value = loss.item()
        loss_history.append(loss_value)

        print(f"Epoch {epoch + 1}/{epochs} - Loss: {loss_value:.4f}")

        if CUT_TRAINING_SHORT and loss_value < TRAINING_CUTOFF:
            break

    return loss_history


def test_classifier(classifier, inputs, targets):
    print("\nTesting started...\n")
    classifier.eval()

    with torch.no_grad():
        outputs = classifier(inputs)
        _, predicted = torch.max(outputs, 1)
        actual = torch.LongTensor(targets).to(device)

        correct = (predicted == actual).sum().item()
        total = actual.size(0)

    return correct, total

# --- Run Everything ---
classifier = SpikingIrisClassifier().to(device)
loss_function = nn.CrossEntropyLoss()
optimizer = torch.optim.Adam(classifier.parameters(), lr=5e-4)

train_loss = train_classifier(classifier, loss_function, optimizer, train_encoded, y_train)
correct, total = test_classifier(classifier, test_encoded, y_test)

# --- Plot Loss Curve ---
# plt.figure(figsize=(10, 5))
# plt.plot(train_loss)
# plt.title("Training Loss")
# plt.xlabel("Epoch")
# plt.ylabel("CrossEntropy Loss")
# plt.grid(True)
# plt.show()

# --- Report Accuracy ---
print("------")
print(f"Test Accuracy: {100 * correct / total:.2f}% ({correct}/{total})")
print("------")


# mapping model
neuron_layers = {
    "Input" : {
        "decay_mode": beta,
        "threshold": threshold,
        "neurons": input_nodes,
        "reset_mode": reset_mode
    },
    "Layer1": {
        "decay_mode": beta,
        "threshold": threshold,
        "neurons": hidden_neurons,
        "reset_mode": reset_mode
    },
    "Layer2": {
        "decay_mode": beta,
        "threshold": threshold,
        "neurons": output_neurons,
        "reset_mode": reset_mode
    }
}

neuron_weights = {
    "Input-Layer1": {
        "weights": classifier.input.weight.detach().cpu().numpy().tolist()
    },
    "Layer1-Layer2": {
        "weights": classifier.transfer1.weight.detach().cpu().numpy().tolist()
    }
}

print(neuron_weights)

neuron_mapper = Neuron_Mapper(neuron_layers, neuron_weights)
neuron_mapper.map()
neuron_mapper.log_mapping()

# write to file
output_file = "iris_neuron_mapping.txt"
with open(output_file, 'w') as f:
    f.write(neuron_mapper.generate_init())

print(X_test.shape)
print(test_encoded.shape)
with open("test_values.txt", 'w') as f:
    for sample in range(test_encoded.shape[1]):  # input samples
        for t in range(test_encoded.shape[0]):  # time steps
            for feature in range(test_encoded.shape[2]):  # 4 features
                value = test_encoded[t][sample][feature]
                if value > 0:
                    cluster_id = 32  # 6 bits
                    neuron_id = feature  # 5 bits
                    packet = (cluster_id << 5) | neuron_id  # 6-bit cluster + 5-bit neuron
                    f.write(f"{packet:03X}\n")
                else:
                    f.write("FFF\n")
print("outputs")
print(y_test)