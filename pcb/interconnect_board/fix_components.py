#!/usr/bin/env python3
"""Regenerate all 4 component.lp files with symbol_variants properly inserted."""

import os

BASE = "/data/Projects/PNM-Arch-Paper/Paper/pcb/interconnect_board/library/cmp"

# Original component content (signal list only, no symbol_variants)
# Format: (librepcb_component UUID ... (signal ...) ... )
# We insert symbol_variants before the final closing paren.

COMPONENTS = {
    "23989f38-11e2-469b-862c-eaf66d20afe1": """(librepcb_component 23989f38-11e2-469b-862c-eaf66d20afe1
 (name "LXY Repeater")
 (description "Z-axis repeater for spine-to-NoB gating")
 (keywords "pnm")
 (author "PNM Project")
 (version "0.1")
 (created 2026-08-25T00:00:00Z)
 (deprecated false)
 (generated_by "")
 (schematic_only false)
 (default_value "")
 (prefix "U")
 (signal d6ef702c-e0c2-43d6-99c7-ccd77f787ae2 (name "clk") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal fcf9265e-dbf0-4706-bdfd-b92689bbdaed (name "rst_n") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal a2ed1bb5-c384-4970-b249-fa432c0bb83e (name "route_bitmap") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 846e6e09-f47b-46d8-abb0-a857a82d1bf1 (name "spin_data") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal fe03f1b8-e3b9-4e15-b50c-1b4f5bb1b9c5 (name "spin_valid") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 0f1708aa-d070-4734-995e-ef614f3745d7 (name "spin_sop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal d5168469-9534-412a-86f2-a1b1e3ad47fe (name "spin_eop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal d96396cf-0dd6-472c-807c-96dcd392fc55 (name "spin_ready") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal d571417f-4404-4b75-a086-3971810bbae2 (name "spin_vc") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal a7dc2e5b-11ae-42ee-bcb4-395748887dbe (name "spout_data") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 54efabf9-9c73-4a97-98f3-9cfe67f4ea90 (name "spout_valid") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 0321bfbf-8237-41fe-ac44-c6ecc683327c (name "spout_sop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 27092570-520d-4943-b363-a648432d9289 (name "spout_eop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 0d4199ef-76e6-4f25-8c0f-0a4c0a7f4352 (name "spout_ready") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal dfb4a609-57b8-4ea7-a86f-b2c40099afde (name "spout_vc") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal a807c40e-7f08-4d9d-a9da-ddcc820a78ee (name "nob_data") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 57b0afdc-a456-4bf1-b404-c085e910cbb9 (name "nob_valid") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 063b9c69-f30f-4db5-806e-c642b22960a7 (name "nob_sop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 8c613c77-5c28-44c9-8182-cc8f76b32992 (name "nob_eop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 016c06c3-f52d-4876-8b6f-31ad99b8c497 (name "nob_ready") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 7748cc64-c63d-459f-8624-e8ea110e7aba (name "nob_vc") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal f8cc9b9e-f14b-4a61-978f-01c21ff3a0d7 (name "nob_up_data") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal e6c501a1-6a56-481c-bf93-1cee089a9edb (name "nob_up_valid") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 945dcbe9-90a8-4971-a288-cb1514f7ac80 (name "nob_up_sop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 66b6a5d0-5448-4497-8442-8a6fd81b1716 (name "nob_up_eop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 94b3c888-70b6-4e71-a180-96aa0d48ef71 (name "nob_up_ready") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 6783f808-bfbb-435e-b21e-b126f8e4b72a (name "nob_up_vc") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 238fec79-fd70-418d-9e29-015b693b8ddf (name "spup_in_data") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 2e6a5f95-5dab-41a3-a61e-557174da063f (name "spup_in_valid") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 86ed77d9-e5b6-498c-8e1c-ad09a3df5623 (name "spup_in_sop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal d2a72957-f122-4458-996d-f353601068a1 (name "spup_in_eop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal bd8f756a-24e8-4b01-8792-c01db1fb6d1a (name "spup_in_ready") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal b07082a3-344a-4d8a-a735-100ecc01ec0a (name "spup_in_vc") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal a993d4cd-3db4-4ae2-912c-28bee08a1234 (name "spup_data") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 8ed5b678-3111-4cbe-9118-9d2bf328c49b (name "spup_valid") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal ff90d4e7-d470-4de2-96e9-a4b4ef6649cf (name "spup_sop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 72a66974-4a7a-408b-9165-dac57a2c344b (name "spup_eop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal cee60d15-222a-439f-b7b4-2febd9cce1dc (name "spup_ready") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 7e22a51c-ead5-413d-9681-cb64e2db5347 (name "spup_vc") (role passive) (required true) (negated false) (clock false) (forced_net ""))
)""",

    "f84c13cb-431a-491b-867e-bbeb7110ee90": """(librepcb_component f84c13cb-431a-491b-867e-bbeb7110ee90
 (name "HFR")
 (description "Hardware Flit Repeater pipe stage")
 (keywords "pnm")
 (author "PNM Project")
 (version "0.1")
 (created 2026-08-25T00:00:00Z)
 (deprecated false)
 (generated_by "")
 (schematic_only false)
 (default_value "")
 (prefix "U")
 (signal f013e73a-5fb3-4f74-90f5-6c3842ac4493 (name "clk") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal ce7927e3-6eaa-4f75-b332-f9e05a37d5ff (name "rst_n") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 69d2dea6-a5cb-4488-8ef3-bfce342da103 (name "route_bitmap") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 4b05b470-1d4e-4b10-9eec-05e169c128bf (name "in_data") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 2c99b09b-5418-400d-9d85-3807386ce498 (name "in_valid") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal fa9f17db-7b69-4c47-9a3d-13ad1611f14d (name "in_sop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 10868ac6-1694-4c66-9068-b1fe5e44a9cb (name "in_eop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 14c152b2-8636-4d34-9620-27a12a9582c3 (name "in_ready") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 55c29607-645b-4551-a565-a8ad9ea92648 (name "in_vc") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 20f1fcad-9d6d-478c-9f1c-24ab50c14aca (name "out_data") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 044760ae-6c96-4592-8fb5-e5e9fc890dcd (name "out_valid") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 2137ca15-5ce7-41e0-93aa-6e37b0bbd1dd (name "out_sop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 32c73dde-e5f0-4e52-86a7-bf856df94f41 (name "out_eop") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal aac0ab24-c235-4f9c-b4d4-f3830cbf6b1c (name "out_ready") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 0f2d087a-eaac-4456-9aaf-b81ca7f4cbf1 (name "out_vc") (role passive) (required true) (negated false) (clock false) (forced_net ""))
)""",

    "e66a8e1c-0d4e-487b-bd56-fd2bef9759e9": """(librepcb_component e66a8e1c-0d4e-487b-bd56-fd2bef9759e9
 (name "Spine Mezzanine")
 (description "60-pin mezzanine for vertical spine")
 (keywords "pnm")
 (author "PNM Project")
 (version "0.1")
 (created 2026-08-25T00:00:00Z)
 (deprecated false)
 (generated_by "")
 (schematic_only false)
 (default_value "")
 (prefix "U")
 (signal 4df1f028-d9f7-4cb6-a6fc-edd64d32db75 (name "CLK") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 1d094dd6-adef-429f-8448-34504f39ebdd (name "RST_N") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal a01071e4-12a4-489d-a79c-b6387fe12529 (name "SPINE_DATA0") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 8ecfa138-760a-4ed1-9fae-aec4f03c7f06 (name "SPINE_DATA1") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 181fe017-bf4c-46ef-bc04-32716ef1ee63 (name "SPINE_DATA2") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal ee46719d-ad80-418a-9c89-372fa2c3c82e (name "SPINE_DATA3") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 9ef7f3a8-37fe-4cd2-85f5-29fa40ee3f80 (name "SPINE_DATA4") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 0ea7cd7e-42bf-47c0-bb13-7653b293b58c (name "SPINE_DATA5") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 9b840418-dbfd-4c0e-bb1d-8098ba4e065c (name "SPINE_DATA6") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 48aecb0e-32b3-4fa8-83b3-eda779af7bc7 (name "SPINE_DATA7") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal cc9403e8-87cc-4c72-b82a-6699f40198b3 (name "SPINE_VALID") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal fbac5923-b5bf-4b95-b28d-525bdacd5fb9 (name "SPINE_SOP") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal c3fba9ea-e2aa-4607-8a24-57571e1dd94f (name "SPINE_EOP") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 3c902cdc-8552-49a9-8605-ad3f75bc22a9 (name "SPINE_READY") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal dbe0135f-5c1c-44b5-863a-08367b1b46cb (name "SPINE_VC0") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 602d3141-146d-44a3-aaec-1214cea5a6af (name "SPINE_VC1") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal a4f60a0d-8823-4756-b617-35a0b58f1cfe (name "VDD0") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 786b4ec8-10fb-405d-8e8f-97313b467780 (name "VDD1") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal bd743b9b-f920-405c-8a27-b40fa369e520 (name "VDD2") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal baecc85d-fb6a-4790-a218-9d417fd8ff8b (name "VDD3") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 1f193c1a-e2d6-4d15-9b1c-2a3bd44db28b (name "VSS0") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 7e175f1f-11c6-458d-9ab0-2c28255fc58d (name "VSS1") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal e7d886cc-2052-45e9-9e8c-3946e208ca20 (name "VSS2") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal ea0d8d02-6600-4384-b5f9-4b61ca2cd4f1 (name "VSS3") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 50056737-cfc5-4e58-8a95-6c355fae6bd3 (name "VSS4") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 110e6fc2-b08f-4f94-aaf0-db5d63d05c2e (name "VSS5") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 0fe8ca88-14be-4aeb-8f8c-d444c8ad7725 (name "VSS6") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 1c18f6a4-e3d7-4fe1-9ca6-a10e3b40b63b (name "VSS7") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal a47d2aaa-2951-4b66-8839-573c96cffa53 (name "GND_STEEL") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 4b1a45aa-1f03-4121-bf34-1c52ea807da1 (name "SHIELD") (role passive) (required true) (negated false) (clock false) (forced_net ""))
)""",

    "b7af4d44-52e0-455e-b9b3-c36faaad257f": """(librepcb_component b7af4d44-52e0-455e-b9b3-c36faaad257f
 (name "NoB Connector")
 (description "40-pin board-to-board for compute node")
 (keywords "pnm")
 (author "PNM Project")
 (version "0.1")
 (created 2026-08-25T00:00:00Z)
 (deprecated false)
 (generated_by "")
 (schematic_only false)
 (default_value "")
 (prefix "U")
 (signal fda0a053-a280-4f84-af11-944da65229b1 (name "NOB_D0") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal cc020756-9caf-4b5f-9df4-7da572b84952 (name "NOB_D1") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 8409170f-f878-4369-935d-1c8c5c7a6486 (name "NOB_D2") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal ffc26c82-c503-48ce-90b7-ca60f3729e4c (name "NOB_D3") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal b2b6e6c3-2a14-4b1c-90c1-dd963855fd83 (name "NOB_D4") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal be378196-cd1d-4012-9df8-79d5492fbc62 (name "NOB_D5") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal fcbd106d-1abd-46e1-84bc-f94aea49d0ab (name "NOB_D6") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 52bd9243-198b-44bc-9d09-b8a84a4c999e (name "NOB_D7") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal dabf6ce0-a4f8-4c59-9c13-6b7312d2a068 (name "NOB_VALID") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 199702e1-b487-42fc-a8d9-6e259c06b035 (name "NOB_SOP") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 1130ba3b-04b0-452c-b598-34e00111b742 (name "NOB_EOP") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 14b35d83-8f11-4ae5-8822-ee82ff50ba97 (name "NOB_READY") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 901820e0-9685-4263-920e-dcd232d19f86 (name "NOB_VC0") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal a7373d50-09ea-4d54-a580-42c4953192d1 (name "NOB_VC1") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 2c9bb135-1b31-483f-b889-4d9f1416aa80 (name "NOB_UP_D0") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 396bb2c3-8e66-44f6-8ba4-8c8ab5817ad7 (name "NOB_UP_D1") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal c7feeb82-d06b-4e07-9668-7b7d22166790 (name "NOB_UP_D2") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 61226259-593b-408a-8142-ac9593fe13ac (name "NOB_UP_D3") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 3180b6b0-90f1-4f6a-b21d-a08d96dca9b6 (name "NOB_UP_D4") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 6968c03c-029d-4c45-9174-c119229ea34c (name "NOB_UP_D5") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 07ffc3da-bcf2-4092-a99a-a01d294c4bc0 (name "NOB_UP_D6") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal be7048f3-2b70-4281-9f9e-7eb123efee77 (name "NOB_UP_D7") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal ff5bde9a-5658-45f6-983a-8633113c368b (name "NOB_UP_VALID") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 8261b238-d23f-4e5c-a803-b5510f8d2ef9 (name "NOB_UP_SOP") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 512d2b35-ba98-48bd-8008-b04ec7991308 (name "NOB_UP_EOP") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal dc787f84-fc8e-4b1f-b1f5-f7b5e71fe38c (name "NOB_UP_READY") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal fb4cf1aa-15db-4886-8e10-a284044fcd0a (name "NOB_UP_VC0") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 4ab2aac5-530c-4f75-a198-1557c6d5c3db (name "NOB_UP_VC1") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 435b79a9-910d-4ca8-b338-7481d795fd5f (name "VDD0") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 3ea75417-caad-4c4d-b465-7a9a1d415617 (name "VDD1") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 44868114-80f5-4b8e-acfa-c49efc95a380 (name "VSS0") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 306e32b9-d753-448d-a7e7-62566b773247 (name "VSS1") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 6ec652f6-21be-4ee0-bf81-97603ce4cab1 (name "VSS2") (role passive) (required true) (negated false) (clock false) (forced_net ""))
 (signal 20024bd3-3bb2-4746-80ab-58fdfa87630a (name "VSS3") (role passive) (required true) (negated false) (clock false) (forced_net ""))
)""",
}

