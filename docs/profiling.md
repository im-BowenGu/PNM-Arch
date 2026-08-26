# Profiling & Benchmarking Guide

## Simulation Benchmarks

### Co-simulation Harness (`sim/`)

The Go co-simulation harness (`cmd/pnm`) runs six scenarios against the generated
Verilog fabric, measuring cycle-accurate latency and throughput.

**Run all scenarios:**
```bash
cd sim && go run ./cmd/pnm                       # default 3x4x4 = 48 nodes
cd sim && go run ./cmd/pnm -l 8 -x 8 -y 8        # 512-node reference chassis
cd sim && go run ./cmd/pnm --scenarios sweep stress --seed 1
```

**Profiling:**
```bash
go run ./cmd/pnm --cpuprofile /tmp/pnm.cpu --memprofile /tmp/pnm.mem
go tool pprof -http=:8080 /tmp/pnm.cpu
```

**Model compiler profiling:**
```bash
go run ./cmd/pnmc --cpuprofile /tmp/pnmc.cpu compile-model examples/gemma4_test -l 8 -x 8 -y 8
```

### Scenario Descriptions

| Scenario | What it measures | Pass criterion |
|----------|-----------------|----------------|
| `sweep` | Exact closed-form latency per flit path | Byte-exact match to formula |
| `vcsweep` | Sweep + all 4 VC classes, MixedVC | Byte-exact match |
| `load` | 500-flit throughput, per-node backpressure | Floor check |
| `hotspot` | MoE hot expert, kilobyte tokens, 1-in-8 DMA | Floor check |
| `stress` | ~3% corrupt-CRC messages, doorbell rejection | Reject count match |
| `replay` | Stress run twice, delivery logs bit-identical | Replay determinism |

### Closed-Form Latency

The sweep scenario asserts exact equality to:

```
latency = wire_len - 1 + l_eff * spine_hops + x * X_hops + PE_PIPE_DELAY
```

Where:
- `wire_len`: byte-wide link pipeline depth (HFR stages)
- `l_eff`: effective spine hops (layer repeater + crossbar)
- `x`: X-dimension hops
- `PE_PIPE_DELAY = 2`: generated MAC stub elastic pipe

### Workloads

```bash
go run ./cmd/pnmc workload jacobi5 -l 1 -x 4 -y 4 -run     # stencil (intra-layer)
go run ./cmd/pnmc workload matvec -l 4 -x 4 -y 4 -frag 16 -run   # matvec (spine)
go run ./cmd/pnmc workload reduction -l 4 -x 4 -y 4 -frag 32 -run # reduction
go run ./cmd/pnmc workload broadcast -l 4 -x 4 -y 4 -frag 64 -run # broadcast
go run ./cmd/pnmc workload nbody -l 4 -x 2 -y 2 -frag 8 -run     # O(N^2) saturation
```

## HDL Synthesis Metrics

### Verilator Lint

```bash
# Individual modules
verilator --lint-only <module>.v

# Full router_sbc
verilator --lint-only -Wno-MULTITOP router_sbc.v rv32_core.v uart.v clint.v pcie_phy.v nvme_ctrl.v

# Full fabric
verilator --lint-only -Wno-MULTITOP hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v
```

### Resource Estimates (post-lint, iverilog elaboration)

| Module | Approx. gates | Notes |
|--------|--------------|-------|
| `rv32_core.v` | ~3K | 5-stage FSM, no caches |
| `uart.v` | ~200 | 16550-compatible |
| `clint.v` | ~150 | mtime + msip |
| `bmc_router_top.v` | ~8K | Full BMC SoC |
| `router_sbc.v` | ~15K | SBC + SRAM + PCIe + NVMe |
| `router_sbc_moe.v` | ~12K | SBC + MoE gating + BF16 |
| `pcie_phy.v` | ~4K | Gen5 x16 LTSSM + DMA |
| `nvme_ctrl.v` | ~3K | NVMe command FSM + DMA |
| `bf16_fma.v` | ~1K | 3-cycle FMA pipeline |
| `moe_gating.v` | ~2K | Top-k sorter |
| `doorbell.v` | ~500 | 3-condition fire + CRC |
| `lpddr5_phy.v` | ~1K | 4-bank, CL16 |
| `lpddr5x_phy.v` | ~1K | 4-bank, CL14 |
| `lpddr6_phy.v` | ~500 | Flat, CL4 |

### Simulation Timing

| Testbench | Sim time | Notes |
|-----------|----------|-------|
| `tb_fabric` | ~500 us | 500 flits, 6 scenarios |
| `tb_router_sbc` | ~945 us | SRAM + DRAM + PCIe + NVMe |
| `tb_bmc_router` | ~50 ms | Full BMC boot sequence |
| `tb_pcie_phy` | ~19 ms | 12-test suite |
| `tb_nvme_ctrl` | ~10 ms | 8-block read/write |
| `tb_lpddr5_phy` | ~3.5 ms | Write/read + telemetry |
| `tb_lpddr5x_phy` | ~3.5 ms | Write/read + telemetry |
| `tb_lpddr6_phy` | ~3.3 ms | Write/read + telemetry |

### Scaling Profile

| Chassis | Nodes | Layers | Sim time (sweep) | vvp processes |
|---------|-------|--------|-------------------|---------------|
| Small   | 16    | 1      | ~1s               | 1             |
| Default | 48    | 3      | ~5s               | 3             |
| Large   | 128   | 4      | ~15s              | 4             |
| Full    | 512   | 8      | ~60s              | 8             |

## Go Test Suite

```bash
go test ./internal/pnm/                         # all tests
go test ./internal/pnm/ -run TestPyRand          # CPython RNG pinning
go test ./internal/pnm/ -run TestDESClosedForm   # DES twin validation
go test ./internal/pnm/ -run TestDESCrossCheckRTL # DES vs RTL cross-check
go test -bench=. ./internal/pnm/                 # microbenchmarks
```

## Compiler Profiling

```bash
# C firmware (compile check)
gcc -Wall -Wextra -std=c11 -c sim/fw/pnm_fw.c -o /dev/null

# Model compiler
go run ./cmd/pnmc compile-model examples/gemma4_test -l 8 -x 8 -y 8
go run ./cmd/pnmc run-driver examples/gemma4_test -l 8 -x 8 -y 8

# Source-language compilers
go run ./cmd/pnmc compile examples/bias_add.pnm -l 8 -x 8 -y 8
```
