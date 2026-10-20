# Real-weight inference: benchmark, serving parity, and RTL proof of concept

The co-simulation harness runs the **actual Gemma 4 26B-A4B checkpoint** on
the simulated stack — no torch, no transformers, no Python runtime — a pure Go
forward pass over the real BF16 weights, driven by the real Gemma BPE
tokenizer, with the fabric/firmware/MoE dispatch artifacts underneath.  As of
the parity session it is **greedy-token-identical to a Hugging Face / vLLM
reference** on the tested chat prompts.

## Download the model

The checkpoint is a gated Google release.  Accept the licence on Hugging
Face, create a read token, then:

```bash
HF_TOKEN=hf_xxx ./download_model.sh                 # -> models/gemma-4-26B-A4B (~52 GB)
HF_TOKEN=hf_xxx ./download_model.sh --out /data/gemma4_dl/complete
```

Every file is pinned to its upstream SHA-256 and verified after download; a
partial transfer is resumed (`curl -C -`) and a corrupt one is re-fetched.
Point `PNM_MODEL_DIR` at the directory (or pass it as the first argument to
`pnmhost inference`).  The instruction-tuned checkpoint used only for chat
templates can be fetched with `--repo google/gemma-4-26B-A4B-it`.

`reproduce.sh --real-weights` downloads the model if absent and then runs the
serving check below (needs `HF_TOKEN`).

## Model under test

| Property | Value |
|---|---|
| Model | google/gemma-4-26B-A4B (Gemma 4, 26.5B params, BF16) |
| Weights | `models/gemma-4-26B-A4B/` (2 shards, URL+SHA-256 pinned in `download_model.sh`) |
| Tokenizer | `tokenizer.json` — 262,144 vocab, byte-fallback BPE, 514,906 merges |
| Chassis | 30 layers × hidden 2816, 16 attn heads (256) / 2 global KV (512) on full-attn layers |
| MoE | 128 experts, top-8, gate_up_proj [128,1408,2816] + down_proj [128,2816,704] |

## Serving parity with HF/vLLM (greedy)

Two things were needed to behave like a real serving stack — answer the
question and stop:

1. **Chat template = `enable_thinking` rendering.**  HF
   `apply_chat_template(..., enable_thinking=True)` prepends a system turn
   `<|turn>system\n<|think|>\n<turn|>\n` (ids `[105 9731 107 98 107 106 107]`)
   even with no user system message.  The engine now emits the same ids as HF.
2. **bf16 store emulation.**  HF/vLLM store every activation tensor in bf16
   between ops.  `roundBF16` (round-to-nearest-even) is applied at every
   store: embeddings, all Linear outputs, every RMSNorm/vNorm, RoPE cos/sin +
   rotated outputs, the SDPA output, GELU/swiglu gate·up products, the expert
   gate/up/act/down and the bf16 weighted add (bf16 accumulate), the router
   chain (norm × scale × hidden^-½ → Linear → softmax → normalized weights),
   the tied-embedding logits and the final softcap, the KV cache, residual
   adds and layer boundaries.  Router weights now land on HF's exact bf16
   grid and near-ties (e.g. the L5 7↔27 tie) break like HF.

Greedy results (verified against HF `transformers` 5.12, bf16, CPU):

| Prompt (chat template) | Engine greedy tokens | Match |
|---|---|---|
| "What is the capital of Germany" | `[818 5279 529 9405 563 15687 236761 106]` → "The capital of Germany is Berlin." | first 8 = HF exactly, stops on `<turn|>` (106) |
| "What is the capital of France?" | `[818 5279 529 7001 563 9079 236761 106]` → "The capital of France is Paris." | first 8 = HF exactly |
| "The capital of Germany is" (plain completion) | step-0 token now `▁Germany` (matches HF) | diverges at step 1 only on ~1-ULP router near-ties |

```bash
$ pnmhost inference models/gemma-4-26B-A4B "What is the capital of Germany" -max-tokens 32
[1m48s] real-weights forward: "The capital of Germany is Berlin.<turn|>" (engine: gemma4-bf16)
  result: ALL PASSED
```

The base checkpoint is a pretrained text-completer, not an instruction-tuned
assistant: asked to "define concatenation" it echoes or loops under either
template.  Use the `-it` variant (`--repo google/gemma-4-26B-A4B-it`) for
instruction answers; the numeric engine is the same.

## Run it

```bash
cd sim
go run ./cmd/pnmhost inference "$PNM_MODEL_DIR" "What is the capital of Germany" -max-tokens 32

# real-weight debug harnesses (logits / routes / chat ids), opt-in:
PNM_REAL_TESTS=1 go test ./internal/pnm/ -run TestTmp -count=1 -v

# fabric dispatch with real token payloads through the Verilog co-sim:
go run ./cmd/pnmc run-fabric "$PNM_MODEL_DIR" -l 2 -x 2 -y 2 --prompt "Who was Alan Turing?"
```

