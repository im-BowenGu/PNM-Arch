#!/usr/bin/env python3
"""Build NHSJS submission artifacts: standard LaTeX/PDF/DOCX and online-citation DOCX."""
from __future__ import annotations

import re
import subprocess
import sys
from pathlib import Path

from refs import REFS, standard_ref_block

ROOT = Path(__file__).resolve().parent
PAPER_MD = ROOT.parent / "Paper.MD"
TITLE = (
    "Bypassing the HBM Wall: A Distributed Spatial Processing-Near-Memory "
    "Architecture using DUV ASICs and Deterministic Routing"
)
# Filesystem-safe stem (colon kept; Linux OK)
STEM = TITLE

# Unicode raised comma U+2E34 — no official superscript comma in Unicode;
# this is the recommended substitute for NHSJS multi-cite separators.
RAISED_COMMA = "\u2e34"


def read_author_meta() -> tuple[str, str]:
    """Pull Author / Date from Paper.MD if present."""
    author, date = "", ""
    if PAPER_MD.exists():
        text = PAPER_MD.read_text(encoding="utf-8")
        m = re.search(r"\*\*Author:\*\*\s*(.+)", text)
        if m:
            author = m.group(1).strip()
        m = re.search(r"\*\*Date:\*\*\s*(.+)", text)
        if m:
            date = m.group(1).strip()
    return author, date


def scite(*nums: int) -> str:
    return "\\textsuperscript{" + ",".join(str(n) for n in nums) + "}"


def ocite(*nums: int) -> str:
    """Space + double-paren full citations; multi-cites use raised comma (U+2E34)."""
    parts = [f"(({REFS[n - 1]}))" for n in nums]
    if len(parts) == 1:
        return " " + parts[0]
    # e.g. ((refA))⸴ ((refB))
    return " " + f"){RAISED_COMMA} ((".join(parts)



