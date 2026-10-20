#!/usr/bin/env python3
"""real_decoder_block.py — BF16 spec reference & emitter for the integrated
Gemma-4-shaped decoder datapath (HDL/core/gemma_decoder_block.v).

The datapath is a small "homunculus" slice of Gemma-4 layer 0:  N=16 hidden,
2 heads x 8 head-dim, 16-wide dense MLP, 4 experts (top-2), 4-key KV cache.
All weights are REAL layer-0 tensors from the checkpoint, sliced to the small
config; all arithmetic is the exact BF16 op set validated in bf16_fp_ref.py.

The op order below IS the spec: the RTL FSM mirrors it op-for-op, and this
script runs the sim and requires bit-exact equality of the final hidden state.

Forward (mirrors HF Gemma4TextDecoderLayer.forward, bf16):
  residual = x
  x  = input_layernorm(x); x = attn(x)   [q/k/v proj, per-head q/k-norm(+scale),
       v-norm(-scale), rope, softmax over KV cache]
  x  = post_attention_layernorm(x); x = residual + x
  r0 = x; u = pre_feedforward_layernorm(x)
  dense = down_proj(gelu_tanh(gate(u)) * up(u));  h1 = post_ff_1_norm(dense)
  rout  = router.norm(r0) * router.scale * hidden^-0.5
  p     = softmax(router.proj(rout)); top-2, normalized, x per_expert_scale
  x2    = pre_feedforward_layernorm_2(r0)
  moe   = sum_k p_k * down_k(gelu_tanh(gate_k(x2)) * up_k(x2)); h2 = post_ff_2_norm(moe)
  x  = post_feedforward_layernorm(h1 + h2); x = r0 + x; x *= layer_scalar
"""
import argparse
import json
import math
import os
import struct
import subprocess
import sys
from fractions import Fraction

from bf16_fp_ref import (op_mul as mul, op_add as add, op_sub as sub,
                         op_div as div, op_exp as exp, op_rsqrt as rsqrt,
                         round_bf16)

HERE = os.path.dirname(os.path.abspath(__file__))

# ---- homunculus config ------------------------------------------------------
N, NH, HD, FFD = 16, 2, 8, 16
E, EFF, CACHE = 4, 8, 4
POSQ = CACHE                      # query token position (after the CACHE keys)
RHO = 1e4                         # homunculus rope theta (sliding default)
EPS = 1e-6

# real checkpoint global hidden size (embed scale + input scaling reference)
REAL_HIDDEN = 2816

# token ids for the KV cache keys and the query
KEY_TOKENS = [1034, 24195, 1201, 369]     # arbitrary slice of the vocab
QUERY_TOKEN = 15938                        # "Who"


# ---- safetensors access -----------------------------------------------------

def load_index(model):
    with open(os.path.join(model, "model.safetensors.index.json")) as f:
        return json.load(f)["weight_map"]


def shard_header(model, shard):
    with open(os.path.join(model, shard), "rb") as f:
        n = struct.unpack("<Q", f.read(8))[0]
        return n, json.loads(f.read(n))


def read_bf16(model, shard, hdr_len, abs_off, nitems):
    with open(os.path.join(model, shard), "rb") as f:
        f.seek(8 + hdr_len + abs_off)
        raw = f.read(nitems * 2)
    return [int.from_bytes(raw[i * 2:i * 2 + 2], "little") for i in range(nitems)]


def tensor_slice(model, idx, name, rows, cols, out_rows, out_cols):
    """Top-left out_rows x out_cols slice of a 2-D BF16 tensor."""
    shard = idx[name]
    hdr_len, hdr = shard_header(model, shard)
    base = hdr[name]["data_offsets"][0]
    words = []
    for r in range(out_rows):
        off = base + r * cols * 2
        words.append(read_bf16(model, shard, hdr_len, off, out_cols))
    return words


def tensor1d(model, idx, name, count):
    shard = idx[name]
    hdr_len, hdr = shard_header(model, shard)
    base = hdr[name]["data_offsets"][0]
    return read_bf16(model, shard, hdr_len, base, count)


