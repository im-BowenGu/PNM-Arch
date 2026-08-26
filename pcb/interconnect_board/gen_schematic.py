#!/usr/bin/env python3
"""Generate complete interconnect_board schematic with proper wiring.

Creates netsegments (junctions + lines + labels) so every pin is connected
to its net.  Pins on the same net across different components are linked
through netlabels sharing the same net UUID.
"""

import uuid
import os
import re
import math

BASE = os.path.dirname(os.path.abspath(__file__))
LIB = os.path.join(BASE, "library")

def uid():
    return str(uuid.uuid4())

# ── Parse pin positions from symbol library files ──────────────────────

def parse_pin_positions(sym_uuid):
    """Parse pin positions from a symbol.lp file. Returns {pin_name: (x_mm, y_mm)}."""
    sym_file = os.path.join(LIB, "sym", sym_uuid, "symbol.lp")
    pins = {}
    with open(sym_file) as f:
        content = f.read()
    # Match: (pin UUID (name "NAME") (position X Y) ...)
    for m in re.finditer(
        r'\(pin\s+[0-9a-f-]+\s+\(name\s+"([^"]+)"\)\s+\(position\s+([-\d.]+)\s+([-\d.]+)\)',
        content
    ):
        name = m.group(1)
        x = float(m.group(2))
        y = float(m.group(3))
        pins[name] = (x, y)
    return pins

# ── Symbol → Component pin mapping (by name) ──────────────────────────