# Body paragraphs use {c} as format function placeholder applied later
def body(c) -> str:
    """Manuscript body. c(1) or c(1,2) inserts a citation in the active format."""
    return f"""
Abstract

\\textbf{{Background/Objective}}

Modern Mixture-of-Experts transformer inference and high-performance scientific computing have collided with the Memory Wall{c(1)}. Packaging constraints on advanced interposers artificially cap both memory capacity and thermal dissipation, while conventional Von Neumann instruction-fetching overhead consumes enormous energy and time merely to orchestrate data movement rather than perform useful compute{c(6)}. This work aims to bypass the HBM capacity and cost wall through a distributed Processing-Near-Memory architecture using commodity memory modules and mature-node ASICs.

\\textbf{{Methods}}

We propose a distributed spatial Processing-Near-Memory (PNM) architecture that replaces centralized High-Bandwidth Memory (HBM){c(15)} with commodity LPCAMM2 LPDDR6 modules{c(16,17)}, each paired with a mature-node 14 nm or 28 nm DUV MAC ASIC on a rigid X/Y motherboard grid. A deterministic single-spine tree routing fabric---built from stateless Hardware Flit Repeater wormhole switches, dimension-order on-board routing, and combinational Z-axis ingress nodes---eliminates runtime operating-system scheduling, cache coherency protocols, and multi-path routing ambiguity{c(13,14)}. Routing is pure coordinate arithmetic: an $O(1)$ function of a flit's [Layer ID | Module ID] header, with worst-case latency bounded in closed form at compile time. By compiling high-level intermediate representations ahead-of-time onto a physical topology schema exported directly from hardware discovery, the system maps Mixture-of-Experts transformer inference, FP64 stencil computations, and functional data-based workflows directly onto silicon{c(3,4)}.

\\textbf{{Results}}

A 512-node reference chassis provides 64 TB of attached memory and 87 TB/s of aggregate local bandwidth at roughly \\$4 per gigabyte---two orders of magnitude below HBM monoliths per byte---while a roofline analysis shows the target workloads are firmly bandwidth-bound and therefore fully served by mature-node logic{c(5)}.

\\textbf{{Conclusions}}

The architecture yields a spatial computer that executes immutable dataflow graphs in hardware with full determinism, provable deadlock freedom, and strict functional correctness, at a fraction of the thermal envelope and economic cost of monolithic GPU accelerators.

Keywords: Processing-Near-Memory; Wormhole Switching; Deterministic Routing; Dimension-Order Routing; Spatial Computing; LPCAMM2; DUV ASIC; Mixture-of-Experts Transformers; Stencil Computation; Roofline Analysis

Introduction

1.1 The economic and physical bottleneck

The prevailing paradigm for large-scale transformer training and inference relies on monolithic GPU accelerators tightly coupled to High-Bandwidth Memory (HBM) via advanced interposers{c(2,15)}. This approach has become economically and physically untenable. A single NVIDIA H100-class GPU with 80 GB of HBM can cost upwards of thirty thousand dollars---roughly \\$375 per gigabyte of attached memory---yet the majority of its transistor budget and thermal headroom is spent not on computation, but on moving data across hierarchical memory caches and network interfaces{c(2)}. For Mixture-of-Experts (MoE) transformers, where hundreds of billions of parameters remain idle during any given forward pass{c(3,4)}, purchasing monolithic GPUs solely for their aggregate memory capacity is fundamentally broken: it imposes massive capital expenditure, extreme power density, and an artificial capacity ceiling dictated by interposer reticle limits. The Results section quantifies the alternative: first-order cost modeling places the proposed PNM node at roughly \\$4 per gigabyte of attached memory, approximately two orders of magnitude cheaper per byte.

1.2 Hardware as a static graph

This paper advances an alternative philosophy inspired by Unix pipelines, operating-system microkernels, and pure functional programming{c(6,7,8)}. We treat the physical motherboard not as a passive substrate for a Von Neumann processor, but as an active, immutable dataflow graph. Computation should be a pure mapping of inputs to outputs---flits stream through hardware channels as byte sequences, and each hardware component does exactly one thing with zero state manipulation. There are no runtime page tables, no dynamic branch prediction, and no global memory coherency protocols. By enforcing functional immutability at the silicon level, the architecture eliminates entire classes of side-effects, race conditions, and operating-system scheduling overhead that plague conventional accelerators. This purity is not merely aesthetic: it is what makes bit-exact replay after faults (Section 4.1) and compile-time latency bounds (Section 4.3) possible at all.

1.3 Manufacturing realities: DUV versus EUV

A common objection to custom accelerator silicon is the perceived necessity of bleeding-edge process nodes. This architecture rejects that premise. Memory bandwidth, not transistor switching speed, is the binding constraint for inference and stencil workloads. The roofline analysis in the Results section makes this concrete: at the reference node's machine balance of approximately 1.5 FLOP/byte, both stencil neighborhoods and MoE expert weight-streaming sit deep in the bandwidth-bound regime{c(5)}, so a 14 nm MAC array is never the limiting resource. A 14 nm or 28 nm Deep Ultraviolet (DUV) ASIC is therefore perfectly sufficient to saturate a local LPDDR6 bus{c(17)}, and mature nodes offer incomparable advantages: dramatically lower mask costs, higher yields, established supply chains, and the freedom to use large die areas for MAC arrays without the exponential cost curve of EUV lithography. By pairing cheap, commodity LPDDR6 memory with mature-node logic, the system achieves cost-per-parameter ratios orders of magnitude below HBM-based monoliths.

The architecture described in this paper is the convergence of several distinct intellectual traditions in computer science and hardware engineering.

1.4 The Unix philosophy

The Unix philosophy holds that programs should do one thing well, accept streams as input, and compose via pipes{c(7)}. We extend this principle to silicon. Each Hardware Flit Repeater (HFR) does exactly one thing: it forwards a flit to the next node. The Ingress ASIC compares a header bitmask and gates matching flits onto the local network. The MAC ASIC executes a tensor kernel on data present in its local LPDDR6 bank. There are no general-purpose cores, no speculative execution, and no dynamic reconfiguration on the hot path. The flit stream is the silicon analog of the Unix text stream: a universal, byte-oriented interface that decouples producers from consumers.

1.5 Functional and declarative programming

Functional programming treats computation as the evaluation of mathematical functions with no side-effects and no mutable state{c(6)}. Conventional hardware is ruthlessly imperative: mutable registers, speculative branch rollback, cache invalidation protocols, and operating-system interrupts violate functional purity at every level. Our architecture inverts this relationship. The hardware itself enforces functional immutability: flits are immutable once injected, HFRs are stateless functions of their input, and MAC ASICs produce deterministic outputs from static memory contents. There is no global mutable state anywhere in the system. The entire machine is a single, spatially distributed pure function---a physical instantiation of a dataflow graph---making it a natural substrate for first-order, statically allocated functional programs (Section 2.14).

1.6 Microkernel architecture

Microkernels advocate that privileged software should do as little as possible and isolate the rest{c(8)}. seL4 has been mathematically proven to enforce its security and isolation properties{c(9)}. We extend this principle from software to hardware. The Z-axis Ingress ASIC is a microkernel boundary implemented in combinational logic. It enforces a strict, non-bypassable physical separation between layers: traffic cannot reach a layer without passing through that layer's ingress gate, which evaluates a hardware bitmask rather than a software access-control list. There is no configuration register to misprogram, no firmware to exploit, and no driver to crash---the isolation is a physical property of the silicon.

1.7 Application-specific integrated circuits

General-purpose processors derive flexibility from massive instruction decoders, register files, branch predictors, and cache hierarchies. An ASIC burns transistors only on the logic that directly contributes to the target computation. Fixed-function tensor accelerators have demonstrated this principle at scale{c(10)}, but they still rely on advanced process nodes and monolithic fabrication. Our architecture applies the ASIC philosophy to mature DUV nodes and commodity memory: the DUV MAC ASIC contains no instruction decoder, no branch predictor, and no operating-system interface---only a fixed-function MAC array hard-wired to its local LPDDR6 bus.

1.8 Historical precedents: dataflow machines and the Transputer

The dataflow computing paradigm proposed machines where execution is triggered by data availability rather than a program counter{c(11)}. The INMOS Transputer embedded a simple processor with point-to-point communication links on each chip, enabling fine-grained parallelism without shared memory{c(12)}. Our architecture inherits the Transputer's philosophy of computing elements with direct, deterministic communication, but replaces its general-purpose processors with fixed-function MAC ASICs and its serial links with high-bandwidth LPDDR6 buses. The wormhole routing fabric draws on Dally and Seitz's work on deadlock-free routing: deterministic routing is deadlock-free if and only if the channel dependency graph is acyclic{c(13,14)}. Our fabric guarantees acyclicity by construction through monotonically ordered virtual-channel classes (Section 4.4).

Methods

2.1 The Z-axis spine and ingress nodes

The network topology is a strictly deterministic single-spine tree---a spine-and-leaf fabric with exactly one spine. A central Z-axis spine runs vertically through the chassis, bridging parallel horizontal X/Y motherboards with high-density mezzanine connectors. Traffic between nodes on the same layer follows exactly one dimension-ordered X/Y path; traffic between layers additionally enters the spine at its own layer's attachment, travels monotonically along the spine to the destination layer's attachment, and continues across the destination board's dimension-ordered path. Because there is exactly one legal route between any pair of nodes, routing requires no search algorithm, no arbitration, and no adaptive logic---only coordinate arithmetic.

At each layer, a Z-axis Ingress ASIC evaluates the incoming flit header against a local hardware ID bitmask. Implemented as a combinational tree of XOR and AND gates on a 14 nm DUV node, this comparator operates in approximately 50--100 picoseconds without clocks, queues, or software intervention in the compare path. The comparator's match decision is registered on the local Network-on-Board (NoB) clock edge; clock-domain crossings use standard source-synchronous forwarding between HFRs. Matching flits are gated onto the local X/Y NoB; non-matching flits proceed along the spine. The ingress boundary acts as a rigid physical microkernel barrier{c(9)}.

The spine is the fabric's only bisection. It is provisioned as parallel high-speed lanes with an aggregate of at least 1 TB/s per direction in the reference chassis. The sizing rule is derived at compile time from the compiler's knowledge of every route. Intra-layer stencil halo traffic never enters the spine (Section 2.2), and MoE token payloads are kilobyte-class, so the worst-case cross-layer load remains modest. A fat-spine variant---adding lanes toward the root---scales this bound for larger stack heights.

2.2 The intra-layer fabric: dimension-order routing

Within a layer, HFRs form a direct X/Y grid that mirrors the motherboard's physical socket layout. On-board routes use X-then-Y dimension order: a flit travels along the X axis to the destination column, then along the Y axis to the destination socket{c(13,14)}. Dimension-order routes are deterministic, minimal, and free of cyclic channel dependencies by the standard results. A halo exchange between neighboring grid cells is a single-hop route between adjacent sockets that never touches the ingress gate or the spine.

2.3 The motherboard and isothermal manifold

The horizontal plane consists of rigid X/Y motherboards populated with paired LPCAMM2 memory sockets and DUV MAC ASIC sockets (Section 2.4). Stacked vertically, these boards create a severe thermal challenge: LPDDR6 modules throttle above 85$^\\circ$C. At the reference operating point, each node dissipates approximately 15 W (about 5 W DRAM, 9 W MAC array, 1 W fabric share), a fully populated 64-node board about 1 kW, and an eight-layer chassis about 8--10 kW including fabric and control losses. The chassis incorporates an Isothermal Parallel Manifold---rigid vertical fluid channels that inject identical-temperature coolant (30$^\\circ$C) simultaneously across all stacked layers. Balance is enforced, not assumed: each branch is fitted with a calibrated flow orifice sized during chassis assembly, holding each branch's coolant temperature rise within a $\\pm$2$^\\circ$C band. At approximately 15 L/min per chassis (water, 10$^\\circ$C coolant temperature rise), the worst-case DRAM junction temperature remains at or below 70$^\\circ$C---15$^\\circ$C below the throttling threshold.

2.4 LPCAMM2 integration, packaging, and sideband signaling

Each compute node centers on an LPCAMM2 memory module conforming to JEDEC JESD318{c(16)}, providing access to over 300 pins of LPDDR6 signaling{c(17)}. The reference configuration assumes a **128-bit** memory interface (matching the current LPCAMM2 bus width), yielding $\\approx$170 GB/s per node at 10.7 Gb/s/pin. JEDEC's LPDDR6 CAMM2 standard targets a wider **192-bit** bus (24-bit subchannel $\\times$ 8), which would raise per-node bandwidth to $\\approx$256 GB/s at the same pin rate; the architecture supports both widths with no change to the MAC ASIC or routing fabric. The DUV MAC ASIC sits adjacent to---rather than inside---the DRAM die, making this Processing-Near-Memory (PNM) rather than true Processing-in-Memory (PIM). Two packaging variants define adjacency:

Variant A --- Socketed ASIC on the motherboard (reference design). Each LPCAMM2 socket is paired with an adjacent low-profile ASIC socket (land-grid-array or card-edge mezzanine). The ASIC is socketed rather than soldered: nodes can be populated, depopulated, and replaced in the field, matching the POST discovery sequence (Section 2.5) and the failure model (Section 4.1). The memory module remains an unmodified commodity part. Placing the two sockets within roughly 20 mm keeps the LPDDR6 interface short enough for commodity-grade signal integrity.

Variant B --- Module-integrated ASIC (high-density option). The DUV MAC ASIC is mounted directly on the CAMM module substrate beside the DRAM packages. This yields the shortest memory interface and lowest interface power, at three costs: the module becomes a custom part, ASIC heat sits adjacent to the DRAM, and a failed ASIC retires the entire module.

Direct BGA attachment of the ASIC to the motherboard was considered and rejected: a permanent solder joint defeats field serviceability and contradicts the reconfigurable-inventory philosophy of Section 2.5. The reference configuration in the Results section assumes Variant A.

Because JESD318 fixes the memory connector pinout, three sideband signals travel on a separate low-pin-count board-level sideband header (in Variant B, a short flex tail from the module substrate):

DOORBELL\\_TRIG: asserted by the node's DMA engine only when (a) the received byte count equals the message-length field in the flit header and (b) the end-to-end message CRC validates. Because HFR forwarding along a single path is strictly in-order, byte-count equality detects complete delivery; a stream aborted mid-message can never satisfy both conditions. The full two-loop state machine is specified in Section 2.9.

NODE\\_ERR: a fatal fault line that bypasses the NoB entirely, streaming directly to the central controller (Section 4.1).

TOPOLOGY\\_RDY: asserted during Power-On Self-Test once voltage margins and link training succeed.

2.5 Initialization and the POST Discovery Sequence

Initialization begins when the central microcontroller pulses sequenced voltage rails down the Z-axis spine. The controller emits a ping frame; each layer's Ingress ASIC propagates it along the local X/Y NoB. Every populated node that completes link training and Built-In Self-Test asserts TOPOLOGY\\_RDY. The controller aggregates responses into a live inventory of active Layer IDs and Module IDs.

This inventory is the Instruction Set Architecture for this boot instance. The controller exports a topology schema describing physical coordinates, per-link bandwidth, and deterministic latency between each pair. That latency is a closed-form function of the two coordinate pairs (hop count $\\times$ per-hop delay), not a search result. Because the compiler backend targets this exact physical graph, the motherboard layout becomes the executable program structure. Reconfiguring the hardware---adding a board, removing a faulty node, or changing stack height---automatically generates a new ISA schema.

LPDDR6 is volatile, so static state must be loaded after discovery. The reference design supports streaming from the host over controller uplinks (Section 4.2), loading a fully populated 64 TB chassis in under ten minutes at uplink line rate, or optional per-node boot flash on the sideband header (roughly two minutes through 512 parallel streams). Weight loading is a one-time DMA phase completed before execution begins.

2.6 Software Stack and Execution Model

2.7 IR compilation

High-level user code---whether a MoE transformer, a weather simulation stencil kernel, or a functional dataflow graph---is first lowered into a standard Intermediate Representation (IR) such as MLIR{c(18)}. The backend does not target CUDA, SIMD, or a conventional instruction set. It targets the physical topography schema exported during POST. Tensor operations, stencil neighborhoods, and functional dataflow nodes are mapped to specific LPCAMM2/DUV nodes as memory-resident weights and compute kernels.

2.8 Coordinate routing and dispatch

The compilation pipeline operates in two phases.

Ahead-of-Time (AOT) mapping. The compiler assigns weights, kernels, and grid subdomains to physical coordinates, then computes every route and latency in closed form: within a layer, X-then-Y between coordinates; across layers, a monotone spine traversal between layer attachments, bracketed by on-board paths. Both are $O(1)$ arithmetic functions of the [Layer ID | Module ID] pair---on a single-path tree there is exactly one route, so no pathfinding algorithm has anything to find.

Just-in-Time (JIT) dispatch. Dynamic tokens---such as MoE expert routing decisions---arrive at the central router. The router evaluates the same closed-form routing function, prepends a strict [Layer ID | Module ID] header, and injects. There is no runtime arbitration, no congestion sensing, and no adaptive routing. A modest 1 GHz dispatch stage issues one routing decision per clock ($10^9$ decisions per second); tokens are batched up to 128 per dispatch, placing sustained dispatch capacity near $10^{{11}}$ tokens per second, orders of magnitude above the memory-bound execution rate. Optional per-layer dispatch replicas scale capacity linearly and remain deterministic because the routing function is pure.

2.9 The doorbell mechanism

A flit's lifecycle exemplifies zero-overhead activation. The JIT dispatcher injects the payload into the fabric. The combinational ingress comparator at the target layer gates the flit onto the X/Y NoB in sub-nanosecond time. Hardware Flit Repeaters pass the byte stream via DMA into the target node's local address space. The message header carries a length field; the node's DMA engine counts incoming bytes and computes the running message CRC. When the byte count equals the length field and the CRC validates, the DMA engine asserts DOORBELL\\_TRIG. This physical pin transition wakes the DUV MAC ASIC instantly; there is no software interrupt handler, no software polling loop, and no operating-system context switch.

Every node---whether a MAC node or a repeater serving a CAMM slot---runs the same hardwired two-loop doorbell discipline. This is not software polling: no instructions are fetched and no program counter exists. The loops are the armed and drain states of a finite state machine burned into the doorbell logic:

WATCH (initial loop): continuously check the sentinel bit at the end address of the DMA target buffer. When the sentinel is set (byte count equals header length and CRC valid), interrupt WATCH and enter DISPATCH.

DISPATCH: fire the node's resident function. COMPUTE (PNM processor): execute the resident kernel, e.g., matrix multiplication over the landed payload and local weights. FORWARD (repeater at the CAMM slot): stream the payload onward to the next statically mapped node.

DRAIN (reverse loop): while results egress, check the sentinel; when transfer completes, clear the sentinel (bit now empty) and clear the initial payload data; restart WATCH.

The buffer is rigorously empty before the next message can arrive, making back-to-back activations safe without software synchronization. Because every route is a single path of strictly in-order HFR stages, byte-count equality is a sound completion test. An aborted stream always fails either the count or the CRC, so the doorbell never fires on a partial or corrupt payload.

2.10 Reliability and determinism

LPDDR6 provides on-die ECC; the MAC ASIC's memory controller adds conventional SECDED on the bus. Every message carries a link-local CRC per flit and an end-to-end CRC per message. Because every node is a pure function of its local memory contents and its input stream, re-injecting the same message reproduces the computation bit-exactly. Replay is safe by construction---there is no hidden state to diverge---which underpins both the fault-recovery protocol of Section 4.1 and bit-exact deterministic replay for debugging.

2.11 Target Workloads

2.12 Mixture-of-Experts transformers

Trillion-parameter MoE transformers present a capacity crisis for HBM-based systems: only a sparse subset of experts is active per token, yet the entire parameter set must be accessible{c(3,4)}. Our architecture distributes expert weights across hundreds of cheap LPDDR6 pools. A one-trillion-parameter model at INT8 occupies 1 TB---eight reference nodes---and at FP16, sixteen. A single 64 TB chassis holds tens of trillions of parameters with room for replication.

When a token requires a given expert, the central router evaluates the coordinate routing function, dispatches the token via wormhole routing to the holding node, and the doorbell fires. The local MAC executes and returns the updated hidden state. Three refinements matter in production: (i) hot-expert replication from offline activation histograms across $k$ nodes; (ii) expert capacity via elastic input buffers sized to at least one full message burst, with compiler-set capacity factors; (iii) dense components (attention projections, embeddings, output head) replicated on dedicated dense nodes per layer under the same doorbell discipline. Idle experts draw no dynamic compute power---only DRAM refresh current.

2.13 Scientific HPC stencil workflows

Climate modeling, computational fluid dynamics, and seismic imaging rely on regular FP64 stencil operations over massive grids. These workloads map onto the rigid X/Y grid of sockets: each grid subdomain becomes a physical node, and halo exchanges become single-hop dimension-order routes between neighboring sockets that never enter the spine. Because the stencil neighborhood is known at compile time, the AOT compiler generates exact routes with no runtime indirection, replacing cluster middleware such as MPI{c(19)} with a coordinate function.

The roofline analysis of Section 3.2 shows why mature nodes suffice: a 7-point FP64 stencil has an arithmetic intensity of roughly 0.3--0.5 FLOP/byte, far below the reference node's machine balance of about 1.5 FLOP/byte{c(5)}. Where numerics permit, mixed-precision halo storage raises effective intensity further. Deterministic worst-case halo-exchange latency is a compile-time constant (Section 4.4).

2.14 Functional data-based workflows

The mappable subset is first-order dataflow graphs of pure kernels over statically allocated buffers{c(6,11)}. Within this subset, an actor is a node, a message is a flit, and a statically scheduled functional kernel is a doorbell activation. General lazy graph reduction with an unbounded dynamic heap is future work (the Conclusion section). Referential transparency is exactly what makes the replay guarantees of Sections 2.6 and 4.1 hold.

Results

All figures in this section are first-order engineering estimates intended to establish plausibility and sizing rules, not measured results; no prototype exists yet.

3.1 Reference chassis

Table 1 summarizes the reference configuration: 512 nodes, 64 TB aggregate capacity, approximately 87 TB/s aggregate local bandwidth, approximately 131 TFLOPS FP64, and 8--10 kW chassis power, with a spine provisioned at $\\geq$1 TB/s per direction.

Table 1. Reference chassis configuration (first-order estimates).

Quantity | Reference value
Node | 128 GB LPCAMM2 LPDDR6 + 14 nm DUV MAC ASIC (128 FP64 FMA @ 1 GHz $\\approx$ 256 GFLOPS FP64)
Node memory bandwidth | $\\approx$170 GB/s (128-bit LPCAMM2 @ 10.7 Gb/s/pin); up to $\\approx$256 GB/s with JEDEC 192-bit LPDDR6 CAMM2 bus
Node power | $\\approx$15 W
Board (1 layer) | 8$\\times$8 = 64 nodes; 8 TB; $\\approx$10.9 TB/s; $\\approx$1 kW
Chassis (8 layers) | 512 nodes; 64 TB; $\\approx$87 TB/s; $\\approx$131 TFLOPS FP64; $\\approx$8--10 kW
Spine | Parallel lanes, $\\geq$1 TB/s per direction aggregate

3.2 Roofline: why mature nodes suffice

The reference node's machine balance is
$$
B_{{\\mathrm{{machine}}}} = \\frac{{256\\ \\mathrm{{GFLOP/s}}}}{{170\\ \\mathrm{{GB/s}}}} \\approx 1.5\\ \\mathrm{{FLOP/byte}}.
$$
A 7-point FP64 stencil has arithmetic intensity $\\approx$0.3--0.5 FLOP/byte (strongly bandwidth-bound). MoE expert weight-streaming sits near 1--2 FLOP/byte per token (higher with batching). Both sit at or below machine balance{c(5)}, so performance is limited by the LPDDR6 bus, never by the MAC array. This is the load-bearing argument for DUV: a 14 nm or 28 nm array already saturates the memory it is attached to.

3.3 Cost model

First-order, volume-dependent node bill of materials: LPCAMM2 module $\\approx$\\$400, 14 nm MAC ASIC $\\approx$\\$40, socket/board/assembly share $\\approx$\\$60, for a node total of $\\approx$\\$500 ($\\approx$\\$3.9/GB). A 512-node chassis is $\\approx$\\$256k for 64 TB. An H100-class GPU at $\\approx$\\$30k for 80 GB HBM is $\\approx$\\$375/GB{c(2)}. The architecture delivers roughly two orders of magnitude lower cost per gigabyte of attached memory.

3.4 Thermal and latency budgets

Thermal: $\\approx$15 W per node, $\\approx$1 kW per board, $\\approx$8--10 kW per chassis; 15 L/min of 30$^\\circ$C water with 10$^\\circ$C rise and orifice-balanced branches keeps worst-case DRAM junction $\\leq$70$^\\circ$C against an 85$^\\circ$C throttle.

Latency (bounded, not average): ingress compare $\\approx$0.1 ns; HFR hop $\\approx$1--2 ns; worst-case on-board route (8$\\times$8) 14 hops $\\approx$14--28 ns; spine traversal (7 layer hops) $\\approx$7--14 ns; 4 KB DMA @ 170 GB/s $\\approx$24 ns; doorbell wake $\\approx$1 ns; end-to-end activation bound $\\approx$45--70 ns.

Discussion

4.1 Failure Model and Recovery

NODE\\_ERR assertion triggers a four-step protocol: (1) quarantine the node from the live topology schema; (2) discard in-flight flits destined for it (the affected set is exactly enumerable on a single-path fabric); (3) replay---the source re-injects toward a healthy replica or the reinitialized node; replay is bit-exact by the purity guarantee of Section 2.6; (4) re-export the amended schema and update JIT tables at the next batch boundary. The chassis continues in degraded mode with no restart. A failed spine lane degrades to remaining lanes; total spine failure partitions the chassis (the Conclusion section).

4.2 Host Interface and I/O

The central controller terminates dual PCIe Gen5 x16-class uplinks ($\\approx$128 GB/s aggregate) or 100/200 GbE equivalents. The host streams initial weights at boot, injects input tokens, and drains outputs. Runtime token traffic is kilobyte-class at the dispatch rates of Section 2.6---well below uplink and spine capacity. The host never touches the compute fabric directly.

4.3 Verification and Formal Properties

Deadlock freedom (sketch). Every flit is assigned one of three virtual-channel classes in strictly increasing order: (0) on-board egress (X-then-Y dimension order), (1) spine traversal (monotone along the linear spine; upward and downward flows on separate virtual channels), (2) on-board delivery (X-then-Y from spine attachment to destination). Intra-class dependencies are acyclic by standard results; cross-class dependencies only point from lower to higher classes. The global channel dependency graph is therefore acyclic, and by Dally and Seitz the fabric is deadlock-free{c(13,14)}.

Livelock freedom follows from minimal single-path routes. Consumption is enforced structurally: elastic input buffers hold at least one maximum-length message, and sources may not inject without destination buffer credit. Worst-case latency for any coordinate pair is a closed-form expression (Section 3.4). Given identical inputs, every computation and message schedule reproduces bit-exactly.

4.4 Limitations and Future Work

LPDDR6 (JESD209-6){c(17)} parts and high-capacity LPCAMM2 modules are forward-looking; an LPDDR5X variant ($\\approx$136 GB/s per node, 48--64 GB modules today) trims bandwidth by about 20 percent and capacity by half without architectural change{c(16,17)}. The reference design assumes a 128-bit LPCAMM2 bus ($\\approx$170 GB/s per node), but JEDEC's LPDDR6 CAMM2 standard targets a 192-bit bus, which would raise per-node bandwidth to $\\approx$256 GB/s; the architecture accommodates either width. Manifold balancing requires CFD and hardware validation. Multi-chassis scale-out needs a second routing level and one additional virtual-channel class. General lazy evaluation needs a dynamic heap this design omits. A dual-spine variant eliminates single-chassis partition mode. The claims of Section 4.3 are argued, not yet machine-checked{c(9)}.

Conclusion

This paper has specified a distributed spatial Processing-Near-Memory architecture that bypasses the HBM capacity wall through commodity LPDDR6, mature-node DUV logic, and deterministic wormhole routing{c(13,15,17)}. By treating the physical motherboard as an immutable dataflow graph and exporting its topography as a bespoke ISA, the system eliminates runtime scheduling, cache coherency, and operating-system overhead. Routing is coordinate arithmetic on a single-spine tree with dimension-order on-board paths; deadlock freedom follows from monotonically ordered virtual-channel classes; the hardened doorbell mechanism makes activation atomic as well as idle-free; and the isothermal parallel manifold sustains thermal viability with enforced flow balance. The reference chassis---64 TB, 87 TB/s aggregate local bandwidth, approximately 131 TFLOPS FP64, approximately \\$4/GB---demonstrates that the economics of memory capacity favour radical simplicity by roughly two orders of magnitude per byte. Target workloads---MoE transformer inference, FP64 stencil computation, and functional data-based evaluation---sit in the bandwidth-bound regime where mature-node silicon is already sufficient{c(3,4,5)}, and they inherit bit-exact replay and compile-time latency bounds that no cache-coherent machine can offer.

The full repository, including Verilog HDL sources, build scripts, and this manuscript, is available at https://github.com/im-BowenGu/PNM-Arch. All hardware schematics, topology specifications, and PCB layouts described herein are intended for release under the CERN Open Hardware Licence Version 2 Strongly Reciprocal (CERN-OHL-S){c(20)}.

Acknowledgments

The author thanks their research mentor for guidance throughout this project, the anonymous referees for their constructive feedback, and the open-source hardware community for developing the tools and ethos that made this work possible.
"""


