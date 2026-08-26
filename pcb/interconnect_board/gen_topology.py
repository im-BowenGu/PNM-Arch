#!/usr/bin/env python3
"""Parameterized interconnect board topology generator.

Generates different board variants for the PNM interconnect fabric:
  - X2+LXY: LXY repeater at center, HFR pipe stage, dual NoB connectors
  - XY: Pure XY repeater at center (no Z-axis, no HFR)

Layout: spine pass-through connector at center, LXY repeaters flanking it,
HFR pipe stage below, NoB connectors on left/right edges, mezzanine
connectors on bottom edge (to pnm_node boards below).
Board count (num_layers) affects mezzanine connector count and spacing.

Usage:
  python3 gen_topology.py --variant x2_lxy --output .
  python3 gen_topology.py --variant xy --layers 2 --output .
  python3 gen_topology.py --variant x2_lxy --layers 8 --board-x 4 --board-y 4
"""

import argparse
import os
import uuid
import math
import re

def uid():
    return str(uuid.uuid4())

def mm_to_nm(mm):
    return int(mm * 1e6)


# ── Topology definitions ──────────────────────────────────────────────

TOPOLOGIES = {
    "x2_lxy": {
        "description": "X2+LXY: LXY repeater flanking center spine cutout, HFR pipe stage, dual NoB + mezz connectors",
        "components": [
            {"type": "spine_pass", "name": "J_SPINE", "role": "spine_pass_through"},
            {"type": "lxy",  "name": "U1", "role": "lxy_repeater_up"},
            {"type": "lxy",  "name": "U2", "role": "lxy_repeater_dn"},
            {"type": "hfr",  "name": "U3", "role": "hfr_pipe"},
            {"type": "mezz", "name": "J_MEZZ1", "role": "mezzanine_node1"},
            {"type": "mezz", "name": "J_MEZZ2", "role": "mezzanine_node2"},
            {"type": "nob",  "name": "J_NOB1", "role": "nob_x"},
            {"type": "nob",  "name": "J_NOB2", "role": "nob_y"},
        ],
        "signal_groups": {
            "spine_up": ["CLK", "RST_N", "DATA0", "DATA1", "DATA2", "DATA3",
                         "DATA4", "DATA5", "DATA6", "DATA7", "VALID", "SOP",
                         "EOP", "READY", "VC0", "VC1", "VDD0", "VDD1", "VSS",
                         "GND_STEEL", "SHIELD"],
            "spine_dn": ["CLK", "RST_N", "DATA0", "DATA1", "DATA2", "DATA3",
                         "DATA4", "DATA5", "DATA6", "DATA7", "VALID", "SOP",
                         "EOP", "READY", "VC0", "VC1", "VDD0", "VDD1", "VSS",
                         "GND_STEEL", "SHIELD"],
            "nob_down": ["D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7",
                          "VALID", "SOP", "EOP", "READY", "VC0", "VC1"],
            "nob_up": ["D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7",
                        "VALID", "SOP", "EOP", "READY", "VC0", "VC1"],
            "power": ["VDD", "VSS", "GND_STEEL", "SHIELD"],
            "control": ["CLK", "RST_N", "ROUTE_BITMAP"],
        },
    },
    "xy": {
        "description": "XY: Pure XY repeater at center (no Z-axis, no HFR)",
        "components": [
            {"type": "spine_pass", "name": "J_SPINE", "role": "spine_pass_through"},
            {"type": "lxy",  "name": "U1", "role": "xy_repeater"},
            {"type": "mezz", "name": "J_MEZZ1", "role": "mezzanine_node1"},
            {"type": "mezz", "name": "J_MEZZ2", "role": "mezzanine_node2"},
            {"type": "nob",  "name": "J_NOB1", "role": "nob_x"},
            {"type": "nob",  "name": "J_NOB2", "role": "nob_y"},
        ],
        "signal_groups": {
            "spine_up": ["CLK", "RST_N", "DATA0", "DATA1", "DATA2", "DATA3",
                         "DATA4", "DATA5", "DATA6", "DATA7", "VALID", "SOP",
                         "EOP", "READY", "VC0", "VC1", "VDD0", "VDD1", "VSS",
                         "GND_STEEL", "SHIELD"],
            "spine_dn": ["CLK", "RST_N", "DATA0", "DATA1", "DATA2", "DATA3",
                         "DATA4", "DATA5", "DATA6", "DATA7", "VALID", "SOP",
                         "EOP", "READY", "VC0", "VC1", "VDD0", "VDD1", "VSS",
                         "GND_STEEL", "SHIELD"],
            "nob_down": ["D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7",
                          "VALID", "SOP", "EOP", "READY", "VC0", "VC1"],
            "nob_up": ["D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7",
                        "VALID", "SOP", "EOP", "READY", "VC0", "VC1"],
            "power": ["VDD", "VSS", "GND_STEEL", "SHIELD"],
            "control": ["CLK", "RST_N", "ROUTE_BITMAP"],
        },
    },
}


# ── Symbol library (shared across variants) ───────────────────────────

