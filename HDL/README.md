# PNM Fabric HDL Sketch

Verilog-2005 model of the **routing fabric**, **compute units**, and **co-simulation harness** from the paper *Breaking the HBM wall*.

## Modules

| File | Role |
|---|---|
| `pnm_defs.vh` | Packet format, VC constants, routing-bitmap layout |
| `hfr.v` | Hardware Flit Repeater (1-stage elastic pipe) + layer bit-mask comparator (monitor) |
| `flit_gate.v` | Combinational-match wormhole demux (shared core); match value/mask are runtime inputs (pre-loaded routing table) |
| `vc_merge.v` | 2-in/1-out round-robin packet-atomic merge for the reverse (egress) paths — node TX → Y-up → X-up → lxy_repeater → up-spine (paper §2.9/§4.3) |
| `lxy_repeater.v` | Z-axis repeater (layer ID compare + strip); compare driven by the routing bitmap's LAYER field; egress port wraps `vc_merge` |
| `xy_turn.v` | X→Y dimension-order turn gate |
| `node_eject.v` | Y-lane → node DMA eject gate (forwards `MODULE_ID` as DEST) |
| `crc16.v` | Byte-wise CRC-16/CCITT-FALSE (init `0xFFFF`, poly `0x1021`) |
| `doorbell.v` | Node DMA doorbell FSM — fires on byte count + CRC + DEST match, `NODE_ERR` on refusal |
| `pe_tile_stub.v` | Processing Element (PE) tile — AXI-Stream slave→master elastic pipe (1–2 cycle MAC latency) running a bias-add kernel (`KERNEL_CONST`) with in-silicon CRC-16 validate + recompute (`corrupt_out` doorbell verdict); carries the node's routing bitmap and mask-compares the DEST nibble against DIST (`route_err`) |
| `node.v` | **Compute node** — one MoE expert pass (gate/up → gelu-tanh·up → down) on a `CU_TYPE`-selectable numeric ASIC (BF16/FP16/FP32/FP64/INT8/INT4/FP4/MXFP4) behind a shared `c = a*b + c` accumulate interface and FSM; converges with the router's fused-FMA datapath. Supersedes the `pe_tile_stub` bias-add placeholder as the node's real MAC |
| **Compute units** | |
| `fp16_fma.v` | FP16 Fused Multiply-Add (3-cycle pipeline) |
| `bf16_fma.v` | BF16 Fused Multiply-Add (3-cycle pipeline) |
| `fp32_fma.v` | FP32 Fused Multiply-Add (3-cycle pipeline) |
| `fp64_fma.v` | FP64 Fused Multiply-Add (3-cycle pipeline) |
| `fp16_mac_array.v` | FP16 systolic MAC array |
| `bf16_mac_array.v` | BF16 systolic MAC array |
| `fp32_alu.v` | FP32 ALU: ADD, SUB, MUL, DIV, MIN, MAX, CMP (4-cycle FMA path, 28-cycle div) |
| `fp32_alu_chip.v` | FP32 ALU chip — wraps `fp32_alu.v` with AXI-Stream flit interface for PNM fabric integration |
| `int8_mac.v` | INT8 multiply-accumulate |
| **Fabric integration** | |
| `pnm_host_bridge.v` | The CPU-less router bridge — PNM router engine, SRAM, host register window (SPI on a Pi, or any third-party MCU) |
| `kv_cache_bank.v` | KV cache bank (on-node) |
| `kv_offload.v` | KV cache offload engine |
| `moe_gating.v` | MoE expert gating (top-K selection) |
| **Memory \& interconnect** | |
| `lpddr6_camm.v` | Behavioral LPCAMM2/LPDDR6 module (banked array, CAS-latency wait, refresh scheduler); parameterized across DDR4/DDR5 SODIMM timing generations |
| `sodimm_ctrl.v` | Banked DDR SODIMM memory controller — per-bank open-row tracker + ACT/PRE/CAS FSM (ST\_WAIT\_RAS → ST\_PRE → ST\_RCD → ST\_CAS), tRAS enforcement, byte-enable masking, refresh storms; same bus contract as `lpddr6_camm` |
| `pcb_link.v` | PCB trace model — shift-register delay line of ⌈DELAY\_NS/10⌉ cycles, SOP/EOP/data bit-exact; `pcb_triple_link` wraps three for X/Y/spine populations |
| `optical_link.v` | Optical inter-chassis link — dual-clock async elastic FIFO (gray-coded pointers, 2-FF syncs) + propagation pipe (E/O + fiber at 4.9 ns/m + O/E); SOP/EOP preserved end-to-end; write-side occupancy-threshold flow control; `optical_pair` composes two links into one bidirectional port |
| **Testbenches** | |
| `tb_fabric.v` | Functional smoke test |
| `tb_load.v` | 500-packet load test with backpressure + real CRC-16 injection |
| `tb_doorbell.v` | Doorbell FSM test: `pe_tile_stub` → `doorbell`, 6 activations + 2 rejections (truncated, wrong DEST), 2 `corrupt_out` pulses, 1 `route_err` |
| `tb_fp16_fma.v` | FP16 FMA testbench |
| `tb_bf16_fma.v` | BF16 FMA testbench |
| `tb_fp32_fma.v` | FP32 FMA testbench |
| `tb_fp64_fma.v` | FP64 FMA testbench |
| `tb_fp32_alu.v` | FP32 ALU testbench (ADD/SUB/MUL/DIV/MIN/MAX/CMP) |
| `tb_fp16_mac_array.v` | FP16 MAC array testbench |
| `tb_bf16_mac_array.v` | BF16 MAC array testbench |
| `tb_int8_mac.v` | INT8 MAC testbench |
| `tb_pnm_host_bridge.v` | Host bridge testbench — the TB plays the host and checks the emitted flit and the counters |
| `tb_host_path_e2e.v` | The whole host path — SPI adapter, arbiter, and bridge composed, over the real SPI frame protocol |
| `tb_gating_modes.v` | The two gating managers — the same weights and the same hidden state programmed through the embedded node's bus and through the fabric, requiring the same top-K decision |
| `tb_moe_gating.v` | MoE gating testbench |
| `tb_node.v` | Compute-node testbench — boots expert weights, streams the hidden vector, dumps gate/up/act/out (`node_reference_test.py` drives it; BF16 + INT8 bit-exact) |
| `tb_dma_lpddr6.v` | Host→BMC→DMA→LPDDR6 roundtrip with mid-transfer refresh stalls |
| `tb_sodimm_lpddr.v` | Same protocol stack across DDR4/DDR5/LPDDR6 timing generations |
| `tb_pcb_link.v` | PCB links: passthrough, exact latency, 200-packet stream, triple-link counter |
| `tb_sodimm_ctrl.v` | Banked DDR controller: cold/hit/conflict latencies in closed form, tRAS wait insertion, BE masking, refresh storm, DDR4 vs DDR5 sweep (`*** SODIMM CTRL TEST PASSED ***`) |
| `tb_optical_link.v` | Optical links: idle latency (PROP\_CYCLES+5), burst SOP/EOP alignment, flood zero-loss, gapped packets, async 100↔80 MHz CDC with ready deassertion, bidirectional pair (`*** OPTICAL LINK TEST PASSED ***`) |