# Symbol variant definitions for each component
VARIANTS = {
    "23989f38-11e2-469b-862c-eaf66d20afe1": {
        "variant_uuid": "a0000001-0000-4000-8000-000000000001",
        "item_uuid": "a0000001-0000-4000-8000-000000000002",
        "sym_uuid": "6debbc07-d017-4798-a27f-847077fdaa93",
        "pin_map": [
            ("clk", "46386ecf-b3e0-4f21-9f41-c9fa19ed65ba", "d6ef702c-e0c2-43d6-99c7-ccd77f787ae2"),
            ("rst_n", "2d26dd69-a896-4791-8cc6-4999cdae407a", "fcf9265e-dbf0-4706-bdfd-b92689bbdaed"),
            ("route_bitmap", "a5f5f66d-b1e4-41e4-88cb-b19be575df4f", "a2ed1bb5-c384-4970-b249-fa432c0bb83e"),
            ("spin_data", "1763d6cc-84db-450c-8047-509ed64c9d4c", "846e6e09-f47b-46d8-abb0-a857a82d1bf1"),
            ("spin_valid", "d3c0dcb9-1bb1-4446-9900-7d3c44eed15c", "fe03f1b8-e3b9-4e15-b50c-1b4f5bb1b9c5"),
            ("spin_sop", "447fc185-fce4-4703-9d9e-ba12e35d347e", "0f1708aa-d070-4734-995e-ef614f3745d7"),
            ("spin_eop", "1f372e87-16e0-4373-b47a-de01adf62bb3", "d5168469-9534-412a-86f2-a1b1e3ad47fe"),
            ("spin_ready", "82cc1c0f-2a0d-459c-9805-8e6e42d6a653", "d96396cf-0dd6-472c-807c-96dcd392fc55"),
            ("spin_vc", "6cb87bb3-14fb-4752-9916-9995b2fb1e06", "d571417f-4404-4b75-a086-3971810bbae2"),
            ("spout_data", "8bdebcc2-1b36-40e1-85fc-a0715ec29afc", "a7dc2e5b-11ae-42ee-bcb4-395748887dbe"),
            ("spout_valid", "f690047d-68f4-442f-850b-c4fef7d20795", "54efabf9-9c73-4a97-98f3-9cfe67f4ea90"),
            ("spout_sop", "beddd9db-0479-4257-b3e1-5ddfda70242f", "0321bfbf-8237-41fe-ac44-c6ecc683327c"),
            ("spout_eop", "523742e4-402c-4e03-8c55-70955d862990", "27092570-520d-4943-b363-a648432d9289"),
            ("spout_ready", "1f17f876-9f4c-45b4-adf5-f39436ea348e", "0d4199ef-76e6-4f25-8c0f-0a4c0a7f4352"),
            ("spout_vc", "7b9a6624-6ac3-4d80-8dbb-7149128d4d6b", "dfb4a609-57b8-4ea7-a86f-b2c40099afde"),
            ("nob_data", "7d2ec2d5-f443-42d0-8ccf-4c216f0a0066", "a807c40e-7f08-4d9d-a9da-ddcc820a78ee"),
            ("nob_valid", "83e35fa9-3529-428b-b9ab-106b0a3fdb39", "57b0afdc-a456-4bf1-b404-c085e910cbb9"),
            ("nob_sop", "00ff7fa2-a685-485c-84da-ef0dac8718f1", "063b9c69-f30f-4db5-806e-c642b22960a7"),
            ("nob_eop", "0cdec99a-60ae-4391-898f-3ccdca8e8f0b", "8c613c77-5c28-44c9-8182-cc8f76b32992"),
            ("nob_ready", "ddb17070-2964-4bca-9879-9d4d9a4861ad", "016c06c3-f52d-4876-8b6f-31ad99b8c497"),
            ("nob_vc", "c13d3599-25fa-4765-8777-08156a190759", "7748cc64-c63d-459f-8624-e8ea110e7aba"),
            ("nob_up_data", "bbefac4d-251c-4bc6-bff0-101de8254cfd", "f8cc9b9e-f14b-4a61-978f-01c21ff3a0d7"),
            ("nob_up_valid", "3c5a1a73-010f-4b88-a63f-b8833025e9d3", "e6c501a1-6a56-481c-bf93-1cee089a9edb"),
            ("nob_up_sop", "397a6ded-2365-4a2b-a6d1-fda15f267443", "945dcbe9-90a8-4971-a288-cb1514f7ac80"),
            ("nob_up_eop", "2d4e4d1d-1e79-4cac-9843-5fa35e2f8094", "66b6a5d0-5448-4497-8442-8a6fd81b1716"),
            ("nob_up_ready", "a2c87517-01da-4fc6-9f25-8fd08b251004", "94b3c888-70b6-4e71-a180-96aa0d48ef71"),
            ("nob_up_vc", "9e05c0b3-b103-46d3-9662-702d4c94486e", "6783f808-bfbb-435e-b21e-b126f8e4b72a"),
            ("spup_in_data", "73697cf9-511a-4f43-b62d-ff317b7341b0", "238fec79-fd70-418d-9e29-015b693b8ddf"),
            ("spup_in_valid", "f43d1a61-b0a4-4276-9b74-a6049073f3a8", "2e6a5f95-5dab-41a3-a61e-557174da063f"),
            ("spup_in_sop", "21725cab-c6e8-44bc-9ae7-fca543cd34cf", "86ed77d9-e5b6-498c-8e1c-ad09a3df5623"),
            ("spup_in_eop", "8a1d72f6-c70f-45ad-b10c-4e7e425b3f0b", "d2a72957-f122-4458-996d-f353601068a1"),
            ("spup_in_ready", "c3ee8509-8b3e-4d10-bd0f-dbdfc6671a09", "bd8f756a-24e8-4b01-8792-c01db1fb6d1a"),
            ("spup_in_vc", "8ef89ca5-29e0-463f-8236-c94e6e28af03", "b07082a3-344a-4d8a-a735-100ecc01ec0a"),
            ("spup_data", "96405acb-781b-431d-be51-292fe1f80311", "a993d4cd-3db4-4ae2-912c-28bee08a1234"),
            ("spup_valid", "43f55966-62e3-49cb-8840-717d53936591", "8ed5b678-3111-4cbe-9118-9d2bf328c49b"),
            ("spup_sop", "b3a67e62-d4bf-4288-94df-76f5ce999bfd", "ff90d4e7-d470-4de2-96e9-a4b4ef6649cf"),
            ("spup_eop", "71a15f46-b9e4-4733-a7fe-9d9e88adf2cc", "72a66974-4a7a-408b-9165-dac57a2c344b"),
            ("spup_ready", "d0cd13c7-d613-48a9-a9c8-bd10b2b32589", "cee60d15-222a-439f-b7b4-2febd9cce1dc"),
            ("spup_vc", "3f98712d-7d34-430e-b279-25ef1c805857", "7e22a51c-ead5-413d-9681-cb64e2db5347"),
        ],
    },
    "f84c13cb-431a-491b-867e-bbeb7110ee90": {
        "variant_uuid": "a0000001-0000-4000-8000-000000000011",
        "item_uuid": "a0000001-0000-4000-8000-000000000012",
        "sym_uuid": "c9a05b54-5bbc-447c-bda4-a1c770d623f4",
        "pin_map": [
            ("clk", "46386ecf-b3e0-4f21-9f41-c9fa19ed65ba", "f013e73a-5fb3-4f74-90f5-6c3842ac4493"),
            ("rst_n", "2d26dd69-a896-4791-8cc6-4999cdae407a", "ce7927e3-6eaa-4f75-b332-f9e05a37d5ff"),
            ("route_bitmap", "a5f5f66d-b1e4-41e4-88cb-b19be575df4f", "69d2dea6-a5cb-4488-8ef3-bfce342da103"),
            ("in_data", "9d57bbb5-fa2b-4f24-8f9c-0bcc12947c2a", "4b05b470-1d4e-4b10-9eec-05e169c128bf"),
            ("in_valid", "99a1831e-0834-47d2-a005-a1283c3d5768", "2c99b09b-5418-400d-9d85-3807386ce498"),
            ("in_sop", "9577fbfc-3e62-473e-8e03-b16559125615", "fa9f17db-7b69-4c47-9a3d-13ad1611f14d"),
            ("in_eop", "19e96d3e-0c15-4e79-84de-1f1fd562ab33", "10868ac6-1694-4c66-9068-b1fe5e44a9cb"),
            ("in_ready", "077fe962-9f66-40b4-9339-98bbb7e97f81", "14c152b2-8636-4d34-9620-27a12a9582c3"),
            ("in_vc", "3c6289c2-aabd-4381-8596-88bb3a084eaa", "55c29607-645b-4551-a565-a8ad9ea92648"),
            ("out_data", "e3531c32-225f-446e-97fa-ed9c6e31c3a1", "20f1fcad-9d6d-478c-9f1c-24ab50c14aca"),
            ("out_valid", "c8998086-cb14-421a-b803-de919143b135", "044760ae-6c96-4592-8fb5-e5e9fc890dcd"),
            ("out_sop", "d37519df-423c-4d73-93aa-ea13c7c0bccc", "2137ca15-5ce7-41e0-93aa-6e37b0bbd1dd"),
            ("out_eop", "227ec3e2-1e7b-4fae-94f7-80f0a803fa7b", "32c73dde-e5f0-4e52-86a7-bf856df94f41"),
            ("out_ready", "939aaa76-19af-48a5-bb6c-354e146b1188", "aac0ab24-c235-4f9c-b4d4-f3830cbf6b1c"),
            ("out_vc", "a466e366-0c4a-426c-89de-e3a179c1be07", "0f2d087a-eaac-4456-9aaf-b81ca7f4cbf1"),
        ],
    },
    "e66a8e1c-0d4e-487b-bd56-fd2bef9759e9": {
        "variant_uuid": "a0000001-0000-4000-8000-000000000021",
        "item_uuid": "a0000001-0000-4000-8000-000000000022",
        "sym_uuid": "de979f19-c30d-4c07-afe5-039cc76915a5",
        "pin_map": [
            ("CLK", "7b28f43c-8841-4a7f-9977-f6e0f3c2c2af", "4df1f028-d9f7-4cb6-a6fc-edd64d32db75"),
            ("RST_N", "b83a7caa-7416-4606-b2ca-4b1f7d505b4d", "1d094dd6-adef-429f-8448-34504f39ebdd"),
            ("SPINE_DATA0", "e67ea0bb-e039-44fa-a973-4324ffd96b08", "a01071e4-12a4-489d-a79c-b6387fe12529"),
            ("SPINE_DATA1", "d1a90389-428d-4ba7-805f-80bbe80ce6e7", "8ecfa138-760a-4ed1-9fae-aec4f03c7f06"),
            ("SPINE_DATA2", "66f3440f-d79a-4438-9cd8-da23d2ebb77b", "181fe017-bf4c-46ef-bc04-32716ef1ee63"),
            ("SPINE_DATA3", "5106aaf1-00e6-4c84-8f58-b3680d98aa8d", "ee46719d-ad80-418a-9c89-372fa2c3c82e"),
            ("SPINE_DATA4", "38157b7c-f656-4ba9-abb2-11cf09a15105", "9ef7f3a8-37fe-4cd2-85f5-29fa40ee3f80"),
            ("SPINE_DATA5", "e149ca5b-2191-4a0f-9268-8a5531020ecc", "0ea7cd7e-42bf-47c0-bb13-7653b293b58c"),
            ("SPINE_DATA6", "5efa3fdb-2fd7-44d6-9896-0b556a14c799", "9b840418-dbfd-4c0e-bb1d-8098ba4e065c"),
            ("SPINE_DATA7", "bcda9c3d-d8a6-43de-900f-6bf8e909ae3f", "48aecb0e-32b3-4fa8-83b3-eda779af7bc7"),
            ("SPINE_VALID", "5f57f161-2303-41a8-b6dc-11d9739c8330", "cc9403e8-87cc-4c72-b82a-6699f40198b3"),
            ("SPINE_SOP", "73f95b11-f98b-40a6-a102-014b5d99667d", "fbac5923-b5bf-4b95-b28d-525bdacd5fb9"),
            ("SPINE_EOP", "e9f88f17-5508-48fb-80bd-9fc41d0f4d67", "c3fba9ea-e2aa-4607-8a24-57571e1dd94f"),
            ("SPINE_READY", "cbc97563-9757-476f-82d5-60a8d85b3755", "3c902cdc-8552-49a9-8605-ad3f75bc22a9"),
            ("SPINE_VC0", "0852b92c-9e71-476c-ae27-9058dabdd2e6", "dbe0135f-5c1c-44b5-863a-08367b1b46cb"),
            ("SPINE_VC1", "1ac2b497-5175-4ae1-8d94-38ce028d347c", "602d3141-146d-44a3-aaec-1214cea5a6af"),
            ("VDD0", "aba5e036-0f10-4460-b607-f83da011d28c", "a4f60a0d-8823-4756-b617-35a0b58f1cfe"),
            ("VDD1", "3003390c-097e-45a6-a4be-28b01867ace7", "786b4ec8-10fb-405d-8e8f-97313b467780"),
            ("VDD2", "c79d1527-0cd5-4435-8db8-2a7191d42b75", "bd743b9b-f920-405c-8a27-b40fa369e520"),
            ("VDD3", "f7c60e56-ce7b-45d5-be0d-9bd99f2fbab5", "baecc85d-fb6a-4790-a218-9d417fd8ff8b"),
            ("VSS0", "5f244c0e-c833-4b98-914c-af5d9acf0b7a", "1f193c1a-e2d6-4d15-9b1c-2a3bd44db28b"),
            ("VSS1", "729924f3-4aa4-44e4-aa67-c2f844fc77c6", "7e175f1f-11c6-458d-9ab0-2c28255fc58d"),
            ("VSS2", "e86ed932-3255-41de-81c3-5ea1ec1cb490", "e7d886cc-2052-45e9-9e8c-3946e208ca20"),
            ("VSS3", "84b6c62a-f163-4e38-b826-8a0d6689e089", "ea0d8d02-6600-4384-b5f9-4b61ca2cd4f1"),
            ("VSS4", "efab35c4-c080-415a-9366-d7b211906b1f", "50056737-cfc5-4e58-8a95-6c355fae6bd3"),
            ("VSS5", "750182ce-3538-4ec2-b8cf-8b0ea529f54b", "110e6fc2-b08f-4f94-aaf0-db5d63d05c2e"),
            ("VSS6", "85eaf246-114a-4e30-885b-384a2cc52b96", "0fe8ca88-14be-4aeb-8f8c-d444c8ad7725"),
            ("VSS7", "39ba5949-3b18-4a4a-a0df-4236a030da68", "1c18f6a4-e3d7-4fe1-9ca6-a10e3b40b63b"),
            ("GND_STEEL", "7f00d9b3-6bda-481c-a8f5-a274295a7001", "a47d2aaa-2951-4b66-8839-573c96cffa53"),
            ("SHIELD", "5a3e3230-b7d2-4485-9971-0ef67b355358", "4b1a45aa-1f03-4121-bf34-1c52ea807da1"),
        ],
    },
    "b7af4d44-52e0-455e-b9b3-c36faaad257f": {
        "variant_uuid": "a0000001-0000-4000-8000-000000000031",
        "item_uuid": "a0000001-0000-4000-8000-000000000032",
        "sym_uuid": "356aa821-bf2e-45e6-805f-67f4c74f9028",
        "pin_map": [
            ("NOB_D0", "bf001e74-4db9-4f02-955a-495a53159e2f", "fda0a053-a280-4f84-af11-944da65229b1"),
            ("NOB_D1", "2ce34b7d-7559-4883-b97c-e961f522e2cb", "cc020756-9caf-4b5f-9df4-7da572b84952"),
            ("NOB_D2", "0fe636a6-55ab-4731-9bd1-fe3fbb25e492", "8409170f-f878-4369-935d-1c8c5c7a6486"),
            ("NOB_D3", "87f2b9ef-65ef-46c7-97af-097818f06fea", "ffc26c82-c503-48ce-90b7-ca60f3729e4c"),
            ("NOB_D4", "9b0b9ec4-8857-4d12-bfc2-da496cca1ffb", "b2b6e6c3-2a14-4b1c-90c1-dd963855fd83"),
            ("NOB_D5", "a1505c5c-52f5-4012-a237-7cad8f1ed155", "be378196-cd1d-4012-9df8-79d5492fbc62"),
            ("NOB_D6", "aedf84f8-3b0f-433f-80e9-1372e5c713a4", "fcbd106d-1abd-46e1-84bc-f94aea49d0ab"),
            ("NOB_D7", "e446fbd0-7fb4-44c6-a876-06022b335a36", "52bd9243-198b-44bc-9d09-b8a84a4c999e"),
            ("NOB_VALID", "449b7b79-e46d-42a1-8c60-1b522dd6b7cd", "dabf6ce0-a4f8-4c59-9c13-6b7312d2a068"),
            ("NOB_SOP", "2941329f-8439-4f2f-ac39-a71f23a5a9ec", "199702e1-b487-42fc-a8d9-6e259c06b035"),
            ("NOB_EOP", "ec428a0d-ee07-492d-94b8-25d5d232e414", "1130ba3b-04b0-452c-b598-34e00111b742"),
            ("NOB_READY", "cd7964c5-907d-42c2-897c-142795588a54", "14b35d83-8f11-4ae5-8822-ee82ff50ba97"),
            ("NOB_VC0", "2ca5b5df-179e-46ee-a2a6-412673c811a3", "901820e0-9685-4263-920e-dcd232d19f86"),
            ("NOB_VC1", "99e25179-d3a6-4afa-b99b-61ba7a3d752a", "a7373d50-09ea-4d54-a580-42c4953192d1"),
            ("NOB_UP_D0", "aadde95c-5a9e-4eea-8cbd-8428d9d4216c", "2c9bb135-1b31-483f-b889-4d9f1416aa80"),
            ("NOB_UP_D1", "54dcb7cf-7149-4e1c-83fb-468ed2171f82", "396bb2c3-8e66-44f6-8ba4-8c8ab5817ad7"),
            ("NOB_UP_D2", "3a6cd065-98c0-408f-9a5d-8d629b9c2ede", "c7feeb82-d06b-4e07-9668-7b7d22166790"),
            ("NOB_UP_D3", "ab9d5bf1-6470-49f7-a3bd-b5d78444a2d6", "61226259-593b-408a-8142-ac9593fe13ac"),
            ("NOB_UP_D4", "35e7f6b8-6cd2-4fc4-a558-c26b86f5ea60", "3180b6b0-90f1-4f6a-b21d-a08d96dca9b6"),
            ("NOB_UP_D5", "7ec17550-312e-48c4-8d86-6a987f53166d", "6968c03c-029d-4c45-9174-c119229ea34c"),
            ("NOB_UP_D6", "b1bec2cc-44e4-4d3a-8f1f-adca81e7bdf1", "07ffc3da-bcf2-4092-a99a-a01d294c4bc0"),
            ("NOB_UP_D7", "142e2fbb-c952-42ce-84fc-3594c00c1739", "be7048f3-2b70-4281-9f9e-7eb123efee77"),
            ("NOB_UP_VALID", "e72c7d9c-2bd3-4de2-b625-8a28237a9092", "ff5bde9a-5658-45f6-983a-8633113c368b"),
            ("NOB_UP_SOP", "8406b433-4c1c-4f85-8b75-8db35d17d5e0", "8261b238-d23f-4e5c-a803-b5510f8d2ef9"),
            ("NOB_UP_EOP", "29e3a147-48ab-4c62-b7aa-f8d30641f2b1", "512d2b35-ba98-48bd-8008-b04ec7991308"),
            ("NOB_UP_READY", "ebefa9b4-2d5f-4c90-ae22-98ac15deead0", "dc787f84-fc8e-4b1f-b1f5-f7b5e71fe38c"),
            ("NOB_UP_VC0", "2bf2ef65-053c-49f3-a56a-5bfa43e11387", "fb4cf1aa-15db-4886-8e10-a284044fcd0a"),
            ("NOB_UP_VC1", "99b504dc-6739-439e-be06-071373d525bf", "4ab2aac5-530c-4f75-a198-1557c6d5c3db"),
            ("VDD0", "aba5e036-0f10-4460-b607-f83da011d28c", "435b79a9-910d-4ca8-b338-7481d795fd5f"),
            ("VDD1", "3003390c-097e-45a6-a4be-28b01867ace7", "3ea75417-caad-4c4d-b465-7a9a1d415617"),
            ("VSS0", "5f244c0e-c833-4b98-914c-af5d9acf0b7a", "44868114-80f5-4b8e-acfa-c49efc95a380"),
            ("VSS1", "729924f3-4aa4-44e4-aa67-c2f844fc77c6", "306e32b9-d753-448d-a7e7-62566b773247"),
            ("VSS2", "e86ed932-3255-41de-81c3-5ea1ec1cb490", "6ec652f6-21be-4ee0-bf81-97603ce4cab1"),
            ("VSS3", "84b6c62a-f163-4e38-b826-8a0d6689e089", "20024bd3-3bb2-4746-80ab-58fdfa87630a"),
        ],
    },
}


