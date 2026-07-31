#!/usr/bin/env python3
"""Virtual execution units — the node's MAC ASIC + LPCAMM2 socket, in Python.

Each (layer, x, y) node in the generated topology owns a VirtualUnit. The
unit receives the DMA stream that *actually came through the Verilog fabric*
(delivery.log, written by tb_pnm.v) and executes its resident kernel on it.

This models the paper's per-node contract:

  * the doorbell discipline (Paper.MD §2.9): the DMA engine counts incoming
    bytes and keeps a running CRC; the node's resident function fires only
    when the byte count equals the header length field *and* the end-to-end
    CRC validates. A partial or corrupt message never fires the doorbell.
  * resident kernels with local state (§2.5 weight loading, §2.9 COMPUTE):
    each unit is programmed with a kernel and a local weight vector at
    "boot" (scenario generation), exactly like MoE expert weights loaded
    into the node's CAMM before execution begins.

    python (stimulus)  ->  verilog fabric (routing)  ->  python (kernels)
"""
from __future__ import annotations

# ── end-to-end message CRC (checked by the doorbell, Paper.MD §2.9) ──────
#
# CRC-16/CCITT-FALSE over the message body the node DMA actually sees:
# [CTRL, LEN_LO, LEN_HI, payload...].  The two header bytes (LAYER_ID,
# MODULE_ID) are source-routing bytes stripped in flight and are not covered.

def crc16(data) -> int:
    crc = 0xFFFF
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 \
                else (crc << 1) & 0xFFFF
    return crc


def crc_bytes(body: list) -> tuple:
    """(CRC_HI, CRC_LO) as carried on the wire, big-endian."""
    c = crc16(body)
    return (c >> 8) & 0xFF, c & 0xFF


# ── resident kernels (the node's hard-wired functions) ───────────────────

def k_echo(pkt: dict, state: dict) -> list:
    """Identity: echo the payload back byte-for-byte (validation node)."""
    return list(pkt["payload"])


def k_sum(pkt: dict, state: dict) -> int:
    """Reduction: byte checksum of the payload."""
    return sum(pkt["payload"]) & 0xFFFFFFFF


def k_accum(pkt: dict, state: dict) -> int:
    """Stateful accumulator: fold payload bytes into running CAMM state."""
    state["acc"] = (state.get("acc", 0) + sum(pkt["payload"])) & 0xFFFFFFFF
    return state["acc"]


def k_dot(pkt: dict, state: dict) -> int:
    """MAC array (Paper.MD §2.9 COMPUTE): dot product of the landed token
    against the node's resident weight vector (zero-padded / truncated).

    This is the canonical MoE-expert / stencil-row activation: int8 weights
    resident in local LPDDR6, payload streamed through the MAC array.
    """
    w = state["weights"]
    p = pkt["payload"]
    n = max(len(p), len(w))
    acc = 0
    for i in range(n):
        acc += (p[i] if i < len(p) else 0) * (w[i] if i < len(w) else 0)
    return acc & 0xFFFFFFFF


KERNELS = {"echo": k_echo, "sum": k_sum, "accum": k_accum, "dot": k_dot}


def decode(byte_list: list) -> dict:
    """Decode a node DMA stream: CTRL, LEN_LO, LEN_HI, payload..., CRC_HI, CRC_LO."""
    ctrl = byte_list[0]
    length = byte_list[1] | (byte_list[2] << 8)
    payload = byte_list[3:3 + length]
    crc = (byte_list[-2], byte_list[-1])
    return dict(ctrl=ctrl, length=length, payload=payload, crc=crc)


class VirtualUnit:
    """A node's MAC ASIC + LPCAMM2 socket running the doorbell discipline.

    consume() is the DMA engine + doorbell (Paper.MD §2.9): it only fires
    the resident kernel when the landed message is complete (byte count ==
    LEN field + framing) and the end-to-end CRC validates.  Statistics are
    kept so the testbench can prove that corrupt messages never fire.
    """

    def __init__(self, node: tuple, kernel: str = "dot", weights: list | None = None):
        self.node = node
        self.kernel_name = kernel
        self.kernel = KERNELS[kernel]
        self.state: dict = {"weights": list(weights or [])}
        self.packets: list = []     # decoded + accepted packets, arrival order
        self.results: list = []     # kernel results, arrival order
        self.activations = 0        # doorbell fires
        self.rejections = 0         # doorbell refused (corrupt / truncated)
        self.reject_reasons: list = []

    def consume(self, byte_list: list) -> dict | None:
        """Consume one hardware-delivered DMA packet; fire the doorbell.

        Returns the decoded packet if the doorbell fired, else None.
        """
        p = decode(byte_list)
        # (a) byte-count equality: complete delivery test (§2.9)
        if len(byte_list) != p["length"] + 5:
            self.rejections += 1
            self.reject_reasons.append(
                f"count {len(byte_list)} != len {p['length']} + 5")
            return None
        # (b) end-to-end CRC over [CTRL, LEN_LO, LEN_HI, payload]
        if (p["crc"][0] << 8 | p["crc"][1]) != crc16(byte_list[:-2]):
            self.rejections += 1
            self.reject_reasons.append("CRC mismatch")
            return None
        # doorbell fires: DISPATCH the resident kernel
        self.packets.append(p)
        self.results.append(self.kernel(p, self.state))
        self.activations += 1
        return p