## Compute units

Each node's PE tile (`pe_tile_stub.v`) instantiates one of several compute unit types selected by the model compiler:

| Module | Type | Precision | Latency | Use case |
|--------|------|-----------|---------|----------|
| `bf16_fma.v` | FMA | BF16 | 3 cycles | MoE experts, dense MLP |
| `fp16_fma.v` | FMA | FP16 | 3 cycles | FP16 models |
| `fp32_fma.v` | FMA | FP32 | 3 cycles | High-precision compute |
| `fp64_fma.v` | FMA | FP64 | 3 cycles | Double-precision scientific |
| `bf16_mac_array.v` | Systolic array | BF16 | variable | Attention QKV |
| `fp16_mac_array.v` | Systolic array | FP16 | variable | FP16 attention |
| `fp32_alu.v` | ALU | FP32 | 3 (MIN/MAX/CMP), 4 (FMA), 28 (DIV) | Layernorm (divider + multiplier) |
| `fp32_alu_chip.v` | ALU chip | FP32 | 5-29 cycles | AXI-Stream integrated ALU for fabric |
| `int8_mac.v` | MAC | INT8 | 2 cycles | Quantized inference |
| `int4_mac.v` | MAC | INT4 | 2 cycles | INT4 quantized (packed nibbles) |
| `int4_mac_array.v` | Systolic array | INT4/INT8 | variable | INT4 quantized inference (4x density) |
| `fp4_mac.v` | MAC | FP4 (E2M1) | 2 cycles | FP4 quantized (packed nibbles) |
| `fp4_mac_array.v` | Systolic array | FP4 | variable | FP4 quantized inference (4x density vs BF16) |
| `mxfp4_mac_array.v` | Systolic array | MXFP4 | variable | MXFP4 (block-scaled E2M1) inference |
| `weight_dequant.v` | Dequantizer | INT4/INT8/FP4/MXFP4 → BF16 | 1 cycle | Weight-only quantization |