SYMBOL_DEFS = {
    "mezz": {
        "sym_uuid": "de979f19-c30d-4c07-afe5-039cc76915a5",
        "cmp_uuid": "e66a8e1c-0d4e-487b-bd56-fd2bef9759e9",
        "variant_uuid": "a0000001-0000-4000-8000-000000000021",
        "item_uuid": "a0000001-0000-4000-8000-000000000022",
    },
    "lxy": {
        "sym_uuid": "6debbc07-d017-4798-a27f-847077fdaa93",
        "cmp_uuid": "23989f38-11e2-469b-862c-eaf66d20afe1",
        "variant_uuid": "a0000001-0000-4000-8000-000000000001",
        "item_uuid": "a0000001-0000-4000-8000-000000000002",
    },
    "hfr": {
        "sym_uuid": "c9a05b54-5bbc-447c-bda4-a1c770d623f4",
        "cmp_uuid": "f84c13cb-431a-491b-867e-bbeb7110ee90",
        "variant_uuid": "a0000001-0000-4000-8000-000000000011",
        "item_uuid": "a0000001-0000-4000-8000-000000000012",
    },
    "nob": {
        "sym_uuid": "356aa821-bf2e-45e6-805f-67f4c74f9028",
        "cmp_uuid": "b7af4d44-52e0-455e-b9b3-c36faaad257f",
        "variant_uuid": "a0000001-0000-4000-8000-000000000031",
        "item_uuid": "a0000001-0000-4000-8000-000000000032",
    },
    "spine_pass": {
        "sym_uuid": "1a2b3c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d",
        "cmp_uuid": "a0000001-0000-4000-8000-000000000042",
        "variant_uuid": "a0000001-0000-4000-8000-000000000043",
        "item_uuid": "a0000001-0000-4000-8000-000000000044",
    },
}


def parse_pin_positions(sym_uuid, lib_dir):
    """Parse pin positions from a symbol.lp file."""
    sym_file = os.path.join(lib_dir, "sym", sym_uuid, "symbol.lp")
    pins = {}
    with open(sym_file) as f:
        content = f.read()
    for m in re.finditer(
        r'\(pin\s+[0-9a-f-]+\s+\(name\s+"([^"]+)"\)\s+\(position\s+([-\d.]+)\s+([-\d.]+)\)',
        content
    ):
        pins[m.group(1)] = (float(m.group(2)), float(m.group(3)))
    return pins


def compute_absolute_pin_pos(sym_x, sym_y, mirror, local_x, local_y):
    """Compute absolute pin position (LibrePCB Transform::map)."""
    px = -local_x if mirror else local_x
    py = local_y
    return (sym_x + px, sym_y + py)


# ── Net signal definitions ────────────────────────────────────────────
# These map net UUIDs to net names for the circuit and schematic.
NET_SIGNALS = {
    "CLK":        "e2000001-0000-4000-8000-000000000001",
    "RST_N":      "e2000001-0000-4000-8000-000000000002",
    "VDD":        "e2000001-0000-4000-8000-000000000003",
    "VSS":        "e2000001-0000-4000-8000-000000000004",
    "GND_STEEL":  "e2000001-0000-4000-8000-000000000005",
    "SHIELD":     "e2000001-0000-4000-8000-000000000006",
}
# Generate net UUIDs for bus signals
_net_counter = 100
for prefix in ["SPINE_DATA", "NOB_D", "NOB_UP_D"]:
    for i in range(8):
        name = f"{prefix}{i}"
        _net_counter += 1
        NET_SIGNALS[name] = f"e2{_net_counter:06d}-4000-4000-8000-000000000001"
for name in ["SPINE_VALID", "SPINE_SOP", "SPINE_EOP", "SPINE_READY", "SPINE_VC0", "SPINE_VC1",
             "NOB_VALID", "NOB_SOP", "NOB_EOP", "NOB_READY", "NOB_VC0", "NOB_VC1",
             "NOB_UP_VALID", "NOB_UP_SOP", "NOB_UP_EOP", "NOB_UP_READY", "NOB_UP_VC0", "NOB_UP_VC1"]:
    _net_counter += 1
    NET_SIGNALS[name] = f"e2{_net_counter:06d}-4000-4000-8000-000000000001"
# Dedicated nets for bus-level signals (single-pin representation of multi-bit buses)
# and configuration inputs (route_bitmap strapped via pull resistors)
for name in ["SPIN_DATA_BUS", "SPOUT_DATA_BUS", "NOB_DATA_BUS", "NOB_UP_DATA_BUS",
             "SPUP_DATA_BUS", "SPUP_IN_DATA_BUS",
             "HFR_IN_DATA_BUS", "HFR_OUT_DATA_BUS",
             "ROUTE_BITMAP_LXY", "ROUTE_BITMAP_HFR",
             "SPINE_UP_CLK", "SPINE_UP_RST_N", "SPINE_DN_CLK", "SPINE_DN_RST_N"]:
    _net_counter += 1
    NET_SIGNALS[name] = f"e2{_net_counter:06d}-4000-4000-8000-000000000001"


# ── Symbol pin UUIDs ──────────────────────────────────────────────────
# Extracted from symbol.lp files — needed for netsegment wiring.