SYMBOLS = {
    "lxy": {
        "sym_uuid": "6debbc07-d017-4798-a27f-847077fdaa93",
        "cmp_uuid": "23989f38-11e2-469b-862c-eaf66d20afe1",
        "variant_uuid": "a0000001-0000-4000-8000-000000000001",
        "item_uuid": "a0000001-0000-4000-8000-000000000002",
        "prefix": "U",
        "pin_map": [
            ("clk", "46386ecf-b3e0-4f21-9f41-c9fa19ed65ba"),
            ("rst_n", "2d26dd69-a896-4791-8cc6-4999cdae407a"),
            ("route_bitmap", "a5f5f66d-b1e4-41e4-88cb-b19be575df4f"),
            ("spin_data", "1763d6cc-84db-450c-8047-509ed64c9d4c"),
            ("spin_valid", "d3c0dcb9-1bb1-4446-9900-7d3c44eed15c"),
            ("spin_sop", "447fc185-fce4-4703-9d9e-ba12e35d347e"),
            ("spin_eop", "1f372e87-16e0-4373-b47a-de01adf62bb3"),
            ("spin_ready", "82cc1c0f-2a0d-459c-9805-8e6e42d6a653"),
            ("spin_vc", "6cb87bb3-14fb-4752-9916-9995b2fb1e06"),
            ("spout_data", "8bdebcc2-1b36-40e1-85fc-a0715ec29afc"),
            ("spout_valid", "f690047d-68f4-442f-850b-c4fef7d20795"),
            ("spout_sop", "beddd9db-0479-4257-b3e1-5ddfda70242f"),
            ("spout_eop", "523742e4-402c-4e03-8c55-70955d862990"),
            ("spout_ready", "1f17f876-9f4c-45b4-adf5-f39436ea348e"),
            ("spout_vc", "7b9a6624-6ac3-4d80-8dbb-7149128d4d6b"),
            ("nob_data", "7d2ec2d5-f443-42d0-8ccf-4c216f0a0066"),
            ("nob_valid", "83e35fa9-3529-428b-b9ab-106b0a3fdb39"),
            ("nob_sop", "00ff7fa2-a685-485c-84da-ef0dac8718f1"),
            ("nob_eop", "0cdec99a-60ae-4391-898f-3ccdca8e8f0b"),
            ("nob_ready", "ddb17070-2964-4bca-9879-9d4d9a4861ad"),
            ("nob_vc", "c13d3599-25fa-4765-8777-08156a190759"),
            ("nob_up_data", "bbefac4d-251c-4bc6-bff0-101de8254cfd"),
            ("nob_up_valid", "3c5a1a73-010f-4b88-a63f-b8833025e9d3"),
            ("nob_up_sop", "397a6ded-2365-4a2b-a6d1-fda15f267443"),
            ("nob_up_eop", "2d4e4d1d-1e79-4cac-9843-5fa35e2f8094"),
            ("nob_up_ready", "a2c87517-01da-4fc6-9f25-8fd08b251004"),
            ("nob_up_vc", "9e05c0b3-b103-46d3-9662-702d4c94486e"),
            ("spup_in_data", "73697cf9-511a-4f43-b62d-ff317b7341b0"),
            ("spup_in_valid", "f43d1a61-b0a4-4276-9b74-a6049073f3a8"),
            ("spup_in_sop", "21725cab-c6e8-44bc-9ae7-fca543cd34cf"),
            ("spup_in_eop", "8a1d72f6-c70f-45ad-b10c-4e7e425b3f0b"),
            ("spup_in_ready", "c3ee8509-8b3e-4d10-bd0f-dbdfc6671a09"),
            ("spup_in_vc", "8ef89ca5-29e0-463f-8236-c94e6e28af03"),
            ("spup_data", "96405acb-781b-431d-be51-292fe1f80311"),
            ("spup_valid", "43f55966-62e3-49cb-8840-717d53936591"),
            ("spup_sop", "b3a67e62-d4bf-4288-94df-76f5ce999bfd"),
            ("spup_eop", "71a15f46-b9e4-4733-a7fe-9d9e88adf2cc"),
            ("spup_ready", "d0cd13c7-d613-48a9-a9c8-bd10b2b32589"),
            ("spup_vc", "3f98712d-7d34-430e-b279-25ef1c805857"),
        ],
    },
    "hfr": {
        "sym_uuid": "c9a05b54-5bbc-447c-bda4-a1c770d623f4",
        "cmp_uuid": "f84c13cb-431a-491b-867e-bbeb7110ee90",
        "variant_uuid": "a0000001-0000-4000-8000-000000000011",
        "item_uuid": "a0000001-0000-4000-8000-000000000012",
        "prefix": "U",
        "pin_map": [
            ("clk", "46386ecf-b3e0-4f21-9f41-c9fa19ed65ba"),
            ("rst_n", "2d26dd69-a896-4791-8cc6-4999cdae407a"),
            ("route_bitmap", "a5f5f66d-b1e4-41e4-88cb-b19be575df4f"),
            ("in_data", "9d57bbb5-fa2b-4f24-8f9c-0bcc12947c2a"),
            ("in_valid", "99a1831e-0834-47d2-a005-a1283c3d5768"),
            ("in_sop", "9577fbfc-3e62-473e-8e03-b16559125615"),
            ("in_eop", "19e96d3e-0c15-4e79-84de-1f1fd562ab33"),
            ("in_ready", "077fe962-9f66-40b4-9339-98bbb7e97f81"),
            ("in_vc", "3c6289c2-aabd-4381-8596-88bb3a084eaa"),
            ("out_data", "e3531c32-225f-446e-97fa-ed9c6e31c3a1"),
            ("out_valid", "c8998086-cb14-421a-b803-de919143b135"),
            ("out_sop", "d37519df-423c-4d73-93aa-ea13c7c0bccc"),
            ("out_eop", "227ec3e2-1e7b-4fae-94f7-80f0a803fa7b"),
            ("out_ready", "939aaa76-19af-48a5-bb6c-354e146b1188"),
            ("out_vc", "a466e366-0c4a-426c-89de-e3a179c1be07"),
        ],
    },
    "mezz": {
        "sym_uuid": "de979f19-c30d-4c07-afe5-039cc76915a5",
        "cmp_uuid": "e66a8e1c-0d4e-487b-bd56-fd2bef9759e9",
        "variant_uuid": "a0000001-0000-4000-8000-000000000021",
        "item_uuid": "a0000001-0000-4000-8000-000000000022",
        "prefix": "U",
        "pin_map": [
            ("CLK", "7b28f43c-8841-4a7f-9977-f6e0f3c2c2af"),
            ("RST_N", "b83a7caa-7416-4606-b2ca-4b1f7d505b4d"),
            ("SPINE_DATA0", "e67ea0bb-e039-44fa-a973-4324ffd96b08"),
            ("SPINE_DATA1", "d1a90389-428d-4ba7-805f-80bbe80ce6e7"),
            ("SPINE_DATA2", "66f3440f-d79a-4438-9cd8-da23d2ebb77b"),
            ("SPINE_DATA3", "5106aaf1-00e6-4c84-8f58-b3680d98aa8d"),
            ("SPINE_DATA4", "38157b7c-f656-4ba9-abb2-11cf09a15105"),
            ("SPINE_DATA5", "e149ca5b-2191-4a0f-9268-8a5531020ecc"),
            ("SPINE_DATA6", "5efa3fdb-2fd7-44d6-9896-0b556a14c799"),
            ("SPINE_DATA7", "bcda9c3d-d8a6-43de-900f-6bf8e909ae3f"),
            ("SPINE_VALID", "5f57f161-2303-41a8-b6dc-11d9739c8330"),
            ("SPINE_SOP", "73f95b11-f98b-40a6-a102-014b5d99667d"),
            ("SPINE_EOP", "e9f88f17-5508-48fb-80bd-9fc41d0f4d67"),
            ("SPINE_READY", "cbc97563-9757-476f-82d5-60a8d85b3755"),
            ("SPINE_VC0", "0852b92c-9e71-476c-ae27-9058dabdd2e6"),
            ("SPINE_VC1", "1ac2b497-5175-4ae1-8d94-38ce028d347c"),
            ("VDD0", "aba5e036-0f10-4460-b607-f83da011d28c"),
            ("VDD1", "3003390c-097e-45a6-a4be-28b01867ace7"),
            ("VDD2", "c79d1527-0cd5-4435-8db8-2a7191d42b75"),
            ("VDD3", "f7c60e56-ce7b-45d5-be0d-9bd99f2fbab5"),
            ("VSS0", "5f244c0e-c833-4b98-914c-af5d9acf0b7a"),
            ("VSS1", "729924f3-4aa4-44e4-aa67-c2f844fc77c6"),
            ("VSS2", "e86ed932-3255-41de-81c3-5ea1ec1cb490"),
            ("VSS3", "84b6c62a-f163-4e38-b826-8a0d6689e089"),
            ("VSS4", "efab35c4-c080-415a-9366-d7b211906b1f"),
            ("VSS5", "750182ce-3538-4ec2-b8cf-8b0ea529f54b"),
            ("VSS6", "85eaf246-114a-4e30-885b-384a2cc52b96"),
            ("VSS7", "39ba5949-3b18-4a4a-a0df-4236a030da68"),
            ("GND_STEEL", "7f00d9b3-6bda-481c-a8f5-a274295a7001"),
            ("SHIELD", "5a3e3230-b7d2-4485-9971-0ef67b355358"),
        ],
    },
    "nob": {
        "sym_uuid": "356aa821-bf2e-45e6-805f-67f4c74f9028",
        "cmp_uuid": "b7af4d44-52e0-455e-b9b3-c36faaad257f",
        "variant_uuid": "a0000001-0000-4000-8000-000000000031",
        "item_uuid": "a0000001-0000-4000-8000-000000000032",
        "prefix": "U",
        "pin_map": [
            ("NOB_D0", "bf001e74-4db9-4f02-955a-495a53159e2f"),
            ("NOB_D1", "2ce34b7d-7559-4883-b97c-e961f522e2cb"),
            ("NOB_D2", "0fe636a6-55ab-4731-9bd1-fe3fbb25e492"),
            ("NOB_D3", "87f2b9ef-65ef-46c7-97af-097818f06fea"),
            ("NOB_D4", "9b0b9ec4-8857-4d12-bfc2-da496cca1ffb"),
            ("NOB_D5", "a1505c5c-52f5-4012-a237-7cad8f1ed155"),
            ("NOB_D6", "aedf84f8-3b0f-433f-80e9-1372e5c713a4"),
            ("NOB_D7", "e446fbd0-7fb4-44c6-a876-06022b335a36"),
            ("NOB_VALID", "449b7b79-e46d-42a1-8c60-1b522dd6b7cd"),
            ("NOB_SOP", "2941329f-8439-4f2f-ac39-a71f23a5a9ec"),
            ("NOB_EOP", "ec428a0d-ee07-492d-94b8-25d5d232e414"),
            ("NOB_READY", "cd7964c5-907d-42c2-897c-142795588a54"),
            ("NOB_VC0", "2ca5b5df-179e-46ee-a2a6-412673c811a3"),
            ("NOB_VC1", "99e25179-d3a6-4afa-b99b-61ba7a3d752a"),
            ("NOB_UP_D0", "aadde95c-5a9e-4eea-8cbd-8428d9d4216c"),
            ("NOB_UP_D1", "54dcb7cf-7149-4e1c-83fb-468ed2171f82"),
            ("NOB_UP_D2", "3a6cd065-98c0-408f-9a5d-8d629b9c2ede"),
            ("NOB_UP_D3", "ab9d5bf1-6470-49f7-a3bd-b5d78444a2d6"),
            ("NOB_UP_D4", "35e7f6b8-6cd2-4fc4-a558-c26b86f5ea60"),
            ("NOB_UP_D5", "7ec17550-312e-48c4-8d86-6a987f53166d"),
            ("NOB_UP_D6", "b1bec2cc-44e4-4d3a-8f1f-adca81e7bdf1"),
            ("NOB_UP_D7", "142e2fbb-c952-42ce-84fc-3594c00c1739"),
            ("NOB_UP_VALID", "e72c7d9c-2bd3-4de2-b625-8a28237a9092"),
            ("NOB_UP_SOP", "8406b433-4c1c-4f85-8b75-8db35d17d5e0"),
            ("NOB_UP_EOP", "29e3a147-48ab-4c62-b7aa-f8d30641f2b1"),
            ("NOB_UP_READY", "ebefa9b4-2d5f-4c90-ae22-98ac15deead0"),
            ("NOB_UP_VC0", "2bf2ef65-053c-49f3-a56a-5bfa43e11387"),
            ("NOB_UP_VC1", "99b504dc-6739-439e-be06-071373d525bf"),
            ("VDD0", "aba5e036-0f10-4460-b607-f83da011d28c"),
            ("VDD1", "3003390c-097e-45a6-a4be-28b01867ace7"),
            ("VSS0", "5f244c0e-c833-4b98-914c-af5d9acf0b7a"),
            ("VSS1", "729924f3-4aa4-44e4-aa67-c2f844fc77c6"),
            ("VSS2", "e86ed932-3255-41de-81c3-5ea1ec1cb490"),
            ("VSS3", "84b6c62a-f163-4e38-b826-8a0d6689e089"),
        ],
    },
}

