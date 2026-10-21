#!/usr/bin/env bash
# reproduce.sh — run every sim/examples scenario and the HDL testbenches.
# Exits non-zero on first failure. Run from the repo root.
#
# Usage: ./reproduce.sh [--real-weights] [--self-check]
#   --real-weights  download (if absent) and run the real Gemma 4 26B-A4B
#                   forward pass; requires HF_TOKEN (gated model, ~52 GB).
#   --self-check    fast (no compilation) structural health check: repo
#                   layout, every path this script feeds to iverilog/yosys,
#                   required tools, and writable build dirs. Wired into
#                   `pnmt lint` and the flake `verify` so path regressions
#                   (e.g. a board JSON moved or a cwd-sensitivity bug) fail
#                   in seconds instead of mid-run.
set -euo pipefail

GO="go"
IVERILOG="iverilog"
VVP="vvp"

REAL_WEIGHTS=0
SELF_CHECK=0
for arg in "$@"; do
    case "$arg" in
        --real-weights) REAL_WEIGHTS=1 ;;
        --self-check) SELF_CHECK=1 ;;
        -h|--help)
            sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "reproduce.sh: unknown argument: $arg" >&2; exit 2 ;;
    esac
done

cd "$(dirname "$0")"
ROOT="$PWD"
SIM="$PWD/sim"
HDL="$PWD/HDL"

# ---------------------------------------------------------------------------
# --self-check: structural verification against the exact paths the run uses.
# Every path added to the run below must be listed here, so a rename/move
# breaks `pnmt lint` (and the nix `verify`) immediately rather than after a
# 3-minute benchmark sweep.
# ---------------------------------------------------------------------------
if [ "$SELF_CHECK" = 1 ]; then
    errors=0
    fail_sc() { printf "  [FAIL] %s\n" "$1"; errors=$((errors + 1)); }

    # Repo layout the script anchors on.
    for d in "$ROOT" "$SIM" "$HDL" "$HDL/core" "$ROOT/implementations" \
             "$ROOT/implementations/boards" "$ROOT/implementations/build" \
             "$ROOT/paper"; do
        [ -d "$d" ] || fail_sc "missing directory: $d"
    done

    # Every path referenced by an iverilog/yosys/gcc/go invocation below.
    for f in \
        "$SIM/cmd" \
        "$SIM/examples" \
        "$HDL/hfr.v" "$HDL/flit_gate.v" "$HDL/vc_merge.v" \
        "$HDL/lxy_repeater.v" "$HDL/xy_turn.v" "$HDL/node_eject.v" \
        "$HDL/tb_fabric.v" "$HDL/tb_load.v" \
        "$HDL/pnm_host_bridge.v" "$HDL/tb_pnm_host_bridge.v" \
        "$HDL/pnm_host_top.v" "$HDL/tb_host_path_e2e.v" \
        "$HDL/core/bf16_fp.vh" "$HDL/core/fma_core.v" \
        "$HDL/core/arith_unit.v" \
        "$HDL/core/gemma_decoder_block.v" "$HDL/core/node.v" \
        "$HDL/core/moe_gating.v" "$HDL/core/gating_asic.v" \
        "$HDL/core/tb_gating_modes.v" "$HDL/core/tb_gating_server.v" \
        "$HDL/core/bf16_fma.v" "$HDL/core/fp16_fma.v" \
        "$HDL/core/fp32_fma.v" "$HDL/core/fp64_fma.v" \
        "$HDL/core/fp32_alu.v" "$HDL/core/fp64_alu.v" "$HDL/core/int8_alu.v" \
        "$HDL/core/int8_mac.v" "$HDL/core/int4_mac.v" "$HDL/core/fp4_mac.v" \
        "$HDL/core/bf16_mac_array.v" "$HDL/core/fp16_mac_array.v" "$HDL/core/fp_mac_array.v" \
        "$HDL/core/fp32_mac_array.v" "$HDL/core/int4_mac_array.v" \
        "$HDL/core/quant_mac_array.v" \
        "$HDL/core/fp4_mac_array.v" "$HDL/core/mxfp4_mac_array.v" \
        "$HDL/core/pe_tile_stub.v" "$HDL/core/doorbell.v" "$HDL/core/crc16.v" \
        "$HDL/core/tb_moe_gating.v" "$HDL/core/tb_bf16_fma.v" \
        "$HDL/core/tb_fp16_fma.v" "$HDL/core/tb_fp32_fma.v" \
        "$HDL/core/tb_fp64_fma.v" "$HDL/core/tb_fp32_alu.v" \
        "$HDL/core/tb_fp16_mac_array.v" "$HDL/core/tb_bf16_mac_array.v" \
        "$HDL/core/tb_int8_mac.v" "$HDL/core/tb_fp4_mac.v" \
        "$HDL/core/bf16_fp_ref.py" "$HDL/core/gating_reference_test.py" \
        "$HDL/core/node_reference_test.py" \
        "$HDL/core/node_mem.v" "$HDL/core/tb_node_mem.v" \
        "$HDL/core/ternary_acc.v" "$HDL/core/tb_ternary_acc.v" \
        "$HDL/core/ternary_acc_array.v" "$HDL/core/tb_ternary_acc_array.v" \
        "$HDL/core/node_mem_reference_test.py" \
        "$ROOT/implementations/boards/node_bf16.json" \
        "$ROOT/implementations/boards/node_int8.json" \
        "$ROOT/implementations/boards/node_ternary.json" \
        "$ROOT/implementations/boards/node_dual_mem.json" \
        "$ROOT/implementations/build_asm.py" \
        "$ROOT/synth.sh" "$ROOT/download_model.sh"; do
        [ -e "$f" ] || fail_sc "missing path: $f"
    done

    # Required tools for the non-real-weight run.
    for t in "$GO" "$IVERILOG" "$VVP"; do
        command -v "$t" >/dev/null 2>&1 || fail_sc "required tool not on PATH: $t"
    done

    # Writable build dirs (ownership/perm regressions bite here).
    for d in "$ROOT/implementations/build" "$ROOT/paper" "$ROOT/sim"; do
        [ -w "$d" ] || fail_sc "not writable by $USER: $d"
    done

    # Repo root must be the git tree (reproduce.sh anchors on itself; a copy
    # elsewhere would silently run the wrong sim tree). Informational only:
    # the nix `verify` sandbox ships src without .git, so this must not fail.
    if [ ! -d "$ROOT/.git" ]; then
        printf "  [note] no .git at $ROOT (nix sandbox?) — path anchor assumed\n"
    fi

    if [ "$errors" -gt 0 ]; then
        printf "reproduce.sh --self-check: %d problem(s)\n" "$errors"
        exit 1
    fi
    printf "reproduce.sh --self-check: OK (%s)\n" "$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo no-git)"
    exit 0
