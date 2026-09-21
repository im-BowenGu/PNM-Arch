#!/usr/bin/env bash
# reproduce.sh — run every sim/examples scenario and the HDL testbenches.
# Exits non-zero on first failure. Run from the repo root.
set -euo pipefail

GO="go"
IVERILOG="iverilog"
VVP="vvp"

cd "$(dirname "$0")"
SIM="$PWD/sim"
HDL="$PWD/HDL"

pass=0; fail=0; skip=0

run() {
    local label="$1"; shift
    printf "  %-52s" "$label"
    if "$@" >/dev/null 2>&1; then
        printf "PASS\n"; pass=$((pass + 1))
    else
        printf "FAIL\n"; fail=$((fail + 1))
    fi
}

skip_tool() {
    local label="$1" tool="$2"
    if command -v "$tool" >/dev/null 2>&1; then
        return 0
    fi
    printf "  %-52sSKIP (%s not found)\n" "$label" "$tool"
    skip=$((skip + 1))
    return 1
}

echo "=== sim/examples ==="

cd "$SIM"

echo "--- pnmc: bias_add.pnm (8x8x8) ---"
run "pnmc bias_add.pnm 8x8x8" $GO run ./cmd/pnmc examples/bias_add.pnm -l 8 -x 8 -y 8

echo "--- pnmc: compile-model gemma4_test (4x4x4) ---"
run "compile-model gemma4_test" $GO run ./cmd/pnmc compile-model examples/gemma4_test -l 4 -x 4 -y 4

echo "--- pnmc: run-driver gemma4_test (4x4x4) ---"
run "run-driver gemma4_test" $GO run ./cmd/pnmc run-driver examples/gemma4_test -l 4 -x 4 -y 4

echo "--- pnmc: compile-model mini_glm_moe (4x4x4) ---"
run "compile-model mini_glm_moe" $GO run ./cmd/pnmc compile-model examples/mini_glm_moe -l 4 -x 4 -y 4

echo "--- pnmc: run-driver mini_glm_moe (4x4x4) ---"
run "run-driver mini_glm_moe" $GO run ./cmd/pnmc run-driver examples/mini_glm_moe -l 4 -x 4 -y 4

echo ""
echo "=== pnm co-sim (default 3x4x4, all scenarios) ==="
run "pnm all scenarios" $GO run ./cmd/pnm

echo ""
echo "=== Go tests ==="
run "go test ./internal/pnm/" bash -c "cd $SIM && $GO test ./internal/pnm/ -count=1 -timeout 180s"

echo ""
echo "=== HDL testbenches ==="

if skip_tool "tb_fabric" $IVERILOG; then
    run "tb_fabric" bash -c "cd $HDL && $IVERILOG -g2005 -o /tmp/tb_fabric.out hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_fabric.v && $VVP /tmp/tb_fabric.out"
fi

if skip_tool "tb_load" $IVERILOG; then
    run "tb_load" bash -c "cd $HDL && $IVERILOG -g2005 -o /tmp/tb_load.out hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_load.v && $VVP /tmp/tb_load.out"
fi

if skip_tool "tb_doorbell" $IVERILOG; then
    run "tb_doorbell" bash -c "cd $HDL && $IVERILOG -g2005 -o /tmp/tb_doorbell.out core/tb_doorbell.v core/pe_tile_stub.v core/doorbell.v core/crc16.v core/bf16_fma.v core/weight_dequant.v core/int8_mac.v core/fp4_mac.v && $VVP /tmp/tb_doorbell.out"
fi

if skip_tool "tb_fp32_alu" $IVERILOG; then
    run "tb_fp32_alu" bash -c "cd $HDL && $IVERILOG -g2005 -o /tmp/tb_fp32_alu.out core/fp32_alu.v core/fp32_fma.v core/tb_fp32_alu.v && $VVP /tmp/tb_fp32_alu.out"
fi

if skip_tool "tb_fp32_fma" $IVERILOG; then
    run "tb_fp32_fma" bash -c "cd $HDL && $IVERILOG -g2005 -o /tmp/tb_fp32_fma.out core/fp32_fma.v core/tb_fp32_fma.v && $VVP /tmp/tb_fp32_fma.out"
fi

if skip_tool "tb_fp64_fma" $IVERILOG; then
    run "tb_fp64_fma" bash -c "cd $HDL && $IVERILOG -g2005 -o /tmp/tb_fp64_fma.out core/fp64_fma.v core/tb_fp64_fma.v && $VVP /tmp/tb_fp64_fma.out"
fi

if skip_tool "tb_bf16_fma" $IVERILOG; then
    run "tb_bf16_fma" bash -c "cd $HDL && $IVERILOG -g2005 -o /tmp/tb_bf16_fma.out core/bf16_fma.v core/tb_bf16_fma.v && $VVP /tmp/tb_bf16_fma.out"
fi

if skip_tool "tb_fp16_fma" $IVERILOG; then
    run "tb_fp16_fma" bash -c "cd $HDL && $IVERILOG -g2005 -o /tmp/tb_fp16_fma.out core/fp16_fma.v core/tb_fp16_fma.v && $VVP /tmp/tb_fp16_fma.out"
fi

if skip_tool "tb_int8_mac" $IVERILOG; then
    run "tb_int8_mac" bash -c "cd $HDL && $IVERILOG -g2005 -o /tmp/tb_int8_mac.out core/int8_mac.v core/tb_int8_mac.v && $VVP /tmp/tb_int8_mac.out"
fi

if skip_tool "tb_moe_gating" $IVERILOG; then
    run "tb_moe_gating" bash -c "cd $HDL && $IVERILOG -g2005 -o /tmp/tb_moe_gating.out core/moe_gating.v core/bf16_fma.v core/tb_moe_gating.v && $VVP /tmp/tb_moe_gating.out"
fi

if skip_tool "tb_orchestrator_chip" $IVERILOG; then
    run "tb_orchestrator_chip" bash -c "cd $HDL && $IVERILOG -g2005 -o /tmp/tb_orchestrator_chip.out orchestrator_chip.v core/moe_gating.v core/bf16_fma.v tb_orchestrator_chip.v && $VVP /tmp/tb_orchestrator_chip.out"
fi

if skip_tool "tb_bf16_mac_array" $IVERILOG; then
    run "tb_bf16_mac_array" bash -c "cd $HDL && $IVERILOG -g2005 -o /tmp/tb_bf16_mac_array.out core/bf16_mac_array.v core/bf16_fma.v core/tb_bf16_mac_array.v && $VVP /tmp/tb_bf16_mac_array.out"
fi

if skip_tool "tb_fp16_mac_array" $IVERILOG; then
    run "tb_fp16_mac_array" bash -c "cd $HDL && $IVERILOG -g2005 -o /tmp/tb_fp16_mac_array.out core/fp16_mac_array.v core/fp16_fma.v core/tb_fp16_mac_array.v && $VVP /tmp/tb_fp16_mac_array.out"
fi

echo ""
echo "================================"
printf "PASS: %d  FAIL: %d  SKIP: %d\n" "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