def tensor3d_expert(model, idx, name, exp_rows, exp_cols, out_experts, out_rows, out_cols):
    """Slice [0:out_experts, 0:out_rows, 0:out_cols] of an [E, R, C] tensor."""
    shard = idx[name]
    hdr_len, hdr = shard_header(model, shard)
    base = hdr[name]["data_offsets"][0]
    mats = []
    for e in range(out_experts):
        off = base + e * exp_rows * exp_cols * 2
        rows = []
        for r in range(out_rows):
            rows.append(read_bf16(model, shard, hdr_len, off + r * exp_cols * 2, out_cols))
        mats.append(rows)
    return mats


# ---- arithmetic -------------------------------------------------------------

def rmsnorm_full(v, w):
    s = 0
    for i in range(N):
        s = add(s, mul(v[i], v[i]))
    mean = mul(s, C_INVN)
    v_inv = rsqrt(add(mean, C_EPS))
    return [mul(mul(v[i], v_inv), w[i]) for i in range(N)]


def rmsnorm_noscale(v):
    s = 0
    for i in range(N):
        s = add(s, mul(v[i], v[i]))
    mean = mul(s, C_INVN)
    v_inv = rsqrt(add(mean, C_EPS))
    return [mul(v[i], v_inv) for i in range(N)]


def rmsnorm_heads(v, w):
    """Per-head RMSNorm with per-head scale weights (q/k_norm)."""
    out = [0] * N
    for h in range(NH):
        s = 0
        for d in range(HD):
            s = add(s, mul(v[h * HD + d], v[h * HD + d]))
        v_inv = rsqrt(add(mul(s, C_INVHD), C_EPS))
        for d in range(HD):
            out[h * HD + d] = mul(mul(v[h * HD + d], v_inv), w[h * HD + d])
    return out


def vnorm_heads(v):
    """Per-head RMSNorm WITHOUT scale (v_norm)."""
    out = [0] * N
    for h in range(NH):
        s = 0
        for d in range(HD):
            s = add(s, mul(v[h * HD + d], v[h * HD + d]))
        v_inv = rsqrt(add(mul(s, C_INVHD), C_EPS))
        for d in range(HD):
            out[h * HD + d] = mul(v[h * HD + d], v_inv)
    return out


def linear(W, x):
    width = len(x)
    out = []
    for o in range(len(W)):
        acc = 0
        for j in range(width):
            acc = add(acc, mul(W[o][j], x[j]))
        out.append(acc)
    return out