fi

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

echo "--- pnmc: compile-model gemma4_test_synthetic (4x4x4) ---"
run "compile-model gemma4_test_synthetic" $GO run ./cmd/pnmc compile-model examples/gemma4_test_synthetic -l 4 -x 4 -y 4

echo "--- pnmc: run-driver gemma4_test_synthetic (4x4x4) ---"
run "run-driver gemma4_test_synthetic" $GO run ./cmd/pnmc run-driver examples/gemma4_test_synthetic -l 4 -x 4 -y 4

echo "--- pnmc: compile-model mini_glm_moe (4x4x4) ---"
run "compile-model mini_glm_moe" $GO run ./cmd/pnmc compile-model examples/mini_glm_moe -l 4 -x 4 -y 4

echo "--- pnmc: run-driver mini_glm_moe (4x4x4) ---"
run "run-driver mini_glm_moe" $GO run ./cmd/pnmc run-driver examples/mini_glm_moe -l 4 -x 4 -y 4

echo ""
echo "=== source-language front end (R / Haskell / HLSL) ==="
if skip_tool "pnmsrc" $GO; then
    for ex in hello.R hello.hs hello.hlsl; do
        run "pnmsrc $ex (compile + chained fabric run)" bash -c \
            "cd $SIM && $GO run ./cmd/pnmsrc examples/$ex -run -inputs x=4,y=7 2>&1 | grep -q 'result .* = 39'"
    done
fi

echo ""
echo "=== pnm co-sim (default 3x4x4, all scenarios) ==="
run "pnm all scenarios" $GO run ./cmd/pnm

echo ""
echo "=== architecture benchmark (fabric sweep + cost/TCO model) ==="
rm -rf /tmp/pnm_benchmark_export
run "pnmhost benchmark" bash -c "cd $SIM && $GO run ./cmd/pnmhost benchmark -output /tmp/pnm_benchmark_export >/dev/null 2>&1"

echo ""
echo "=== Go tests ==="
run "go test ./internal/pnm/" bash -c "cd $SIM && $GO test ./internal/pnm/ -count=1 -timeout 600s"

echo ""
echo "=== HDL testbenches ==="

