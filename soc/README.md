# LiteX SoC Environment

This folder contains the LiteX SoC builder ecosystem. The installed LiteX packages are **not tracked by git** — follow the instructions below to set them up.

## Setup Instructions

### 1. Install LiteX

```bash
cd soc/
wget https://raw.githubusercontent.com/enjoy-digital/litex/master/litex_setup.py
python3 litex_setup.py --init --install --user
```

> **Note:** The `--user` flag installs Python packages to your user directory. Remove it if using a virtual environment.

### 2. Install RISC-V Toolchain (if not already installed)

```bash
python3 litex_setup.py --gcc=riscv
```

### 3. Verify Installation

```bash
python3 -c "import litex; print('LiteX installed successfully')"
```

## Folder Structure

```
soc/
├── README.md          # This file (tracked by git)
├── litex_setup.py     # LiteX installer (gitignored)
├── litex/             # LiteX core (gitignored)
├── litex-boards/      # Board definitions (gitignored)
├── litedram/          # DRAM controller (gitignored)
├── liteeth/           # Ethernet core (gitignored)
└── ...                # Other LiteX packages (gitignored)
```

## Custom SoC Configurations

Your custom SoC build scripts and platform files should be placed in `../soc-config/` (tracked by git).