# Signal UUIDs from component definitions
SIGNAL_UUIDS = {
    "lxy": {
        "clk": "d6ef702c-e0c2-43d6-99c7-ccd77f787ae2",
        "rst_n": "fcf9265e-dbf0-4706-bdfd-b92689bbdaed",
        "route_bitmap": "a2ed1bb5-c384-4970-b249-fa432c0bb83e",
        "spin_data": "846e6e09-f47b-46d8-abb0-a857a82d1bf1",
        "spin_valid": "fe03f1b8-e3b9-4e15-b50c-1b4f5bb1b9c5",
        "spin_sop": "0f1708aa-d070-4734-995e-ef614f3745d7",
        "spin_eop": "d5168469-9534-412a-86f2-a1b1e3ad47fe",
        "spin_ready": "d96396cf-0dd6-472c-807c-96dcd392fc55",
        "spin_vc": "d571417f-4404-4b75-a086-3971810bbae2",
        "spout_data": "a7dc2e5b-11ae-42ee-bcb4-395748887dbe",
        "spout_valid": "54efabf9-9c73-4a97-98f3-9cfe67f4ea90",
        "spout_sop": "0321bfbf-8237-41fe-ac44-c6ecc683327c",
        "spout_eop": "27092570-520d-4943-b363-a648432d9289",
        "spout_ready": "0d4199ef-76e6-4f25-8c0f-0a4c0a7f4352",
        "spout_vc": "dfb4a609-57b8-4ea7-a86f-b2c40099afde",
        "nob_data": "a807c40e-7f08-4d9d-a9da-ddcc820a78ee",
        "nob_valid": "57b0afdc-a456-4bf1-b404-c085e910cbb9",
        "nob_sop": "063b9c69-f30f-4db5-806e-c642b22960a7",
        "nob_eop": "8c613c77-5c28-44c9-8182-cc8f76b32992",
        "nob_ready": "016c06c3-f52d-4876-8b6f-31ad99b8c497",
        "nob_vc": "7748cc64-c63d-459f-8624-e8ea110e7aba",
        "nob_up_data": "f8cc9b9e-f14b-4a61-978f-01c21ff3a0d7",
        "nob_up_valid": "e6c501a1-6a56-481c-bf93-1cee089a9edb",
        "nob_up_sop": "945dcbe9-90a8-4971-a288-cb1514f7ac80",
        "nob_up_eop": "66b6a5d0-5448-4497-8442-8a6fd81b1716",
        "nob_up_ready": "94b3c888-70b6-4e71-a180-96aa0d48ef71",
        "nob_up_vc": "6783f808-bfbb-435e-b21e-b126f8e4b72a",
        "spup_in_data": "238fec79-fd70-418d-9e29-015b693b8ddf",
        "spup_in_valid": "2e6a5f95-5dab-41a3-a61e-557174da063f",
        "spup_in_sop": "86ed77d9-e5b6-498c-8e1c-ad09a3df5623",
        "spup_in_eop": "d2a72957-f122-4458-996d-f353601068a1",
        "spup_in_ready": "bd8f756a-24e8-4b01-8792-c01db1fb6d1a",
        "spup_in_vc": "b07082a3-344a-4d8a-a735-100ecc01ec0a",
        "spup_data": "a993d4cd-3db4-4ae2-912c-28bee08a1234",
        "spup_valid": "8ed5b678-3111-4cbe-9118-9d2bf328c49b",
        "spup_sop": "ff90d4e7-d470-4de2-96e9-a4b4ef6649cf",
        "spup_eop": "72a66974-4a7a-408b-9165-dac57a2c344b",
        "spup_ready": "cee60d15-222a-439f-b7b4-2febd9cce1dc",
        "spup_vc": "7e22a51c-ead5-413d-9681-cb64e2db5347",
    },
    "hfr": {
        "clk": "f013e73a-5fb3-4f74-90f5-6c3842ac4493",
        "rst_n": "ce7927e3-6eaa-4f75-b332-f9e05a37d5ff",
        "route_bitmap": "69d2dea6-a5cb-4488-8ef3-bfce342da103",
        "in_data": "4b05b470-1d4e-4b10-9eec-05e169c128bf",
        "in_valid": "2c99b09b-5418-400d-9d85-3807386ce498",
        "in_sop": "fa9f17db-7b69-4c47-9a3d-13ad1611f14d",
        "in_eop": "10868ac6-1694-4c66-9068-b1fe5e44a9cb",
        "in_ready": "14c152b2-8636-4d34-9620-27a12a9582c3",
        "in_vc": "55c29607-645b-4551-a565-a8ad9ea92648",
        "out_data": "20f1fcad-9d6d-478c-9f1c-24ab50c14aca",
        "out_valid": "044760ae-6c96-4592-8fb5-e5e9fc890dcd",
        "out_sop": "2137ca15-5ce7-41e0-93aa-6e37b0bbd1dd",
        "out_eop": "32c73dde-e5f0-4e52-86a7-bf856df94f41",
        "out_ready": "aac0ab24-c235-4f9c-b4d4-f3830cbf6b1c",
        "out_vc": "0f2d087a-eaac-4456-9aaf-b81ca7f4cbf1",
    },
    "mezz": {
        "CLK": "4df1f028-d9f7-4cb6-a6fc-edd64d32db75",
        "RST_N": "1d094dd6-adef-429f-8448-34504f39ebdd",
        "SPINE_DATA0": "a01071e4-12a4-489d-a79c-b6387fe12529",
        "SPINE_DATA1": "8ecfa138-760a-4ed1-9fae-aec4f03c7f06",
        "SPINE_DATA2": "181fe017-bf4c-46ef-bc04-32716ef1ee63",
        "SPINE_DATA3": "ee46719d-ad80-418a-9c89-372fa2c3c82e",
        "SPINE_DATA4": "9ef7f3a8-37fe-4cd2-85f5-29fa40ee3f80",
        "SPINE_DATA5": "0ea7cd7e-42bf-47c0-bb13-7653b293b58c",
        "SPINE_DATA6": "9b840418-dbfd-4c0e-bb1d-8098ba4e065c",
        "SPINE_DATA7": "48aecb0e-32b3-4fa8-83b3-eda779af7bc7",
        "SPINE_VALID": "cc9403e8-87cc-4c72-b82a-6699f40198b3",
        "SPINE_SOP": "fbac5923-b5bf-4b95-b28d-525bdacd5fb9",
        "SPINE_EOP": "c3fba9ea-e2aa-4607-8a24-57571e1dd94f",
        "SPINE_READY": "3c902cdc-8552-49a9-8605-ad3f75bc22a9",
        "SPINE_VC0": "dbe0135f-5c1c-44b5-863a-08367b1b46cb",
        "SPINE_VC1": "602d3141-146d-44a3-aaec-1214cea5a6af",
        "VDD0": "a4f60a0d-8823-4756-b617-35a0b58f1cfe",
        "VDD1": "786b4ec8-10fb-405d-8e8f-97313b467780",
        "VDD2": "bd743b9b-f920-405c-8a27-b40fa369e520",
        "VDD3": "baecc85d-fb6a-4790-a218-9d417fd8ff8b",
        "VSS0": "1f193c1a-e2d6-4d15-9b1c-2a3bd44db28b",
        "VSS1": "7e175f1f-11c6-458d-9ab0-2c28255fc58d",
        "VSS2": "e7d886cc-2052-45e9-9e8c-3946e208ca20",
        "VSS3": "ea0d8d02-6600-4384-b5f9-4b61ca2cd4f1",
        "VSS4": "50056737-cfc5-4e58-8a95-6c355fae6bd3",
        "VSS5": "110e6fc2-b08f-4f94-aaf0-db5d63d05c2e",
        "VSS6": "0fe8ca88-14be-4aeb-8f8c-d444c8ad7725",
        "VSS7": "1c18f6a4-e3d7-4fe1-9ca6-a10e3b40b63b",
        "GND_STEEL": "a47d2aaa-2951-4b66-8839-573c96cffa53",
        "SHIELD": "4b1a45aa-1f03-4121-bf34-1c52ea807da1",
    },
    "nob": {
        "NOB_D0": "fda0a053-a280-4f84-af11-944da65229b1",
        "NOB_D1": "cc020756-9caf-4b5f-9df4-7da572b84952",
        "NOB_D2": "8409170f-f878-4369-935d-1c8c5c7a6486",
        "NOB_D3": "ffc26c82-c503-48ce-90b7-ca60f3729e4c",
        "NOB_D4": "b2b6e6c3-2a14-4b1c-90c1-dd963855fd83",
        "NOB_D5": "be378196-cd1d-4012-9df8-79d5492fbc62",
        "NOB_D6": "fcbd106d-1abd-46e1-84bc-f94aea49d0ab",
        "NOB_D7": "52bd9243-198b-44bc-9d09-b8a84a4c999e",
        "NOB_VALID": "dabf6ce0-a4f8-4c59-9c13-6b7312d2a068",
        "NOB_SOP": "199702e1-b487-42fc-a8d9-6e259c06b035",
        "NOB_EOP": "1130ba3b-04b0-452c-b598-34e00111b742",
        "NOB_READY": "14b35d83-8f11-4ae5-8822-ee82ff50ba97",
        "NOB_VC0": "901820e0-9685-4263-920e-dcd232d19f86",
        "NOB_VC1": "a7373d50-09ea-4d54-a580-42c4953192d1",
        "NOB_UP_D0": "2c9bb135-1b31-483f-b889-4d9f1416aa80",
        "NOB_UP_D1": "396bb2c3-8e66-44f6-8ba4-8c8ab5817ad7",
        "NOB_UP_D2": "c7feeb82-d06b-4e07-9668-7b7d22166790",
        "NOB_UP_D3": "61226259-593b-408a-8142-ac9593fe13ac",
        "NOB_UP_D4": "3180b6b0-90f1-4f6a-b21d-a08d96dca9b6",
        "NOB_UP_D5": "6968c03c-029d-4c45-9174-c119229ea34c",
        "NOB_UP_D6": "07ffc3da-bcf2-4092-a99a-a01d294c4bc0",
        "NOB_UP_D7": "be7048f3-2b70-4281-9f9e-7eb123efee77",
        "NOB_UP_VALID": "ff5bde9a-5658-45f6-983a-8633113c368b",
        "NOB_UP_SOP": "8261b238-d23f-4e5c-a803-b5510f8d2ef9",
        "NOB_UP_EOP": "512d2b35-ba98-48bd-8008-b04ec7991308",
        "NOB_UP_READY": "dc787f84-fc8e-4b1f-b1f5-f7b5e71fe38c",
        "NOB_UP_VC0": "fb4cf1aa-15db-4886-8e10-a284044fcd0a",
        "NOB_UP_VC1": "4ab2aac5-530c-4f75-a198-1557c6d5c3db",
        "VDD0": "435b79a9-910d-4ca8-b338-7481d795fd5f",
        "VDD1": "3ea75417-caad-4c4d-b465-7a9a1d415617",
        "VSS0": "44868114-80f5-4b8e-acfa-c49efc95a380",
        "VSS1": "306e32b9-d753-448d-a7e7-62566b773247",
        "VSS2": "6ec652f6-21be-4ee0-bf81-97603ce4cab1",
        "VSS3": "20024bd3-3bb2-4746-80ab-58fdfa87630a",
    },
}