SYMBOL_PIN_UUIDS = {
    "mezz": {
        "CLK": "7b28f43c-8841-4a7f-9977-f6e0f3c2c2af",
        "RST_N": "b83a7caa-7416-4606-b2ca-4b1f7d505b4d",
        "SPINE_DATA0": "e67ea0bb-e039-44fa-a973-4324ffd96b08",
        "SPINE_DATA1": "d1a90389-428d-4ba7-805f-80bbe80ce6e7",
        "SPINE_DATA2": "66f3440f-d79a-4438-9cd8-da23d2ebb77b",
        "SPINE_DATA3": "5106aaf1-00e6-4c84-8f58-b3680d98aa8d",
        "SPINE_DATA4": "38157b7c-f656-4ba9-abb2-11cf09a15105",
        "SPINE_DATA5": "e149ca5b-2191-4a0f-9268-8a5531020ecc",
        "SPINE_DATA6": "5efa3fdb-2fd7-44d6-9896-0b556a14c799",
        "SPINE_DATA7": "bcda9c3d-d8a6-43de-900f-6bf8e909ae3f",
        "SPINE_VALID": "5f57f161-2303-41a8-b6dc-11d9739c8330",
        "SPINE_SOP": "73f95b11-f98b-40a6-a102-014b5d99667d",
        "SPINE_EOP": "e9f88f17-5508-48fb-80bd-9fc41d0f4d67",
        "SPINE_READY": "cbc97563-9757-476f-82d5-60a8d85b3755",
        "SPINE_VC0": "0852b92c-9e71-476c-ae27-9058dabdd2e6",
        "SPINE_VC1": "1ac2b497-5175-4ae1-8d94-38ce028d347c",
        "VDD0": "aba5e036-0f10-4460-b607-f83da011d28c",
        "VDD1": "3003390c-097e-45a6-a4be-28b01867ace7",
        "VDD2": "c79d1527-0cd5-4435-8db8-2a7191d42b75",
        "VDD3": "f7c60e56-ce7b-45d5-be0d-9bd99f2fbab5",
        "VSS0": "5f244c0e-c833-4b98-914c-af5d9acf0b7a",
        "VSS1": "729924f3-4aa4-44e4-aa67-c2f844fc77c6",
        "VSS2": "e86ed932-3255-41de-81c3-5ea1ec1cb490",
        "VSS3": "84b6c62a-f163-4e38-b826-8a0d6689e089",
        "VSS4": "efab35c4-c080-415a-9366-d7b211906b1f",
        "VSS5": "750182ce-3538-4ec2-b8cf-8b0ea529f54b",
        "VSS6": "85eaf246-114a-4e30-885b-384a2cc52b96",
        "VSS7": "39ba5949-3b18-4a4a-a0df-4236a030da68",
        "GND_STEEL": "7f00d9b3-6bda-481c-a8f5-a274295a7001",
        "SHIELD": "5a3e3230-b7d2-4485-9971-0ef67b355358",
    },
    "lxy": {
        "clk": "46386ecf-b3e0-4f21-9f41-c9fa19ed65ba",
        "rst_n": "2d26dd69-a896-4791-8cc6-4999cdae407a",
        "route_bitmap": "a5f5f66d-b1e4-41e4-88cb-b19be575df4f",
        "spin_data": "1763d6cc-84db-450c-8047-509ed64c9d4c",
        "spin_valid": "d3c0dcb9-1bb1-4446-9900-7d3c44eed15c",
        "spin_sop": "447fc185-fce4-4703-9d9e-ba12e35d347e",
        "spin_eop": "1f372e87-16e0-4373-b47a-de01adf62bb3",
        "spin_ready": "82cc1c0f-2a0d-459c-9805-8e6e42d6a653",
        "spin_vc": "6cb87bb3-14fb-4752-9916-9995b2fb1e06",
        "spout_data": "8bdebcc2-1b36-40e1-85fc-a0715ec29afc",
        "spout_valid": "f690047d-68f4-442f-850b-c4fef7d20795",
        "spout_sop": "beddd9db-0479-4257-b3e1-5ddfda70242f",
        "spout_eop": "523742e4-402c-4e03-8c55-70955d862990",
        "spout_ready": "1f17f876-9f4c-45b4-adf5-f39436ea348e",
        "spout_vc": "7b9a6624-6ac3-4d80-8dbb-7149128d4d6b",
        "nob_data": "7d2ec2d5-f443-42d0-8ccf-4c216f0a0066",
        "nob_valid": "83e35fa9-3529-428b-b9ab-106b0a3fdb39",
        "nob_sop": "00ff7fa2-a685-485c-84da-ef0dac8718f1",
        "nob_eop": "0cdec99a-60ae-4391-898f-3ccdca8e8f0b",
        "nob_ready": "ddb17070-2964-4bca-9879-9d4d9a4861ad",
        "nob_vc": "c13d3599-25fa-4765-8777-08156a190759",
        "nob_up_data": "bbefac4d-251c-4bc6-bff0-101de8254cfd",
        "nob_up_valid": "3c5a1a73-010f-4b88-a63f-b8833025e9d3",
        "nob_up_sop": "397a6ded-2365-4a2b-a6d1-fda15f267443",
        "nob_up_eop": "2d4e4d1d-1e79-4cac-9843-5fa35e2f8094",
        "nob_up_ready": "a2c87517-01da-4fc6-9f25-8fd08b251004",
        "nob_up_vc": "9e05c0b3-b103-46d3-9662-702d4c94486e",
        "spup_in_data": "73697cf9-511a-4f43-b62d-ff317b7341b0",
        "spup_in_valid": "f43d1a61-b0a4-4276-9b74-a6049073f3a8",
        "spup_in_sop": "21725cab-c6e8-44bc-9ae7-fca543cd34cf",
        "spup_in_eop": "8a1d72f6-c70f-45ad-b10c-4e7e425b3f0b",
        "spup_in_ready": "c3ee8509-8b3e-4d10-bd0f-dbdfc6671a09",
        "spup_in_vc": "8ef89ca5-29e0-463f-8236-c94e6e28af03",
        "spup_data": "96405acb-781b-431d-be51-292fe1f80311",
        "spup_valid": "43f55966-62e3-49cb-8840-717d53936591",
        "spup_sop": "b3a67e62-d4bf-4288-94df-76f5ce999bfd",
        "spup_eop": "71a15f46-b9e4-4733-a7fe-9d9e88adf2cc",
        "spup_ready": "d0cd13c7-d613-48a9-a9c8-bd10b2b32589",
        "spup_vc": "3f98712d-7d34-430e-b279-25ef1c805857",
    },
    "hfr": {
        "clk": "46386ecf-b3e0-4f21-9f41-c9fa19ed65ba",
        "rst_n": "2d26dd69-a896-4791-8cc6-4999cdae407a",
        "route_bitmap": "a5f5f66d-b1e4-41e4-88cb-b19be575df4f",
        "in_data": "9d57bbb5-fa2b-4f24-8f9c-0bcc12947c2a",
        "in_valid": "99a1831e-0834-47d2-a005-a1283c3d5768",
        "in_sop": "9577fbfc-3e62-473e-8e03-b16559125615",
        "in_eop": "19e96d3e-0c15-4e79-84de-1f1fd562ab33",
        "in_ready": "077fe962-9f66-40b4-9339-98bbb7e97f81",
        "in_vc": "3c6289c2-aabd-4381-8596-88bb3a084eaa",
        "out_data": "e3531c32-225f-446e-97fa-ed9c6e31c3a1",
        "out_valid": "c8998086-cb14-421a-b803-de919143b135",
        "out_sop": "d37519df-423c-4d73-93aa-ea13c7c0bccc",
        "out_eop": "227ec3e2-1e7b-4fae-94f7-80f0a803fa7b",
        "out_ready": "939aaa76-19af-48a5-bb6c-354e146b1188",
        "out_vc": "a466e366-0c4a-426c-89de-e3a179c1be07",
    },
    "nob": {
        "NOB_D0": "bf001e74-4db9-4f02-955a-495a53159e2f",
        "NOB_D1": "2ce34b7d-7559-4883-b97c-e961f522e2cb",
        "NOB_D2": "0fe636a6-55ab-4731-9bd1-fe3fbb25e492",
        "NOB_D3": "87f2b9ef-65ef-46c7-97af-097818f06fea",
        "NOB_D4": "9b0b9ec4-8857-4d12-bfc2-da496cca1ffb",
        "NOB_D5": "a1505c5c-52f5-4012-a237-7cad8f1ed155",
        "NOB_D6": "aedf84f8-3b0f-433f-80e9-1372e5c713a4",
        "NOB_D7": "e446fbd0-7fb4-44c6-a876-06022b335a36",
        "NOB_VALID": "449b7b79-e46d-42a1-8c60-1b522dd6b7cd",
        "NOB_SOP": "2941329f-8439-4f2f-ac39-a71f23a5a9ec",
        "NOB_EOP": "ec428a0d-ee07-492d-94b8-25d5d232e414",
        "NOB_READY": "cd7964c5-907d-42c2-897c-142795588a54",
        "NOB_VC0": "2ca5b5df-179e-46ee-a2a6-412673c811a3",
        "NOB_VC1": "99e25179-d3a6-4afa-b99b-61ba7a3d752a",
        "NOB_UP_D0": "aadde95c-5a9e-4eea-8cbd-8428d9d4216c",
        "NOB_UP_D1": "54dcb7cf-7149-4e1c-83fb-468ed2171f82",
        "NOB_UP_D2": "3a6cd065-98c0-408f-9a5d-8d629b9c2ede",
        "NOB_UP_D3": "ab9d5bf1-6470-49f7-a3bd-b5d78444a2d6",
        "NOB_UP_D4": "35e7f6b8-6cd2-4fc4-a558-c26b86f5ea60",
        "NOB_UP_D5": "7ec17550-312e-48c4-8d86-6a987f53166d",
        "NOB_UP_D6": "b1bec2cc-44e4-4d3a-8f1f-adca81e7bdf1",
        "NOB_UP_D7": "142e2fbb-c952-42ce-84fc-3594c00c1739",
        "NOB_UP_VALID": "e72c7d9c-2bd3-4de2-b625-8a28237a9092",
        "NOB_UP_SOP": "8406b433-4c1c-4f85-8b75-8db35d17d5e0",
        "NOB_UP_EOP": "29e3a147-48ab-4c62-b7aa-f8d30641f2b1",
        "NOB_UP_READY": "ebefa9b4-2d5f-4c90-ae22-98ac15deead0",
        "NOB_UP_VC0": "2bf2ef65-053c-49f3-a56a-5bfa43e11387",
        "NOB_UP_VC1": "99b504dc-6739-439e-be06-071373d525bf",
        "VDD0": "aba5e036-0f10-4460-b607-f83da011d28c",
        "VDD1": "3003390c-097e-45a6-a4be-28b01867ace7",
        "VSS0": "5f244c0e-c833-4b98-914c-af5d9acf0b7a",
        "VSS1": "729924f3-4aa4-44e4-aa67-c2f844fc77c6",
        "VSS2": "e86ed932-3255-41de-81c3-5ea1ec1cb490",
        "VSS3": "84b6c62a-f163-4e38-b826-8a0d6689e089",
    },
    "spine_pass": {
        "UP_CLK": "a0000001-0000-4000-8000-000000000101",
        "UP_RST_N": "a0000001-0000-4000-8000-000000000102",
        "UP_DATA0": "a0000001-0000-4000-8000-000000000103",
        "UP_DATA1": "a0000001-0000-4000-8000-000000000104",
        "UP_DATA2": "a0000001-0000-4000-8000-000000000105",
        "UP_DATA3": "a0000001-0000-4000-8000-000000000106",
        "UP_DATA4": "a0000001-0000-4000-8000-000000000107",
        "UP_DATA5": "a0000001-0000-4000-8000-000000000108",
        "UP_DATA6": "a0000001-0000-4000-8000-000000000109",
        "UP_DATA7": "a0000001-0000-4000-8000-00000000010A",
        "UP_VALID": "a0000001-0000-4000-8000-00000000010B",
        "UP_SOP": "a0000001-0000-4000-8000-00000000010C",
        "UP_EOP": "a0000001-0000-4000-8000-00000000010D",
        "UP_READY": "a0000001-0000-4000-8000-00000000010E",
        "UP_VC0": "a0000001-0000-4000-8000-00000000010F",
        "UP_VC1": "a0000001-0000-4000-8000-000000000110",
        "DN_CLK": "a0000001-0000-4000-8000-000000000111",
        "DN_RST_N": "a0000001-0000-4000-8000-000000000112",
        "DN_DATA0": "a0000001-0000-4000-8000-000000000113",
        "DN_DATA1": "a0000001-0000-4000-8000-000000000114",
        "DN_DATA2": "a0000001-0000-4000-8000-000000000115",
        "DN_DATA3": "a0000001-0000-4000-8000-000000000116",
        "DN_DATA4": "a0000001-0000-4000-8000-000000000117",
        "DN_DATA5": "a0000001-0000-4000-8000-000000000118",
        "DN_DATA6": "a0000001-0000-4000-8000-000000000119",
        "DN_DATA7": "a0000001-0000-4000-8000-00000000011A",
        "DN_VALID": "a0000001-0000-4000-8000-00000000011B",
        "DN_SOP": "a0000001-0000-4000-8000-00000000011C",
        "DN_EOP": "a0000001-0000-4000-8000-00000000011D",
        "DN_READY": "a0000001-0000-4000-8000-00000000011E",
        "DN_VC0": "a0000001-0000-4000-8000-00000000011F",
        "DN_VC1": "a0000001-0000-4000-8000-000000000120",
        "UP_VDD0": "a0000001-0000-4000-8000-000000000121",
        "UP_VDD1": "a0000001-0000-4000-8000-000000000122",
        "UP_VSS": "a0000001-0000-4000-8000-000000000123",
        "UP_GND_STEEL": "a0000001-0000-4000-8000-000000000124",
        "UP_SHIELD": "a0000001-0000-4000-8000-000000000125",
        "DN_VDD0": "a0000001-0000-4000-8000-000000000126",
        "DN_VDD1": "a0000001-0000-4000-8000-000000000127",
        "DN_VSS": "a0000001-0000-4000-8000-000000000128",
        "DN_GND_STEEL": "a0000001-0000-4000-8000-000000000129",
        "DN_SHIELD": "a0000001-0000-4000-8000-00000000012A",
    },
}