## Benchmark (single process, host CPU)

30-layer stack, 262,144-vocab logits per step, BF16 weights, pure-Go float32
arithmetic and bf16 store rounding (no BLAS, no SIMD, no GPU).

| Run | Wall | Notes |
|---|---|---|
| load + prefill + 1 token | 76.8 s | embedding (3 GB) + full prompt attention + 1 decode |
| full chat answer (8 tokens) | 108.9 s | stops on `<turn|>`; `-max-tokens` above 8 does not extend it |
| steady-state decode | ≈5 s/token | one KV append + 30 layers + full-vocab logits |
| peak RSS | ≈15.9 GB | cached BF16 weight matrices; experts read per top-k row |

- The 262,144 × 2816 embedding is ~3 GB; the full-vocab logits (738 M MAC per
  step) dominates decode.
- MoE experts materialise only the top-8 rows per token (46 MB/step instead of
  the full ~2 GB gate_up/down per layer) — the RL dispatch the paper describes.
- At the paper's projected silicon (1 GHz, systolic arrays) the fabric loop
  timing is `Scenario model-fabric [PASS]`.

## RTL proof of concept: real weights on the BF16 FMA array (vvp)

The full numeric forward runs in Go because a cycle-accurate simulation of
26 B parameters is infeasible, and the RTL currently exposes the compute
*primitives* (BF16 FMA, systolic MAC array, MoE gating, RoPE, KV cache)
rather than an integrated transformer datapath.  To show that real checkpoint
weights *do* execute on the project's BF16 FMA hardware, `real_matvec_poc.py`
runs a real tensor through the systolic array under `iverilog`/`vvp` and checks
the result bit-for-bit:

```bash
python3 HDL/core/real_matvec_poc.py --model "$PNM_MODEL_DIR"
```

It takes a 16×16 tile of the real layer-0 `router.proj.weight` and a real
16-wide activation (the scaled embedding of token 15938, `√2816 · embed`),
loads them into `bf16_mac_array.v`, fires the array, and compares the 16
outputs against an exact BF16-FMA reference (exact product+sum, round-nearest-
even to bf16).  Result: **16/16 outputs bit-exact**, e.g. column values
`be00 3d8f be03 3e4f …` — a genuine MoE router projection slice computed on
RTL BF16 FMA units under `vvp`, not in Go.

## RTL: integrated decoder block, bit-exact on real layer-0 (vvp)

A full decoder datapath — attention + KV cache + dense gelu-tanh MLP + MoE
top-2 experts — now runs as RTL under `iverilog`/`vvp` and reproduces the
Go/HF reference **bit-for-bit** on real weights.

- `HDL/core/bf16_fp.vh` — combinational BF16 library: mul/add/sub/div
  (exact-RNE with FTZ), exp (log2-e range reduction + 17-entry 2^(i/16) LUT),
  rsqrt (exponent-halve seed + 4 Newton iters), tanh (`1 − 2/(e^2x+1)`),
  gelu-tanh, numeric `bf16_gt`/max/softmax helpers.  Validated standalone:
  **10984/10984 vectors bit-exact** vs the exact-Fraction oracle in
  `bf16_fp_ref.py` (mul/add/sub/div/exp/rsqrt/tanh).
- `HDL/core/gemma_decoder_block.v` — parameterised FSM (one clock per stage,
  ~45 stages) mirroring `decoder_forward()` in `real_decoder_block.py`:
  input norm → q/k/v → per-head q-norm + half-split RoPE → attention scores
  → max-subtract softmax over the KV cache → context → o-proj →
  post-attn-norm + residual → pre-ff norm → dense gate/up gelu-tanh → 
  post-ff-1 norm → router (norm-no-scale × scale × hidden^−½ → E-softmax
  → top-2 → renormalise → × per_expert_scale) → pre-ff-2 norm over the plain
  residual → ascending top-2 experts (gate_up / down with gelu-tanh) →
  post-ff-2 norm → combine + post-ff norm + residual → × layer_scalar.
- `HDL/core/real_decoder_block.py` — BF16 spec reference + emitter (homunculus
  N=16 NH=2 HD=8 FFD=16 E=4 EFF=8 CACHE=4, real layer-0 slices + real
  embeddings, `√2816` embed scale, θ=1e4 rope).  Emits `dblock_{addrs,vmem,kc,
  vc,rope,x,out}.hex`, compiles both `.v`, runs `vvp` and compares every
  output word:
  `*** PASS: integrated decoder block N/16 bit-exact vs BF16 reference ***`
  (output `3d88 bdf6 be02 bf11 bd8c be36 bde6 beac c052 …`).