All FMA modules share an identical interface: `clk, rst_n, a, b, c, valid_in → result, valid_out`
(3-cycle pipeline). The `pe_tile_stub.v` uses `USE_FMA` (0=bias-add, 1=BF16 FMA) and `CU_TYPE`
(0=bias-add, 1=BF16 FMA, 2=INT4 MAC, 3=FP4 MAC, 4=MXFP4 MAC) parameters to select the compute path.
`node.v` is the real expert MAC: its `CU_TYPE` (0..7) selects the embedded engine from the
table above behind one shared accumulate interface, and `WIDTH` (16/16/32/64/8/8/8/8) must
match. Bit-exact RTL validation for CU 0 (BF16) and CU 4 (INT8) lives in
`core/node_reference_test.py` (`--cu N`, plus `--real` for a real layer-0 expert).

## Packet format (byte-wide links, CRC-protected destination)

```
wire format:
byte 0 : LAYER_ID            (stripped by lxy_repeater)
byte 1 : MODULE_ID = {X[3:0], Y[3:0]}   (forwarded to DMA as DEST)
byte 2 : CTRL      = {vc_class[7:6], op[5:4], rsvd[3:0]}
byte 3 : LEN_LO
byte 4 : LEN_HI
byte 5.. : payload (LEN bytes)
last 2 : CRC-16, covers [MODULE_ID, CTRL, LEN_LO, LEN_HI, payload]

node DMA stream (= wire[1:]): DEST | CTRL | LEN_LO | LEN_HI | payload | CRC_HI | CRC_LO
```

The `lxy_repeater` strips `LAYER_ID`; `node_eject` **forwards** `MODULE_ID` unchanged,
so the DMA stream's DEST byte and the two trailing CRC bytes are all inside CRC
coverage. The doorbell requires the landed byte count to equal `LEN+6` (DEST + CTRL +
2 length + payload + 2 CRC), the CRC to validate, and DEST to equal the node's own
coordinate `{X[3:0], Y[3:0]}`.

## Routing bitmap (11 bits, `pnm_defs.vh`)

Every repeater and node carries a pre-loaded routing-table entry (paper §2.1/§2.8)
that drives its bit-mask comparator:

```
bit [10:7] LAYER : 4-bit layer ID, 1-based (matches LAYER_ID low nibble)
bit [6]    AXIS  : 0 = X, 1 = Y
bit [5]    SIGN  : 0 = +, 1 = -
bit [4:0]  DIST  : hop distance from the lxy_repeater
```

- `lxy_repeater` masks `in_data ^ {4'h0, LAYER}` with `0x0F` to gate flits onto the
  board (spine `LAYER_ID` bytes are 1..8, so the low nibble is the value).
- `hfr` repeats the same layer mask as a pure-combinational monitor (`layer_match`);
  the data path stays a stateless pipe.
- `pe_tile_stub` holds its node's entry and mask-selects the DEST nibble by AXIS
  (`route_err` when the nibble != DIST). `LAYER`/`SIGN` are not re-checkable at the
  node: `LAYER_ID` was stripped at the repeater and the DMA stream carries no direction.