# ── Signal mapping: which net each component pin connects to ───────────
# Maps (component_key, pin_signal_name) → net_signal_name
SIGNAL_MAP = {
    # Spine pass-through: UP side → SPINE_UP_*, DN side → SPINE_DN_*
    ("spine_pass", "UP_CLK"): "SPINE_UP_CLK",
    ("spine_pass", "UP_RST_N"): "SPINE_UP_RST_N",
    ("spine_pass", "UP_VDD0"): "VDD", ("spine_pass", "UP_VDD1"): "VDD",
    ("spine_pass", "UP_VSS"): "VSS",
    ("spine_pass", "UP_GND_STEEL"): "GND_STEEL",
    ("spine_pass", "UP_SHIELD"): "SHIELD",
    ("spine_pass", "DN_CLK"): "SPINE_DN_CLK",
    ("spine_pass", "DN_RST_N"): "SPINE_DN_RST_N",
    ("spine_pass", "DN_VDD0"): "VDD", ("spine_pass", "DN_VDD1"): "VDD",
    ("spine_pass", "DN_VSS"): "VSS",
    ("spine_pass", "DN_GND_STEEL"): "GND_STEEL",
    ("spine_pass", "DN_SHIELD"): "SHIELD",
    # Mezzanine
    ("mezz", "CLK"): "CLK", ("mezz", "RST_N"): "RST_N",
    ("mezz", "GND_STEEL"): "GND_STEEL", ("mezz", "SHIELD"): "SHIELD",
    ("mezz", "VDD0"): "VDD", ("mezz", "VDD1"): "VDD", ("mezz", "VDD2"): "VDD", ("mezz", "VDD3"): "VDD",
    ("mezz", "VSS0"): "VSS", ("mezz", "VSS1"): "VSS", ("mezz", "VSS2"): "VSS", ("mezz", "VSS3"): "VSS",
    ("mezz", "VSS4"): "VSS", ("mezz", "VSS5"): "VSS", ("mezz", "VSS6"): "VSS", ("mezz", "VSS7"): "VSS",
    # LXY
    ("lxy", "clk"): "CLK", ("lxy", "rst_n"): "RST_N",
    # HFR
    ("hfr", "clk"): "CLK", ("hfr", "rst_n"): "RST_N",
    # NoB connectors
    ("nob", "VDD0"): "VDD", ("nob", "VDD1"): "VDD",
    ("nob", "VSS0"): "VSS", ("nob", "VSS1"): "VSS", ("nob", "VSS2"): "VSS", ("nob", "VSS3"): "VSS",
}