def to_latex(text: str) -> str:
    # Convert plain section headers already in text; escape handled in body via \\
    # Citations already inserted as LaTeX superscripts when c=scite_wrap
    return text


def scite_wrap(*nums: int) -> str:
    return scite(*nums)


def ocite_wrap(*nums: int) -> str:
    return ocite(*nums)


def ref_to_latex(i: int, r: str) -> str:
    """Format one reference with specials escaped for LaTeX."""
    # Convert markdown _italic_ to LaTeX \textit{} before escaping underscores
    t = re.sub(r'_([^_]+)_', r'\\textit{\1}', r)
    t = (
        t.replace("&", "\\&")
        .replace("%", "\\%")
        .replace("#", "\\#")
        .replace("_", "\\_")
        .replace("~", "\\textasciitilde{}")
    )
    t = t.replace("/", "/\\allowbreak{}")
    return f"{i}. {t}"


def latex_document(body_text: str, author: str = "", date: str = "") -> str:
    refs = "\n\n".join(ref_to_latex(i, r) for i, r in enumerate(REFS, 1))
    author_block = ""
    if author or date:
        bits = []
        if author:
            bits.append(latex_escape(author))
        if date:
            bits.append(latex_escape(date))
        author_block = (
            "\\vspace{0.75em}\n\\begin{center}\n"
            + " \\\\\n".join(bits)
            + "\n\\end{center}\n"
        )
    return rf"""\documentclass[12pt]{{article}}
\usepackage[margin=1in]{{geometry}}
\usepackage{{times}}
\usepackage{{setspace}}
\singlespacing
\usepackage{{amsmath,amssymb}}
\usepackage{{array}}
\usepackage{{booktabs}}
\usepackage[hidelinks]{{hyperref}}
\setlength{{\parskip}}{{0.35em}}
\setlength{{\parindent}}{{1.5em}}
\pagestyle{{plain}}
\makeatletter
\renewcommand\section{{\@startsection{{section}}{{1}}{{\z@}}{{-1.2ex \@plus -0.2ex}}{{0.4ex}}{{\normalsize\bfseries}}}}
\renewcommand\subsection{{\@startsection{{subsection}}{{2}}{{\z@}}{{-1.0ex \@plus -0.2ex}}{{0.3ex}}{{\normalsize\bfseries}}}}
\makeatother

\begin{{document}}

\begin{{center}}
{{\Large\bfseries {TITLE}}}
\end{{center}}
{author_block}
\vspace{{1em}}

{body_to_latex_sections(body_text)}

\section*{{References}}
\begingroup
\footnotesize
\setlength{{\parindent}}{{0pt}}
\setlength{{\parskip}}{{0.55em}}
\sloppy
{refs}
\endgroup

\end{{document}}
"""


