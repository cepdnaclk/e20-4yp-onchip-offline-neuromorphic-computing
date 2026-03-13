#!/usr/bin/env python3
"""
Benchmark Visualization: Custom Accelerator Unit vs Default RV32I Instructions
================================================================================
Saves two separate images:
  1. benchmark_chart1_cycles.png  — Total cycle count comparison
  2. benchmark_chart2_breakdown.png — Execution phase breakdown (stacked bars)

Measured results (from CPU_tb_benchmark.v Verilog simulation):
  - Custom accelerator unit    : 89 cycles
  - Default RV32I instructions : 595 cycles
  - Speedup                    : 6.69×

Run:
    python tools/benchmark_chart.py
Requires: matplotlib  (pip install matplotlib)
"""

import os
import matplotlib.pyplot as plt
import matplotlib.patches as mpatches
import matplotlib.ticker as ticker

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))

# ── Simulation-measured results ──────────────────────────────────────────────
CUSTOM_CYCLES = 89
RISCV_CYCLES  = 595
SPEEDUP = RISCV_CYCLES / CUSTOM_CYCLES

# ── Execution breakdown ───────────────────────────────────────────────────────
# Custom unit — teal/cyan family to distinguish from RV32I
custom_breakdown = [
    # (label,              cycles, colour)
    ("CPU Init",            12, "#2E7D32"),   # dark green
    ("HW DMA Load",         62, "#00838F"),   # teal
    ("HW Backprop Compute", 13, "#0077B4"),   # cyan-teal
    ("Writeback",            2, "#FF6F00"),   # amber
]

# RV32I — warm red/orange/blue/purple family
riscv_breakdown = [
    # (label,              cycles, colour)
    ("CPU Init (RV32I)",    15,  "#388E3C"),   # medium green
    ("Gradient Loads",      48,  "#E65100"),   # deep orange
    ("Loop Control",        80,  "#C62828"),   # dark red
    ("Delta Compute",      224,  "#1565C0"),   # dark blue
    ("Weight Update",      228,  "#6A1B9A"),   # purple
]

BAR_LABELS = ["Custom Unit", "Default RV32I\nInstructions"]

SUBTITLE = "Verilog simulation  —  16 time step backpropagation weight update"

# ── shared style helpers ──────────────────────────────────────────────────────
BG      = "white"
AX_BG   = "#F5F7FA"
GRID_C  = "#D0D7DE"
TEXT_C  = "#1F2328"
ACCENT  = "#0969DA"
GREEN   = "#1A7F37"
RED     = "#CF222E"


def style_ax(ax):
    ax.set_facecolor(AX_BG)
    ax.tick_params(colors=TEXT_C, labelsize=11)
    for spine in ax.spines.values():
        spine.set_edgecolor(GRID_C)
    ax.yaxis.label.set_color(TEXT_C)
    ax.xaxis.label.set_color(TEXT_C)
    ax.title.set_color(TEXT_C)


# ═══════════════════════════════════════════════════════════════════════════════
#  IMAGE 1 — Total cycle count
# ═══════════════════════════════════════════════════════════════════════════════
fig1, ax1 = plt.subplots(figsize=(8, 6))
fig1.patch.set_facecolor(BG)
style_ax(ax1)

fig1.suptitle(
    "Neuromorphic Accelerator: Custom Unit vs Default RV32I Instructions",
    fontsize=13, fontweight="bold", color=TEXT_C, y=0.98,
)
ax1.set_title(SUBTITLE, fontsize=10, color="#57606A", pad=8)

bars = ax1.bar(
    BAR_LABELS,
    [CUSTOM_CYCLES, RISCV_CYCLES],
    color=[GREEN, RED],
    width=0.40,
    edgecolor="white",
    linewidth=1.2,
    zorder=3,
)

# Value labels above each bar
for bar, val in zip(bars, [CUSTOM_CYCLES, RISCV_CYCLES]):
    ax1.text(
        bar.get_x() + bar.get_width() / 2,
        bar.get_height() + 12,
        f"{val} cycles",
        ha="center", va="bottom",
        fontsize=12, fontweight="bold", color=TEXT_C,
    )

# Speedup annotation — placed between the two bars, well above both
mid_x   = 0.5                                    # between bar 0 (x=0) and bar 1 (x=1)
arrow_y_bottom = CUSTOM_CYCLES + 30
arrow_y_top    = RISCV_CYCLES  - 20
ax1.annotate(
    "",
    xy=(mid_x, arrow_y_bottom),
    xytext=(mid_x, arrow_y_top),
    arrowprops=dict(arrowstyle="<->", color=ACCENT, lw=2.0),
)
ax1.text(
    mid_x + 0.06,
    (arrow_y_bottom + arrow_y_top) / 2,
    f"{SPEEDUP:.2f}× faster",
    ha="left", va="center",
    fontsize=12, fontweight="bold", color=ACCENT,
)