# Map spine_pass UP_DATA/DN_DATA bus signals
for i in range(8):
    SIGNAL_MAP[("spine_pass", f"UP_DATA{i}")] = f"SPINE_DATA{i}"
    SIGNAL_MAP[("spine_pass", f"DN_DATA{i}")] = f"SPINE_DATA{i}"
for name in ["VALID", "SOP", "EOP", "READY", "VC0", "VC1"]:
    SIGNAL_MAP[("spine_pass", f"UP_{name}")] = f"SPINE_{name}"
    SIGNAL_MAP[("spine_pass", f"DN_{name}")] = f"SPINE_{name}"

# Map mezzanine bus signals by index pattern
for i in range(8):
    SIGNAL_MAP[("mezz", f"SPINE_DATA{i}")] = f"SPINE_DATA{i}"
    SIGNAL_MAP[("nob", f"NOB_D{i}")] = f"NOB_D{i}"
    SIGNAL_MAP[("nob", f"NOB_UP_D{i}")] = f"NOB_UP_D{i}"

for name in ["SPINE_VALID", "SPINE_SOP", "SPINE_EOP", "SPINE_READY", "SPINE_VC0", "SPINE_VC1",
             "NOB_VALID", "NOB_SOP", "NOB_EOP", "NOB_READY", "NOB_VC0", "NOB_VC1",
             "NOB_UP_VALID", "NOB_UP_SOP", "NOB_UP_EOP", "NOB_UP_READY", "NOB_UP_VC0", "NOB_UP_VC1"]:
    SIGNAL_MAP[("mezz", name)] = name
    SIGNAL_MAP[("nob", name)] = name