if command -v "$IVERILOG" >/dev/null 2>&1; then
    run "bf16_fp library (bf16 ops bit-exact)" python3 "$HDL/core/bf16_fp_ref.py"
    run "gating ASIC server (8x16 logits bit-exact, vvp)" python3 "$HDL/core/gating_reference_test.py"
    run "gating ASIC management modes (embedded node vs host, vvp)" bash -c "
        $IVERILOG -g2005 -o /tmp/pnm_tb_gm $HDL/core/tb_gating_modes.v $HDL/core/gating_asic.v \
            $HDL/core/moe_gating.v $HDL/core/arith_unit.v $HDL/core/bf16_fma.v $HDL/core/fma_core.v &&
        $VVP /tmp/pnm_tb_gm | tee /tmp/pnm_gating_modes.log | grep -q 'GATING MODE TEST PASSED'"
    run "node compute ASIC (8x16 BF16 bit-exact, vvp)" python3 "$HDL/core/node_reference_test.py"
    run "node compute ASIC (8x16 INT8 exact, vvp)" python3 "$HDL/core/node_reference_test.py" --cu 4
    run "node compute ASIC (8x16 ternary BitNet exact, vvp)" python3 "$HDL/core/node_reference_test.py" --cu 8
    run "node memory (multi-channel interleave bit-exact, vvp)" python3 "$HDL/core/node_mem_reference_test.py"
    run "assembly builder (node_bf16 board, vvp)" python3 "$ROOT/implementations/build_asm.py" "$ROOT/implementations/boards/node_bf16.json"
    run "assembly builder (node_int8 board, vvp)" python3 "$ROOT/implementations/build_asm.py" "$ROOT/implementations/boards/node_int8.json"
    run "assembly builder (node_ternary board, vvp)" python3 "$ROOT/implementations/build_asm.py" "$ROOT/implementations/boards/node_ternary.json"
    run "assembly builder (node_dual_mem board, vvp)" python3 "$ROOT/implementations/build_asm.py" "$ROOT/implementations/boards/node_dual_mem.json"
fi

# All unit/fabric/phy testbenches are owned by pnmt's single test registry
# (sim/cmd/pnmt/main.go). reproduce.sh delegates to it instead of re-listing
# iverilog invocations, so the two lists cannot drift (past drift caused two
# real bugs: root-relative board paths, and a stale bibliography).
if skip_tool "pnmt" $IVERILOG; then
    run "pnmt hdl (all HDL testbenches, one registry)" bash -c "cd $SIM && $GO run ./cmd/pnmt hdl"
fi

echo ""
echo "=== Synthesis smoke test ==="
if skip_tool "synth.sh" yosys; then
    run "yosys generic synthesis (9 modules)" "$ROOT/synth.sh"
fi

echo ""
echo "=== arXiv source package ==="
if command -v pdflatex >/dev/null 2>&1; then
    # The bundle must compile on its own (arXiv compiles the sources it is
    # given): copy it out of the repo, build there, and check the page count.
    rm -rf /tmp/pnm_arxiv_check
    if [ -d "$ROOT/paper/submission/arxiv" ]; then
        cp -r "$ROOT/paper/submission/arxiv" /tmp/pnm_arxiv_check
        run "arXiv bundle compiles standalone (pdflatex)" bash -c \
            "cd /tmp/pnm_arxiv_check && pdflatex -interaction=nonstopmode -halt-on-error paper.tex >/dev/null 2>&1"
        printf "  %-52s" "arXiv bundle page count"
        pages=$(cd /tmp/pnm_arxiv_check && pdflatex -interaction=nonstopmode paper.tex 2>&1 | grep -oE "Output written on paper.pdf \(([0-9]+) pages" | grep -oE "[0-9]+" | head -1)
        if [ -n "$pages" ]; then
            printf "PASS (%s pages)\n" "$pages"; pass=$((pass + 1))
        else
            printf "FAIL\n"; fail=$((fail + 1))
        fi
    else
        printf "  %-52s" "arXiv bundle present"
        printf "FAIL (run: cd paper && python3 build.py)\n"; fail=$((fail + 1))
    fi
fi

