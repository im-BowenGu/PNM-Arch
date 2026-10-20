#!/usr/bin/env python3
"""bf16_fp_ref.py — exact BF16 arithmetic oracle + runner for HDL/core/bf16_fp.vh.

The core ops (mul/add/sub/div) are computed here with exact rational arithmetic
(`fractions.Fraction`) and rounded to nearest-even BF16.  The transcendental
ops (exp/rsqrt/tanh) mirror the *same fixed algorithm* the RTL uses, applying
the core ops in the same order.  Both are emitted as golden `R` vectors; the
Verilog DUT must reproduce them bit-for-bit under iverilog/vvp.

Example (inside `nix develop`):
    python3 HDL/core/bf16_fp_ref.py
"""
import os
import random
import struct
import subprocess
import sys
from fractions import Fraction

HERE = os.path.dirname(os.path.abspath(__file__))

ONE = 0x3F80
TWO = 0x4000
HALF = 0x3F00
LOG2E = 0x3FB9
NAN = 0x7FC0
INF = 0x7F80

OP_MUL, OP_ADD, OP_SUB, OP_DIV, OP_EXP, OP_RSQRT, OP_TANH = range(7)


def bf16_val(u):
    return struct.unpack("<f", struct.pack("<I", (u & 0xFFFF) << 16))[0]


def _rne(q):
    n, d = q.numerator, q.denominator
    m, rem = divmod(n, d)
    if 2 * rem > d or (2 * rem == d and (m & 1)):
        m += 1
    return m


def round_bf16(x):
    """Exact rational x -> nearest-even BF16 word (FTZ subnormals to zero)."""
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
    if e < -126:
        return sign  # FTZ
    m = _rne(a / Fraction(2) ** (e - 7))
    if m == 256:
        m, e = 128, e + 1
    expf = e + 127
    if expf >= 255:
        return sign | 0x7F80
    return sign | (expf << 7) | (m - 128)


def cls(x):
    if (x >> 7) & 0xFF == 0xFF:
        return 2 if (x & 0x7F) == 0 else 3
    if (x >> 7) & 0xFF == 0:
        return 0
    return 1


def op_mul(a, b):
    s = ((a ^ b) >> 15) & 1
    ca, cb = cls(a), cls(b)
    if ca == 3 or cb == 3:
        return NAN
    if ca == 0 or cb == 0:
        return s << 15
    if ca == 2 or cb == 2:
        return (s << 15) | 0x7F80
    return round_bf16(Fraction(bf16_val(a)) * Fraction(bf16_val(b)))


def op_add(a, b):
    ca, cb = cls(a), cls(b)
    if ca == 3 or cb == 3:
        return NAN
    if ca == 0 and cb == 0:
        return 0
    if ca == 0:
        return b
    if cb == 0:
        return a
    if ca == 2 or cb == 2:
        return INF
    return round_bf16(Fraction(bf16_val(a)) + Fraction(bf16_val(b)))


def op_sub(a, b):
    return op_add(a, b ^ 0x8000)


def op_fma(a, b, c):
    """Fused multiply-add: RNE(a*b + c) with a single rounding.

    Mirrors HDL/core/fma_core.v semantics (product + addend aligned inside an
    enlarged window, rounded once; subnormals flushed to zero).  Used as the
    accumulation oracle for moe_gating / gating_asic router logits, which run
    acc = fma(w, h, acc) in BF16.
    """
    ca, cb, cc = cls(a), cls(b), cls(c)
    if ca == 3 or cb == 3 or cc == 3:
        return NAN
    if (ca == 2 and cb == 0) or (ca == 0 and cb == 2):
        return NAN
    if ca == 2 or cb == 2:
        s = ((a ^ b) >> 15) & 1
        if cc == 2 and ((c >> 15) & 1) != s:
            return NAN
        return (s << 15) | 0x7F80
    if cc == 2:
        return c
    av = Fraction(bf16_val(a)) if ca == 1 else Fraction(0)
    bv = Fraction(bf16_val(b)) if cb == 1 else Fraction(0)
    cv = Fraction(bf16_val(c)) if cc == 1 else Fraction(0)
    # -0*b or 0*-b is -0; round_bf16 maps 0 -> +0 for both signs, so only the
    # magnitude matters for the finite path: keep the exact sum and round.
    return round_bf16(av * bv + cv)


