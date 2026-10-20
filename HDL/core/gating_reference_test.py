#!/usr/bin/env python3
"""gating_reference_test.py — RTL validation for the Gating ASIC used by the
pnmgate harness.

Boots the persistent gating-ASIC server (tb_gating_server.v + gating_asic.v +
moe_gating.v + bf16_fma.v + fma_core.v) with a weight file and streams ONE
request through it, then compares every router logit bit-for-bit against the
exact BF16 oracle `acc = op_fma(w, h, acc)` (fused multiply-add accumulation —
the same single-rounding semantics as moe_gating's bf16_fma datapath).

Usage (inside `nix develop`):
    python3 HDL/core/gating_reference_test.py            # small E=8 W=16 case
    PNM_MODEL_DIR=/data/gemma4_dl/complete \
      python3 HDL/core/gating_reference_test.py --real   # full 128x2816, real L0

The --real mode slices the real layer-0 router.proj.weight from the checkpoint
(so the ASIC arithmetic is exercised on real-lived magnitudes) with a
deterministic pseudo-random hidden vector.
"""
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("GATING_REF_OUT", "/tmp/pnm_gating_ref")


def bf16_word(u):
    return "%04x" % u


def pack_words(words, path):
    with open(path, "w") as f:
        for w in words:
            f.write(bf16_word(w) + "\n")


def rand_bf16(rng, lo=-8, hi=8):
    from bf16_fp_ref import cls
    while True:
        u = rng.getrandbits(16)
        if cls(u) == 1:
            e = ((u >> 7) & 0xFF) - 127
            if lo <= e <= hi:
                return u


def run_server(exps, width, topk, layer, req_hidden, weights):
    import shutil
    shutil.rmtree(OUT, ignore_errors=True)
    os.makedirs(OUT, exist_ok=True)
    pack_words(weights, os.path.join(OUT, "w_0.hex"))
    pack_words(req_hidden, os.path.join(OUT, "h_0.hex"))

    vvp = os.path.join(OUT, "server.vvp")
    subprocess.run(
        ["iverilog", "-g2005", "-s", "tb_gating_server", "-o", vvp,
         os.path.join(HERE, "tb_gating_server.v"),
         os.path.join(HERE, "gating_asic.v"),
         os.path.join(HERE, "moe_gating.v"),
         os.path.join(HERE, "arith_unit.v"),
         os.path.join(HERE, "bf16_fma.v"),
         os.path.join(HERE, "fma_core.v"),
         "-P", "tb_gating_server.NUM_EXPERTS=%d" % exps,
         "-P", "tb_gating_server.HIDDEN_DIM=%d" % width,
         "-P", "tb_gating_server.TOP_K=%d" % topk,
         "-P", "tb_gating_server.ADDR_BITS=%d" % max(12, (exps * width - 1).bit_length()),
         "-P", "tb_gating_server.LAYER=%d" % layer,
         "-P", "tb_gating_server.MAXREQ=1"],
        check=True)

    proc = subprocess.Popen(["vvp", "server.vvp"], cwd=OUT,
                            stdout=subprocess.DEVNULL,
                            stderr=subprocess.DEVNULL)
    import time
    t0 = time.monotonic()
    ready = False
    while time.monotonic() - t0 < 600:
        if os.path.exists(os.path.join(OUT, "status.txt")):
            ready = True
            break
        if proc.poll() is not None:
            break
        time.sleep(0.05)
    if not ready:
        proc.kill()
        raise RuntimeError("ASIC did not boot")

    # fire request 0
    open(os.path.join(OUT, "req_0.go"), "w").close()
    # wait for completion marker
    t0 = time.monotonic()
    while time.monotonic() - t0 < 600:
        if os.path.exists(os.path.join(OUT, "res_0.done")):
            break
        if proc.poll() is not None:
            break
        time.sleep(0.05)
    if not os.path.exists(os.path.join(OUT, "res_0.done")):
        proc.kill()
        raise RuntimeError("ASIC did not serve request")
    proc.wait(timeout=60)
    with open(os.path.join(OUT, "res_0.txt")) as f:
        lines = f.read().splitlines()
    ids = [int(x) for x in lines[0].split()[1:]]
    logits = [int(x, 16) for x in lines[1].split()]
    return ids, logits


def reference_logits(weights, hidden):
    from bf16_fp_ref import op_fma
    E, W = len(weights), len(hidden)
    out = []
    for e in range(E):
        acc = 0
        for h in range(W):
            acc = op_fma(weights[e][h], hidden[h], acc)
        out.append(acc)
    return out


def topk_of(logits, k):
    from bf16_fp_ref import bf16_val
    order = sorted(range(len(logits)), key=lambda i: bf16_val(logits[i]), reverse=True)
    return order[:k], logits


def main():
    real = "--real" in sys.argv
    layer = 0
    if real:
        model = os.environ.get("PNM_MODEL_DIR")
        if not model or not os.path.isdir(model):
            print("--real needs PNM_MODEL_DIR=<checkpoint dir>", file=sys.stderr)
            return 2
        sys.path.insert(0, HERE)
        import real_decoder_block as rdb
        idxs = rdb.load_index(model)
        E, W, K = 128, 2816, 8
        rows = rdb.tensor_slice(model, idxs, "model.language_model.layers.0.router.proj.weight",
                                E, W, E, W)
        weights = rows
        rng = random.Random(7)
        hidden = [rand_bf16(rng) for _ in range(W)]
    else:
        E, W, K = 8, 16, 4
        rng = random.Random(3)
        weights = [[rand_bf16(rng) for _ in range(W)] for _ in range(E)]
        hidden = [rand_bf16(rng) for _ in range(W)]

    ids, logits = run_server(E, W, K, layer, hidden,
                             [w for row in weights for w in row])

    ref = reference_logits(weights, hidden)
    ref_ids = topk_of(ref, K)[0]

    mism = [i for i in range(E) if ref[i] != logits[i]]
    print("E=%d W=%d K=%d layer=%d" % (E, W, K, layer))
    print("rtl  topk = %s" % ids)
    print("ref  topk = %s" % ref_ids)
    if ids != ref_ids:
        print("*** TOP-K MISMATCH rtl=%s ref=%s ***" % (ids, ref_ids))
        return 1
    if mism:
        print("*** LOGIT MISMATCH on %d/%d experts, first: %s ***"
              % (len(mism), E, mism[:6]))
        for i in mism[:6]:
            print("    e=%d rtl=%04x ref=%04x" % (i, logits[i], ref[i]))
        return 1
    print("*** PASS: gating ASIC %dx%d logits bit-exact vs fused-FMA oracle ***"
          % (E, W))
    return 0


if __name__ == "__main__":
    sys.exit(main())