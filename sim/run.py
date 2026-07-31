#!/usr/bin/env python3
"""Build and run the PNM co-simulation (Python <> Verilog, no compiled bridge).

    python3 sim/run.py                          # 3x4x4 = 48 nodes, all scenarios
    python3 sim/run.py -l 8 -x 8 -y 8           # the 512-node reference chassis
    python3 sim/run.py --scenarios sweep stress --seed 1
    python3 sim/run.py --groups 8               # 8 parallel vvp slices

Pipeline (Paper.MD section 2.1-2.2 routing, section 2.9 doorbell):

    python stimulus ---------> verilog fabric ---------> python virtual units
    (AOT compiler/scheduler)   (pnm_top.v, real gates)   (doorbell + kernels)

  * gen_topology.py writes the paper-mirroring topology
  * run.py writes the injection program, the Python-side manifest (every
    flit, its destination, resident kernel + weights, payload, CRC, golden
    results) and the per-node backpressure schedule
  * the chassis is partitioned into contiguous layer slices (default: one
    per CPU core); each slice gets its own topology, stimulus and pure-
    Verilog harness (gen_tb.py), and its own vvp process, run in parallel
    (spine stages upstream of a destination layer are transparent
    pass-through, so per-slice delivery is byte-exact vs. the monolith)
  * each harness streams its stimulus at up to 1 byte/cycle with
    valid/ready flow control, applies the backpressure, and logs every
    delivered byte, cycle-stamped
  * Python parses the logs, runs each node's doorbell + resident kernel on
    what the hardware actually delivered, and checks everything against the
    manifest: byte-exact delivery, byte conservation, kernel results,
    doorbell rejection of corrupt messages, and per-packet latency

Scenarios:
    sweep    one flit to every node, idle fabric: exact closed-form latency
             (hop count x per-hop delay, Paper.MD section 2.5/3.4)
    load     500 flits, random destinations/kernels, slow-DMA backpressure
    hotspot  MoE hot expert (section 2.12): one node takes a large share of
             kilobyte-class tokens via the worst-case corner path
    stress   scaled mixed load: 4B..1KB payloads, corrupt-CRC negative
             tests (the doorbell must not fire, section 2.9), pass-through
    replay   run stress twice with the same seed; delivery.log must be
             bit-identical (section 2.10/4.3 deterministic replay)

Exits non-zero if any scenario fails.
"""
from __future__ import annotations

import argparse
import os
import random
import subprocess
import sys
from itertools import product
from pathlib import Path

import gen_topology
import gen_tb
from virtual_units import VirtualUnit, crc_bytes

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent
HDL = ROOT / "HDL"

FABRIC = ["flit_gate.v", "hfr.v", "z_ingress.v", "xy_turn.v", "node_eject.v"]

# CTRL field: {vc_class[7:6], op[5:4], rsvd[3:0]}  (HDL/pnm_defs.vh)
CTRL_COMPUTE_SPINE = 0x40   # VC_SPINE | OP_COMPUTE
CTRL_FORWARD_SPINE = 0x50   # VC_SPINE | OP_FORWARD (pass-through traffic)

KERNEL_MIX = ("dot", "sum", "accum", "echo")


# -- wire encoding ---------------------------------------------------------

