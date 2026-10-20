#!/usr/bin/env python3
"""node_reference_test.py — RTL validation for the compute node (HDL/core/node.v):
the node-network MAC cell running a full MoE expert pass (gate -> [act] -> down)
on a selectable numeric ASIC (CU_TYPE).

Mirrors gating_reference_test.py: boots the module with a weight file and a
hidden vector, then compares every output word against the exact oracle.

Bit-exact oracles are provided for:
  CU_TYPE 0 (BF16): fused-FMA accumulation `acc = op_fma(w, a, acc)` for the
    three projections (same single-rounding semantics as the router logits)
    plus the bf16_fp.vh gelu_tanh sequence (gate -> up -> swiglu -> down).
  CU_TYPE 4 (INT8): exact integer matvec; activation is the identity, the
    down projection consumes the sign-extended low byte of each gate.
  CU_TYPE 8 (ternary): exact BitNet b1.58 matvec (weights {-1,0,+1} x INT8,
    INT32 accumulate); identity activation, down reads the low byte.
Other CU_TYPEs run as an elaboration+execution smoke check (the per-unit
arithmetic is validated by the unit's own testbench).

Usage (inside `nix develop`):
    python3 HDL/core/node_reference_test.py            # BF16, N=16 EFF=8 random
    python3 HDL/core/node_reference_test.py --cu 4     # INT8 expert pass
    PNM_MODEL_DIR=/data/gemma4_dl/complete \
      python3 HDL/core/node_reference_test.py --real   # real L0 expert 0 (BF16)
    PNM_MODEL_DIR=/data/gemma4_dl/complete \
      python3 HDL/core/node_reference_test.py --real --cu 8  # real L0, ternary
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("NODE_OUT", "/tmp/pnm_node")

WIDTHS = {0: 16, 1: 16, 2: 32, 3: 64, 4: 8, 5: 8, 6: 8, 7: 8, 8: 8}

sys.path.insert(0, HERE)
from bf16_fp_ref import op_mul  # noqa: E402

ONE = 0x3F80
TWO = 0x4000
HALF = 0x3F00
GA = 0x3F4C   # bf16(sqrt(2/pi))
GB = 0x3D37   # bf16(0.044715)


def pack_words(words, path, width):
    digits = width // 4
    with open(path, "w") as f:
        for w in words:
            f.write("%0*x\n" % (digits, w & ((1 << width) - 1)))


def rand_bf16(rng, lo=-8, hi=8):
    from bf16_fp_ref import cls
    while True:
        u = rng.getrandbits(16)
        if cls(u) == 1:
            e = ((u >> 7) & 0xFF) - 127
            if lo <= e <= hi:
                return u


def s8(x):
    x &= 0xFF
    return x - 256 if x >= 128 else x


def gelu_oracle(x):
    """bf16_gelu in the RTL op-for-op (bf16_fp.vh) on BF16 words."""
    from bf16_fp_ref import op_add, op_div, op_exp, op_mul as _mul, op_sub
    x3 = _mul(_mul(x, x), x)
    inner = op_add(x, _mul(x3, GB))
    t = _mul(inner, GA)
    e2 = op_exp(_mul(t, TWO))
    r = op_div(TWO, op_add(e2, ONE))
    p = op_sub(ONE, r)
    p = op_add(ONE, p)
    return _mul(_mul(x, HALF), p)


def fma_chain(weights, vec):
    """acc = op_fma(w, v, acc) over the vector — moe_gating fused-FMA oracle."""
    from bf16_fp_ref import op_fma
    acc = 0
    for w, v in zip(weights, vec):
        acc = op_fma(w, v, acc)
    return acc


def reference(gu, dw, hidden):
    ngate = len(gu) // 2
    gate = [fma_chain(row, hidden) for row in gu[:ngate]]
    up = [fma_chain(row, hidden) for row in gu[ngate:]]
    act = [op_mul(gelu_oracle(g), u) for g, u in zip(gate, up)]
    out = [fma_chain(row, act) for row in dw]
    return gate, up, act, out


def reference_ternary(gu, dw, hidden):
    """Exact BitNet b1.58 matvec: ternary weights {-1,0,+1} x INT8 activations.

    gate = sum code*w; activation is the identity (already INT8); the down
    projection consumes the low byte of each gate, matching the node FSM's
    `eng_a[7:0]`. Returned words are the truncated external elements (WIDTH=8)."""
    eff = len(dw[0])

    def tern(code):
        c = code & 0x3
        return 1 if c == 1 else (-1 if c == 2 else 0)

    gate = [sum(tern(gu[j][c]) * s8(hidden[c]) for c in range(len(hidden)))
            for j in range(eff)]
    up = [0] * eff
    act8 = [g & 0xFF for g in gate]
    out = [sum(tern(dw[r][j]) * s8(act8[j]) for j in range(eff))
           for r in range(len(dw))]
    return ([g & 0xFF for g in gate], up, act8, [o & 0xFF for o in out])


def reference_int8(gu, dw, hidden):
    """Exact INT8 matvec: gate -> (identity act = gate) -> down.

    The down projection multiplies the sign-extended low byte of each gate,
    matching `eng_a[7:0]` fed to int8_mac. Returned words are the truncated
    external elements (WIDTH=8)."""
    eff = len(dw[0])
    gate = [sum(s8(gu[j][c]) * s8(hidden[c]) for c in range(len(hidden)))
            for j in range(eff)]
    up = [0] * eff
    act8 = [g & 0xFF for g in gate]
    out = [sum(s8(dw[r][j]) * s8(act8[j]) for j in range(eff))
           for r in range(len(dw))]
    return ([g & 0xFF for g in gate], up, act8, [o & 0xFF for o in out])


def _bf16_to_float(u):
    import struct
    return struct.unpack("<f", struct.pack("<I", (u & 0xFFFF) << 16))[0]


def quantize_ternary_real(gu, dw, hidden):
    """Quantize real BF16 weights to BitNet b1.58 and the hidden vector to INT8.

    Weights use per-output-channel (per-row) absmean scaling: code = round(w/s)
    clamped to {-1,0,+1} (2-bit codes 1/2/0).  The hidden vector is quantized
    per-tensor to INT8.  The node CU 8 then runs the exact integer matvec that
    reference_ternary predicts, so this validates the RTL on real weights."""
    def qrow(row):
        scale = sum(abs(x) for x in row) / max(1, len(row))
        if scale == 0:
            scale = 1.0
        return [(1 if round(x / scale) >= 1 else
                 2 if round(x / scale) <= -1 else 0) for x in row]
    gu_f = [[_bf16_to_float(w) for w in r] for r in gu]
    dw_f = [[_bf16_to_float(w) for w in r] for r in dw]
    h_f = [_bf16_to_float(w) for w in hidden]
    mx = max(abs(x) for x in h_f) or 1.0
    h_q = [(int(round(x / mx * 127)) & 0xFF) for x in h_f]
    return [qrow(r) for r in gu_f], [qrow(r) for r in dw_f], h_q


def run(n, eff, cu, mxfp4_shift, gu, dw, hidden, mem_chan=1):
    import shutil
    width = WIDTHS[cu]
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT, exist_ok=True)
    pack_words([w for row in gu for w in row], os.path.join(OUT, "wu.hex"), width)
    pack_words([w for row in dw for w in row], os.path.join(OUT, "wd.hex"), width)
    pack_words(hidden, os.path.join(OUT, "x.hex"), width)

    vvp = os.path.join(OUT, "node.vvp")
    subprocess.run(
        ["iverilog", "-g2005", "-s", "tb_node", "-o", vvp,
         os.path.join(HERE, "tb_node.v"),
         os.path.join(HERE, "node.v"),
         os.path.join(HERE, "arith_unit.v"),
         os.path.join(HERE, "bf16_fma.v"),
         os.path.join(HERE, "fp16_fma.v"),
         os.path.join(HERE, "fp32_fma.v"),
         os.path.join(HERE, "fp64_fma.v"),
         os.path.join(HERE, "fma_core.v"),
         os.path.join(HERE, "int8_mac.v"),
         os.path.join(HERE, "int4_mac.v"),
         os.path.join(HERE, "fp4_mac.v"),
         os.path.join(HERE, "ternary_acc.v"),
         "-I", HERE,
         "-P", "tb_node.N=%d" % n,
         "-P", "tb_node.EFF=%d" % eff,
         "-P", "tb_node.CU_TYPE=%d" % cu,
         "-P", "tb_node.WIDTH=%d" % width,
         "-P", "tb_node.MEM_CHAN=%d" % mem_chan,
         "-P", "tb_node.MXFP4_SHIFT=%d" % mxfp4_shift],
        check=True)
    r = subprocess.run(["vvp", "node.vvp"], cwd=OUT, capture_output=True,
                       text=True, check=True)
    got = {}
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0] in ("R", "G", "U", "A"):
            try:
                got.setdefault(parts[0], {})[int(parts[1])] = int(parts[2], 16)
            except ValueError:
                got.setdefault(parts[0], {})[int(parts[1])] = -1  # x/z
    return got


def compare(stage, got, ref, width):
    digits = width // 4
    n = len(ref)
    fmt = "%0*x"
    mism = [i for i in range(n)
            if got.get(stage, {}).get(i, -2) != ref[i]]
    if mism:
        print("  [%s] MISMATCH %d/%d first=%s" % (stage, len(mism), n, mism[:4]))
        for i in mism[:4]:
            print("    %s[%d] rtl=%s ref=%s"
                  % (stage, i, fmt % (digits, got.get(stage, {}).get(i, 0)),
                     fmt % (digits, ref[i])))
        print("    rtl = %s" % " ".join(
            fmt % (digits, got.get(stage, {}).get(i, 0)) for i in range(min(n, 16))))
        print("    ref = %s" % " ".join(fmt % (digits, ref[i]) for i in range(min(n, 16))))
    return mism


def gen_random(cu, width, n, eff, rng):
    if cu == 0:
        gu = [[rand_bf16(rng) for _ in range(n)] for _ in range(2 * eff)]
        dw = [[rand_bf16(rng) for _ in range(eff)] for _ in range(n)]
        hidden = [rand_bf16(rng) for _ in range(n)]
    elif cu == 4:
        gu = [[rng.randint(-128, 127) & 0xFF for _ in range(n)] for _ in range(2 * eff)]
        dw = [[rng.randint(-128, 127) & 0xFF for _ in range(eff)] for _ in range(n)]
        hidden = [rng.randint(-128, 127) & 0xFF for _ in range(n)]
    elif cu in (1, 2, 3):
        import struct
        fmt = {1: "<e", 2: "<f", 3: "<d"}[cu]
        ufmt = {1: "<H", 2: "<I", 3: "<Q"}[cu]

        def rnd():
            return struct.unpack(ufmt, struct.pack(fmt, rng.uniform(-2.0, 2.0)))[0]
        gu = [[rnd() for _ in range(n)] for _ in range(2 * eff)]
        dw = [[rnd() for _ in range(eff)] for _ in range(n)]
        hidden = [rnd() for _ in range(n)]
    elif cu == 8:
        # BitNet b1.58: ternary weight codes {0:0, 1:+1, 2:-1} x INT8 hidden.
        gu = [[rng.choice((0, 1, 2)) for _ in range(n)] for _ in range(2 * eff)]
        dw = [[rng.choice((0, 1, 2)) for _ in range(eff)] for _ in range(n)]
        hidden = [rng.randint(-128, 127) & 0xFF for _ in range(n)]
    else:
        mask = (1 << width) - 1
        gu = [[rng.getrandbits(width) & mask for _ in range(n)] for _ in range(2 * eff)]
        dw = [[rng.getrandbits(width) & mask for _ in range(eff)] for _ in range(n)]
        hidden = [rng.getrandbits(width) & mask for _ in range(n)]
    return gu, dw, hidden


def main():
    args = sys.argv[1:]
    real = "--real" in args
    cu = 0
    if "--cu" in args:
        cu = int(args[args.index("--cu") + 1])
    if cu not in WIDTHS:
        print("unknown --cu %d (0..8)" % cu, file=sys.stderr)
        return 2
    width = WIDTHS[cu]
    mxfp4_shift = 0
    if "--mxfp4-shift" in args:
        mxfp4_shift = int(args[args.index("--mxfp4-shift") + 1])

    n, eff = 16, 8
    ref = None
    if real:
        if cu not in (0, 8):
            print("--real supports --cu 0 (BF16) or --cu 8 (ternary)", file=sys.stderr)
            return 2
        model = os.environ.get("PNM_MODEL_DIR")
        if not model or not os.path.isdir(model):
            print("--real needs PNM_MODEL_DIR=<checkpoint dir>", file=sys.stderr)
            return 2
        sys.path.insert(0, HERE)
        import real_decoder_block as rdb
        idx = rdb.load_index(model)
        gu = rdb.tensor3d_expert(model, idx,
                                 "model.language_model.layers.0.experts.gate_up_proj",
                                 2 * 704, 2816, 1, 2 * eff, n)[0]
        dw = rdb.tensor3d_expert(model, idx,
                                 "model.language_model.layers.0.experts.down_proj",
                                 2816, 704, 1, n, eff)[0]
        rows = rdb.embed_rows(model, idx,
                              "model.language_model.embed_tokens.weight",
                              [0], 2816, n)
        hidden = rdb.scaled_embed(rows[0])
        tag = "real L0 expert 0"
        if cu == 8:
            gu, dw, hidden = quantize_ternary_real(gu, dw, hidden)
            tag = "real L0 expert 0 (ternary b1.58)"
    else:
        rng = random.Random(11)
        gu, dw, hidden = gen_random(cu, width, n, eff, rng)
        tag = "random"

    if cu == 0:
        ref = reference(gu, dw, hidden)
    elif cu == 4:
        ref = reference_int8(gu, dw, hidden)
    elif cu == 8:
        ref = reference_ternary(gu, dw, hidden)

    # MEM_CHAN = multi-channel memory ingest width.  The expert result is
    # independent of how the hidden vector is banked, so every channel count
    # must reproduce the same oracle output.
    if "--mem-chan" in args:
        chans = [int(args[args.index("--mem-chan") + 1])]
    elif real:
        chans = [1]
    else:
        chans = [c for c in (1, 2, 4) if n % c == 0]

    print("node N=%d EFF=%d CU=%d WIDTH=%d (%s):" % (n, eff, cu, width, tag))

    all_ok = True
    for mc in chans:
        got = run(n, eff, cu, mxfp4_shift, gu, dw, hidden, mem_chan=mc)
        if ref is None:
            # smoke: elaboration + execution; all outputs must be defined
            ok = all(stage in got and len(got[stage]) == (n if stage == "R" else eff)
                     and all(v >= 0 for v in got[stage].values())
                     for stage in ("R", "G", "U", "A"))
            if not ok:
                print("  *** smoke FAIL (MEM_CHAN=%d): missing/undefined words ***" % mc)
                all_ok = False
                continue
            print("  MEM_CHAN=%d R[0..%d] = %s" % (mc, n - 1, " ".join(
                "%0*x" % (width // 4, got["R"][i]) for i in range(n))))
            continue
        m = sum(len(compare(s, got, r, width))
                for s, r in (("G", ref[0]), ("U", ref[1]), ("A", ref[2]), ("R", ref[3])))
        if m:
            print("  *** MEM_CHAN=%d: %d stage-word mismatches ***" % (mc, m))
            all_ok = False
        else:
            print("  MEM_CHAN=%d bit-exact" % mc)

    if not all_ok:
        return 1
    if ref is None:
        print("*** PASS: node CU=%d elaborates and runs across MEM_CHAN=%s "
              "(smoke; unit arithmetic covered by the CU testbench) ***" % (cu, chans))
    else:
        print("*** PASS: node %s gate/up/act/out bit-exact vs the CU=%d oracle "
              "across MEM_CHAN=%s ***" % (tag, cu, chans))
    return 0


if __name__ == "__main__":
    sys.exit(main())