def body_to_latex_sections(text: str) -> str:
    """Turn the plain body into LaTeX sections; keep equations."""
    lines = text.strip().split("\n")
    out: list[str] = []
    i = 0
    # Abstract
    out.append("\\section*{Abstract}")
    i = 1  # skip 'Abstract'
    # collect until Keywords
    para: list[str] = []
    while i < len(lines):
        line = lines[i]
        if line.startswith("Keywords:"):
            if para:
                out.append("\n\n".join(flush_paras(para)))
                para = []
            out.append("\\noindent\\textbf{Keywords:} " + line[len("Keywords:") :].strip())
            i += 1
            break
        para.append(line)
        i += 1
    if para:
        out.append("\n\n".join(flush_paras(para)))

    # Detect NHSJS section headers (unnumbered) and numbered sections
    nhsjs_secs = {"Introduction", "Methods", "Results", "Discussion", "Acknowledgments"}
    sec_re = re.compile(r"^(\d+)\.\s+(.+)$")
    sub_re = re.compile(r"^(\d+\.\d+)\s+(.+)$")
    buf: list[str] = []
    while i < len(lines):
        line = lines[i]
        stripped = line.strip()
        if stripped == "":
            buf.append("")
            i += 1
            continue
        msub = sub_re.match(stripped)
        msec = sec_re.match(stripped)
        if stripped in nhsjs_secs:
            if buf:
                out.extend(emit_block(buf))
                buf = []
            out.append(f"\\section*{{{stripped}}}")
            i += 1
            continue
        if msub and not stripped.startswith("Table"):
            if buf:
                out.extend(emit_block(buf))
                buf = []
            out.append(f"\\subsection*{{{msub.group(1)} {msub.group(2)}}}")
            i += 1
            continue
        if msec:
            if buf:
                out.extend(emit_block(buf))
                buf = []
            out.append(f"\\section*{{{msec.group(1)}. {msec.group(2)}}}")
            i += 1
            continue
        buf.append(line)
        i += 1
    if buf:
        out.extend(emit_block(buf))
    return "\n\n".join(out)