# ── Schematic instance layout ─────────────────────────────────────────
# (key, name, x_mm, y_mm, mirror, sym_inst_uuid, lib_gate_uuid)
SCHEM_INSTANCES = [
    ("mezz", "J1", 50.8, 25.4, False, "a1000001-0000-4000-8000-000000000001", "a0000001-0000-4000-8000-000000000022"),
    ("lxy",  "U1", 50.8, 76.2, False, "a1000001-0000-4000-8000-000000000011", "a0000001-0000-4000-8000-000000000002"),
    ("hfr",  "U2", 101.6, 76.2, False, "a1000001-0000-4000-8000-000000000021", "a0000001-0000-4000-8000-000000000012"),
    ("nob",  "J2", 25.4, 127.0, False, "a1000001-0000-4000-8000-000000000031", "a0000001-0000-4000-8000-000000000032"),
    ("nob",  "J3", 76.2, 127.0, True,  "a1000001-0000-4000-8000-000000000041", "a0000001-0000-4000-8000-000000000032"),
]

# ── Net signal definitions (UUID → name) ──────────────────────────────
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
             "ROUTE_BITMAP_LXY", "ROUTE_BITMAP_HFR"]:
    _net_counter += 1
    NET_SIGNALS[name] = f"e2{_net_counter:06d}-4000-4000-8000-000000000001"