- `pe_tile_stub` also runs the CRC half of the doorbell in silicon: it validates the
  incoming end-to-end CRC while streaming and pulses `corrupt_out` on failure — the
  hardware verdict the co-sim records as the node's refusal (Paper §2.9).
- `flit_gate` takes `match_value`/`match_mask` as runtime inputs rather than
  parameters, so a gate's decision can be reprogrammed at boot like the paper's
  immutable routing tables.

## PE tile stub (`pe_tile_stub.v`)

The fabric decouples transport from computation behind a standard AXI-Stream /
Ready-Valid Processing Element (PE) interface, so the underlying execution block
(systolic array, FP16 MAC array, or ALU) can be swapped independently of the
routing fabric. `pe_tile_stub.v` is the placeholder for the MAC unit: it consumes
a flit byte on `s_axis`, holds it in an elastic pipe for `MULT_LATENCY` clock
cycles (the modelled multiply-accumulate latency, 1–2), and re-presents it on
`m_axis`, owning the `s_axis_tready` / `m_axis_tvalid` handshake flags. Framing
rides along: `s_axis_tlast`/`m_axis_tlast` (EOP) and `s_axis_tstart`/
`m_axis_tstart` (SOP, the packet head) pass through the elastic pipe unchanged.

The stub **computes**: its resident kernel is an element-wise bias add — every
payload byte is emitted as `(payload[i] + KERNEL_CONST) mod 256` — and the trailing
CRC bytes are replaced by a CRC-16/CCITT-FALSE recomputed over the transformed body
(`crc16.v`, the hardware twin of `sim/internal/pnm/crc.go`). While streaming, the stub
also validates the *incoming* CRC (over the unmodified body): on failure it pulses
`corrupt_out`, the hardware doorbell verdict, which the co-sim harness (`cmd/pnm`)
records as the
node's refusal. With `KERNEL_CONST = 0` the recomputed CRC equals the incoming one
and the stub is byte-exact — a pure latency pipe — so existing testbenches are
unchanged by the compute. The node's 11-bit `routing_bitmap` (its routing-table
entry) rides alongside and the stub mask-checks every packet head: `route_err`
pulses when the AXIS-selected DEST nibble differs from DIST (`tb_doorbell.v` drives
layer 1, Y, +, dist 5 for node `0x25` and expects exactly one `route_err` — the
wrong-DEST packet).

## Build & run

