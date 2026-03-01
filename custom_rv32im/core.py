# Custom RV32IM CPU — LiteX CPU Wrapper
#
# Integrates the custom 5-stage pipelined RV32IM CPU (CPU_wb.v) with LiteX.
# Based on the SERV CPU wrapper pattern (separate ibus/dbus Wishbone masters).

import os

from migen import *

from litex.gen import *

from litex.soc.interconnect import wishbone
from litex.soc.cores.cpu import CPU, CPU_GCC_TRIPLE_RISCV32

# Variants -----------------------------------------------------------------------------------------

CPU_VARIANTS = ["standard"]

# GCC Flags ----------------------------------------------------------------------------------------

GCC_FLAGS = {
    #                               /------------ Base ISA
    #                               |    /------- Hardware Multiply + Divide
    #                               |    |/----- Atomics
    #                               |    ||/---- Compressed ISA
    #                               |    |||/--- Single-Precision Floating-Point
    #                               |    ||||/-- Double-Precision Floating-Point
    #                               i    macfd
    "standard":         "-march=rv32i2p0_m    -mabi=ilp32",
}

# CustomRV32IM ------------------------------------------------------------------------------------

class CustomRV32IM(CPU):
    category             = "softcore"
    family               = "riscv"
    name                 = "custom_rv32im"
    human_name           = "Custom RV32IM"
    variants             = CPU_VARIANTS
    data_width           = 32
    endianness           = "little"
    gcc_triple           = CPU_GCC_TRIPLE_RISCV32
    linker_output_format = "elf32-littleriscv"
    nop                  = "nop"
    io_regions           = {0x8000_0000: 0x8000_0000}  # Origin, Length.

    # GCC Flags.
    @property
    def gcc_flags(self):
        flags =  GCC_FLAGS[self.variant]
        flags += " -D__custom_rv32im__ "
        return flags

    def __init__(self, platform, variant="standard"):
        self.platform     = platform
        self.variant      = variant
        self.reset        = Signal()
        self.ibus         = ibus = wishbone.Interface(data_width=32, address_width=32, addressing="byte")
        self.dbus         = dbus = wishbone.Interface(data_width=32, address_width=32, addressing="byte")
        self.periph_buses = [ibus, dbus]  # Connected to main SoC Wishbone bus.
        self.memory_buses = []            # No direct memory bus (all through periph).

        # # #

        # CPU Instance — maps Verilog ports to LiteX Wishbone signals.
        self.cpu_params = dict(
            # Clock / Reset.
            i_CLK   = ClockSignal("sys"),
            i_RESET = ResetSignal("sys") | self.reset,

            # Instruction Wishbone Master (ibus).
            o_ibus_cyc_o = ibus.cyc,
            o_ibus_stb_o = ibus.stb,
            o_ibus_adr_o = ibus.adr,
            i_ibus_dat_i = ibus.dat_r,
            i_ibus_ack_i = ibus.ack,

            # Data Wishbone Master (dbus).
            o_dbus_cyc_o = dbus.cyc,
            o_dbus_stb_o = dbus.stb,
            o_dbus_we_o  = dbus.we,
            o_dbus_adr_o = dbus.adr,
            o_dbus_dat_o = dbus.dat_w,
            o_dbus_sel_o = dbus.sel,
            i_dbus_dat_i = dbus.dat_r,
            i_dbus_ack_i = dbus.ack,
        )

        # ibus sel is always 0xf (always fetch full 32-bit words).
        self.comb += [
            ibus.sel.eq(0xf),
        ]

        # Add Verilog sources.
        self.add_sources(platform)

    def set_reset_address(self, reset_address):
        self.reset_address = reset_address
        # Note: CPU_wb.v currently resets PC to 0x00000000.
        # For LiteX, the linker script will place code at the reset address.

    @staticmethod
    def add_sources(platform):
        # Path to the RISC_V source tree.
        cpu_dir = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "RISC_V"))
        
        # Add only the specific subdirectories that contain _wb.v files
        # as include paths. Do NOT use os.walk — it pulls in duplicate
        # Memory.v files from many subdirectories.
        required_dirs = [
            "CPU",
            "ALUunit",
            "Adder",
            "BranchController",
            "ControlUnit",
            "EX_MEM_pipeline",
            "HazardHandling",
            "HazardHandling/LoadUserHazard",
            "ID_EXPipeline",
            "ID_IF_pipeLIne",
            "ImidiateGenarator",
            "MEM_WBPipline",
            "MUX_32bit",
            "ProgramCounter",
            "RegisterFile",
        ]
        for subdir in required_dirs:
            platform.add_verilog_include_path(os.path.join(cpu_dir, subdir))
        
        # Add the top-level CPU_wb.v (it `include's all submodules).
        platform.add_source(os.path.join(cpu_dir, "CPU", "CPU_wb.v"))

    def do_finalize(self):
        assert hasattr(self, "reset_address")
        self.specials += Instance("CPU_wb", **self.cpu_params)
