# Quarantined / de-prioritized code

Code that is no longer part of the active build, test, or documentation path.
Kept for provenance and possible later revival. Nothing under this tree is
compiled, tested, or documented as current.

| Path | What it was | Why it left the active tree |
|------|-------------|------------------------------|
| `fw/pnm_lustre.{c,h}` | C Lustre OSS striping client | Unrelated to the processing-near-memory argument (a filesystem striping feature); no runtime callers. The Go twin is under `sim/` in `archive/`. |
| `sim/nvme_lustre.{go,_test.go}` | Go Lustre client twin + alias/spacing tests | Same feature; the in-package half that the KV-cache overflow path actually needs (the `NVMeDev` block device) now lives in `sim/internal/pnm/nvme_device.go`. |
| `toolchain/soc-linux/` | Full OS image builder (Redox-path) | Superseded by the seL4 microkernel story in `fw/os/sel4/`/`toolchain/soc/`; orphaned (no build or doc references to the actual stack). |
| `hdl/tb_expert_loop.v` | Monolithic integrated expert loop testbench (1361 lines) | Superseded by `HDL/core/node.v` + `tb_node.v` + `node_reference_test.py`; no build/test path ran it. |
| `hdl/tb_integration.v` | Early fabric integration TB | Superseded by `tb_fabric.v` / `tb_load.v`; referenced by nothing. |
| `hdl/tb_rv32_core.v`, `hdl/tb_rv32_core_load.v` | RV32 core + load TBs | Historical bring-up scaffolding; only `AGENTS.md` prose mentioned them. |
| `hdl/tb_flit_gate.v`, `hdl/tb_hfr.v` | Per-cell fabric TBs | Superseded by the combined `tb_fabric.v`. |
| `hdl/core/tb_int4_mac.v` | Standalone INT4 MAC TB | `pnmt` exercises `tb_int4_mac_array.v` (arrays), not this scalar TB. |
| `hdl/orchestrator_chip_haskell.v` | "Haskell-optimized Router Chip" variant | Dead ceremony: no instantiation and no compiler emits it (the Haskell frontend targets generic FP64 IR). |
| `hdl/core/ram_phy_stub.v` | RAM PHY stub | Only consumed by the archived `tb_expert_loop.v`; no live instantiation. |

Relevant constraints honoured during the move: `kv_cache.go` depends on
`NVMeDev` (`KVCache.NVMe`), which stays in the package; the C firmware build
(`fw/`) does not reference `pnm_lustre.*`; `pnmt`'s `c` category no longer
compiles the Lustre twin.