def op_div(a, b):
    s = ((a ^ b) >> 15) & 1
    ca, cb = cls(a), cls(b)
    if ca == 3 or cb == 3:
        return NAN
    if ca == 0 and cb == 0:
        return NAN
    if cb == 0:
        return NAN if ca == 2 else (s << 15) | 0x7F80
    if ca == 0:
        return s << 15
    if ca == 2 and cb == 2:
        return NAN
    if ca == 2:
        return (s << 15) | 0x7F80
    if cb == 2:
        return s << 15
    return round_bf16(Fraction(bf16_val(a)) / Fraction(bf16_val(b)))


def msb(n):
    return n.bit_length() - 1


def int2bf(iv):
    s = iv < 0
    mag = -iv if s else iv
    if mag == 0:
        return 0
    L = msb(mag)
    e = L
    m9 = mag >> (L - 7) if L >= 7 else mag << (7 - L)
    # pack (no rounding, truncation matches RTL)
    ee = e + 127
    if ee >= 255:
        return (0x8000 if s else 0) | 0x7F80
    if ee < 1:
        return (0x8000 if s else 0)
    return (0x8000 if s else 0) | (ee << 7) | (m9 & 0x7F)


def to_signed(x):
    exp = (x >> 7) & 0xFF
    return exp - 127


def floor_bf(x):
    if cls(x) == 0:
        return 0
    s = (x >> 15) & 1
    sig = 0x80 | (x & 0x7F)
    e = to_signed(x)
    if e >= 7:
        k = sig << (e - 7)
        return -k if s else k
    if e >= 0:
        sh = 7 - e
        k = sig >> sh
        if s and (sig & ((1 << sh) - 1)) != 0:
            k += 1
        return -k if s else k
    return -1 if s else 0


EXP2F = [0x3F80, 0x3FA9, 0x3FD2, 0x3FFD, 0x4027, 0x4052, 0x407E, 0x40AB,
         0x40D9, 0x4109, 0x413A, 0x416C, 0x41A0, 0x41D5, 0x420B, 0x4243, 0x427C]


def op_exp(x):
    if cls(x) == 0:
        return ONE
    t = op_mul(x, LOG2E)
    k = floor_bf(t)
    f = op_sub(t, int2bf(k))
    if k > 128:
        return INF
    if k < -128:
        return 0
    ee = k + 127
    if k >= -126:
        p2k = (ee & 0xFF) << 7
    else:
        p2k = ONE
    idx = floor_bf(op_mul(f, 0x4180))
    if idx > 16:
        idx = 16
    return op_mul(p2k, EXP2F[idx])


def op_rsqrt(x):
    if cls(x) != 1:
        return 0
    e = to_signed(x)
    se = 127 - int(e / 2)  # RTL integer division truncates toward zero
    y = ((se & 0xFF) << 7) if se >= 1 else ONE
    for _ in range(4):
        inner = op_mul(op_mul(x, op_mul(y, y)), HALF)
        y = op_mul(y, op_sub(0x3FC0, inner))
    return y


def op_tanh(x):
    e2 = op_exp(op_mul(x, TWO))
    den = op_add(e2, ONE)
    r = op_div(TWO, den)
    return op_sub(ONE, r)


OPS = {OP_MUL: op_mul, OP_ADD: op_add, OP_SUB: op_sub, OP_DIV: op_div,
       OP_EXP: lambda a, b: op_exp(a), OP_RSQRT: lambda a, b: op_rsqrt(a),
       OP_TANH: lambda a, b: op_tanh(a)}


def rand_bf16(rng, lo_exp=-16, hi_exp=16):
    while True:
        u = rng.getrandbits(16)
        if cls(u) == 1:
            e = (u >> 7) & 0xFF
            if lo_exp + 127 <= e <= hi_exp + 127:
                return u