```bash
python3 HDL/core/bf16_fp_ref.py      # self-contained bf16 library check
python3 HDL/core/real_decoder_block.py --model "$PNM_MODEL_DIR"
```

## RTL: compute node, bit-exact on real layer-0 expert (vvp)

`HDL/core/node.v` is the compute node of the node network — one MoE expert
pass (gate/up → gelu-tanh·up → down) on the same BF16 fused-FMA datapath as
the router. Its `CU_TYPE` parameter selects the embedded numeric ASIC behind
one shared accumulate interface (`c = a*b + c`) and control FSM:

| `CU_TYPE` | Engine | `WIDTH` | Datapath |
|-----------|--------|---------|----------|
| 0 | `bf16_fma` | 16 | gate/up → swiglu → down (Gemma expert) |
| 1 | `fp16_fma` | 16 | gate → down (identity activation) |
| 2 | `fp32_fma` | 32 | gate → down |
| 3 | `fp64_fma` | 64 | gate → down |
| 4 | `int8_mac` | 8 | INT8 gate → down, INT32 accumulate |
| 5 | `int4_mac` | 8 | packed-nibble INT4 |
| 6 | `fp4_mac` | 8 | FP4 (E2M1) |
| 7 | `fp4_mac` | 8 | FP4 + `MXFP4_SHIFT` block scale |

`node_reference_test.py` + `tb_node.v` boot the weight SRAM, stream the
hidden vector, then compare every output word against an exact oracle:

```bash
python3 HDL/core/node_reference_test.py            # BF16, random 16x8 -> bit-exact
python3 HDL/core/node_reference_test.py --cu 4     # INT8 expert pass -> bit-exact
PNM_MODEL_DIR="$PNM_MODEL_DIR" \
  python3 HDL/core/node_reference_test.py --real   # real layer-0 expert 0 -> bit-exact
```

CU 0 (BF16) is bit-exact vs the fused-FMA + bf16_fp.vh gelu oracle; CU 4
(INT8) vs an exact integer matvec. CU 1/2/3 report a finite-value smoke and
CU 5/6/7 an elaboration+run smoke (their arithmetic is validated by each
unit's own testbench).

## Architecture notes (how it maps to the paper)

1. **Real weights**: `safetensors.go` header parsing + absolute-offset
   row-range reads; only the top-k expert rows are materialised per step.
2. **Tokenizer**: `real_tokenizer.go` — byte-fallback BPE with 514,906 merges,
   wired into the host SDK, `compile-model`, `run-fabric` and `run-driver`.
3. **Forward engine** (`real_infer.go`) per HF `modeling_gemma4.py`: q/k/v
   RMSNorm, half-split RoPE (θ=1e4 sliding / θ=1e6 partial-0.25 full), attn
   scaling 1.0, k_eq_v full layers, scaled embeddings (√hidden), dense
   gelu-tanh MLP + top-8 MoE with per-expert scale, router norm-no-scale
   transform, layer_scalar, logit softcap 30, tied-embedding logits, KV-cache
   prefill/decode; every tensor store is bf16-rounded.
4. **Sampling**: greedy by default (`-temperature 0`); splitmix64-seeded
   temperature sampling when set.

## Verification

- `go build ./...`, `go vet ./...` clean; `go test ./internal/pnm/` green
  (3.6 s; the real-weight harnesses are gated behind `PNM_REAL_TESTS=1`).
- `reproduce.sh` — all scenarios and testbenches pass.
- BPE round-trip `"Who was Alan Turing?"` ↔ `[15938 691 27369 63809 236881]`.
- Greedy serving parity: Germany and France chat token-for-token against HF
  through the terminating `<turn|>`.
- RTL PoC: real router-weight tile on `bf16_mac_array` bit-exact under vvp.
- RTL integrated decoder block (attn+MLP+MoE) bit-exact vs the BF16 reference
  on real layer-0 slices; `bf16_fp` library 10984/10984 vectors bit-exact.
- RTL compute node (`node.v`) full MoE expert pass bit-exact vs the fused-FMA
  oracle (BF16 + INT8), incl. a real layer-0 expert-0 gate_up/down slice.

## Known limitations

- The plain-completion path still diverges from HF at step 1 on ~1-ULP router
  near-ties (f32 accumulation order vs torch) — not a structural bug.
- Single-threaded scalar Go: ≈5 s/token decode.
- Intermediates are f32 with bf16 stores at tensor boundaries, matching the
  reference storage regime; bit-exactness of the *accumulation order* inside a
  matmul is not guaranteed against torch.
