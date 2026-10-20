#!/usr/bin/env python3
"""node_mem_reference_test.py — RTL validation for the per-node multi-channel
memory (HDL/core/node_mem.v).

Boots the module with a random word image, issues an aligned burst read, and
compares the CHANNELS-wide egress against the interleave model
`beat b, lane c -> mem[base + b*CHANNELS + c]`.  Every channel count sweeps a
range of CAS latencies and burst lengths.

Usage (inside `nix develop`):
    python3 HDL/core/node_mem_reference_test.py
    python3 HDL/core/node_mem_reference_test.py --channels 4 --depth 64
"""
import argparse
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("NODE_MEM_OUT", "/tmp/pnm_node_mem")


def run_case(channels, depth, width, cas, rng):
    words = channels * depth
    mem = [rng.getrandbits(width) for _ in range(words)]
    req_words = channels * rng.randint(1, min(depth, 8))
    base = channels * rng.randint(0, depth - req_words // channels)
    with open(os.path.join(OUT, "mem.hex"), "w") as f:
        for w in mem:
            f.write("%0*x\n" % (width // 4, w))
    with open(os.path.join(OUT, "req.hex"), "w") as f:
        f.write("%x\n%x\n" % (base, req_words))

    vvp = os.path.join(OUT, "tb_node_mem.vvp")
    src = [os.path.join(HERE, "tb_node_mem.v"), os.path.join(HERE, "node_mem.v")]
    subprocess.check_call([
        "iverilog", "-g2005", "-o", vvp,
        "-Ptb_node_mem.CHANNELS=%d" % channels,
        "-Ptb_node_mem.DEPTH=%d" % depth,
        "-Ptb_node_mem.WIDTH=%d" % width,
        "-Ptb_node_mem.CAS=%d" % cas,
    ] + src)
    out = subprocess.check_output(["vvp", vvp], cwd=OUT).decode()

    got = []
    for line in out.splitlines():
        parts = line.split()
        if parts and parts[0] == "B":
            packed = int(parts[1], 16)
            lane_mask = (1 << width) - 1
            got += [(packed >> (c * width)) & lane_mask for c in range(channels)]
    want = mem[base:base + req_words]
    if got != want:
        for i, (g, w) in enumerate(zip(got, want)):
            if g != w:
                return False, ("channel burst mismatch at word %d: got %#x want %#x "
                               "(channels=%d cas=%d base=%d words=%d)"
                               % (i, g, w, channels, cas, base, req_words))
        return False, "length mismatch: got %d want %d" % (len(got), len(want))
    return True, "channels=%d depth=%d cas=%d base=%d words=%d ok" % (
        channels, depth, cas, base, req_words)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--channels", type=int, default=0, help="0 = sweep 2,4,8")
    ap.add_argument("--depth", type=int, default=64)
    ap.add_argument("--width", type=int, default=16)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    rng = random.Random(args.seed)
    channels_list = [args.channels] if args.channels else [2, 4, 8]
    total = passed = 0
    for ch in channels_list:
        for cas in (1, 2, 5):
            total += 1
            ok, msg = run_case(ch, args.depth, args.width, cas, rng)
            passed += 1 if ok else 0
            print(("  PASS  " if ok else "  FAIL  ") + msg)
    print()
    if passed == total:
        print("*** PASS: node_mem %d/%d bit-exact vs interleave oracle ***"
              % (passed, total))
        return 0
    print("*** FAIL: node_mem %d/%d ***" % (passed, total))
    return 1


if __name__ == "__main__":
    sys.exit(main())