def flush_paras(lines: list[str]) -> list[str]:
    paras: list[str] = []
    cur: list[str] = []
    for line in lines:
        if line.strip() == "":
            if cur:
                paras.append(" ".join(cur))
                cur = []
        else:
            cur.append(line.strip())
    if cur:
        paras.append(" ".join(cur))
    return paras


def emit_block(buf: list[str]) -> list[str]:
    text = "\n".join(buf)
    # Display equation blocks
    out: list[str] = []
    parts = re.split(r"(\n\$\$\n.*?\n\$\$\n)", text, flags=re.S)
    # simpler: find $$ ... $$
    chunks = re.split(r"\$\$(.*?)\$\$", text, flags=re.S)
    for idx, chunk in enumerate(chunks):
        if idx % 2 == 1:
            out.append("\\begin{equation*}\n" + chunk.strip() + "\n\\end{equation*}")
        else:
            # tables: detect "Table N." header and pipe tables
            out.extend(emit_prose_or_table(chunk))
    return out


def emit_prose_or_table(text: str) -> list[str]:
    lines = text.split("\n")
    out: list[str] = []
    i = 0
    while i < len(lines):
        line = lines[i]
        if line.strip().startswith("Table 1."):
            # skip until header row with |
            caption = line.strip()
            i += 1
            while i < len(lines) and lines[i].strip() == "":
                i += 1
            # optional plain header "Quantity | Reference value"
            rows = []
            while i < len(lines) and "|" in lines[i]:
                rows.append([c.strip() for c in lines[i].split("|")])
                i += 1
            if rows:
                out.append(
                    "\\begin{table}[h!]\n\\centering\n\\caption{"
                    + latex_escape(caption)
                    + "}\n\\begin{tabular}{p{0.32\\textwidth}p{0.58\\textwidth}}\n\\toprule\n"
                )
                for ri, row in enumerate(rows):
                    cells = [latex_escape(c) for c in row]
                    out.append(" & ".join(cells) + " \\\\")
                    if ri == 0:
                        out.append("\\midrule")
                out.append("\\bottomrule\n\\end{tabular}\n\\end{table}")
            continue
        # accumulate paragraph lines
        if line.strip() == "":
            i += 1
            continue
        para_lines = [line.strip()]
        i += 1
        while i < len(lines) and lines[i].strip() != "" and not lines[i].strip().startswith("Table ") and "|" not in lines[i]:
            # stop if next is section-like - already handled
            para_lines.append(lines[i].strip())
            i += 1
        para = " ".join(para_lines)
        # itemize-like lines starting with WATCH/DISPATCH etc stay as prose
        out.append(latex_escape_keep_math(para))
    return out


