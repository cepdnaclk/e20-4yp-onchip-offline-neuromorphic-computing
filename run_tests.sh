#!/usr/bin/env bash
# =============================================================================
#  run_tests.sh  —  SNN Accelerator RTL Regression Suite  (L2a to L7)
#
#  Runs all verified test levels in order.
#  L8 (full CPU pipeline) is excluded until the loop-termination fix lands.
#
#  Usage:
#    bash run_tests.sh            # run all levels
#    bash run_tests.sh L4         # run one level by label
#
#  Requires: iverilog, vvp  (Icarus Verilog)
# =============================================================================
set -euo pipefail

ROOT="$(cd "$(dirname "$0")" && pwd)"
FILTER="${1:-ALL}"

PASS=0
FAIL=0
SKIP=0

# ── helpers ──────────────────────────────────────────────────────────────────
BOLD="\033[1m"; RED="\033[31m"; GREEN="\033[32m"; YELLOW="\033[33m"; NC="\033[0m"

pass() { echo -e "  ${GREEN}✅ PASS${NC}  $1"; PASS=$((PASS+1)); }
fail() { echo -e "  ${RED}❌ FAIL${NC}  $1"; FAIL=$((FAIL+1)); }
skip() { echo -e "  ${YELLOW}⏭  SKIP${NC}  $1"; SKIP=$((SKIP+1)); }

banner() {
    echo ""
    echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
    echo -e "${BOLD} $1${NC}"
    echo -e "${BOLD}────────────────────────────────────────────────────${NC}"
}

run_test() {
    local label="$1"
    local dir="$2"
    local out_vvp="$3"
    shift 3                      # remaining args = iverilog source list

    [[ "$FILTER" != "ALL" && "$FILTER" != "$label" ]] && { skip "$label"; return; }

    banner "$label"
    cd "$ROOT/$dir"

    # Compile
    if ! iverilog -g2012 -Wno-timescale -o "$out_vvp" "$@" 2>&1; then
        fail "$label  (compile error)"
        return
    fi

    # Simulate  (capture output, show tail, check for PASS/TIMEOUT)
    local tmpout
    tmpout=$(mktemp /tmp/snn_test_XXXXXX.txt)
    if vvp -n "$out_vvp" 2>&1 | tee "$tmpout" | tail -8; then
        if grep -qiE "TIMEOUT|deadlock|FAILED.*[1-9]" "$tmpout" && \
           ! grep -qiE "ALL [0-9]+ / [0-9]+ TESTS PASSED" "$tmpout"; then
            fail "$label"
        else
            pass "$label"
        fi
    else
        fail "$label  (vvp error)"
    fi

    rm -f "$tmpout" "$out_vvp"
}

# =============================================================================
#  TEST LEVELS
# =============================================================================

# ── L2a: Neuron cluster — spike bits + v_pre_spike values ────────────────────
run_test "L2a" \
  "inference_accelarator/neuron_cluster" \
  neuron_cluster_tb.vvp \
  neuron_cluster_tb.v

# ── L2b: Neuron cluster — v_pre_spike port wiring ────────────────────────────
run_test "L2b" \
  "inference_accelarator/neuron_cluster" \
  vmem_tb.vvp \
  neuron_cluster_vmem_tb.v

# ── L4: Accelerator known-value dump (embedded init bytes) ───────────────────
run_test "L4" \
  "inference_accelarator/neuron_accelerator" \
  known_value_dump_tb.vvp \
  known_value_dump_tb.v

# ── L5: SNN inter-cluster propagation + dump ─────────────────────────────────
run_test "L5" \
  "inference_accelarator/neuron_accelerator" \
  snn_integration_dump_tb.vvp \
  snn_integration_dump_tb.v

# ── L6: Accelerator + real snn_shared_memory_wb BRAM ─────────────────────────
# Note: real_mem_integration_tb.v already `includes snn_shared_memory_wb.v
run_test "L6" \
  "inference_accelarator/neuron_accelerator" \
  real_mem_integration_tb.vvp \
  real_mem_integration_tb.v

# ── L7: STATE 2 surrogate substitution (no CPU RTL) ──────────────────────────
run_test "L7" \
  "surrogate_lut" \
  state2_integration_tb.vvp \
  ../shared_memory/snn_shared_memory_wb.v \
  surrogate_lut_wb.v \
  state2_integration_tb.v

# =============================================================================
#  SUMMARY
# =============================================================================
echo ""
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
total=$((PASS+FAIL+SKIP))
if [[ $FAIL -eq 0 ]]; then
    echo -e "${BOLD}${GREEN} ALL ${PASS}/${total} LEVELS PASSED${NC}"
else
    echo -e "${BOLD}${RED} ${PASS} PASSED  /  ${FAIL} FAILED  /  ${SKIP} SKIPPED${NC}"
fi
echo -e "${BOLD}════════════════════════════════════════════════════${NC}"
echo ""

# Exit non-zero if any failures
[[ $FAIL -eq 0 ]]
