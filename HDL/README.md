# PNM Fabric HDL Sketch

Verilog-2005 model of the **routing fabric**, **compute units**, and **co-simulation harness** from the paper *Bypassing the HBM Wall*.

## Modules

| File | Role |
|---|---|
| `pnm_defs.vh` | Packet format, VC constants, routing-bitmap layout |
| `hfr.v` | Hardware Flit Repeater (1-stage elastic pipe) + layer bit-mask comparator (monitor) |
| `flit_gate.v` | Combinational-match wormhole demux (shared core); match value/mask are runtime inputs (pre-loaded routing table) |
| `vc_merge.v` | 2-in/1-out round-robin packet-atomic merge for the reverse (egress) paths — node TX → Y-up → X-up → xyz_repeater → up-spine (paper §2.9/§4.3) |
| `xyz_repeater.v` | Z-axis repeater (layer ID compare + strip); compare driven by the routing bitmap's LAYER field; egress port wraps `vc_merge` |
| `xy_turn.v` | X→Y dimension-order turn gate |
| `node_eject.v` | Y-lane → node DMA eject gate (forwards `MODULE_ID` as DEST) |
| `crc16.v` | Byte-wise CRC-16/CCITT-FALSE (init `0xFFFF`, poly `0x1021`) |
| `doorbell.v` | Node DMA doorbell FSM — fires on byte count + CRC + DEST match, `NODE_ERR` on refusal |
| `pe_tile_stub.v` | Processing Element (PE) tile — AXI-Stream slave→master elastic pipe (1–2 cycle MAC latency) running a bias-add kernel (`KERNEL_CONST`) with in-silicon CRC-16 validate + recompute (`corrupt_out` doorbell verdict); carries the node's routing bitmap and mask-compares the DEST nibble against DIST (`route_err`) |
| **Compute units** | |
| `fp16_fma.v` | FP16 Fused Multiply-Add (3-cycle pipeline) |
| `bf16_fma.v` | BF16 Fused Multiply-Add (3-cycle pipeline) |
| `fp32_fma.v` | FP32 Fused Multiply-Add (3-cycle pipeline) |
| `fp64_fma.v` | FP64 Fused Multiply-Add (3-cycle pipeline) |
| `fp16_mac_array.v` | FP16 systolic MAC array |
| `bf16_mac_array.v` | BF16 systolic MAC array |
| `fp32_alu.v` | FP32 ALU: ADD, SUB, MUL, DIV, MIN, MAX, CMP (4-cycle FMA path, 25-cycle div) |
| `fp32_alu_chip.v` | FP32 ALU chip — wraps `fp32_alu.v` with AXI-Stream flit interface for PNM fabric integration |
| `int8_mac.v` | INT8 multiply-accumulate |
| **Fabric integration** | |
| `router_chip.v` | Central router chip — PCIe ingress, flit builder, POST discovery FSM, spine injection |
| `kv_cache_bank.v` | KV cache bank (on-node) |
| `kv_offload.v` | KV cache offload engine |
| `moe_gating.v` | MoE expert gating (top-K selection) |
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
| `tb_router_chip.v` | Router chip testbench |
| `tb_moe_gating.v` | MoE gating testbench |

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
| `fp32_alu.v` | ALU | FP32 | 1-25 cycles | Layernorm (divider + multiplier) |
| `fp32_alu_chip.v` | ALU chip | FP32 | 5-29 cycles | AXI-Stream integrated ALU for fabric |
| `int8_mac.v` | MAC | INT8 | 1 cycle | Quantized inference |

All FMA modules share an identical interface: `clk, rst_n, a, b, c, valid_in → result, valid_out`
(3-cycle pipeline). The `pe_tile_stub.v` uses `USE_FMA` parameter to select between
bias-add (0) and BF16 FMA (1) compute paths.

## Packet format (byte-wide links, CRC-protected destination)

```
wire format:
byte 0 : LAYER_ID            (stripped by xyz_repeater)
byte 1 : MODULE_ID = {X[3:0], Y[3:0]}   (forwarded to DMA as DEST)
byte 2 : CTRL      = {vc_class[1:0], op[1:0], rsvd[3:0]}
byte 3 : LEN_LO
byte 4 : LEN_HI
byte 5.. : payload (LEN bytes)
last 2 : CRC-16, covers [MODULE_ID, CTRL, LEN_LO, LEN_HI, payload]

node DMA stream (= wire[1:]): DEST | CTRL | LEN_LO | LEN_HI | payload | CRC_HI | CRC_LO
```