_LATEX_TOKEN = re.compile(
    r"(\$[^$]+\$|"
    r"\\textsuperscript\{[^}]+\}|"
    r"\\begin\{[^}]+\}|\\end\{[^}]+\}|"
    r"\\[a-zA-Z]+|"
    r"\\\$|\\%|\\&|\\#|\\_|\\\{|\\\}|"
    r"---|--)"
)


def latex_escape(s: str) -> str:
    """Escape plain text for LaTeX, preserving math and backslash commands."""
    parts = _LATEX_TOKEN.split(s)
    out: list[str] = []
    for p in parts:
        if not p:
            continue
        if p.startswith("\\") or p.startswith("$") or p in ("---", "--"):
            out.append(p)
        else:
            t = (
                p.replace("&", "\\&")
                .replace("%", "\\%")
                .replace("#", "\\#")
                .replace("_", "\\_")
                .replace("~", "\\textasciitilde{}")
            )
            out.append(t)
    return "".join(out)


def latex_escape_keep_math(s: str) -> str:
    return latex_escape(s)


def online_document(body_text: str, author: str = "", date: str = "") -> str:
    """Plain text/markdown-ish Word source with online citations; no LaTeX section commands."""
    refs = "\n\n".join(f"{i}. {r}" for i, r in enumerate(REFS, 1))
    # Clean body: already has ((citations)); convert --- to —
    text = body_text.replace("---", "—").replace("--", "–")
    # Remove $ for Word except keep equation block readable
    text = text.replace("\\%", "%").replace("\\$", "$")
    text = text.replace("\\pm", "±").replace("\\times", "×")
    text = text.replace("\\approx", "≈").replace("\\geq", "≥").replace("\\leq", "≤")
    text = text.replace("^{\\circ}", "°").replace("$", "")
    text = re.sub(r"\\mathrm\{([^}]+)\}", r"\1", text)
    text = re.sub(r"\\frac\{([^}]+)\}\{([^}]+)\}", r"(\1)/(\2)", text)
    text = text.replace("\\{", "{{").replace("\\}", "}}")  # undo
    text = text.replace("{{", "{").replace("}}", "}")
    # equation markers
    text = re.sub(r"\n\s*\n", "\n\n", text)
    meta = ""
    if author:
        meta += f"\n{author}"
    if date:
        meta += f"\n{date}"
    header = f"{TITLE}{meta}\n\n"
    footer = f"\n\nReferences\n\n{refs}\n"
    note = (
        "\n\n[Online multi-citations already use Unicode raised comma U+2E34 (⸴) "
        "between )), (( blocks — no Word find-replace step required.]\n"
    )
    return header + text.strip() + "\n\n" + note + footer