Requires [Icarus Verilog](https://steveicarus.github.io/iverilog/) (`iverilog`, `vvp`).

```bash
# smoke test
iverilog -g2005 -o tb_fabric.out \
  hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_fabric.v
vvp tb_fabric.out

# load test (500 packets, mixed destinations, 25–100% sink ready, real CRC-16)
iverilog -g2005 -o tb_load.out \
  hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_load.v
vvp tb_load.out

# doorbell DMA (pe_tile_stub → doorbell, CRC-16 end-to-end)
iverilog -g2005 -o tb_doorbell.out \
  core/tb_doorbell.v core/pe_tile_stub.v core/doorbell.v core/crc16.v core/bf16_fma.v core/fma_core.v core/weight_dequant.v core/int8_mac.v core/fp4_mac.v
vvp tb_doorbell.out

# banked DDR SODIMM controller (row hit/miss/conflict latencies, refresh)
iverilog -g2005 -o tb_sodimm_ctrl.out sodimm_ctrl.v tb_sodimm_ctrl.v
vvp tb_sodimm_ctrl.out

# optical inter-chassis links (async CDC FIFO + fiber propagation pipe)
iverilog -g2005 -o tb_optical_link.out optical_link.v tb_optical_link.v
vvp tb_optical_link.out
```

On NixOS:

```bash
nix-shell -p iverilog --run \
  'iverilog -g2005 -o tb_load.out hfr.v flit_gate.v vc_merge.v lxy_repeater.v xy_turn.v node_eject.v tb_load.v && vvp tb_load.out'
```

## Memory and interconnect models

### SODIMM memory controller (`sodimm_ctrl.v`)

Unlike the behavioral `lpddr6_camm`, this is a real banked DDR controller. A
per-bank tracker holds each bank's open row and tRAS countdown and drives an
ACT/PRE/CAS micro-FSM (`ST_WAIT_RAS → ST_PRE → ST_RCD → ST_CAS`):

| Access type | Latency |
|-------------|---------|
| Row hit (bank open, row matches) | CL |
| Cold access (bank closed) | tRCD + CL |
| Row conflict (bank open, different row) | tRP + tRCD + CL |

tRAS is enforced between activate and precharge: a conflict arriving before
tRAS expires waits out the remainder first, so latencies stay deterministic
under any command order.

Byte-enable write masking, a refresh scheduler that closes all banks and drops
`bus_ready` for `REFRESH_BURST` cycles every `REFRESH_CYCLES` (accepted
commands are never dropped), and rd/wr/refresh activity counters complete the
model. The bus interface is pin-compatible with `lpddr6_camm` (valid/ready,
byte address, ready-down-until-complete), so it sits behind `pnm_arb`
unchanged. The testbench drives three profiles — DDR4-like (CL/tRCD/tRP 15,
tRAS 38), DDR5-like (36/36/36/44), and a short-interval refresh-storm stress
unit — and checks exact closed-form latencies, tRAS wait insertion under
immediate conflict, 64-word readback integrity, partial-byte-write masking
(expects `DE11BE11`), stall accounting through the storm, and the DDR4-vs-DDR5
cold-latency ordering.

### Optical inter-chassis link (`optical_link.v`)

The physical realization of the paper's multi-chassis scale-out path
(§3.7/§4.4). Each unidirectional link is:

```
tx domain                          rx domain
-----------                        ----------
tx_data/valid/sop/eop ──▶ [async elastic FIFO] ──▶ [prop pipe ×PROP_CYCLES] ──▶ rx_data/valid/sop/eop
        ▲              gray ptrs, 2-FF syncs      E/O + fiber + O/E          registered output
        │
   tx_ready = (gray-synced occupancy < READY_LIMIT)
   READY_LIMIT = FIFO_DEPTH − PROP_CYCLES − 2
```

- **Framing**: every entry packs `{sop, eop, data}`, so packet delimiters
  survive the hop bit-exactly and the fabric wire format is unchanged on both
  sides.
- **Clocking**: write and read pointers cross domains as Gray codes through
  two-flop synchronizers; the read side pops unconditionally whenever
  non-empty, keeping the return path entirely out of the crossing domain.
- **Flow control**: all backpressure is write-side. `tx_ready` deasserts at
  the occupancy threshold, which guarantees no overflow for any
  ready-respecting producer; a protocol violation latches sticky
  `overflow_err`. Word and packet counters instrument both directions.
- **Latency**: `PROP_CYCLES = ceil((E_O_NS + FIBER_M×4.9 + O_E_NS)/10)` models
  conversion + transit at the physical speed of light in glass (≈4.9 ns/m) +
  recovery. Measured idle-link latency is `PROP_CYCLES + 5` cycles at 100 MHz
  (synchronizer visibility + pop + pipe + output register): 7 cycles for the
  default 2 m span.
- **`optical_pair`**: two links sharing one reset form a bidirectional
  chassis-to-chassis port with an aggregate packet counter.

`tb_optical_link.v` instantiates a same-clock unit, an asynchronous 100↔80 MHz
pair, and a bidirectional pair, and verifies: exact idle latency, a 200-word
burst byte-exact with SOP/EOP alignment, a 600-word back-to-back flood with
zero loss and no overflow flag, sparse packets across idle gaps held in order,
the async crossing under sustained overload (observing `tx_ready` deassert),
and simultaneous bidirectional traffic.

## Scope / non-goals

- Single physical channel per link (paper VC classes → parallel instances)
- `doorbell.v` implements the three-condition fire (byte count + CRC + DEST) and the
  `NODE_ERR` refusal path; it does not model DMA burst scheduling into DRAM banks
- Byte-wide links for readability, not peak bandwidth modeling

See `../Paper.MD` §§2–4 for the architectural specification.

## IR toolchains (in `sim/internal/pnm/`)

The co-simulation harness includes three source-language-to-IR compilers that target
the HDL compute units:

| Toolchain | Source language | Target | File |
|-----------|----------------|--------|------|
| `CompileR` | R (statistical computing) | FP64 (`fp64_fma.v`) | `r_ir.go` |
| `CompileHaskell` | Haskell (functional) | FP64 (`fp64_fma.v`) | `haskell_ir.go` |
| `CompileHLSL` | HLSL (GPU shading) | FP32 ALU (`fp32_alu.v`) | `hlsl_ir.go` |

### FP64 IR format (R and Haskell)

```
f64.load  r0, [addr]          # load FP64 from memory
f64.store [addr], r0          # store FP64 to memory
f64.add   r0, r1, r2          # r0 = r1 + r2 (FP64)
f64.mul   r0, r1, r2          # r0 = r1 * r2
f64.fma   r0, r1, r2, r3      # r0 = r1*r2 + r3 (fp64_fma.v)
f64.div   r0, r1, r2          # r0 = r1 / r2
f64.min   r0, r1, r2          # r0 = min(r1, r2)
f64.max   r0, r1, r2          # r0 = max(r1, r2)
f64.cmp   r0, r1, r2, ==      # r0 = (r1 == r2) ? 1.0 : 0.0
f64.mov   r0, r1              # r0 = r1
f64.const r0, 3.14159         # r0 = literal
```

### FP32 ALU IR format (HLSL)

```
alu.load  r0, [addr]          # load FP32 from memory
alu.store [addr], r0          # store FP32 to memory
alu.add   r0, r1, r2          # r0 = r1 + r2 (FP32)
alu.sub   r0, r1, r2          # r0 = r1 - r2
alu.mul   r0, r1, r2          # r0 = r1 * r2
alu.div   r0, r1, r2          # r0 = r1 / r2 (28-cycle restoring div)
alu.min   r0, r1, r2          # r0 = min(r1, r2)
alu.max   r0, r1, r2          # r0 = max(r1, r2)
alu.cmp   r0, r1, r2, >=      # r0 = (r1 >= r2) ? 1.0 : 0.0
alu.dot   r0, r1, r2          # dot product (expanded to mul+add chain)
alu.lerp  r0, r1, r2, r3      # lerp(a,b,t) = a + t*(b-a)
alu.clamp r0, r1, r2, r3      # clamp(x, lo, hi)
alu.rcp   r0, r1              # reciprocal (1/x)
```

### HLSL intrinsics supported

`dot`, `lerp`/`mix`, `clamp`, `saturate`, `abs`, `min`, `max`, `rcp`, `sqrt`,
`step`, `smoothstep`, `mul`, vector constructors (`float4`/`float3`/`float2`).

### Transpilation pipeline (source → hardware)

```
Source code (R / Haskell / HLSL)
  │
  ├─ Parse: language-specific front end (r_ir.go / haskell_ir.go / hlsl_ir.go)
  │   └─ Extract assignments, arithmetic, function calls, conditionals
  │
  ├─ IR emission: typed register-based instruction set
  │   ├─ FP64 IR  (11 opcodes) → fp64_fma.v  (R, Haskell)
  │   └─ FP32 ALU IR (14 opcodes) → fp32_alu.v (HLSL)
  │
  ├─ Compute unit selection (model compiler)
  │   ├─ BF16 FMA    → MoE experts, dense MLP
  │   ├─ BF16 array  → attention QKV
  │   ├─ FP32 ALU    → layernorm (div + mul)
  │   └─ FP64 FMA    → scientific/R/Haskell workloads
  │
  └─ Flit emission: wrap result in wormhole packet
      └─ LAYER_ID | MODULE_ID | CTRL | LEN | payload | CRC-16
```

The compilers are **ahead-of-time (AOT)**: they run on the host, produce a
sequence of register operations, and the firmware dispatches each operation to
the appropriate compute unit node. No JIT compilation or runtime linking
occurs on the router chip.

### IR-to-compute-unit mapping

| IR opcode | HDL module | Latency | Notes |
|-----------|-----------|---------|-------|
| `f64.fma` | `fp64_fma.v` | 3 cycles | Double-precision FMA |
| `f64.div` | `fp64_fma.v` | 3 cycles | Uses FMA's add path for div |
| `f64.add/mul/min/max/cmp` | `fp64_fma.v` | 3 cycles | All via FMA pipeline |
| `alu.add/sub/mul` | `fp32_alu.v` | 4 cycles | Via internal `fp32_fma` |
| `alu.div` | `fp32_alu.v` | 28 cycles | Left-shifting restoring division |
| `alu.min/max/cmp` | `fp32_alu.v` | 3 cycles | Pipelined signed comparison |
| `alu.dot` | `fp32_alu.v` | N×4 cycles | Expanded to N multiply+add ops |
| `alu.lerp` | `fp32_alu.v` | 3×4 cycles | `a + t*(b-a)` via MUL+ADD |
| `alu.clamp` | `fp32_alu.v` | 2×4 cycles | Two MIN/MAX operations |
| `alu.rcp` | software-lowered | ~27 cycles | Not an ALU datapath; lowered via div/cmp-select in the IR compilers |
| `alu.sqrt` | software-lowered | ~24 cycles | Not an ALU datapath; binary compare-select ladder in the IR compilers |
| BF16 FMA | `bf16_fma.v` | 3 cycles | MoE expert compute |
| BF16 array | `bf16_mac_array.v` | variable | Systolic attention QKV |
| INT8 MAC | `int8_mac.v` | 2 cycles | Quantized inference |

### Toolchain limitations

The IR compilers target a **minimal register-based instruction set** with no
loops, branches, or dynamic allocation. Supported constructs:

| Language | Supported | Not supported |
|----------|-----------|---------------|
| **R** | Assignments, `+` `-` `*` `/`, comparisons, `sum` `mean` `min` `max` `prod` `sqrt` `abs` | Loops, `for`/`while`, arrays, `list`, recursion, `apply`, `paste` (skipped), `c()` (skipped) |
| **Haskell** | Function defs, guards, `let`/`in`, `do` blocks, `if`/`then`/`else`, `+` `-` `*` `/`, comparisons, `sum` `product` `minimum` `maximum` `abs` `sqrt` | Recursion, pattern matching, `where` clauses, lists, monads, type classes, guards with complex expressions |
| **HLSL** | `float`/`int`/`half` vars, `return`, ternary `?:`, `dot` `lerp` `clamp` `saturate` `abs` `min` `max` `rcp` `sqrt` `step` `smoothstep`, vector constructors (`float4`/`float3`/`float2`/`half`×N) | Loops, `if`/`else` blocks (only ternary), textures, samplers, vertex/fragment stages, matrices |

All three compilers produce **straight-line code**: the IR is a linear sequence
of instructions with no control flow. This is sufficient for inference
workloads (forward pass only) but not for training or iterative algorithms.

### The host path, end to end (`pnm_host_top.v`)

`pnm_host_top.v` is the host bridge board's top level: it composes
`pi_bridge` (the SPI adapter) -> `pnm_arb` (the round-robin arbiter) ->
`pnm_host_bridge` (the router engine) and owns the address map, so the
arbiter's 8-bit byte offset and the bridge's 32-bit window are reconciled in
one place.

This module existed because the host path was never simulated.  Every
host-path testbench drove a *model* of the chip: `tb_host_bmc.v` and
`tb_dma_lpddr6.v` drove the SPI adapter and the arbiter into register files
they defined inside the testbench, and `tb_pnm_host_bridge.v` drove the
bridge alone.  The composition was not checked, and it did not work: the
arbiter's byte offset never selected a slave in the bridge, and the
bridge's registered read data was sampled by the arbiter one cycle before it
was updated, so every register read returned zero.  `tb_host_path_e2e.v`
(now the regression for both) drives the real chain over SPI with the same
48-bit frame the Raspberry Pi drivers speak, and checks a register
read-back, a byte-exact wormhole flit with an independently computed CRC-16,
the fabric's acceptance of that flit, and the result path.

The bridge's PNM read path is combinational for the same reason the 16550
and the gating ASIC present theirs: a registered read would be sampled one
cycle early by the arbiter.

### The host bridge (`pnm_host_bridge.v`)

The router bridge is the only stateful silicon in the fabric, and it has **no
processor**: no CPU, no boot ROM, no timer, no console. It is a bridge the
host drives. The host runs the boot sequence, the weight upload and the
dispatch loop; the bridge keeps the hardware that must be hardware:

| Block | What it does |
|-------|-------------|
| PNM router engine | Flit builder (LAYER_ID, MODULE_ID, CTRL, LEN, payload, CRC-16/CCITT-FALSE), POST discovery, coordinate mapping, spine injection |
| SRAM | 64 KB: the routing table, the MoE map, and the host's staging area |
| Host register window | The route/payload/status/counter registers the host writes through |
| Host bus | The port the host attaches to: SPI (via `pi_bridge.v`) or PCIe |

Because the sequencing lives in the host, the same silicon serves a Raspberry
Pi, a microcontroller, or a workstation. `tb_pnm_host_bridge.v` plays the host:
it writes the routing and payload registers and checks that the chip emits a
byte-exact wormhole flit (header, payload, CRC over the protected body,
SOP/EOP) and that the result path and counters read back. `tb_host_bmc.v`
drives the same bridge from a Raspberry Pi model over the SPI adapter, through
the two-port arbiter (`pnm_arb`).

### The gating ASIC and its two managers (`core/gating_asic.v`)

The gating ASIC is a **per-node** device: it holds the router weights and
produces the expert decision for each token that lands on its node. It has two
management paths onto one register file, and a strapping pin (`mgmt_sel`)
selects which one is live:

| Mode | Manager | Interface |
|------|---------|-----------|
| **A** | The embedded management node on the node board (an MCU or a Raspberry Pi Compute Module) | The management bus `mgmt_addr/wdata/rdata/we/valid/ready` — a direct local bus |
| **B** | The host | The fabric-side programming port `prog_data/valid/sop/eop` — the host's bytes, decoded into the same register map |

Mode A is for the board that owns the node: the embedded node also masters the
node's NoB, so it reaches the memory behind the node and can read the token's
hidden state out of local DRAM. It programs the gating weights once at setup
and then takes each token's decision locally — the decision never crosses the
fabric.

Mode B is for the host that owns the machine: it can reprogram the router of
any node at any time, and the same host firmware drives a Pi, a microcontroller
or a workstation.

The two modes are the same silicon and the same register map, so the decision
is identical either way. `tb_gating_modes.v` programs the same weights and the
same hidden state through each path and requires the same top-K selection.

What differs is only what crosses the fabric: in mode A the gating weights
cross once (0.3–1 MB of BF16 per layer) and no per-token management traffic
crosses at all; in mode B every weight byte crosses and every token's decision
crosses back (256 bytes of logits, or 8 bytes for the top-K identifiers, per
token per layer) on the same fabric that is already the capacity bottleneck.

### KV cache architecture

Two modules manage the key-value cache on each node:

#### `kv_cache_bank.v`

On-node SRAM bank that stores KV pairs for attention layers. It operates as a
**pass-through with injection**: normal flits pass through transparently, but
when a KV store/load command arrives, the bank intercepts the flit and either
writes payload bytes to SRAM (store) or reads them back (load).

The bank tracks:
- `write_ptr` / `read_ptr`: circular buffer pointers
- `ks_state`: KV store FSM (header capture → payload capture → done)
- `kl_state`: KV load FSM (header capture → SRAM read → flit injection)

Eviction is LRU: when the bank is full, the oldest entry is overwritten. The
`reclaim_*` interface allows the offload engine to read evicted entries.

#### `kv_offload.v`

Offload engine that transfers KV pairs between node SRAM and the host via the
spine. It monitors `kv_cache_bank` for eviction events and constructs
appropriate flits for host-side storage. The offload path uses VC class 3
(highest priority) to avoid stalling compute traffic.