ax1.set_ylabel("Clock Cycles", fontsize=12)
ax1.set_ylim(0, RISCV_CYCLES * 1.22)
ax1.yaxis.set_major_locator(ticker.MultipleLocator(100))
ax1.grid(axis="y", color=GRID_C, linestyle="--", alpha=0.7, zorder=0)
ax1.set_axisbelow(True)
ax1.tick_params(axis="x", labelsize=12)

fig1.tight_layout(rect=[0, 0, 1, 0.95])
out1 = os.path.join(SCRIPT_DIR, "benchmark_chart1_cycles.png")
fig1.savefig(out1, dpi=150, bbox_inches="tight", facecolor=BG)
print(f"Saved: {out1}")


# ═══════════════════════════════════════════════════════════════════════════════
#  IMAGE 2 — Execution phase breakdown
# ═══════════════════════════════════════════════════════════════════════════════
fig2, ax2 = plt.subplots(figsize=(9, 7))
fig2.patch.set_facecolor(BG)
style_ax(ax2)

fig2.suptitle(
    "Neuromorphic Accelerator: Execution Phase Breakdown",
    fontsize=13, fontweight="bold", color=TEXT_C, y=0.98,
)
ax2.set_title(SUBTITLE, fontsize=10, color="#57606A", pad=8)

x_positions = [0, 1]
all_phases  = [custom_breakdown, riscv_breakdown]
bottoms     = [0, 0]
phase_names_seen = set()
legend_patches   = []

for phase_idx in range(max(len(custom_breakdown), len(riscv_breakdown))):
    for bar_idx, phases in enumerate(all_phases):
        if phase_idx >= len(phases):
            continue
        label, val, color = phases[phase_idx]
        ax2.bar(
            x_positions[bar_idx], val,
            bottom=bottoms[bar_idx],
            color=color, width=0.40,
            edgecolor="white", linewidth=0.8,
            zorder=3,
        )
        # Only label segments tall enough to fit the text cleanly
        if val >= 30:
            ax2.text(
                x_positions[bar_idx],
                bottoms[bar_idx] + val / 2,
                f"{val} cyc",
                ha="center", va="center",
                fontsize=6, fontweight="bold",
                color="white", zorder=4,
            )
        elif val >= 12:
            ax2.text(
                x_positions[bar_idx],
                bottoms[bar_idx] + val / 2,
                f"{val} cyc",
                ha="center", va="center",
                fontsize= 5 , fontweight="bold",
                color="white", zorder=4,
            )
        bottoms[bar_idx] += val

# Total label above each stacked bar
for bar_idx, total in enumerate([sum(v for _, v, _ in custom_breakdown),
                                  sum(v for _, v, _ in riscv_breakdown)]):
    ax2.text(
        x_positions[bar_idx],
        total + 8,
        f"Total: {total}",
        ha="center", va="bottom",
        fontsize=11, fontweight="bold", color=TEXT_C,
    )

# Legend — collect unique phase names
for phases in [riscv_breakdown, custom_breakdown]:
    for label, val, color in phases:
        if label not in phase_names_seen:
            legend_patches.append(mpatches.Patch(facecolor=color, label=label))
            phase_names_seen.add(label)

ax2.legend(
    handles=legend_patches,
    loc="upper left",
    fontsize=9,
    facecolor="white",
    edgecolor=GRID_C,
    labelcolor=TEXT_C,
    framealpha=0.95,
)

ax2.set_xticks(x_positions)
ax2.set_xticklabels(BAR_LABELS, fontsize=12)
ax2.set_ylabel("Clock Cycles", fontsize=12)
ax2.set_ylim(0, RISCV_CYCLES * 1.18)
ax2.yaxis.set_major_locator(ticker.MultipleLocator(100))
ax2.grid(axis="y", color=GRID_C, linestyle="--", alpha=0.7, zorder=0)
ax2.set_axisbelow(True)

fig2.tight_layout(rect=[0, 0, 1, 0.95])
out2 = os.path.join(SCRIPT_DIR, "benchmark_chart2_breakdown.png")
fig2.savefig(out2, dpi=150, bbox_inches="tight", facecolor=BG)
print(f"Saved: {out2}")

plt.show()