def build_variant_block(variant_info):
    lines = []
    for name, pin_uuid, sig_uuid in variant_info["pin_map"]:
        lines.append(f'     (pin {pin_uuid} (signal {sig_uuid}) (text pin))')
    pin_map_str = "\n".join(lines)
    return f"""
 (variant {variant_info["variant_uuid"]}
  (norm "")
  (name "std")
  (description "Standard symbol variant")
  (gate {variant_info["item_uuid"]}
   (symbol {variant_info["sym_uuid"]})
   (position 0 0)
   (rotation 0.0)
   (required true)
   (suffix "")
{pin_map_str}
  )
 )"""


for uuid, original in COMPONENTS.items():
    variant_block = build_variant_block(VARIANTS[uuid])
    # Insert before the final closing paren
    content = original.rstrip()
    assert content.endswith(")"), f"Expected end with ), got: ...{content[-20:]}"
    content = content[:-1]  # Remove final )
    content = content + "\n" + variant_block + "\n)\n"

    cmp_file = os.path.join(BASE, uuid, "component.lp")
    with open(cmp_file, "w") as f:
        f.write(content)

    # Verify
    depth = 0
    roots = 0
    for ch in content:
        if ch == '(':
            depth += 1
            if depth == 1:
                roots += 1
        elif ch == ')':
            depth -= 1
    assert roots == 1, f"{uuid}: expected 1 root, got {roots}"
    assert depth == 0, f"{uuid}: expected depth 0, got {depth}"
    print(f"OK: {uuid} (roots={roots}, depth={depth})")

print("All component files regenerated successfully.")
