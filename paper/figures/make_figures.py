#!/usr/bin/env python3
"""Generate the manuscript figures (paper/figures/*.png).

Run standalone (`python3 paper/figures/make_figures.py`) or via
paper/build.py, which invokes this best-effort before compiling. On
failure (e.g. matplotlib unavailable) the pre-generated PNGs remain.
"""
import sys
from pathlib import Path

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.patches import Rectangle, FancyBboxPatch, FancyArrowPatch, Polygon
except ImportError:
    sys.exit(1)

OUT = Path(__file__).resolve().parent

plt.rcParams.update({
    "font.size": 8.5,
    "font.family": "DejaVu Sans",
    "axes.linewidth": 0.6,
    "savefig.dpi": 200,
})

BOX = dict(boxstyle="round,pad=0.25", lw=0.8, fc="#eef3fa", ec="#33475e")
BOX_IN = dict(boxstyle="round,pad=0.25", lw=0.8, fc="#f5f0e6", ec="#7a6a45")
BOX_OUT = dict(boxstyle="round,pad=0.25", lw=0.8, fc="#eaf3ea", ec="#3d6b3d")
ARROW = dict(arrowstyle="-|>", lw=0.9, color="#33475e", shrinkA=2, shrinkB=2)


def save(fig, name):
    fig.savefig(OUT / name, bbox_inches="tight", facecolor="white")
    plt.close(fig)


def fig_topology():
    fig, ax = plt.subplots(figsize=(7.0, 3.3))
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 60)
    ax.axis("off")
    n_layers, board_h, gap = 8, 5.4, 1.7
    x0, x1, spine_x = 32, 97, 24
    # router chip at the spine root
    ax.add_patch(FancyBboxPatch((spine_x - 11, 0.5), 22, 4.2,
                                boxstyle="round,pad=0.3", lw=1.0,
                                fc="#f5e3e3", ec="#8a3d3d"))
    ax.text(spine_x, 2.6, "router chip\nRV32 SoC + PCIe", ha="center",
            va="center", fontsize=7.5, color="#5c2222")
    ax.annotate("", xy=(spine_x, 6.2), xytext=(spine_x, 4.9), arrowprops=ARROW)
    # spine
    top = 4 + n_layers * (board_h + gap)
    ax.plot([spine_x, spine_x], [4.9, top - 1], color="#33475e", lw=2.2,
            solid_capstyle="butt")
    ax.text(spine_x - 3.4, (top + 4) / 2, "Z-axis spine\n≈2 TB/s per direction",
            rotation=90, ha="center", va="center", fontsize=7.5, color="#33475e")
    # host
    ax.annotate("", xy=(spine_x - 11.5, 2.6), xytext=(6, 2.6),
                arrowprops=ARROW)
    ax.text(5.5, 4.4, "host\nPCIe Gen5 ×16", fontsize=7.5, ha="left")
    for i in range(n_layers):
        y = 5 + i * (board_h + gap)
        ax.add_patch(Rectangle((x0, y), x1 - x0, board_h, fc="#eef3fa",
                               ec="#33475e", lw=0.8))
        # 8x8 node grid
        for cx in range(8):
            for cy in range(8):
                ax.plot(x0 + 5 + cx * 8.6, y + 1.0 + cy * 0.5, "o",
                        ms=1.4, color="#4f7dbc")
        # lxy repeater tap
        ax.add_patch(Rectangle((spine_x + 1.6, y + board_h / 2 - 1.0), 3.4, 2.0,
                               fc="#f7c873", ec="#9a6a1d", lw=0.8))
        ax.plot([spine_x, spine_x + 1.6], [y + board_h / 2] * 2,
                color="#33475e", lw=1.4)
        ax.plot([spine_x + 5.0, x0], [y + board_h / 2] * 2,
                color="#33475e", lw=1.4)
        ax.text(x0 - 1.5, y + board_h / 2, f"L{i}", ha="right", va="center",
                fontsize=7)
    ax.text((x0 + x1) / 2, top + 0.5,
            "each board: 8×8 = 64 nodes (LPDDR6 CAMM2 + DUV MAC ASIC)",
            ha="center", va="bottom", fontsize=8)
    ax.annotate("lxy_repeater\n(bitmask compare)", xy=(spine_x + 3.3, 5 + 5 * (board_h + gap) + board_h / 2 + 1.2),
                xytext=(2, 47), fontsize=7.5,
                arrowprops=dict(arrowstyle="-|>", lw=0.8, color="#9a6a1d"))
    save(fig, "fig_topology.png")