The `xyz_repeater` strips `LAYER_ID`; `node_eject` **forwards** `MODULE_ID` unchanged,
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
bit [4:0]  DIST  : hop distance from the xyz_repeater
```

- `xyz_repeater` masks `in_data ^ {4'h0, LAYER}` with `0x0F` to gate flits onto the
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
  hfr.v flit_gate.v vc_merge.v xyz_repeater.v xy_turn.v node_eject.v tb_fabric.v
vvp tb_fabric.out

# load test (500 packets, mixed destinations, 25–100% sink ready, real CRC-16)
iverilog -g2005 -o tb_load.out \
  hfr.v flit_gate.v vc_merge.v xyz_repeater.v xy_turn.v node_eject.v tb_load.v
vvp tb_load.out

# doorbell DMA (pe_tile_stub → doorbell, CRC-16 end-to-end)
iverilog -g2005 -o tb_doorbell.out \
  tb_doorbell.v pe_tile_stub.v doorbell.v crc16.v
vvp tb_doorbell.out
```

On NixOS:

```bash
nix-shell -p iverilog --run \
  'iverilog -g2005 -o tb_load.out hfr.v flit_gate.v vc_merge.v xyz_repeater.v xy_turn.v node_eject.v tb_load.v && vvp tb_load.out'
```

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
alu.div   r0, r1, r2          # r0 = r1 / r2 (25-cycle restoring div)
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
| `alu.div` | `fp32_alu.v` | 27 cycles | Left-shifting restoring division |
| `alu.min/max/cmp` | `fp32_alu.v` | 4 cycles | Pipelined signed comparison |
| `alu.dot` | `fp32_alu.v` | N×4 cycles | Expanded to N multiply+add ops |
| `alu.lerp` | `fp32_alu.v` | 3×4 cycles | `a + t*(b-a)` via MUL+ADD |
| `alu.clamp` | `fp32_alu.v` | 2×4 cycles | Two MIN/MAX operations |
| `alu.rcp` | `fp32_alu.v` | 27 cycles | Reciprocal via division |
| `alu.sqrt` | `fp32_alu.v` | ~24 cycles | Newton-Raphson iteration |
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

### Router chip architecture (`router_chip.v`)

The router chip is the only stateful silicon in the fabric. It contains four
independent FSMs that run concurrently:

#### 1. Boot FSM (`boot_state`, 7 states)

```
BOOT_RESET → BOOT_POST_PING → BOOT_POST_WAIT → BOOT_LOAD_RT
  → BOOT_LOAD_WT → BOOT_LOAD_MOE → BOOT_READY
```

| Phase | State | What it does |
|-------|-------|-------------|
| POST discovery | `BOOT_POST_PING` | Sends ping flits to all nodes, latches `topology_rdy` bits for 256 cycles |
| | `BOOT_POST_WAIT` | Popcount of latched bits → node count |
| Routing table | `BOOT_LOAD_RT` | Programs xyz_repeaters/HFRs with 11-bit routing bitmaps via PCIe cmd `0x02` |
| Weight upload | `BOOT_LOAD_WT` | Receives weight blobs from host via PCIe cmd `0x01`, wraps in wormhole flits, injects into spine |
| MoE gating | `BOOT_LOAD_MOE` | Loads `router.proj.weight` into on-chip SRAM + expert→(layer, module) map via PCIe cmd `0x03` |
| Ready | `BOOT_READY` | Normal operation; `boot_done` asserted |

#### 2. PCIe Ingress Parser (`pie_state`, 8 states)

| Command | State | Description |
|---------|-------|-------------|
| `0x01` | `PIE_WEIGHT_H` → `PIE_WEIGHT_P` | Weight upload: 4-byte header + payload |
| `0x02` | `PIE_RT_NODE` | Routing table entry: node_id + bitmap |
| `0x03` | `PIE_MOE_H` | MoE map entry: expert→(layer, module) |
| `0x04` | `PIE_INF_TOKEN` → `PIE_INF_TOKEN_P` | Inference token: header + hidden state |
| `0xFF` | — | NOP / idle marker |

The parser buffers up to 6 header bytes in `pie_buf[0:5]` and dispatches to the
appropriate sub-FSM. The `weight_load` signal to the MoE gating unit is
asserted when `pie_state == PIE_MOE_H && pie_pos == 3` (4th byte of MoE header).

#### 3. Flit Builder (`fb_state`, 4 states)

Constructs wormhole flits from PCIe data:

```
FB_IDLE → FB_HDR → FB_PAYLOAD → FB_CRC
```

The builder accumulates LAYER_ID, MODULE_ID, CTRL, LEN in the header phase,
streams payload bytes, and appends a running CRC-16/CCITT-FALSE. The completed
flit is injected into the spine.

#### 4. Result Collection (`rc_state`)

Forwards `spine_extract` bytes (returned computation results) back to PCIe
egress. Runs continuously when `spine_extract_valid` is high.

#### MoE gating integration

The router chip instantiates `moe_gating.v` as `u_gating`. The gating unit
receives:
- `weight_load` / `weight_addr` / `weight_data` from the PCIe parser
- `current_layer` from the flit builder
- `expert_idx_packed` / `expert_logit_packed` from the FMA computation

The gating unit performs a **systolic gated matrix-vector multiply** (hidden
state × router weight matrix) and a **top-K selection** (insertion sort into a
sorted buffer of size K). The selected expert indices and logits are packed
into the dispatch flit.

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