if [ "$REAL_WEIGHTS" = 1 ]; then
    echo ""
    echo "=== Real-weight inference (Gemma 4 26B-A4B, ~52 GB) ==="
    MODEL="${PNM_MODEL_DIR:-$ROOT/models/gemma-4-26B-A4B}"
    if [ ! -f "$MODEL/model.safetensors.index.json" ]; then
        echo "  model not at $MODEL — downloading ..."
        "$ROOT/download_model.sh" --out "$MODEL"
    fi
    printf "  %-52s" "real-weight chat (expects \"Berlin\")"
    set +e
    out=$(cd "$SIM" && $GO run ./cmd/pnmhost inference "$MODEL" \
        "What is the capital of Germany" -max-tokens 32 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "Berlin"; then
        printf "PASS\n"; pass=$((pass + 1))
        printf '%s\n' "$out" | grep -i "forward" | tail -1 | sed 's/^/      /'
    else
        printf "FAIL\n"; fail=$((fail + 1))
        printf '%s\n' "$out" | tail -20 | sed 's/^/      /'
    fi

    printf "  %-52s" "RTL BF16 MAC array (real router tile, vvp)"
    if python3 "$ROOT/HDL/core/real_matvec_poc.py" --model "$MODEL" >/tmp/pnm_rtl_poc.log 2>&1; then
        printf "PASS\n"; pass=$((pass + 1))
        grep -m1 "PASS" /tmp/pnm_rtl_poc.log | sed 's/^/      /'
    else
        printf "FAIL\n"; fail=$((fail + 1))
        tail -20 /tmp/pnm_rtl_poc.log | sed 's/^/      /'
    fi

    printf "  %-52s" "RTL integrated decoder block (real layer-0, vvp)"
    if python3 "$ROOT/HDL/core/real_decoder_block.py" --model "$MODEL" >/tmp/pnm_decoder_block.log 2>&1; then
        printf "PASS\n"; pass=$((pass + 1))
        grep -m1 "PASS" /tmp/pnm_decoder_block.log | sed 's/^/      /'
    else
        printf "FAIL\n"; fail=$((fail + 1))
        tail -20 /tmp/pnm_decoder_block.log | sed 's/^/      /'
    fi

    printf "  %-52s" "RTL gating ASIC (real layer-0 router, vvp)"
    if PNM_MODEL_DIR="$MODEL" python3 "$ROOT/HDL/core/gating_reference_test.py" --real >/tmp/pnm_gating_ref.log 2>&1; then
        printf "PASS\n"; pass=$((pass + 1))
        grep -m1 "PASS" /tmp/pnm_gating_ref.log | sed 's/^/      /'
    else
        printf "FAIL\n"; fail=$((fail + 1))
        tail -20 /tmp/pnm_gating_ref.log | sed 's/^/      /'
    fi

    printf "  %-52s" "node compute ASIC (real layer-0 expert, vvp)"
    if PNM_MODEL_DIR="$MODEL" python3 "$ROOT/HDL/core/node_reference_test.py" --real >/tmp/pnm_node_ref.log 2>&1; then
        printf "PASS\n"; pass=$((pass + 1))
        grep -m1 "PASS" /tmp/pnm_node_ref.log | sed 's/^/      /'
    else
        printf "FAIL\n"; fail=$((fail + 1))
        tail -20 /tmp/pnm_node_ref.log | sed 's/^/      /'
    fi

    printf "  %-52s" "node compute ASIC (real layer-0 expert, ternary, vvp)"
    if PNM_MODEL_DIR="$MODEL" python3 "$ROOT/HDL/core/node_reference_test.py" --real --cu 8 >/tmp/pnm_node_ref_tern.log 2>&1; then
        printf "PASS\n"; pass=$((pass + 1))
        grep -m1 "PASS" /tmp/pnm_node_ref_tern.log | sed 's/^/      /'
    else
        printf "FAIL\n"; fail=$((fail + 1))
        tail -20 /tmp/pnm_node_ref_tern.log | sed 's/^/      /'
    fi

    printf "  %-52s" "multi-layer composition (ASIC->fabric->node, 3 layers)"
    if PNM_MODEL_DIR="$MODEL" bash -c "cd $SIM && $GO test ./internal/pnm/ -count=1 -run TestRouterFabricNodeCompositionMultiLayer -v" >/tmp/pnm_multilayer.log 2>&1; then
        printf "PASS\n"; pass=$((pass + 1))
        grep -E "multi-layer composition" /tmp/pnm_multilayer.log | tail -1 | sed 's/^ *//; s/^/      /'
    else
        printf "FAIL\n"; fail=$((fail + 1))
        tail -20 /tmp/pnm_multilayer.log | sed 's/^/      /'
    fi

    printf "  %-52s" "pnmgate hardware-gated inference (expects \"Berlin\")"
    set +e
    out=$(cd "$SIM" && $GO run ./cmd/pnmgate -model "$MODEL" -layers 0 -width 256 \
        -max-tokens 12 "What is the capital of Germany" 2>&1)
    rc=$?
    set -e
    if [ "$rc" -eq 0 ] && printf '%s' "$out" | grep -q "Berlin"; then
        printf "PASS\n"; pass=$((pass + 1))
        printf '%s\n' "$out" | grep -i "answer" | tail -1 | sed 's/^/      /'
    else
        printf "FAIL\n"; fail=$((fail + 1))
        printf '%s\n' "$out" | tail -20 | sed 's/^/      /'
    fi
fi

echo ""
echo "================================"
printf "PASS: %d  FAIL: %d  SKIP: %d\n" "$pass" "$fail" "$skip"
[ "$fail" -eq 0 ]