# ── Signal mapping: which net each component pin connects to ───────────
# Maps (component_key, pin_signal_name) → net_signal_name
SIGNAL_MAP = {
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

# Map bus signals by index pattern
for i in range(8):
    SIGNAL_MAP[("mezz", f"SPINE_DATA{i}")] = f"SPINE_DATA{i}"
    SIGNAL_MAP[("lxy", "spin_data")] = f"SPINE_DATA{i}"  # only first, but we handle via bus below
    SIGNAL_MAP[("nob", f"NOB_D{i}")] = f"NOB_D{i}"
    SIGNAL_MAP[("nob", f"NOB_UP_D{i}")] = f"NOB_UP_D{i}"

for name in ["SPINE_VALID", "SPINE_SOP", "SPINE_EOP", "SPINE_READY", "SPINE_VC0", "SPINE_VC1",
             "NOB_VALID", "NOB_SOP", "NOB_EOP", "NOB_READY", "NOB_VC0", "NOB_VC1",
             "NOB_UP_VALID", "NOB_UP_SOP", "NOB_UP_EOP", "NOB_UP_READY", "NOB_UP_VC0", "NOB_UP_VC1"]:
    SIGNAL_MAP[("mezz", name)] = name
    SIGNAL_MAP[("nob", name)] = name  # maps for both J2 and J3 via type lookup

# LXY bus signals: spin_* maps to SPINE_*, nob_* maps to NOB_*, etc.
_lxy_spin_map = {
    # Spine control signals
    "spin_valid": "SPINE_VALID", "spin_sop": "SPINE_SOP",
    "spin_eop": "SPINE_EOP", "spin_ready": "SPINE_READY", "spin_vc": "SPINE_VC0",
    # NoB control signals
    "nob_valid": "NOB_VALID", "nob_sop": "NOB_SOP",
    "nob_eop": "NOB_EOP", "nob_ready": "NOB_READY", "nob_vc": "NOB_VC0",
    # NoB up control signals
    "nob_up_valid": "NOB_UP_VALID", "nob_up_sop": "NOB_UP_SOP",
    "nob_up_eop": "NOB_UP_EOP", "nob_up_ready": "NOB_UP_READY", "nob_up_vc": "NOB_UP_VC0",
    # Spine up control signals
    "spup_valid": "SPINE_VALID", "spup_sop": "SPINE_SOP",
    "spup_eop": "SPINE_EOP", "spup_ready": "SPINE_READY", "spup_vc": "SPINE_VC0",
    "spup_in_valid": "SPINE_VALID", "spup_in_sop": "SPINE_SOP",
    "spup_in_eop": "SPINE_EOP", "spup_in_ready": "SPINE_READY", "spup_in_vc": "SPINE_VC0",
    "spout_valid": "SPINE_VALID", "spout_sop": "SPINE_SOP",
    "spout_eop": "SPINE_EOP", "spout_ready": "SPINE_READY", "spout_vc": "SPINE_VC0",
    # Bus data signals (dedicated nets for multi-bit buses represented as single pins)
    "spin_data": "SPIN_DATA_BUS", "spout_data": "SPOUT_DATA_BUS",
    "nob_data": "NOB_DATA_BUS", "nob_up_data": "NOB_UP_DATA_BUS",
    "spup_data": "SPUP_DATA_BUS", "spup_in_data": "SPUP_IN_DATA_BUS",
    # Configuration
    "route_bitmap": "ROUTE_BITMAP_LXY",
}
for lxy_pin, net in _lxy_spin_map.items():
    SIGNAL_MAP[("lxy", lxy_pin)] = net
# Actually, spin_data is a bus — we only map the scalar control signals.
# For data buses, each pin maps to a specific bit.
# LXY spin_data[7:0] = 8 separate pins. But our pin_map has one "spin_data" pin.
# This is a simplified model — in reality these would be bus taps.

# HFR in/out control signals connect to LXY nob/nob_up
_hfr_map = {
    "in_valid": "NOB_VALID", "in_sop": "NOB_SOP",
    "in_eop": "NOB_EOP", "in_ready": "NOB_READY", "in_vc": "NOB_VC0",
    "out_valid": "NOB_UP_VALID", "out_sop": "NOB_UP_SOP",
    "out_eop": "NOB_UP_EOP", "out_ready": "NOB_UP_READY", "out_vc": "NOB_UP_VC0",
    # Bus data signals
    "in_data": "HFR_IN_DATA_BUS", "out_data": "HFR_OUT_DATA_BUS",
    # Configuration
    "route_bitmap": "ROUTE_BITMAP_HFR",
}
for hfr_pin, net in _hfr_map.items():
    SIGNAL_MAP[("hfr", hfr_pin)] = net


def mm_to_nm(mm):
    return int(mm * 1e6)


def compute_absolute_pin_pos(sym_x_mm, sym_y_mm, mirror, rotation_deg, local_x_mm, local_y_mm):
    """Compute absolute pin position using LibrePCB Transform::map logic."""
    px = -local_x_mm if mirror else local_x_mm
    py = local_y_mm
    rad = math.radians(rotation_deg)
    rx = px * math.cos(rad) - py * math.sin(rad)
    ry = px * math.sin(rad) + py * math.cos(rad)
    return (sym_x_mm + rx, sym_y_mm + ry)


def write_circuit():
    """Write circuit.lp with component instances and net signal definitions."""
    ci_uuids = {
        "mezz": "c1000001-0000-4000-8000-000000000001",
        "lxy":  "c1000001-0000-4000-8000-000000000002",
        "hfr":  "c1000001-0000-4000-8000-000000000003",
        "nob_x": "c1000001-0000-4000-8000-000000000004",
        "nob_y": "c1000001-0000-4000-8000-000000000005",
    }

    netclass_uuid = "cd1d4455-4507-46e5-a597-43f7f2123f77"

    # Build net definitions
    net_defs = []
    for name in sorted(NET_SIGNALS.keys()):
        ns_uuid = NET_SIGNALS[name]
        net_defs.append(f' (net {ns_uuid} (auto false) (name "{name}") (netclass {netclass_uuid}))')

    # Build component instances
    def make_sig_entry(sig_uuid, net_name):
        if net_name and net_name in NET_SIGNALS:
            return f'  (signal {sig_uuid} (net {NET_SIGNALS[net_name]}))'
        return f'  (signal {sig_uuid} (net none))'

    cmp_instances = []

    for inst in SCHEM_INSTANCES:
        key, name, x, y, mirror, sym_inst_uuid, lib_gate = inst
        ci_uuid = ci_uuids.get(key, ci_uuids.get(f"{key}_x" if key == "nob" else key))
        if key == "nob":
            ci_uuid = ci_uuids["nob_x"] if name == "J2" else ci_uuids["nob_y"]

        sig_lines = []
        for sig_name, pin_uuid in SYMBOLS[key]["pin_map"]:
            net = SIGNAL_MAP.get((key, sig_name), None)
            sig_uuid = SIGNAL_UUIDS[key][sig_name]
            sig_lines.append(make_sig_entry(sig_uuid, net))

        value = {"mezz": "Samtec Searay 60-pin", "lxy": "LXY Repeater",
                 "hfr": "HFR Pipe Stage", "nob": "Hirose DF40 NoB"}.get(key, key)

        cmp_instances.append(f""" (component {ci_uuid}
  (lib_component {SYMBOLS[key]["cmp_uuid"]})
  (lib_variant {SYMBOLS[key]["variant_uuid"]})
  (name "{name}")
  (value "{value}")
  (lock_assembly false)
  (attributes)
  (assembly_options)
{chr(10).join(sig_lines)}
 )""")

    circuit = f"""(librepcb_circuit
 (variant d600d0a3-c0b6-499e-8e77-cd7a184bd5ad (name "Std") (description "Standard assembly"))
 (netclass {netclass_uuid} (name "default"))
{chr(10).join(net_defs)}
{chr(10).join(cmp_instances)}
)
"""
    with open(os.path.join(BASE, "circuit", "circuit.lp"), "w") as f:
        f.write(circuit)
    print("  Wrote circuit.lp")


def write_schematic():
    """Write schematic.lp with placed symbols, netsegments (wires + labels)."""
    sym_entries = []
    netsegment_entries = []

    # Pre-parse pin positions from symbol library files
    pin_positions = {}
    for key, info in SYMBOLS.items():
        pin_positions[key] = parse_pin_positions(info["sym_uuid"])

    # Place component symbols
    for key, name, x, y, mirror, sym_inst_uuid, lib_gate in SCHEM_INSTANCES:
        ci_uuid_map = {
            "mezz": "c1000001-0000-4000-8000-000000000001",
            "lxy":  "c1000001-0000-4000-8000-000000000002",
            "hfr":  "c1000001-0000-4000-8000-000000000003",
        }
        if key == "nob":
            ci_uuid_map["J2"] = "c1000001-0000-4000-8000-000000000004"
            ci_uuid_map["J3"] = "c1000001-0000-4000-8000-000000000005"
            cmp_ci_uuid = ci_uuid_map[name]
        else:
            cmp_ci_uuid = ci_uuid_map[key]

        sym_entries.append(f""" (symbol {sym_inst_uuid}
  (component {cmp_ci_uuid})
  (lib_gate {lib_gate})
  (position {mm_to_nm(x)} {mm_to_nm(y)})
  (rotation 0.0)
  (mirror {"true" if mirror else "false"})
 )""")

    # Generate netsegments: one per net signal that has pins
    # Group pins by net signal
    net_pins = {}  # net_name → [(sym_inst_uuid, pin_uuid, abs_x_mm, abs_y_mm)]
    for key, name, x, y, mirror, sym_inst_uuid, lib_gate in SCHEM_INSTANCES:
        positions = pin_positions[key]
        for sig_name, pin_uuid in SYMBOLS[key]["pin_map"]:
            net = SIGNAL_MAP.get((key, sig_name), None)
            if net is None:
                continue
            if sig_name not in positions:
                continue
            local_x, local_y = positions[sig_name]
            abs_x, abs_y = compute_absolute_pin_pos(x, y, mirror, 0.0, local_x, local_y)
            if net not in net_pins:
                net_pins[net] = []
            net_pins[net].append((sym_inst_uuid, pin_uuid, abs_x, abs_y))

    for net_name, pins in net_pins.items():
        if len(pins) < 1:
            continue
        ns_net_uuid = NET_SIGNALS[net_name]
        wire_len_mm = 5.0  # short wire stub from pin to junction

        for i, (sym_uuid, pin_uuid, px, py) in enumerate(pins):
            # One netsegment per pin: junction + line + label
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
            label_str = f""" (label {uid()}
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

    schematic = f"""(librepcb_schematic 35bc5a39-0f48-4238-a4db-8b5e221fac37
 (name "Main")
 (grid (interval 2.54) (unit millimeters))
{chr(10).join(sym_entries)}
{chr(10).join(netsegment_entries)}
)
"""
    with open(os.path.join(BASE, "schematics", "main", "schematic.lp"), "w") as f:
        f.write(schematic)
    print(f"  Wrote schematic.lp with {len(sym_entries)} symbols and {len(netsegment_entries)} netsegments")


if __name__ == "__main__":
    print("=== Interconnect Board Schematic Generator ===")
    print("\n1. Writing circuit.lp...")
    write_circuit()
    print("\n2. Writing schematic.lp...")
    write_schematic()
    print("\nDone! Validate with: librepcb-cli open-project pcb/interconnect_board/interconnect_board.lpp")
