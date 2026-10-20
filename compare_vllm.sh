#!/usr/bin/env bash
# compare_vllm.sh — our engine (bf16, layer-0 router gated on the RTL Gating
# ASIC under vvp) vs the official vLLM serving stack (FP8 IT checkpoint).
#
# Both sides get the SAME user prompt, the SAME chat template (the -it
# chat_template.jinja rendered with enable_thinking=true), and the SAME
# sampling params, so the only variables are:
#   * weights:  bf16 (ours) vs FP8+dynamic-act quantised (vLLM)
#   * logits:   our f32 software forward with layer 0 routed by real RTL
#               vs vLLM's internal MoE router
#
# Usage: ./compare_vllm.sh [-temp 0.7] [-top-k 64] [-top-p 0.90] [-n 48] "prompt"
#        (omit the prompt to use the default)

set -euo pipefail
cd "$(dirname "$0")"
ROOT="$PWD"
SIM="$PWD/sim"

TEMP=0.7 TOP_K=64 TOP_P=0.90 N=48 PROMPT="What is dataflow architecture, functional programming and proccessing near memory"
MODEL="${PNM_MODEL_DIR:-/data/ai/models/gemma-4-26b-a4b-it-bf16-fused}"
IT_FP8="${PNM_IT_FP8:-/data/ai/models/gemma-4-26b-a4b-it-fp8}"

while [ $# -gt 0 ]; do
    case "$1" in
        -temp)    TEMP="$2"; shift 2 ;;
        -top-k)   TOP_K="$2"; shift 2 ;;
        -top-p)   TOP_P="$2"; shift 2 ;;
        -n)       N="$2"; shift 2 ;;
        -model)   MODEL="$2"; shift 2 ;;
        -h|--help) sed -n '2,16p' "$0"; exit 0 ;;
        *)        PROMPT="$1"; shift ;;
    esac
done

# --- python/vLLM environment (nix host: no /sbin/ldconfig, no nvcc, driver
#     libs live outside the store path). These are host-specific.
PY=/nix/store/60m4rxhg2fldqaak400c0lry96ijrzqn-python3-3.13.13/bin/python3.13
PYTHONPATH=/data/ai/.venv/lib/python3.13/site-packages
NV=""
for d in /data/Projects/notnixos/.vm/stage-new-system/nix/store/*-nvidia-x11-*/lib; do
    if [ -e "$d/libcuda.so.1" ]; then NV="$d"; break; fi
done
LLIB="${NV:+$NV:}/nix/store/604gsr59rj7dzd0nrhp143rpvf7gyiaz-gcc-15.3.0-lib/lib:/nix/store/61a1nwx3w6rqyaisj5rn1sal1981apm7-zlib-1.3.2/lib"

echo "prompt : $PROMPT"
echo "params : temp=$TEMP top_k=$TOP_K top_p=$TOP_P n=$N"
echo "ours   : $MODEL (bf16 IT, layer 0 -> RTL Gating ASIC, reasoning on)"
echo "vllm   : $IT_FP8 (fp8 IT)"
echo

# --- our engine ---------------------------------------------------------
mkdir -p "$ROOT/.bin"
( cd "$SIM" && go build -o "$ROOT/.bin/pnmgate" ./cmd/pnmgate )

# --- both sides, same prompt, same params -------------------------------
RUN=$(mktemp -d)
( cd "$ROOT" && timeout 1800 "$ROOT/.bin/pnmgate" -model "$MODEL" -layers 0 -width 256 \
        -max-tokens "$N" -temp "$TEMP" -think "$PROMPT" > "$RUN/ours.log" 2>&1;
  echo "rc=$?" > "$RUN/ours.rc" ) &
OURS_PID=$!
( CUDA_VISIBLE_DEVICES=0 VLLM_USE_FLASHINFER_SAMPLER=0 VLLM_USE_FLASHINFER_MOE_FP8=0 \
  PYTHONPATH=$PYTHONPATH LD_LIBRARY_PATH=$LLIB timeout 1800 "$PY" "$ROOT/tools/vllm_cmp.py" \
        "$PROMPT" "$TEMP" "$TOP_K" "$TOP_P" "$N" > "$RUN/vllm.log" 2>&1;
  echo "rc=$?" > "$RUN/vllm.rc" ) &
VLLM_PID=$!

wait $OURS_PID; wait $VLLM_PID

echo "=========== OURS (bf16 IT, RTL-gated layer 0, reasoning) ==========="
cat "$RUN/ours.rc" 2>/dev/null || echo "rc=?"
grep -E "^reasoning|^answer|^tokens" "$RUN/ours.log" || tail -5 "$RUN/ours.log"
echo
echo "=========== vLLM (fp8, GPU) ==========="
cat "$RUN/vllm.rc" 2>/dev/null || echo "rc=?"
grep -E "^PARAMS|^IDS|^TEXT" "$RUN/vllm.log" || tail -5 "$RUN/vllm.log"
echo
echo "logs: $RUN/{ours,vllm}.log"