def _box(ax, xy, wh, text, style=BOX, fs=7.5):
    ax.add_patch(FancyBboxPatch(xy, wh[0], wh[1], **style))
    ax.text(xy[0] + wh[0] / 2, xy[1] + wh[1] / 2, text, ha="center",
            va="center", fontsize=fs)


def fig_pipeline():
    fig, ax = plt.subplots(figsize=(7.0, 2.5))
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 30)
    ax.axis("off")
    row1_y, h, gap = 17.5, 8.5, 2.6
    x = 1.0
    stages = [("model\nconfig.json\n+ safetensors", 15, BOX_IN),
              ("1 ingest", 12, BOX), ("2 partition", 12, BOX),
              ("3 kernel\nmapping", 12, BOX), ("4 coordinate\n+ route", 13, BOX),
              ("5 dispatch\nschedule", 13, BOX)]
    centers = []
    for label, w, style in stages:
        _box(ax, (x, row1_y), (w, h), label, style)
        centers.append((x, w))
        x += w + gap
    for i in range(len(stages) - 1):
        x0i, w0 = centers[i]
        x1i, w1 = centers[i + 1]
        ax.annotate("", xy=(x1i - gap / 2 - 0.2, row1_y + h / 2),
                    xytext=(x0i + w0 + gap / 2 + 0.2, row1_y + h / 2),
                    arrowprops=ARROW)
    # second row
    row2_y = 3.0
    x2 = 40.0
    second = [("emit: .pnm program\n+ weight images", 20),
              ("POST: routing tables\n+ weight upload", 22),
              ("execute: doorbell\nfires per token", 20)]
    c2 = []
    for label, w in second:
        _box(ax, (x2, row2_y), (w, h), label, BOX_OUT)
        c2.append((x2, w))
        x2 += w + gap
    for i in range(len(second) - 1):
        x0i, w0 = c2[i]
        x1i, w1 = c2[i + 1]
        ax.annotate("", xy=(x1i - gap / 2 - 0.2, row2_y + h / 2),
                    xytext=(x0i + w0 + gap / 2 + 0.2, row2_y + h / 2),
                    arrowprops=ARROW)
    # 5 -> emit
    x5, w5 = centers[5]
    ax.annotate("", xy=(c2[0][0] + 4, row2_y + h + 0.4),
                xytext=(x5 + w5 / 2, row1_y - 0.4),
                arrowprops=dict(arrowstyle="-|>", lw=0.9, color="#33475e",
                                connectionstyle="arc3,rad=0.25"))
    ax.text(2, row1_y + h + 1.6, "compile time (host, ahead of time)",
            fontsize=7.5, style="italic")
    ax.text(40, row2_y + h + 1.6,
            "boot + runtime (router chip + fabric)", fontsize=7.5,
            style="italic")
    save(fig, "fig_pipeline.png")


