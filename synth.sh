#!/usr/bin/env bash
# synth.sh — Yosys generic-synthesis smoke test.
#
# Maps the routing fabric, the doorbell, and a BF16 FMA unit to
# technology-independent cells and reports cell counts plus the longest
# topological (logic-depth) path. This is NOT place-and-route and carries
# no timing closure; it only demonstrates that the RTL elaborates and
# synthesizes. Requires yosys on PATH (provided by `nix develop`).
#
# Run from the repo root; exits non-zero on any yosys error.
set -euo pipefail
cd "$(dirname "$0")"
HDL=HDL
FAIL=0

run_synth() {
    local top="$1"; shift
    printf "  %-46s" "$top"
    local log
    log=$(mktemp)
    if yosys -p "read_verilog -I $HDL $*; hierarchy -check -top $top; synth -top $top; stat; ltp -noff" >"$log" 2>&1; then
        local cells depth
        cells=$(grep -oE 'Number of cells:[[:space:]]+[0-9]+' "$log" | tail -1 | grep -oE '[0-9]+$' || true)
        depth=$(grep -oiE 'longest topological path[^0-9]*[0-9]+' "$log" | tail -1 | grep -oE '[0-9]+$' || true)
        printf "cells=%-7s depth=%s\n" "${cells:-?}" "${depth:-?}"
    else
        printf "FAIL\n"
        tail -20 "$log"
        FAIL=1
    fi
    rm -f "$log"
}

echo "=== Yosys generic synthesis smoke test ==="
run_synth hfr            "$HDL/hfr.v"
run_synth flit_gate      "$HDL/flit_gate.v"
run_synth vc_merge       "$HDL/vc_merge.v"
run_synth lxy_repeater   "$HDL/lxy_repeater.v $HDL/flit_gate.v $HDL/vc_merge.v"
run_synth xy_turn        "$HDL/xy_turn.v $HDL/flit_gate.v"
run_synth node_eject     "$HDL/node_eject.v $HDL/flit_gate.v"
run_synth doorbell       "$HDL/core/doorbell.v $HDL/core/crc16.v"
run_synth bf16_fma       "$HDL/core/arith_unit.v $HDL/core/bf16_fma.v $HDL/core/fma_core.v"
run_synth rv32_core      "$HDL/rv32_core.v"

exit $FAIL