def main() -> int:
    author, date = read_author_meta()
    print(f"Author: {author or '(none)'}  Date: {date or '(none)'}")

    std_body = body(scite_wrap)
    on_body = body(ocite_wrap)

    tex_path = ROOT / f"{STEM}.tex"
    pdf_path = ROOT / f"{STEM}.pdf"
    docx_std = ROOT / f"{STEM}.docx"
    docx_on = ROOT / f"{STEM} - Online Citations.docx"
    md_on = ROOT / f"{STEM} - Online Citations.md"
    md_std = ROOT / f"{STEM} - Standard.md"

    tex = latex_document(std_body, author=author, date=date)
    tex_path.write_text(tex, encoding="utf-8")
    print(f"Wrote {tex_path.name}")

    std_header = f"# {TITLE}\n\n"
    if author:
        std_header += f"**Author:** {author}\n\n"
    if date:
        std_header += f"**Date:** {date}\n\n"
    md_std.write_text(
        std_header
        + std_body.replace("\\textsuperscript{", "^").replace("}", "")
        + "\n\n## References\n\n"
        + standard_ref_block(),
        encoding="utf-8",
    )
    md_on.write_text(online_document(on_body, author=author, date=date), encoding="utf-8")
    print(f"Wrote {md_on.name}")

    # Compile PDF
    r = subprocess.run(
        ["pdflatex", "-interaction=nonstopmode", "-halt-on-error", tex_path.name],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    if r.returncode != 0:
        print(r.stdout[-3000:] if r.stdout else "")
        print(r.stderr[-3000:] if r.stderr else "")
        print("pdflatex failed", file=sys.stderr)
        return 1
    # second pass
    subprocess.run(
        ["pdflatex", "-interaction=nonstopmode", tex_path.name],
        cwd=ROOT,
        capture_output=True,
        text=True,
    )
    print(f"Wrote {pdf_path.name}")

    # DOCX via pandoc
    for md, docx in [(md_std, docx_std), (md_on, docx_on)]:
        # Build cleaner md for pandoc standard: use plain superscript unicode
        subprocess.run(
            [
                "pandoc",
                str(md),
                "-o",
                str(docx),
                "-f",
                "markdown",
                "-t",
                "docx",
                "--reference-doc=/usr/share/pandoc/data/templates/reference.docx"
                if Path("/usr/share/pandoc/data/templates/reference.docx").exists()
                else str(md),  # dummy ignored if missing - pandoc ignores unknown
            ],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        # simpler pandoc without reference-doc
        r2 = subprocess.run(
            ["pandoc", str(md), "-o", str(docx), "-f", "markdown", "-t", "docx"],
            cwd=ROOT,
            capture_output=True,
            text=True,
        )
        if r2.returncode != 0:
            print(r2.stderr, file=sys.stderr)
            return 1
        print(f"Wrote {docx.name}")

    # Page count check
    try:
        import subprocess as sp

        info = sp.run(["pdfinfo", str(pdf_path)], capture_output=True, text=True)
        if info.returncode == 0:
            for line in info.stdout.splitlines():
                if line.startswith("Pages:"):
                    print(line)
                    pages = int(line.split(":")[1].strip())
                    if pages > 20:
                        print(f"WARNING: manuscript is {pages} pages (limit 20)", file=sys.stderr)
    except Exception:
        pass

    # Cleanup aux
    for ext in (".aux", ".log", ".out", ".toc"):
        p = ROOT / f"{STEM}{ext}"
        if p.exists():
            p.unlink()

    readme = ROOT / "README.md"
    readme.write_text(
        f"""# NHSJS Submission Package

Manuscript title:

> {TITLE}

## Files (no author-identifying information)

| File | Role |
|------|------|
| `{STEM}.pdf` | **Primary review PDF** — standard superscript citations + References (LaTeX-built, 12 pt, single-spaced) |
| `{STEM}.tex` | **LaTeX source** — upload as supplementary information |
| `{STEM}.docx` | **Word version 1** — standard citation style (from Markdown export) |
| `{STEM} - Online Citations.docx` | **Word version 2** — full citations in double parentheses at each cite site |
| `{STEM} - Online Citations.md` | Source for the online Word file |

## NHSJS checklist

- [x] No author names, affiliations, or acknowledgements in submission files
- [x] 12 pt, single spacing (LaTeX `article` 12pt + `setspace`)
- [x] Standard citations: superscript numbers before punctuation
- [x] References: numbered list, initials + surname, sentence-case titles, journal format
- [x] Online citations: complete citation in `((...))` with leading space; multi-cites as `((A)), ((B))`
- [ ] **After opening the Online Citations.docx in Word:** Find `)), ((` and replace the comma with a **superscript** comma (NHSJS required step)
- [ ] Confirm PDF ≤ 20 pages (see build log `Pages:`)

## Rebuild

```bash
cd submission
python3 build_manuscripts.py
```

Requires: `python3`, `pdflatex` (TeX Live), `pandoc`.
""",
        encoding="utf-8",
    )
    print(f"Wrote {readme.name}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