def fig_doorbell():
    fig, ax = plt.subplots(figsize=(7.0, 3.6))
    ax.set_xlim(0, 100)
    ax.set_ylim(0, 46)
    ax.axis("off")
    # byte strip
    segs = [("LAYER_ID", 1, "#dfe6ee"), ("MODULE_ID\n(DEST)", 1.4, "#f7c873"),
            ("CTRL", 1.0, "#cfe3f5"), ("LEN_LO\nLEN_HI", 1.6, "#cfe3f5"),
            ("payload (LEN bytes)", 12.0, "#eaf3ea"),
            ("CRC_HI\nCRC_LO", 1.6, "#f2cfcf")]
    total = sum(s[1] for s in segs)
    x, y0, hgt = 3.0, 34.0, 7.0
    width = 94.0
    xs = []
    for label, w, color in segs:
        ww = width * w / total
        ax.add_patch(Rectangle((x, y0), ww, hgt, fc=color, ec="#33475e", lw=0.8))
        ax.text(x + ww / 2, y0 + hgt / 2, label, ha="center", va="center",
                fontsize=6.8)
        xs.append((x, ww))
        x += ww
    # CRC coverage brace
    cov_x0 = xs[1][0]
    cov_x1 = xs[4][0] + xs[4][1]
    ax.plot([cov_x0, cov_x0, cov_x1, cov_x1], [y0 - 1.6, y0 - 3.2, y0 - 3.2,
            y0 - 1.6], color="#8a3d3d", lw=0.9)
    ax.text((cov_x0 + cov_x1) / 2, y0 - 5.4,
            "CRC-16/CCITT-FALSE covers [MODULE_ID, CTRL, LEN, payload]",
            ha="center", va="top", fontsize=7.2, color="#8a3d3d")
    ax.annotate("LAYER_ID stripped\nat the lxy_repeater", xy=(xs[0][0] + 1, y0 + hgt),
                xytext=(xs[0][0] - 1, y0 + hgt + 5), fontsize=6.8,
                arrowprops=dict(arrowstyle="-|>", lw=0.7, color="#33475e"))
    # conditions
    cy, ch = 8.0, 7.5
    conds = ["byte count == LEN + 6", "CRC validates", "DEST == LOCAL_MODULE"]
    cw = 24.0
    cxs = [3.0, 30.0, 57.0]
    ccenters = []
    for cx, label in zip(cxs, conds):
        _box(ax, (cx, cy), (cw, ch), label, BOX, fs=7.5)
        ccenters.append(cx + cw / 2)
    gx = 85.0
    ax.add_patch(plt.Circle((gx, cy + ch / 2), 3.4, fc="#eef3fa",
                            ec="#33475e", lw=1.0))
    ax.text(gx, cy + ch / 2, "AND", ha="center", va="center", fontsize=7.5)
    for cc in ccenters:
        ax.annotate("", xy=(gx - 3.6, cy + ch / 2),
                    xytext=(cc + cw / 2 + 0.6, cy + ch / 2),
                    arrowprops=dict(arrowstyle="-|>", lw=0.8, color="#33475e",
                                    connectionstyle="arc3,rad=0.12"))
    ax.annotate("", xy=(96.5, cy + ch / 2 + 4.5), xytext=(gx + 1.5, cy + ch / 2 + 2.4),
                arrowprops=ARROW)
    ax.text(96.5, cy + ch / 2 + 6.2, "DOORBELL_TRIG\n+ DOORBELL_ACK",
            ha="right", va="bottom", fontsize=7.5, color="#3d6b3d")
    # refusal path
    ax.annotate("", xy=(gx, cy - 2.6), xytext=(gx, cy + ch / 2 - 3.6),
                arrowprops=dict(arrowstyle="-|>", lw=0.8, color="#8a3d3d",
                                ls="dashed"))
    ax.text(gx - 1.5, cy - 3.4,
            "any condition fails: ACK withheld → source watchdog → NODE_ERR",
            ha="center", va="top", fontsize=7.2, color="#8a3d3d")
    ax.text(3, 43.5, "incoming flit (wire format, Section 2.9)", fontsize=7.5,
            style="italic")
    ax.text(3, 3.0, "three-condition fire (identical in RTL and Go twin)",
            fontsize=7.5, style="italic")
    save(fig, "fig_doorbell.png")


