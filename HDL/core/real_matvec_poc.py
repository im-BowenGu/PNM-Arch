#!/usr/bin/env python3
"""real_matvec_poc.py — run a REAL Gemma-4 checkpoint tensor through the RTL
BF16 systolic MAC array (HDL/core/bf16_mac_array.v) under iverilog/vvp, and
check the RTL output against an exact BF16-FMA reference computed here.

This is a proof of concept that the project's BF16 FMA hardware executes real
model weights, bit-exactly, outside of the pure-Go pnmhost path.  It is NOT a
full transformer forward: it takes a 16x16 tile of a real weight matrix and a
real 16-wide activation (a scaled token embedding) and computes M @ X on the
systolic array.

Example (inside `nix develop`):
    python3 HDL/core/real_matvec_poc.py --model /data/gemma4_dl/complete
"""
import argparse
import json
import math
import os
import struct
import subprocess
import sys
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))


# --- safetensors access (header-only, absolute offsets) ---------------------

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
    if len(raw) != nitems * 2:
        raise IOError("short read")
    return [int.from_bytes(raw[i * 2:i * 2 + 2], "little") for i in range(nitems)]


def tensor_row_words(model, idx, name, row, ncols, count):
    """Return `count` BF16 words starting at (row, 0) of a 2-D BF16 tensor."""
    shard = idx[name]
    hdr_len, hdr = shard_header(model, shard)
    if name not in hdr:
        raise KeyError(name)
    base = hdr[name]["data_offsets"][0]
    off = base + row * ncols * 2
    return read_bf16(model, shard, hdr_len, off, count)


# --- exact BF16 arithmetic (reference) --------------------------------------

def bf16_val(u):
    return struct.unpack("<f", struct.pack("<I", (u & 0xFFFF) << 16))[0]


def _rne(q):
    n, d = q.numerator, q.denominator
    m, rem = divmod(n, d)
    if 2 * rem > d or (2 * rem == d and (m & 1)):
        m += 1
    return m


def round_bf16(x):
    """Round a Fraction to nearest-even BF16, returning the 16-bit word."""
    if x == 0:
        return 0
    neg = x < 0
    a = -x if neg else x
    sign = 0x8000 if neg else 0
    e = a.numerator.bit_length() - a.denominator.bit_length()
    while Fraction(2) ** (e + 1) <= a:
        e += 1
    while Fraction(2) ** e > a:
        e -= 1
    if e < -126:                                   # subnormal (FTZ=0 in bf16_fma)
        m = _rne(a / Fraction(2) ** 133)           # value = m * 2^-133
        if m >= 128:                               # rounds up to smallest normal
            return sign | (1 << 7)
        return sign | m
    m = _rne(a / Fraction(2) ** (e - 7))           # 1.mmmmmmm, m in [128,256)
    if m == 256:
        m, e = 128, e + 1
    expf = e + 127
    if expf >= 255:
        return sign | 0x7F80                       # overflow -> Inf
    return sign | (expf << 7) | (m - 128)


def fma_bf16(a, b, c):
    return round_bf16(Fraction(bf16_val(a)) * Fraction(bf16_val(b)) + Fraction(bf16_val(c)))


def rtl_dot(X, M, n):
    """result[o] = fold_i fma_bf16(X[i], M[o][i], acc) — the array's dataflow."""
    out = []
    for o in range(n):
        acc = 0
        for i in range(n):
            acc = fma_bf16(X[i], M[o][i], acc)
        out.append(acc)
    return out


def f32_dot(X, M, n):
    out = []
    for o in range(n):
        acc = 0.0
        for i in range(n):
            acc += bf16_val(X[i]) * bf16_val(M[o][i])
        out.append(acc)
    return out


# --- driver -----------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--model", default=os.environ.get("PNM_MODEL_DIR", "/data/gemma4_dl/complete"))
    ap.add_argument("--layer", type=int, default=0)
    ap.add_argument("--tensor", default="router.proj.weight",
                    help="suffix of the weight tensor (default router.proj.weight)")
    ap.add_argument("--token", type=int, default=15938, help="token id for the activation (default 15938 'Who')")
    ap.add_argument("--size", type=int, default=16)
    ap.add_argument("--out", default="/tmp/pnm_real_matvec")
    ap.add_argument("--no-run", action="store_true", help="emit files + reference only")
    args = ap.parse_args()

    n = args.size
    idx = load_index(args.model)
    wname = f"model.language_model.layers.{args.layer}.{args.tensor}"
    ename = "model.language_model.embed_tokens.weight"
    if wname not in idx:
        print(f"tensor not found: {wname}", file=sys.stderr)
        return 1

    whdr_len, whdr = shard_header(args.model, idx[wname])
    wcols = whdr[wname]["shape"][1]
    ehdr_len, ehdr = shard_header(args.model, idx[ename])
    ecols = ehdr[ename]["shape"][1]
    if ecols != wcols:
        print(f"dim mismatch embed={ecols} weight={wcols}", file=sys.stderr)
        return 1

    # M[o][i] = real weight tile; X[i] = real scaled embedding activation.
    M = [tensor_row_words(args.model, idx, wname, o, wcols, n) for o in range(n)]
    e = tensor_row_words(args.model, idx, ename, args.token, ecols, n)
    scale = math.sqrt(wcols)
    X = [round_bf16(Fraction(bf16_val(w) * scale)) for w in e]

    expected = rtl_dot(X, M, n)
    f32ref = f32_dot(X, M, n)

    os.makedirs(args.out, exist_ok=True)
    with open(os.path.join(args.out, "real_weights.hex"), "w") as f:
        for r in range(n):
            for c in range(n):
                f.write("%04x\n" % M[c][r])          # transpose: col c accumulates M[c]
    with open(os.path.join(args.out, "real_act.hex"), "w") as f:
        for i in range(n):
            f.write("%04x\n" % X[i])

    print(f"model     : {args.model}")
    print(f"weight    : {wname}  shape=({n},{n}) tile")
    print(f"activation: {ename}[{args.token}][0:{n}] * sqrt({wcols})")
    print(f"expected  : " + " ".join("%04x" % w for w in expected))
    print(f"f32 dot   : " + " ".join("%.4f" % v for v in f32ref))

    if args.no_run:
        return 0

    tb = os.path.join(HERE, "tb_bf16_mac_array_real.v")
    src = [os.path.join(HERE, s) for s in
           ("arith_unit.v", "bf16_mac_array.v", "bf16_fma.v", "fma_core.v", tb)]
    vvp = os.path.join(args.out, "tb_bf16_mac_array_real.vvp")
    subprocess.run(["iverilog", "-g2005", "-o", vvp, *src], check=True)
    r = subprocess.run(["vvp", "tb_bf16_mac_array_real.vvp"], cwd=args.out,
                       capture_output=True, text=True, check=True)

    got = {}
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0] == "REAL":
            got[int(parts[1])] = int(parts[2], 16)

    if len(got) != n:
        print("RTL produced no results:", r.stdout, r.stderr, file=sys.stderr)
        return 1

    print(f"rtl       : " + " ".join("%04x" % got[c] for c in range(n)))
    mism = [c for c in range(n) if got[c] != expected[c]]
    if mism:
        print(f"*** MISMATCH at columns {mism} ***")
        for c in mism:
            print(f"    col {c}: rtl={got[c]:04x} ref={expected[c]:04x}")
        return 1
    print(f"*** PASS: {n}/{n} real-weight BF16 MAC outputs match the RTL exactly ***")
    return 0


if __name__ == "__main__":
    sys.exit(main())