def rope(v, pos):
    out = [0] * N
    for h in range(NH):
        for p in range(HD // 2):
            t0, t1 = h * HD + 2 * p, h * HD + 2 * p + 1
            c, s = ROPE_T[pos][h][p]
            out[t0] = sub(mul(v[t0], c), mul(v[t1], s))
            out[t1] = add(mul(v[t0], s), mul(v[t1], c))
    return out


def softmax(v):
    m = max(v)
    e = [exp(sub(x, m)) for x in v]
    z = 0
    for x in e:
        z = add(z, x)
    return [div(x, z) for x in e]


def gelu_tanh(x):
    x3 = mul(mul(x, x), x)
    inner = add(x, mul(x3, C_GELU_B))
    t = add(C_ONE, bf16_tanh(mul(inner, C_GELU_A)))
    return mul(mul(x, C_HALF), t)


def bf16_tanh(x):
    e2 = exp(mul(x, C_TWO))
    r = div(C_TWO, add(e2, C_ONE))
    return sub(C_ONE, r)


def top2_idx(p):
    best, best2 = -1, -1
    for i in range(E):
        if best == -1 or p[i] > p[best]:
            best = i
    for i in range(E):
        if i == best:
            continue
        if best2 == -1 or p[i] > p[best2]:
            best2 = i
    return best, best2


# ---- layer forward (THE spec) ----------------------------------------------

def decoder_forward(x, kc, vc):
    res = list(x)
    xn = rmsnorm_full(x, W_N1)                          # input_layernorm
    q = linear(W_Q, xn)
    k = linear(W_K, xn)
    v = linear(W_V, xn)
    qr = rope(rmsnorm_heads(q, W_QN), POSQ)             # q_norm then rope
    # attention over KV cache (k already normed+roped at its position)
    probs = [[] for _ in range(NH)]
    for h in range(NH):
        scores = [0] * CACHE
        for c in range(CACHE):
            acc = 0
            for d in range(HD):
                acc = add(acc, mul(qr[h * HD + d], kc[c][h * HD + d]))
            scores[c] = acc
        probs[h] = softmax(scores)
    ctx = [0] * N
    for h in range(NH):
        for d in range(HD):
            acc = 0
            for c in range(CACHE):
                acc = add(acc, mul(probs[h][c], vc[c][h * HD + d]))
            ctx[h * HD + d] = acc
    ao = linear(W_O, ctx)                               # attn output
    xs = [add(rmsnorm_full(ao, W_N2)[i], res[i]) for i in range(N)]  # post_attn_norm + residual

    r0 = list(xs)
    u = rmsnorm_full(xs, W_PRE1)
    gate = linear(W_GATE, u)
    up = linear(W_UP, u)
    act = [mul(gelu_tanh(gate[i]), up[i]) for i in range(FFD)]
    dense = linear(W_DOWN, act)
    h1 = rmsnorm_full(dense, W_PF1)                     # post_ff_1_norm

    rf = rmsnorm_noscale(r0)                            # router norm (no scale)
    rout = [mul(mul(rf[i], W_RSCA[i]), C_INVSQRTN) for i in range(N)]
    plog = softmax(linear(W_RPROJ, rout))               # E softmax
    t0, t1 = top2_idx(plog)
    wsum = add(plog[t0], plog[t1])
    w0 = mul(div(plog[t0], wsum), W_PES[t0])
    w1 = mul(div(plog[t1], wsum), W_PES[t1])
    x2 = rmsnorm_full(r0, W_PRE2)                       # expert input
    moe = [0] * N
    for eidx in sorted((t0, t1)):                       # ascending index
        gate_k = linear([row for row in EGU[eidx][:EFF]], x2)
        up_k = linear([row for row in EGU[eidx][EFF:2 * EFF]], x2)
        act_k = [mul(gelu_tanh(gate_k[i]), up_k[i]) for i in range(EFF)]
        dk = linear(EDOW[eidx], act_k)
        wk = w0 if eidx == t0 else w1
        for i in range(N):
            moe[i] = add(moe[i], mul(wk, dk[i]))
    h2 = rmsnorm_full(moe, W_PF2)                       # post_ff_2_norm

    comb = [add(h1[i], h2[i]) for i in range(N)]
    y = [add(rmsnorm_full(comb, W_PFF)[i], r0[i]) for i in range(N)]
    return [mul(y[i], C_LSCA) for i in range(N)]


# ---- weight / rope / kv setup -----------------------------------------------

def load_weights(model):
    idx = load_index(model)
    L0 = "model.language_model.layers.0."
    V = {}
    V["N1"] = tensor1d(model, idx, L0 + "input_layernorm.weight", N)
    V["N2"] = tensor1d(model, idx, L0 + "post_attention_layernorm.weight", N)
    V["QN"] = tensor1d(model, idx, L0 + "self_attn.q_norm.weight", N)
    V["KN"] = tensor1d(model, idx, L0 + "self_attn.k_norm.weight", N)
    for x, w in (("Q", "q_proj"), ("K", "k_proj"), ("V", "v_proj")):
        V[x] = tensor_slice(model, idx, L0 + "self_attn.%s.weight" % w, 0, 0, N, N)
    V["O"] = tensor_slice(model, idx, L0 + "self_attn.o_proj.weight", 0, 0, N, N)
    V["PRE1"] = tensor1d(model, idx, L0 + "pre_feedforward_layernorm.weight", N)
    V["GATE"] = tensor_slice(model, idx, L0 + "mlp.gate_proj.weight", 0, 0, FFD, N)
    V["UP"] = tensor_slice(model, idx, L0 + "mlp.up_proj.weight", 0, 0, FFD, N)
    V["DOWN"] = tensor_slice(model, idx, L0 + "mlp.down_proj.weight", 0, 0, N, FFD)
    V["PF1"] = tensor1d(model, idx, L0 + "post_feedforward_layernorm_1.weight", N)
    V["PRE2"] = tensor1d(model, idx, L0 + "pre_feedforward_layernorm_2.weight", N)
    V["PF2"] = tensor1d(model, idx, L0 + "post_feedforward_layernorm_2.weight", N)
    V["PFF"] = tensor1d(model, idx, L0 + "post_feedforward_layernorm.weight", N)
    V["RPROJ"] = tensor_slice(model, idx, L0 + "router.proj.weight", 0, 0, E, N)
    V["RSCA"] = tensor1d(model, idx, L0 + "router.scale", N)
    V["PES"] = tensor1d(model, idx, L0 + "router.per_expert_scale", E)
    V["LSCA"] = tensor1d(model, idx, L0 + "layer_scalar", 1)[0]
    gu = tensor3d_expert(model, idx, L0 + "experts.gate_up_proj", 2 * EFF, N, E, 2 * EFF, N)
    dw = tensor3d_expert(model, idx, L0 + "experts.down_proj", N, EFF, E, N, EFF)
    return V, gu, dw


def build_rope_tables():
    freqs = [RHO ** (-2.0 * p / HD) for p in range(HD // 2)]
    tbl = {}
    for pos in range(CACHE + 1):
        tbl[pos] = []
        for h in range(NH):
            tbl[pos].append([
                (round_bf16(Fraction(math.cos(pos * f))),
                 round_bf16(Fraction(math.sin(pos * f)))) for f in freqs])
    return tbl


def build_kv(embed_rows):
    kc, vc = [], []
    for c, tok in enumerate(KEY_TOKENS):
        xe = scaled_embed(embed_rows[tok])
        kraw = linear(W_K, xe)
        kc.append(rope(rmsnorm_heads(kraw, W_KN), c))
        vraw = linear(W_V, xe)
        vc.append(vnorm_heads(vraw))
    return kc, vc


def scaled_embed(row):
    scale = math.sqrt(REAL_HIDDEN)
    return [mul(w, round_bf16(Fraction(scale))) for w in row[:N]]


def embed_rows(model, idx, name, rows, cols, N):
    """BF16 2-D rows [0:N] for the given row indices (sparse reads)."""
    shard = idx[name]
    hdr_len, hdr = shard_header(model, shard)
    base = hdr[name]["data_offsets"][0]
    out = {}
    for r in rows:
        out[r] = read_bf16(model, shard, hdr_len, base + r * cols * 2, N)
    return out


# ---- shared mutable state (consts filled in main) ---------------------------

C_INVN = C_INVHD = C_INVSQRTN = C_EPS = C_GELU_A = C_GELU_B = None
C_HALF = C_ONE = C_TWO = C_LSCA = 0
W_N1 = W_N2 = W_QN = W_KN = W_PA = None
W_Q = W_K = W_V = W_O = None
W_PRE1 = W_GATE = W_UP = W_DOWN = W_PF1 = W_PRE2 = W_PF2 = W_PFF = None
W_RPROJ = W_RSCA = W_PES = None
EGU = EDOW = None
ROPE_T = {}


# ---- emitter ----------------------------------------------------------------

def build_wmem():
    """consts then named regions; returns (wmem list, A dict of base addrs)."""
    consts = [round_bf16(Fraction(EPS)),   # 0 eps
              round_bf16(Fraction(1, N)),  # 1 invN
              round_bf16(Fraction(1, HD)), # 2 invHD
              round_bf16(Fraction(1.0 / math.sqrt(N))),  # 3 invSqrtN
              round_bf16(Fraction(math.sqrt(2 / math.pi))),  # 4 geluA
              round_bf16(Fraction(44715, 1000000)),  # 5 geluB 0.044715
              round_bf16(Fraction(1, 2)),  # 6 half
              round_bf16(Fraction(1)),     # 7 one
              round_bf16(Fraction(2)),     # 8 two
              C_LSCA,                      # 9 layer_scalar
              0,                           # 10 zero
              0]                           # 11 unused
    regions = [("N1", N), ("N2", N), ("QN", N), ("KN", N),
               ("PRE1", N), ("PF1", N), ("PRE2", N), ("PF2", N), ("PFF", N),
               ("Q", N * N), ("K", N * N), ("V", N * N), ("O", N * N),
               ("GATE", FFD * N), ("UP", FFD * N), ("DOWN", N * FFD),
               ("RPROJ", E * N), ("RSCA", N), ("PES", E),
               ("EGU", E * 2 * EFF * N), ("EDOW", E * N * EFF)]
    A = {}
    wmem = list(consts)
    for name, size in regions:
        A[name] = len(wmem)
        wmem += [0] * size
    return wmem, A


def fill_wmem(wmem, A):
    for name in ("N1", "N2", "QN", "KN", "PRE1", "PF1", "PRE2", "PF2", "PFF"):
        for i in range(N):
            wmem[A[name] + i] = WDM[name][i]
    for name in ("Q", "K", "V", "O"):
        base = A[name]
        for r in range(N):
            for j in range(N):
                wmem[base + r * N + j] = WDM[name][r][j]
    for name in ("GATE", "UP"):
        base = A[name]
        for r in range(FFD):
            for j in range(N):
                wmem[base + r * N + j] = WDM[name][r][j]
    base = A["DOWN"]
    for r in range(N):
        for j in range(FFD):
            wmem[base + r * FFD + j] = WDM["DOWN"][r][j]
    base = A["RPROJ"]
    for r in range(E):
        for j in range(N):
            wmem[base + r * N + j] = WDM["RPROJ"][r][j]
    for i in range(N):
        wmem[A["RSCA"] + i] = WDM["RSCA"][i]
    for i in range(E):
        wmem[A["PES"] + i] = WDM["PES"][i]
    base = A["EGU"]
    for e in range(E):
        for r in range(2 * EFF):
            for j in range(N):
                wmem[base + (e * 2 * EFF + r) * N + j] = EGU[e][r][j]
    base = A["EDOW"]
    for e in range(E):
        for r in range(N):
            for j in range(EFF):
                wmem[base + (e * N + r) * EFF + j] = EDOW[e][r][j]


def emit_vh(path, A, wmem):
    lines = []
    for name in ("N1", "N2", "QN", "KN", "PRE1", "PF1", "PRE2", "PF2", "PFF",
                 "Q", "K", "V", "O", "GATE", "UP", "DOWN", "RPROJ", "RSCA", "PES",
                 "EGU", "EDOW"):
        lines.append("`define AW_%s %d" % (name, A[name]))
    cvals = ["EPS", "INVN", "INVHD", "INVSQRTN", "GELUA", "GELUB", "HALF", "ONE",
             "TWO", "LSCA", "ZERO", "UNUSED"]
    for i, name in enumerate(cvals):
        lines.append("`define CC_%s 16'h%04x" % (name, wmem[i]))
    lines.append("`define WMEMSZ %d" % len(wmem))
    lines.append("`define RCOSC (CACHE+1)*NH*(HD/2)*2")
    with open(path, "w") as f:
        f.write("\n".join(lines) + "\n")


def emit_hex(path, data):
    with open(path, "w") as f:
        for w in data:
            f.write("%04x\n" % (w & 0xFFFF))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.environ.get("PNM_MODEL_DIR", "/data/gemma4_dl/complete"))
    ap.add_argument("--out", default="/tmp/pnm_decoder_block")
    ap.add_argument("--no-run", action="store_true")
    args = ap.parse_args()

    global W_N1, W_N2, W_QN, W_KN, W_PA, W_Q, W_K, W_V, W_O
    global W_PRE1, W_GATE, W_UP, W_DOWN, W_PF1, W_PRE2, W_PF2, W_PFF
    global W_RPROJ, W_RSCA, W_PES, C_LSCA, EGU, EDOW, ROPE_T, WDM
    global C_INVN, C_INVHD, C_INVSQRTN, C_EPS, C_GELU_A, C_GELU_B
    global C_HALF, C_ONE, C_TWO

    V, gu, dw = load_weights(args.model)
    idx = load_index(args.model)
    erows = embed_rows(args.model, idx, "model.language_model.embed_tokens.weight",
                       KEY_TOKENS + [QUERY_TOKEN], 2816, N)

    W_N1, W_N2, W_QN, W_KN = V["N1"], V["N2"], V["QN"], V["KN"]
    W_Q, W_K, W_V, W_O = V["Q"], V["K"], V["V"], V["O"]
    W_PRE1, W_GATE, W_UP, W_DOWN = V["PRE1"], V["GATE"], V["UP"], V["DOWN"]
    W_PF1, W_PRE2, W_PF2, W_PFF = V["PF1"], V["PRE2"], V["PF2"], V["PFF"]
    W_RPROJ, W_RSCA, W_PES = V["RPROJ"], V["RSCA"], V["PES"]
    EGU, EDOW, WDM = gu, dw, V
    C_LSCA = V["LSCA"]

    C_INVN = round_bf16(Fraction(1, N))
    C_INVHD = round_bf16(Fraction(1, HD))
    C_INVSQRTN = round_bf16(Fraction(1.0 / math.sqrt(N)))
    C_EPS = round_bf16(Fraction(EPS))
    C_GELU_A = round_bf16(Fraction(math.sqrt(2 / math.pi)))
    C_GELU_B = round_bf16(Fraction(44715, 1000000))
    C_HALF, C_ONE, C_TWO = round_bf16(Fraction(1, 2)), round_bf16(Fraction(1)), round_bf16(Fraction(2))

    ROPE_T = build_rope_tables()
    kcache, vcache = build_kv(erows)
    x = scaled_embed(erows[QUERY_TOKEN])
    g = decoder_forward(x, kcache, vcache)

    os.makedirs(args.out, exist_ok=True)
    wmem_l, A = build_wmem()
    fill_wmem(wmem_l, A)
    emit_vh(os.path.join(args.out, "dblock_addrs.vh"), A, wmem_l)
    emit_hex(os.path.join(args.out, "dblock_wmem.hex"), wmem_l)
    emit_hex(os.path.join(args.out, "dblock_kc.hex"), [w for vv in kcache for w in vv])
    emit_hex(os.path.join(args.out, "dblock_vc.hex"), [w for vv in vcache for w in vv])
    rope_words = []
    for pos in range(CACHE + 1):
        for h in range(NH):
            for c, s in ROPE_T[pos][h]:
                rope_words += [c, s]
    emit_hex(os.path.join(args.out, "dblock_rope.hex"), rope_words)
    emit_hex(os.path.join(args.out, "dblock_x.hex"), x)
    emit_hex(os.path.join(args.out, "dblock_out.hex"), g)

    print("model     :", args.model)
    print("config    : N=%d NH=%d HD=%d FFD=%d E=%d EFF=%d CACHE=%d POSQ=%d"
          % (N, NH, HD, FFD, E, EFF, CACHE, POSQ))
    print("weights   : layer0 real slices; wmem words=%d" % len(wmem_l))
    print("query tok :", QUERY_TOKEN, " keys:", KEY_TOKENS)
    print("golden out: " + " ".join("%04x" % w for w in g))

    if args.no_run:
        return 0

    tb = os.path.join(HERE, "tb_gemma_decoder_block.v")
    src = [os.path.join(HERE, s) for s in ("gemma_decoder_block.v", tb)]
    vvp = os.path.join(args.out, "tb_gemma_decoder_block.vvp")
    subprocess.run(["iverilog", "-g2005", "-I", HERE, "-I", args.out,
                    "-o", vvp, *src], check=True)
    r = subprocess.run(["vvp", "tb_gemma_decoder_block.vvp"], cwd=args.out,
                       capture_output=True, text=True, check=True)
    got = {}
    for line in r.stdout.splitlines():
        p = line.split()
        if len(p) == 3 and p[0] == "OUT":
            got[int(p[1])] = int(p[2], 16)
    if len(got) != N:
        print("DUT produced %d outputs, expected %d" % (len(got), N), file=sys.stderr)
        print(r.stdout[-3000:], r.stderr[-3000:], file=sys.stderr)
        return 1
    mism = [i for i in range(N) if got[i] != g[i]]
    print("rtl       : " + " ".join("%04x" % got[i] for i in range(N)))
    if mism:
        print("*** MISMATCH at dims", mism)
        for i in mism:
            print("    dim %2d: rtl=%04x ref=%04x" % (i, got[i], g[i]))
        return 1
    print("*** PASS: integrated decoder block N/16 bit-exact vs BF16 reference ***")
    return 0


if __name__ == "__main__":
    sys.exit(main())