# LXY bus signals: spin_* maps to SPINE_*, nob_* maps to NOB_*, etc.
_lxy_spin_map = {
    "spin_valid": "SPINE_VALID", "spin_sop": "SPINE_SOP",
    "spin_eop": "SPINE_EOP", "spin_ready": "SPINE_READY", "spin_vc": "SPINE_VC0",
    "nob_valid": "NOB_VALID", "nob_sop": "NOB_SOP",
    "nob_eop": "NOB_EOP", "nob_ready": "NOB_READY", "nob_vc": "NOB_VC0",
    "nob_up_valid": "NOB_UP_VALID", "nob_up_sop": "NOB_UP_SOP",
    "nob_up_eop": "NOB_UP_EOP", "nob_up_ready": "NOB_UP_READY", "nob_up_vc": "NOB_UP_VC0",
    "spup_valid": "SPINE_VALID", "spup_sop": "SPINE_SOP",
    "spup_eop": "SPINE_EOP", "spup_ready": "SPINE_READY", "spup_vc": "SPINE_VC0",
    "spup_in_valid": "SPINE_VALID", "spup_in_sop": "SPINE_SOP",
    "spup_in_eop": "SPINE_EOP", "spup_in_ready": "SPINE_READY", "spup_in_vc": "SPINE_VC0",
    "spout_valid": "SPINE_VALID", "spout_sop": "SPINE_SOP",
    "spout_eop": "SPINE_EOP", "spout_ready": "SPINE_READY", "spout_vc": "SPINE_VC0",
    "spin_data": "SPIN_DATA_BUS", "spout_data": "SPOUT_DATA_BUS",
    "nob_data": "NOB_DATA_BUS", "nob_up_data": "NOB_UP_DATA_BUS",
    "spup_data": "SPUP_DATA_BUS", "spup_in_data": "SPUP_IN_DATA_BUS",
    "route_bitmap": "ROUTE_BITMAP_LXY",
}
for lxy_pin, net in _lxy_spin_map.items():
    SIGNAL_MAP[("lxy", lxy_pin)] = net

_hfr_map = {
    "in_valid": "NOB_VALID", "in_sop": "NOB_SOP",
    "in_eop": "NOB_EOP", "in_ready": "NOB_READY", "in_vc": "NOB_VC0",
    "out_valid": "NOB_UP_VALID", "out_sop": "NOB_UP_SOP",
    "out_eop": "NOB_UP_EOP", "out_ready": "NOB_UP_READY", "out_vc": "NOB_UP_VC0",
    "in_data": "HFR_IN_DATA_BUS", "out_data": "HFR_OUT_DATA_BUS",
    "route_bitmap": "ROUTE_BITMAP_HFR",
}
for hfr_pin, net in _hfr_map.items():
    SIGNAL_MAP[("hfr", hfr_pin)] = net


# ── Layout generator ──────────────────────────────────────────────────