def build_vectors(seed=1):
    rng = random.Random(seed)
    vecs = []  # (op, a, b)
    edges = [0x0000, 0x8000, ONE, 0xBF80, TWO, 0xC000, HALF, 0x3F00, 0x4000,
             0x3F7F, 0x3F81]
    for op in (OP_MUL, OP_ADD, OP_SUB, OP_DIV):
        for a in edges:
            for b in edges:
                vecs.append((op, a, b))
        for _ in range(1500):
            vecs.append((op, rand_bf16(rng), rand_bf16(rng)))
    for _ in range(1500):  # exp
        vecs.append((OP_EXP, round_bf16(Fraction(rng.randint(-30000, 30000), 1000)), 0))
    for _ in range(1500):  # rsqrt, positive
        while True:
            a = rand_bf16(rng, -16, 16)
            if a & 0x8000 == 0 and cls(a) == 1:
                break
        vecs.append((OP_RSQRT, a, 0))
    for _ in range(1500):  # tanh
        vecs.append((OP_TANH, round_bf16(Fraction(rng.randint(-30000, 30000), 1000)), 0))
    return vecs


def emit(path, vecs):
    ops = [v[0] for v in vecs] + [0xF]
    aa = [v[1] for v in vecs] + [0]
    bb = [v[2] for v in vecs] + [0]
    with open(os.path.join(path, "bf16_ops.hex"), "w") as f:
        for x in ops:
            f.write("%x\n" % x)
    with open(os.path.join(path, "bf16_a.hex"), "w") as f:
        for x in aa:
            f.write("%04x\n" % x)
    with open(os.path.join(path, "bf16_b.hex"), "w") as f:
        for x in bb:
            f.write("%04x\n" % x)


def main():
    out = os.environ.get("BF16_FP_OUT", "/tmp/pnm_bf16_fp")
    os.makedirs(out, exist_ok=True)
    vecs = build_vectors()
    golden = [OPS[op](a, b) for (op, a, b) in vecs]
    emit(out, vecs)
    with open(os.path.join(out, "bf16_golden.hex"), "w") as f:
        for g in golden:
            f.write("%04x\n" % g)

    tb = os.path.join(HERE, "tb_bf16_fp.v")
    inc = os.path.join(HERE, "bf16_fp.vh")
    vvp = os.path.join(out, "tb_bf16_fp.vvp")
    subprocess.run(["iverilog", "-g2005", "-I", HERE, "-o", vvp, tb], check=True)
    r = subprocess.run(["vvp", "tb_bf16_fp.vvp"], cwd=out, capture_output=True,
                       text=True, check=True)
    got = {}
    for line in r.stdout.splitlines():
        parts = line.split()
        if len(parts) == 3 and parts[0] == "R":
            got[int(parts[1])] = int(parts[2], 16)
    if len(got) != len(golden):
        print("DUT produced %d results, expected %d" % (len(got), len(golden)))
        print(r.stdout[-2000:], r.stderr[-2000:], file=sys.stderr)
        return 1

    names = ["mul", "add", "sub", "div", "exp", "rsqrt", "tanh"]
    mism = 0
    per_op = [0] * 7
    for i, (op, a, b) in enumerate(vecs):
        if got[i] != golden[i]:
            mism += 1
            per_op[op] += 1
            if per_op[op] <= 6:
                print("MISMATCH %-5s a=%04x b=%04x rtl=%04x ref=%04x"
                      % (names[op], a, b, got[i], golden[i]))
    if mism:
        print("*** %d/%d mismatches %s ***"
              % (mism, len(vecs), ["%s=%d" % (names[i], per_op[i]) for i in range(7)]))
        return 1
    print("*** PASS: %d/%d bf16_fp vectors bit-exact ***" % (len(vecs), len(vecs)))
    for i in range(7):
        print("    %-5s ok" % names[i])
    return 0


if __name__ == "__main__":
    sys.exit(main())