def flit(layer: int, mod: int, ctrl: int, payload: list,
         corrupt: bool = False) -> list:
    """Encode one wire flit as [(data, sop, eop), ...].

    Wire layout (HDL/pnm_defs.vh):
        LAYER_ID | MODULE_ID | CTRL | LEN_LO | LEN_HI | payload | CRC_HI | CRC_LO
    The CRC is CRC-16/CCITT over [CTRL, LEN_LO, LEN_HI, payload] -- the
    message body the destination DMA sees after header stripping.

    corrupt=True flips a payload byte *after* the CRC is computed: delivery
    still happens (the fabric is pure transport), but the destination
    doorbell must refuse to fire (Paper.MD section 2.9).
    """
    body = [ctrl, len(payload) & 0xFF, (len(payload) >> 8) & 0xFF, *payload]
    hi, lo = crc_bytes(body)
    if corrupt and payload:
        body[2 + (len(payload) + 1) // 2] ^= 0xFF   # mid-payload, post-CRC
    wire = [layer, mod, *body, hi, lo]
    return [(b, i == 0, i == len(wire) - 1) for i, b in enumerate(wire)]


def write_stimulus(stream: list, path: Path) -> int:
    """Write a stimulus hex file; return total byte count."""
    words = [(d | (int(s) << 8) | (int(e) << 9)) for d, s, e in stream]
    path.write_text("".join(f"{w:03x}\n" for w in words), encoding="utf-8")
    return len(words)


# -- golden model (independent of VirtualUnit) -----------------------------

def golden(kernel: str, payload: list, weights: list, gstate: dict):
    """What the node's kernel *should* produce for this payload."""
    if kernel == "echo":
        return list(payload)
    if kernel == "sum":
        return sum(payload) & 0xFFFFFFFF
    if kernel == "accum":
        gstate["acc"] = (gstate.get("acc", 0) + sum(payload)) & 0xFFFFFFFF
        return gstate["acc"]
    if kernel == "dot":
        n = max(len(payload), len(weights))
        return sum((payload[i] if i < len(payload) else 0)
                   * (weights[i] if i < len(weights) else 0)
                   for i in range(n)) & 0xFFFFFFFF
    raise ValueError(kernel)


class Program:
    """Scenario under construction: stream + per-node manifest + tail."""

    def __init__(self, name: str, nodes: list, latency: str):
        self.name = name
        self.latency = latency            # "exact" | "bounded"
        self.stream: list = []
        self.manifest: dict = {}
        self.gstate: dict = {}
        self.tail: list = []              # expected tail packets (wire bytes)
        self.bp: dict = {}
        self.n_injected = 0
        # per-packet injection record: (dest layer | None for pass-through, wf)
        self.order: list = []
        for n in nodes:
            self.manifest[n] = {"kernel": "dot", "weights": [], "packets": []}
            self.gstate[n] = {}

    def program_node(self, node: tuple, kernel: str, weights: list) -> None:
        self.manifest[node]["kernel"] = kernel
        self.manifest[node]["weights"] = list(weights)

    def inject_routed(self, node: tuple, ctrl: int, payload: list,
                      corrupt: bool = False) -> None:
        l, x, y = node
        wf = flit(l + 1, (x << 4) | y, ctrl, payload, corrupt=corrupt)
        self.stream += wf
        entry = {"idx": self.n_injected, "wire_len": len(wf),
                 "dma": [b for b, _, _ in wf[2:]], "corrupt": corrupt,
                 "golden": None}
        if not corrupt:
            m = self.manifest[node]
            entry["golden"] = golden(m["kernel"], payload,
                                     m["weights"], self.gstate[node])
        self.manifest[node]["packets"].append(entry)
        self.order.append((l, wf, entry))
        self.n_injected += 1

    def inject_passthrough(self, payload: list) -> None:
        wf = flit(0xFF, 0xEE, CTRL_FORWARD_SPINE, payload)
        self.stream += wf
        entry = {"idx": self.n_injected, "wire": [b for b, _, _ in wf]}
        self.tail.append(entry)
        self.order.append((None, wf, entry))
        self.n_injected += 1


# -- scenarios --------------------------------------------------------------

def scenario_sweep(layers: int, bx: int, by: int, seed: int) -> Program:
    """One flit to every node; idle fabric (no backpressure).

    Every node runs a different resident kernel; with an idle fabric each
    packet's latency must equal the closed form exactly (Paper.MD 2.5):
    wire_len - 1 pipe stages + l spine hops + x X-lane hops.
    """
    nodes = [(l, x, y) for l, x, y in
             product(range(layers), range(bx), range(by))]
    rng = random.Random(seed)
    p = Program("sweep", nodes, latency="exact")
    for i, n in enumerate(nodes):
        kernel = KERNEL_MIX[i % len(KERNEL_MIX)]
        weights = [rng.randrange(256) for _ in range(16)]
        p.program_node(n, kernel, weights)
        p.bp[n] = 1
    for i, (l, x, y) in enumerate(nodes):
        payload = [(l * 16 + x * 4 + y + k) & 0xFF for k in range(16)]
        p.inject_routed((l, x, y), CTRL_COMPUTE_SPINE | (i & 0x0F), payload)
    return p


def scenario_load(layers: int, bx: int, by: int, seed: int,
                  flits: int = 500) -> Program:
    """Random destinations, mixed resident kernels, slow-DMA sinks."""
    nodes = [(l, x, y) for l, x, y in
             product(range(layers), range(bx), range(by))]
    rng = random.Random(seed)
    p = Program("load", nodes, latency="bounded")
    for n in nodes:
        p.program_node(n, rng.choice(KERNEL_MIX),
                       [rng.randrange(256) for _ in range(64)])
        p.bp[n] = rng.choice((1, 2, 4, 8))
    for i in range(flits):
        if i % 10 == 0:
            p.inject_passthrough([0xDE, 0xAD])
        else:
            n = rng.choice(nodes)
            payload = [rng.randrange(256) for _ in range(rng.randint(1, 64))]
            p.inject_routed(n, CTRL_COMPUTE_SPINE | (i & 0x0F), payload)
    return p


def scenario_hotspot(layers: int, bx: int, by: int, seed: int,
                     flits: int = 400, hot_frac: float = 0.35) -> Program:
    """MoE hot expert (Paper.MD 2.12): one corner node takes `hot_frac` of
    all traffic as kilobyte-class tokens, through the worst-case path in the
    chassis (last layer, last column, last row), with a slow 1-in-8 DMA.
    Remaining nodes take a Zipf-ish share of smaller messages.
    """
    nodes = [(l, x, y) for l, x, y in
             product(range(layers), range(bx), range(by))]
    rng = random.Random(seed)
    hot = (layers - 1, bx - 1, by - 1)
    cold = [n for n in nodes if n != hot]
    rng.shuffle(cold)
    cold_w = [1.0 / (r + 1) for r in range(len(cold))]
    p = Program("hotspot", nodes, latency="bounded")
    p.program_node(hot, "dot", [rng.randrange(256) for _ in range(1024)])
    p.bp[hot] = 8
    for n in cold:
        p.program_node(n, rng.choice(KERNEL_MIX),
                       [rng.randrange(256) for _ in range(128)])
        p.bp[n] = rng.choice((1, 2, 4))
    for i in range(flits):
        if i % 20 == 19:
            p.inject_passthrough([rng.randrange(256)
                                  for _ in range(rng.randint(2, 16))])
        elif rng.random() < hot_frac:
            payload = [rng.randrange(256) for _ in range(1024)]
            p.inject_routed(hot, CTRL_COMPUTE_SPINE | (i & 0x0F), payload)
        else:
            n = rng.choices(cold, weights=cold_w)[0]
            payload = [rng.randrange(256) for _ in range(rng.randint(16, 128))]
            p.inject_routed(n, CTRL_COMPUTE_SPINE | (i & 0x0F), payload)
    return p


def scenario_stress(layers: int, bx: int, by: int, seed: int,
                    flits: int | None = None) -> Program:
    """Full-chassis stress: scaled flit count, 4B..1KB payloads, ~3%
    corrupt-CRC messages (doorbell must reject, Paper.MD 2.9), ~5%
    pass-through, backpressure 1-in-{1,2,4,8} per node DMA."""
    nodes = [(l, x, y) for l, x, y in
             product(range(layers), range(bx), range(by))]
    rng = random.Random(seed)
    if flits is None:
        flits = min(24 * len(nodes), 3000)
    p = Program("stress", nodes, latency="bounded")
    for n in nodes:
        p.program_node(n, rng.choice(KERNEL_MIX),
                       [rng.randrange(256) for _ in range(1024)])
        p.bp[n] = rng.choice((1, 2, 4, 8))
    for i in range(flits):
        r = rng.random()
        if r < 0.05:
            p.inject_passthrough([rng.randrange(256)
                                  for _ in range(rng.randint(2, 32))])
            continue
        n = rng.choice(nodes)
        s = rng.random()
        if s < 0.60:
            plen = rng.randint(4, 32)
        elif s < 0.90:
            plen = rng.randint(33, 256)
        else:
            plen = 1024                       # kilobyte-class token (2.12)
        payload = [rng.randrange(256) for _ in range(plen)]
        corrupt = rng.random() < 0.03
        p.inject_routed(n, CTRL_COMPUTE_SPINE | (i & 0x0F), payload,
                        corrupt=corrupt)
    return p


# -- delivery.log parsing ---------------------------------------------------

def parse_delivery(path: Path) -> dict:
    """Reconstruct what the fabric delivered, with cycle stamps."""
    out = {"inject": [], "nodes": {}, "tail": [], "xres": {}, "yres": {}}
    for line in path.read_text(errors="ignore").splitlines():
        f = line.split()
        if not f:
            continue
        if f[0] == "I":                                   # I cyc d s e
            out["inject"].append(tuple(int(v) for v in f[1:5]))
        elif f[0] == "T":                                 # T cyc d s e
            out["tail"].append(tuple(int(v) for v in f[1:5]))
        elif f[0] == "X":                                 # X cyc l d s e
            out["xres"].setdefault(int(f[2]), []).append(
                (int(f[1]), int(f[3]), int(f[4]), int(f[5])))
        elif f[0] == "Y":                                 # Y cyc l x d s e
            out["yres"].setdefault((int(f[2]), int(f[3])), []).append(
                (int(f[1]), int(f[4]), int(f[5]), int(f[6])))
        elif f[0] == "N":                                 # N cyc l x y d s e
            key = (int(f[2]), int(f[3]), int(f[4]))
            out["nodes"].setdefault(key, []).append(
                (int(f[1]), int(f[5]), int(f[6]), int(f[7])))
    return out


def packetize(stream: list) -> list:
    """Group a (cyc, data, sop, eop) stream into packets with timing."""
    pkts, cur, sop_cyc = [], [], None
    for cyc, d, s, e in stream:
        if s:
            cur, sop_cyc = [], cyc
        cur.append(d)
        if e:
            pkts.append({"bytes": cur, "sop_cyc": sop_cyc, "eop_cyc": cyc})
    return pkts


def inject_table(stream: list) -> list:
    """Indexed injection record: pkt idx -> {sop_cyc, eop_cyc, len}."""
    tbl, sop_cyc, length = [], None, 0
    for cyc, _, s, e in stream:
        if s:
            sop_cyc, length = cyc, 0
        length += 1
        if e:
            tbl.append({"sop_cyc": sop_cyc, "eop_cyc": cyc, "len": length})
    return tbl


# -- verification -------------------------------------------------------------

def verify(delivered: dict, prog: Program, nodes: list,
           l_base: int = 0, expect_tail: bool = True) -> tuple:
    """Check hardware delivery against the manifest; run the doorbells.

    l_base: global id of this fabric slice's first layer.  Hops on spine
    stages upstream of the slice are transparent pass-through, so latency
    checks use l_eff = l - l_base (Paper.MD 2.5: hop count x per-hop delay
    is a compile-time sum over segments).
    expect_tail: only the slice owning the chassis tail (last layer group)
    expects pass-through traffic; all other slices must see none.

    Returns (errors, stats).
    """
    errors: list[str] = []
    stats = {"activations": 0, "rejections": 0, "latencies": [],
             "pkts": 0, "dma_bytes": 0}
    inj = inject_table(delivered["inject"])

    # injection <-> manifest agreement (this slice's routed + pass-through)
    n_routed = sum(len(prog.manifest[n]["packets"]) for n in nodes)
    n_tail = len(prog.tail) if expect_tail else 0
    if len(inj) != n_routed + n_tail:
        errors.append(f"inject: {len(inj)} packets on wire, manifest says "
                      f"{n_routed + n_tail}")

    # byte conservation: every injected byte delivered exactly once or
    # stripped as a source-routing header byte (LAYER at ingress, MODULE
    # at eject -- 2 per routed packet, corrupt or not)
    total_delivered = (
        sum(len(v) for v in delivered["nodes"].values())
        + len(delivered["tail"])
        + sum(len(v) for v in delivered["xres"].values())
        + sum(len(v) for v in delivered["yres"].values()))
    if len(delivered["inject"]) != total_delivered + 2 * n_routed:
        errors.append(f"byte conservation: {len(delivered['inject'])} injected, "
                      f"{total_delivered} delivered + {2 * n_routed} stripped")

    # per-node: byte-exact delivery, then doorbell + resident kernel
    for n in nodes:
        m = prog.manifest[n]
        got = packetize(delivered["nodes"].get(n, []))
        want = m["packets"]
        if [g["bytes"] for g in got] != [w["dma"] for w in want]:
            errors.append(f"{n}: byte-exact delivery mismatch "
                          f"({len(got)} pkts delivered, {len(want)} expected)")
            continue

        u = VirtualUnit(n, m["kernel"], m["weights"])
        for g in got:
            u.consume(g["bytes"])
        stats["activations"] += u.activations
        stats["rejections"] += u.rejections
        stats["pkts"] += len(want)
        stats["dma_bytes"] += sum(len(w["dma"]) for w in want)

        # doorbell accounting: corrupt messages rejected, good ones fired
        n_corrupt = sum(1 for w in want if w["corrupt"])
        if u.rejections != n_corrupt:
            errors.append(f"{n}: doorbell rejected {u.rejections}, "
                          f"expected {n_corrupt} ({u.reject_reasons[:2]})")
        if u.activations != len(want) - n_corrupt:
            errors.append(f"{n}: {u.activations} activations, "
                          f"expected {len(want) - n_corrupt}")

        # resident kernel executed correctly on hardware-delivered data
        golden_seq = [w["golden"] for w in want if not w["corrupt"]]
        if u.results != golden_seq:
            errors.append(f"{n}: kernel '{m['kernel']}' results mismatch "
                          f"({len(u.results)} vs {len(golden_seq)})")

        # per-packet latency against the closed form (Paper.MD 2.5/3.4)
        l, x, _ = n
        l_eff = l - l_base          # spine hops inside this slice
        for g, w in zip(got, want):
            sidx = w.get("sidx")    # injection index within this slice
            if sidx is None or sidx >= len(inj):
                errors.append(f"{n}: slice inject idx {sidx} out of table")
                continue
            t = inj[sidx]
            lat = g["eop_cyc"] - t["sop_cyc"]
            stats["latencies"].append(lat)
            if prog.latency == "exact":
                # idle fabric: wire_len-1 stages + l_eff spine + x X-hops
                expect = w["wire_len"] - 1 + l_eff + x
                if lat != expect:
                    errors.append(f"{n}: latency {lat} != closed form {expect}")
            else:
                # cannot beat the pipe: last wire byte needs l_eff+x HFR hops
                lower = (t["eop_cyc"] - t["sop_cyc"]) + l_eff + x
                if lat < lower:
                    errors.append(f"{n}: latency {lat} < pipe floor {lower}")

    # residual lanes must carry nothing (no misroutes)
    for k, v in delivered["xres"].items():
        if v:
            errors.append(f"xres_{k}: carried {len(v)} misrouted bytes")
    for k, v in delivered["yres"].items():
        if v:
            errors.append(f"yres_{k}: carried {len(v)} misrouted bytes")

    # spine tail: only the slice owning the chassis tail carries
    # pass-through traffic, and it must match byte-exactly
    tail_pkts = packetize(delivered["tail"])
    if expect_tail:
        if [g["bytes"] for g in tail_pkts] != [t["wire"] for t in prog.tail]:
            errors.append(f"tail: {len(tail_pkts)} pkts delivered, "
                          f"{len(prog.tail)} expected (or content mismatch)")
    elif tail_pkts:
        errors.append(f"tail: slice carried {len(tail_pkts)} unexpected "
                      "pass-through pkts (stream split bug?)")

    return errors, stats


def span_cycles(delivered: dict) -> tuple:
    """(first inject cycle, last activity cycle) across all ports."""
    first = min(c for c, _, _, _ in delivered["inject"])
    last = 0
    streams = list(delivered["nodes"].values()) \
        + list(delivered["xres"].values()) \
        + list(delivered["yres"].values()) \
        + [delivered["tail"], delivered["inject"]]
    for v in streams:
        for entry in v:
            last = max(last, entry[0])
    return first, last


# -- build / run (parallel layer-group slices) -------------------------------
#
# vvp is single-threaded.  The chassis is therefore partitioned into
# contiguous layer groups; each group gets its own pnm_top slice, stimulus
# (the packets destined to its layers, in original relative order;
# pass-through traffic goes to the last group, which owns the chassis tail)
# and its own vvp process.  Groups run concurrently, one vvp per CPU core.
#
# This is functionally exact for this fabric: spine stages upstream of the
# destination layer are transparent pass-through (they contribute fixed
# hops, never reorder or alter bytes), so every node receives the same bytes
# in the same order as in a monolithic simulation.  What is NOT modeled is
# cross-group spine contention coupling (a slow board in one group stalling
# traffic bound for another group) -- a compile-time scheduler concern
# (Paper.MD 2.8), not a gate-level correctness property.
#
# Latency checks remain physical per slice: l_eff = l - group_base (see
# verify()); the global closed form is the compile-time sum of slice forms.

def partition_layers(layers: int, groups: int) -> list:
    """Contiguous layer-id ranges, as equal in size as possible."""
    groups = max(1, min(groups, layers))
    base, rem = divmod(layers, groups)
    out, start = [], 0
    for g in range(groups):
        n = base + (1 if g < rem else 0)
        out.append(list(range(start, start + n)))
        start += n
    return out


def group_names(gi: int, groups: int) -> dict:
    if groups == 1:
        return {"top": "pnm_top.v", "tb": "tb_pnm.v", "stim": "stimulus.hex",
                "log": "delivery.log", "out": "tb_pnm.out"}
    return {"top": f"pnm_top_g{gi}.v", "tb": f"tb_pnm_g{gi}.v",
            "stim": f"stimulus_g{gi}.hex", "log": f"delivery_g{gi}.log",
            "out": f"tb_pnm_g{gi}.out"}


def run_one(prog: Program, nodes: list, dims: tuple, groups: int = 1,
            replays: int = 1) -> bool:
    """Generate per-slice inputs, simulate slices in parallel, verify."""
    layers, bx, by = dims
    layer_groups = partition_layers(layers, groups)

    # -- per-slice stimulus, topology, testbench -------------------------
    jobs = []
    for gi, lids in enumerate(layer_groups):
        nm = group_names(gi, len(layer_groups))
        stream = []
        sidx = 0                    # injection index within this slice
        for layer_key, wf, ref in prog.order:
            if layer_key is None:
                if gi == len(layer_groups) - 1:      # chassis tail owner
                    stream += wf
                    ref["sidx"] = sidx
                    sidx += 1
            elif layer_key in lids:
                stream += wf
                ref["sidx"] = sidx
                sidx += 1
        nbytes = write_stimulus(stream, HERE / nm["stim"])
        (HERE / nm["top"]).write_text(
            gen_topology.gen(lids, bx, by), encoding="utf-8")
        (HERE / nm["tb"]).write_text(
            gen_tb.gen(lids, bx, by, prog.bp, nbytes,
                       stim=nm["stim"], log=nm["log"]),
            encoding="utf-8")
        jobs.append({"gi": gi, "lids": lids, "nm": nm, "nbytes": nbytes})

    # -- compile (fast) ---------------------------------------------------
    for j in jobs:
        srcs = [j["nm"]["tb"], j["nm"]["top"]] + [str(HDL / f) for f in FABRIC]
        subprocess.run(["iverilog", "-g2005", f"-I{HDL}", "-s", "tb_pnm",
                        "-o", j["nm"]["out"], *srcs], check=True, cwd=HERE)

    # -- simulate: one vvp process per slice, concurrently ----------------
    ok = True
    logs_prev = None
    for _ in range(replays):
        procs = [subprocess.Popen(["vvp", j["nm"]["out"]],
                                  cwd=HERE, stdout=subprocess.DEVNULL)
                 for j in jobs]
        for j, p in zip(jobs, procs):
            if p.wait() != 0:
                print(f"  group {j['gi']}: vvp exited nonzero")
                ok = False
        logs = [(HERE / j["nm"]["log"]).read_bytes() for j in jobs]
        if logs_prev is not None and logs != logs_prev:
            print("  FAIL: replay divergence -- delivery logs differ between "
                  "identical runs (determinism violated)")
            ok = False
        logs_prev = logs
    if replays == 2 and ok:
        print(f"  replay: {len(jobs)} slice log(s) bit-identical across "
              f"2 runs ({sum(len(b) for b in logs_prev)} bytes)")
    if not ok:
        return False

    # -- verify per slice, aggregate --------------------------------------
    all_errors: list[str] = []
    stats = {"activations": 0, "rejections": 0, "latencies": [],
             "pkts": 0, "dma_bytes": 0}
    max_span = 1
    for j in jobs:
        lids = j["lids"]
        gnodes = [(l, x, y) for l in lids for x in range(bx)
                  for y in range(by)]
        delivered = parse_delivery(HERE / j["nm"]["log"])
        errors, st = verify(delivered, prog, gnodes, l_base=lids[0],
                            expect_tail=(j["gi"] == len(jobs) - 1))
        all_errors += [f"[g{j['gi']}] {e}" for e in errors]
        for k in stats:
            stats[k] += st[k]
        if j["nbytes"]:
            first, last = span_cycles(delivered)
            max_span = max(max_span, last - first)
        if len(jobs) > 1:
            print(f"  slice g{j['gi']}: layers {lids[0]}..{lids[-1]}, "
                  f"{j['nbytes']} wire bytes")

    lat = stats["latencies"]
    lat_s = (f"min/mean/max {min(lat)}/{sum(lat) // len(lat)}/{max(lat)} cyc"
             if lat else "n/a")
    print(f"  fabric: {len(jobs)} slice(s) in parallel, worst span "
          f"{max_span} cycles, {len(prog.stream) / max_span:.2f} wire "
          "bytes/cycle sustained")
    print(f"  nodes: {stats['activations']} doorbell activations, "
          f"{stats['rejections']} corrupt rejected, "
          f"{stats['pkts']} packets, {stats['dma_bytes']} DMA bytes")
    print(f"  latency: {lat_s}")

    if all_errors:
        print(f"  FAIL ({len(all_errors)} problems):")
        for e in all_errors[:12]:
            print(f"    - {e}")
        return False
    print("  PASS: byte-exact delivery, kernels correct, zero drops, "
          "zero misroutes")
    return True


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("-l", "--layers", type=int, default=3)
    ap.add_argument("-x", "--board-x", type=int, default=4)
    ap.add_argument("-y", "--board-y", type=int, default=4)
    ap.add_argument("--scenarios", nargs="+",
                    default=["sweep", "load", "hotspot", "stress", "replay"])
    ap.add_argument("--seed", type=int, default=0xC0FFEE)
    ap.add_argument("--flits", type=int, default=None,
                    help="override flit count for load/hotspot/stress")
    ap.add_argument("--hot-frac", type=float, default=0.35,
                    help="hot-expert traffic share for hotspot")
    ap.add_argument("--groups", type=int, default=None,
                    help="partition layers into G slices, one parallel vvp "
                         "process each (default: min(layers, cpu_count))")
    args = ap.parse_args(argv)
    os.chdir(HERE)

    layers, bx, by = args.layers, args.board_x, args.board_y
    dims = (layers, bx, by)
    nodes = [(l, x, y) for l, x, y in
             product(range(layers), range(bx), range(by))]
    groups = args.groups or min(layers, os.cpu_count() or 1)

    (HERE / "pnm_top_params.py").write_text(
        "# AUTO-GENERATED by sim/gen_topology.py -- do not edit by hand.\n"
        f"LAYERS = {layers}\nBOARD_X = {bx}\nBOARD_Y = {by}\n"
        f"NODES = {layers * bx * by}\nGROUPS = {groups}\n", encoding="utf-8")

    builders = {
        "sweep": lambda: scenario_sweep(layers, bx, by, args.seed),
        "load": lambda: scenario_load(layers, bx, by, args.seed,
                                      args.flits or 500),
        "hotspot": lambda: scenario_hotspot(layers, bx, by, args.seed,
                                            args.flits or 400, args.hot_frac),
        "stress": lambda: scenario_stress(layers, bx, by, args.seed,
                                          args.flits),
        # replay: stress with a reduced default flit count (it runs twice)
        "replay": lambda: scenario_stress(layers, bx, by, args.seed,
                                          args.flits or 300),
    }

    total_fail = 0
    for name in args.scenarios:
        if name not in builders:
            print(f"unknown scenario: {name}")
            return 2
        prog = builders[name]()
        n_routed = sum(len(v["packets"]) for v in prog.manifest.values())
        print(f"\n=== scenario '{name}': {n_routed} routed + "
              f"{len(prog.tail)} pass-through flits, {len(prog.stream)} wire "
              f"bytes, {layers}x{bx}x{by} = {len(nodes)} nodes, "
              f"{groups} slice(s) ===")
        ok = run_one(prog, nodes, dims, groups=groups,
                     replays=2 if name == "replay" else 1)
        total_fail += 0 if ok else 1

    print("\n" + ("ALL SCENARIOS PASSED" if total_fail == 0
                  else f"{total_fail} SCENARIO(S) FAILED"))
    return 0 if total_fail == 0 else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