def generate_layout(topology_key, board_width_mm=60.0, board_height_mm=80.0, num_layers=8, board_x=4, board_y=4):
    """Generate component placement for a topology variant.

    Layout: spine pass-through connector at center, LXY repeaters flanking it,
    HFR pipe stage below, NoB connectors on left/right edges, mezzanine
    connectors on bottom edge (to pnm_node boards below).
    Board count (num_layers) affects mezzanine connector count and spacing.
    """
    topo = TOPOLOGIES[topology_key]
    components = topo["components"]
    cx = board_width_mm / 2
    cy = board_height_mm / 2

    # Mezzanine connector positions: spread across bottom edge based on component count
    mezz_comps = [c for c in components if c["type"] == "mezz"]
    mezz_count = len(mezz_comps)
    mezz_margin = 5.0
    mezz_spacing = (board_width_mm - 2 * mezz_margin) / max(mezz_count - 1, 1)
    mezz_positions = []
    for i in range(mezz_count):
        x = mezz_margin + i * mezz_spacing if mezz_count > 1 else cx
        mezz_positions.append((x, board_height_mm * 0.85))

    if topology_key == "x2_lxy":
        positions = {
            "J_SPINE": (cx, cy - 10),
            "U1":      (cx - 15, cy - 5),
            "U2":      (cx + 15, cy - 5),
            "U3":      (cx, cy + 8),
            "J_NOB1":  (5, cy),
            "J_NOB2":  (board_width_mm - 5, cy),
        }
    elif topology_key == "xy":
        positions = {
            "J_SPINE": (cx, cy - 10),
            "U1":      (cx, cy + 5),
            "J_NOB1":  (5, cy),
            "J_NOB2":  (board_width_mm - 5, cy),
        }
    # Assign mezzanine positions from computed list
    for i, mc in enumerate(mezz_comps):
        if i < len(mezz_positions):
            positions[mc["name"]] = mezz_positions[i]

    # Assign UUIDs
    sym_inst_uuids = {}
    lib_gate_uuids = {}
    for comp in components:
        name = comp["name"]
        sym_inst_uuids[name] = uid()
        lib_gate_uuids[name] = uid()

    return {
        "positions": positions,
        "sym_inst_uuids": sym_inst_uuids,
        "lib_gate_uuids": lib_gate_uuids,
        "components": components,
    }


# ── Schematic writer ──────────────────────────────────────────────────

def write_schematic_variant(topology_key, layout, output_dir, lib_dir):
    """Write schematic.lp with placed symbols and netsegment wiring."""
    components = layout["components"]
    positions = layout["positions"]
    sym_inst_uuids = layout["sym_inst_uuids"]
    lib_gate_uuids = layout["lib_gate_uuids"]

    sym_entries = []
    netsegment_entries = []

    # Pre-parse pin positions from symbol library files
    pin_positions = {}
    for comp in components:
        ctype = comp["type"]
        if ctype not in pin_positions:
            pin_positions[ctype] = parse_pin_positions(SYMBOL_DEFS[ctype]["sym_uuid"], lib_dir)

    # Place component symbols
    for comp in components:
        name = comp["name"]
        ctype = comp["type"]
        x, y = positions[name]
        si_uuid = sym_inst_uuids[name]
        lg_uuid = lib_gate_uuids[name]
        sym_def = SYMBOL_DEFS[ctype]

        ci_uuid = uid()

        sym_entries.append(f""" (symbol {si_uuid}
  (component {ci_uuid})
  (lib_gate {lg_uuid})
  (position {mm_to_nm(x)} {mm_to_nm(y)})
  (rotation 0.0)
  (mirror false)
 )""")

    # Generate netsegments: one per net signal that has pins
    # Group pins by net signal
    net_pins = {}  # net_name → [(sym_inst_uuid, pin_uuid, abs_x_mm, abs_y_mm)]
    for comp in components:
        name = comp["name"]
        ctype = comp["type"]
        x, y = positions[name]
        si_uuid = sym_inst_uuids[name]
        mirror = False

        if ctype not in pin_positions:
            continue
        positions_map = pin_positions[ctype]
        pin_uuids = SYMBOL_PIN_UUIDS.get(ctype, {})

        for pin_name, local_pos in positions_map.items():
            net = SIGNAL_MAP.get((ctype, pin_name), None)
            if net is None:
                continue
            pin_uuid = pin_uuids.get(pin_name, None)
            if pin_uuid is None:
                continue
            local_x, local_y = local_pos
            abs_x, abs_y = compute_absolute_pin_pos(x, y, mirror, local_x, local_y)
            if net not in net_pins:
                net_pins[net] = []
            net_pins[net].append((si_uuid, pin_uuid, abs_x, abs_y))

    for net_name, pins in net_pins.items():
        if len(pins) < 1:
            continue
        if net_name not in NET_SIGNALS:
            continue
        ns_net_uuid = NET_SIGNALS[net_name]
        wire_len_mm = 5.0

        for i, (sym_uuid, pin_uuid, px, py) in enumerate(pins):
            ns_uuid = uid()
            j_uuid = uid()
            jx = px - wire_len_mm
            jy = py

            junction_str = f' (junction {j_uuid} (position {mm_to_nm(jx)} {mm_to_nm(jy)}))'
            line_str = f""" (line {uid()}
  (width 254000)
  (from (symbol {sym_uuid}) (pin {pin_uuid}))
  (to (junction {j_uuid}))
 )"""
            label_str = f""" (label {uid()})
  (position {mm_to_nm(jx)} {mm_to_nm(jy)})
  (rotation 0.0)
  (mirror false)
)"""

            netsegment_entries.append(f""" (netsegment {ns_uuid}
  (net {ns_net_uuid})
{junction_str}
{line_str}
{label_str}
 )""")

    schematic = f"""(librepcb_schematic {uid()}
 (name "Main")
 (grid (interval 2.54) (unit millimeters))
{chr(10).join(sym_entries)}
{chr(10).join(netsegment_entries)}
)
"""
    schematic_path = os.path.join(output_dir, "schematics", "main", "schematic.lp")
    os.makedirs(os.path.dirname(schematic_path), exist_ok=True)
    with open(schematic_path, "w") as f:
        f.write(schematic)
    print(f"  Wrote schematic.lp with {len(sym_entries)} symbols and {len(netsegment_entries)} netsegments")


