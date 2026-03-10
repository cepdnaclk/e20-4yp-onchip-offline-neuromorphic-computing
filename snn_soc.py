#!/usr/bin/env python3
# =============================================================================
# snn_soc.py — Minimal LiteX SoC with Custom RV32IM CPU
# =============================================================================
# Usage:
#   python3 snn_soc.py --build    # Build the SoC (generate Verilog)
#   python3 snn_soc.py --sim      # Simulate with Verilator
# =============================================================================

import os
import sys
import argparse

# Add LiteX to path.
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "soc", "litex"))
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "soc", "migen"))

from migen import *

from litex.gen import *

from litex.build.generic_platform import GenericPlatform, Pins, IOStandard, Subsignal
from litex.build.sim import SimPlatform
from litex.build.sim.config import SimConfig

from litex.soc.integration.soc_core import SoCCore
from litex.soc.integration.builder import Builder

# Import our custom CPU.
sys.path.insert(0, os.path.dirname(__file__))
from custom_rv32im.core import CustomRV32IM

# IOs (minimal — just UART for simulation) --------------------------------------------------------

_io = [
    ("sys_clk", 0, Pins(1)),
    ("sys_rst", 0, Pins(1)),
    ("serial", 0,
        Subsignal("source_valid", Pins(1)),
        Subsignal("source_ready", Pins(1)),
        Subsignal("source_data",  Pins(8)),
        Subsignal("sink_valid",   Pins(1)),
        Subsignal("sink_ready",   Pins(1)),
        Subsignal("sink_data",    Pins(8)),
    ),
]

# SNN SoC -----------------------------------------------------------------------------------------

class _CRG(LiteXModule):
    def __init__(self, platform):
        self.cd_sys = ClockDomain()
        self.comb += self.cd_sys.clk.eq(platform.request("sys_clk"))
        self.comb += self.cd_sys.rst.eq(platform.request("sys_rst"))

class SNNSoC(SoCCore):
    def __init__(self, platform, **kwargs):
        # Override defaults for our minimal SoC.
        kwargs["cpu_type"]             = "vexriscv"
        kwargs["integrated_rom_size"]  = 32*1024  # 32KB ROM at 0x00000000 (BIOS needs ~24KB).
        kwargs["integrated_sram_size"] = 32*1024  # 32KB SRAM.
        kwargs["uart_name"]            = "sim"    # Use stream-based pads for serial2console simulation
        
        # Load our bare-metal firmware into ROM.
        # firmware_path = os.path.join(os.path.dirname(__file__), "firmware", "hello.bin")
        # if os.path.exists(firmware_path):
        #     kwargs["integrated_rom_init"] = firmware_path
        
        self.submodules.crg = _CRG(platform)
        
        # Initialize SoCCore (1MHz for faster simulation time).
        SoCCore.__init__(self, platform, clk_freq=int(1e6), **kwargs)
        
        # CPU resets to 0x00000000, which is where ROM lives.

# Build --------------------------------------------------------------------------------------------

def main():
    parser = argparse.ArgumentParser(description="SNN SoC with Custom RV32IM CPU")
    parser.add_argument("--build", action="store_true", help="Build the SoC")
    parser.add_argument("--sim",   action="store_true", help="Simulate with Verilator")
    args = parser.parse_args()

    if args.sim:
        # Use simulation platform.
        platform = SimPlatform("sim", _io)
        soc = SNNSoC(platform)
        
        builder = Builder(soc, output_dir="build/sim",
            csr_csv="build/sim/csr.csv",
            compile_software=True)  # Compile the BIOS
        
        sim_config = SimConfig(default_clk="sys_clk")
        sim_config.add_module("serial2console", "serial")
        
        builder.build(sim_config=sim_config, trace=False)
    elif args.build:
        # Use generic platform for synthesis.
        platform = GenericPlatform("custom", _io)
        soc = SNNSoC(platform)
        
        builder = Builder(soc, output_dir="build/soc",
            csr_csv="build/soc/csr.csv")
        builder.build()
    else:
        parser.print_help()

if __name__ == "__main__":
    main()