def fig_roofline():
    fig, ax = plt.subplots(figsize=(6.4, 3.6))
    x = [10, 1000]
    for bal, peak, color, label in [
            (1.5, 384.0, "#33475e", "FP64 (384 GFLOP/s, 1.5 FLOP/byte)"),
            (3.0, 768.0, "#4f7dbc", "FP16 (768 GFLOP/s, 3.0 FLOP/byte)"),
            (6.0, 1536.0, "#9a6a1d", "INT8 (1.5 TOPS, 6.0 FLOP/byte)")]:
        xs = [10, peak / bal, 1000]
        ys = [min(v * bal, peak) for v in xs]
        ax.plot(xs, ys, color=color, lw=1.6, label=label)
    for xpos, label, color, ls in [(512, "LPDDR6 node 512 GB/s (2 modules)", "#2f5d2f", "-"),
                                   (256, "LPDDR6 module 256 GB/s", "#3d6b3d", "--"),
                                   (90, "DDR5 90 GB/s", "#8a3d3d", "--")]:
        ax.axvline(xpos, color=color, lw=1.0, ls=ls)
        ax.text(xpos * 1.04, 14.0, label, rotation=90, fontsize=7,
                color=color, va="bottom")
    # workload intensity bands (slopes from origin)
    for lo, hi, color, label in [(0.3, 0.5, "#7a9e4f", "7-pt FP64 stencil\n0.3–0.5 FLOP/byte"),
                                 (1.0, 2.0, "#b06fa8", "MoE weight streaming\n1–2 FLOP/byte")]:
        pts = [(10, 10 * lo), (1000, 1000 * lo), (1000, 1000 * hi), (10, 10 * hi)]
        ax.add_patch(Polygon(pts, closed=True, fc=color, alpha=0.22, ec="none"))
        ax.text(180, 180 * ((lo + hi) / 2) * 1.5, label, fontsize=7,
                color="#3d5230", ha="left")
    ax.set_xscale("log")
    ax.set_yscale("log")
    ax.set_xlim(10, 1000)
    ax.set_ylim(10, 8000)
    ax.set_xlabel("memory bandwidth (GB/s); slope from the origin = arithmetic intensity")
    ax.set_ylabel("FLOP/s per node")
    ax.grid(True, which="major", lw=0.3, alpha=0.4)
    ax.legend(loc="lower right", fontsize=7, framealpha=0.9)
    save(fig, "fig_roofline.png")


def fig_latency():
    scenarios = ["sweep", "vcsweep", "load", "hotspot", "stress", "replay"]
    mins = [24, 24, 9, 27, 12, 14]
    means = [25, 25, 149, 2888, 671, 758]
    maxs = [27, 27, 558, 8279, 8279, 8255]
    xs = range(len(scenarios))
    w = 0.26
    fig, ax = plt.subplots(figsize=(6.4, 3.0))
    ax.bar([i - w for i in xs], mins, w, label="min", color="#7a9e4f")
    ax.bar(list(xs), means, w, label="mean", color="#4f7dbc")
    ax.bar([i + w for i in xs], maxs, w, label="max", color="#c55a5a")
    ax.set_yscale("log")
    ax.set_xticks(list(xs))
    ax.set_xticklabels(scenarios, fontsize=8)
    ax.set_ylabel("latency (cycles, log scale)")
    ax.set_ylim(5, 20000)
    ax.grid(axis="y", which="major", lw=0.3, alpha=0.4)
    ax.legend(fontsize=7.5, ncol=3, loc="upper left")
    ax.set_title("48-node co-simulation, seed 1 (Table 3)", fontsize=8.5)
    save(fig, "fig_latency.png")


def main():
    fig_topology()
    fig_pipeline()
    fig_doorbell()
    fig_roofline()
    fig_latency()
    print("figures written to", OUT)


if __name__ == "__main__":
    main()