def write_circuit_variant(topology_key, layout, output_dir):
    """Write circuit.lp for a topology variant."""
    topo = TOPOLOGIES[topology_key]
    components = layout["components"]

    netclass_uuid = "cd1d4455-4507-46e5-a597-43f7f2123f77"

    # Build net definitions from NET_SIGNALS (only nets actually used)
    used_nets = set()
    for comp in components:
        ctype = comp["type"]
        for pin_name in SYMBOL_PIN_UUIDS.get(ctype, {}).keys():
            net = SIGNAL_MAP.get((ctype, pin_name), None)
            if net and net in NET_SIGNALS:
                used_nets.add(net)

    net_defs = []
    for net_name in sorted(used_nets):
        ns_uuid = NET_SIGNALS[net_name]
        net_defs.append(f' (net {ns_uuid} (auto false) (name "{net_name}") (netclass {netclass_uuid}))')

    circuit = f"""(librepcb_circuit
 (variant {uid()} (name "Std") (description "Standard assembly"))
 (netclass {netclass_uuid} (name "default"))
{chr(10).join(net_defs)}
)
"""
    circuit_path = os.path.join(output_dir, "circuit", "circuit.lp")
    os.makedirs(os.path.dirname(circuit_path), exist_ok=True)
    with open(circuit_path, "w") as f:
        f.write(circuit)
    print(f"  Wrote circuit.lp with {len(net_defs)} nets")


def write_project_variant(topology_key, output_dir):
    """Write project metadata files."""
    project_dir = os.path.join(output_dir, "project")
    os.makedirs(project_dir, exist_ok=True)

    with open(os.path.join(project_dir, "metadata.lp"), "w") as f:
        f.write(f"""(librepcb_project_metadata
 (uuid {uid()})
 (name "{topology_key}")
 (description "PNM interconnect board - {topology_key} topology")
 (author "PNM Project")
 (version "0.1")
 (created 2026-08-25T00:00:00Z)
)
""")

    with open(os.path.join(project_dir, "settings.lp"), "w") as f:
        f.write(f"""(librepcb_project_settings
 (uuid {uid()})
 (locale "en_US")
 (length_unit "millimeters")
)
""")


def write_lib_ref(output_dir, lib_dir):
    """Copy library reference from the source library."""
    dest_lib = os.path.join(output_dir, "library")
    os.makedirs(dest_lib, exist_ok=True)

    project_file = os.path.join(output_dir, ".librepcb-project")
    if not os.path.exists(project_file):
        with open(project_file, "w") as f:
            f.write("(librepcb_project_version 0.1)\n")


# ── Main ──────────────────────────────────────────────────────────────

def main():
    parser = argparse.ArgumentParser(description="Generate PNM interconnect board topology variants")
    parser.add_argument("--variant", choices=list(TOPOLOGIES.keys()), default="x2_lxy",
                        help="Topology variant to generate")
    parser.add_argument("--output", default=".",
                        help="Output directory (default: current directory)")
    parser.add_argument("--board-width", type=float, default=60.0,
                        help="Board width in mm (default: 60.0)")
    parser.add_argument("--board-height", type=float, default=80.0,
                        help="Board height in mm (default: 80.0)")
    parser.add_argument("--layers", type=int, default=8,
                        help="Number of board layers in chassis (1-16, default: 8)")
    parser.add_argument("--board-x", type=int, default=4,
                        help="X nodes per layer (default: 4)")
    parser.add_argument("--board-y", type=int, default=4,
                        help="Y nodes per layer (default: 4)")
    parser.add_argument("--lib-dir", default=None,
                        help="Library directory (default: auto-detect)")
    args = parser.parse_args()

    if args.lib_dir is None:
        args.lib_dir = os.path.join(os.path.dirname(os.path.abspath(__file__)), "library")

    output_dir = os.path.join(args.output, f"interconnect_{args.variant}")
    os.makedirs(output_dir, exist_ok=True)

    topo = TOPOLOGIES[args.variant]
    total_nodes = args.layers * args.board_x * args.board_y
    print(f"=== Generating {args.variant} topology ===")
    print(f"  {topo['description']}")
    print(f"  Components: {len(topo['components'])}")
    print(f"  Chassis: {args.layers} layers x {args.board_x}x{args.board_y} nodes = {total_nodes} nodes")
    print(f"  Output: {output_dir}")
    print()

    # Generate layout
    layout = generate_layout(args.variant, args.board_width, args.board_height,
                             args.layers, args.board_x, args.board_y)

    # Write files
    print("1. Writing project files...")
    write_project_variant(args.variant, output_dir)
    write_lib_ref(output_dir, args.lib_dir)

    print("2. Writing circuit...")
    write_circuit_variant(args.variant, layout, output_dir)

    print("3. Writing schematic...")
    write_schematic_variant(args.variant, layout, output_dir, args.lib_dir)

    print(f"\nDone! Generated {args.variant} topology in {output_dir}/")


if __name__ == "__main__":
    main()
