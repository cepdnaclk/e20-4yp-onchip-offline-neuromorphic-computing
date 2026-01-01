# On-Chip Offline Neuromorphic Computing

A hardware-accelerated neuromorphic System-on-Chip (SoC) designed for **on-chip training and inference** of spiking neural networks using RISC-V control and backpropagation learning.

## 🎯 Project Vision

Unlike traditional neuromorphic accelerators that only perform inference with pre-trained weights, this project implements **hardware-level training** capabilities, enabling neural networks to learn directly on the chip without software intervention.

## 📊 Current Status

**✅ Inference Engine: FULLY FUNCTIONAL & TESTABLE**
- 2,048 LIF (Leaky Integrate-and-Fire) neurons across 64 clusters
- Spike-based communication with hierarchical routing
- Configurable network architectures
- Weight memory with 4,096 rows capacity
- Complete testing infrastructure with MNIST validation

**⏳ Training Engine: IN DEVELOPMENT**
- RISC-V controller integration (planned)
- Backpropagation learning unit (planned)
- On-chip weight updates (planned)

## 🚀 Quick Start

**Test the accelerator right now:**

```bash
# Quick functional test (5 minutes)
./quick_test_setup.sh

# XOR network test (10 minutes)
python3 tools/export_weights_for_hardware.py --test-xor
python3 tools/generate_spike_input.py --dataset xor
cd rtl/neuron_accelerator && iverilog -g2009 -o sim neuron_accelerator_tb.v
./sim
```

**See detailed instructions:**
- **[QUICK_START.md](QUICK_START.md)** - Get started in 5 minutes
- **[TESTING_GUIDE.md](TESTING_GUIDE.md)** - Complete testing documentation
- **[PROJECT_STATUS.md](PROJECT_STATUS.md)** - Full project roadmap

## 🏗️ Architecture

```
┌─────────────────────────────────────────────────────────┐
│                    RISC-V Controller                     │
│                    (Future - Phase 1)                    │
└────────────────────┬────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│              Neuron Accelerator (✅ Working)             │
│  ┌─────────────┐  ┌──────────────┐  ┌─────────────┐   │
│  │  2048       │  │   Spike      │  │   Weight    │   │
│  │  Neurons    │◄─┤   Network    │◄─┤   Memory    │   │
│  │  (64×32)    │  │   (8→4 Port) │  │   (4K rows) │   │
│  └─────────────┘  └──────────────┘  └─────────────┘   │
└─────────────────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────┐
│      Backpropagation Learning Unit (Future - Phase 2)    │
│      • Gradient calculation                              │
│      • Weight updates                                    │
│      • On-chip training                                  │
└─────────────────────────────────────────────────────────┘
```

## 📁 Repository Structure

```
├── rtl/                          # Hardware designs (Verilog)
│   ├── neuron_accelerator/       # Main accelerator (✅ Working)
│   ├── accelerator_controller/   # Control interface
│   ├── neuron_cluster/           # LIF neuron implementations
│   ├── spike_network/            # Spike routing
│   ├── weight_resolver/          # Weight memory access
│   └── ...
├── tools/                        # Testing & validation tools
│   ├── export_weights_for_hardware.py  # Weight exporter
│   └── generate_spike_input.py         # Input data generator
├── QUICK_START.md                # Quick start guide
├── TESTING_GUIDE.md              # Complete testing instructions
└── PROJECT_STATUS.md             # Full project status & roadmap
```

## ✅ Testing Capabilities

**Inference Testing (Available Now):**
- Load pre-trained weights from PyTorch/TensorFlow
- Process MNIST handwritten digit recognition
- XOR network validation
- Custom network architectures
- Performance benchmarking

**Training Testing (Future):**
- On-chip backpropagation
- Weight updates during execution
- Gradient descent algorithms
- Online/offline learning modes

## 🛠️ Tools Provided

- **`quick_test_setup.sh`** - Automated test environment setup
- **`export_weights_for_hardware.py`** - Export trained models to hardware format
- **`generate_spike_input.py`** - Generate spike-encoded test data
- **Simulation automation** - Complete MNIST testing pipeline

## 📚 Documentation

| Document | Description |
|----------|-------------|
| [QUICK_START.md](QUICK_START.md) | Get started testing in 5 minutes |
| [TESTING_GUIDE.md](TESTING_GUIDE.md) | Comprehensive testing guide |
| [PROJECT_STATUS.md](PROJECT_STATUS.md) | Full status & development roadmap |

## 🔬 Research Goals

1. **Hardware Efficiency**: Reduce training energy by 100-1000× vs GPU
2. **On-Chip Learning**: Enable edge devices to adapt without cloud connectivity
3. **Neuromorphic Computing**: Leverage spike-based computation for efficiency
4. **Real-time Training**: Update models during operation

## 🎓 Academic Context

**Final Year Project (FYP)**
- Focus: Neuromorphic hardware with on-chip training
- Novel Contribution: Hardware backpropagation for spiking neural networks
- Target Platform: FPGA prototype / ASIC tapeout

## 📈 Development Phases

- [x] **Phase 0**: Neuron accelerator design & validation ← **Current**
- [ ] **Phase 1**: RISC-V controller integration (4-6 weeks)
- [ ] **Phase 2**: Backpropagation learning unit (6-8 weeks)
- [ ] **Phase 3**: Full SoC integration (4-6 weeks)
- [ ] **Phase 4**: Optimization & deployment (8-12 weeks)

## 🤝 Contributing

This is an academic research project. For collaboration inquiries, please refer to the project documentation.

## 📄 License

Academic research project - License TBD

---

**⚡ Start Testing Now:** Run `./quick_test_setup.sh` to validate your accelerator!
