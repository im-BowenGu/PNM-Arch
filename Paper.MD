# Bypassing the HBM Wall: A Distributed Spatial Processing-Near-Memory Architecture using DUV ASICs and Deterministic Routing

**Author:** Bowen Gu
**Date:** July 30, 2026
**Copyright & Disclaimer:** © 2026 Bowen Gu. This document and the hardware designs described herein are provided "as is," without warranty of any kind, express or implied. All hardware schematics, topology specifications, and PCB layouts described herein are released under the CERN Open Hardware Licence Version 2 — Strongly Reciprocal (CERN-OHL-S); see Section 13. All other rights reserved.

Abstract

\\textbf{{Background/Objective}}

Modern Mixture-of-Experts transformer inference and high-performance scientific computing have collided with the Memory Wall{c(1)}. Packaging constraints on advanced interposers artificially cap both memory capacity and thermal dissipation, while conventional Von Neumann instruction-fetching overhead consumes enormous energy and time merely to orchestrate data movement rather than perform useful compute{c(6)}. This work aims to bypass the HBM capacity and cost wall through a distributed Processing-Near-Memory architecture using commodity memory modules and mature-node ASICs.

\\textbf{{Methods}}

We propose a distributed spatial Processing-Near-Memory (PNM) architecture that replaces centralized High-Bandwidth Memory (HBM){c(15)} with commodity 192-bit LPDDR6 CAMM2 modules{c(16,17)}, each paired with a mature-node 14 nm or 28 nm DUV MAC ASIC on a rigid X/Y motherboard grid. A deterministic single-spine tree routing fabric---built from stateless Hardware Flit Repeater wormhole switches, dimension-order on-board routing, and combinational xyz\\_repeater nodes---eliminates runtime operating-system scheduling, cache coherency protocols, and multi-path routing ambiguity{c(13,14)}. Routing is pure coordinate arithmetic: an $O(1)$ function of a flit's [Layer ID | Module ID] header, with worst-case latency bounded in closed form at compile time. By compiling high-level intermediate representations ahead-of-time onto a physical topology schema exported directly from hardware discovery, the system maps Mixture-of-Experts transformer inference, FP64 stencil computations, and functional data-based workflows directly onto silicon{c(3,4)}.

\\textbf{{Results}}

A 512-node reference chassis provides 64 TB of attached memory and 131 TB/s of aggregate node-local bandwidth at roughly \\$4 per gigabyte---two orders of magnitude below HBM monoliths per byte---while a roofline analysis shows the target workloads are firmly bandwidth-bound and therefore fully served by mature-node logic{c(5)}.

\\textbf{{Conclusions}}

The architecture yields a spatial computer that executes immutable dataflow graphs in hardware with full determinism, provable deadlock freedom, and strict functional correctness, at a fraction of the thermal envelope and economic cost of monolithic GPU accelerators.

Keywords: Processing-Near-Memory; Wormhole Switching; Deterministic Routing; Dimension-Order Routing; Spatial Computing; LPDDR6 CAMM2; DUV ASIC; Mixture-of-Experts Transformers; Stencil Computation; Roofline Analysis

Introduction

1.1 The economic and physical bottleneck

The prevailing paradigm for large-scale transformer training and inference relies on monolithic GPU accelerators tightly coupled to High-Bandwidth Memory (HBM) via advanced interposers{c(2,15)}. This approach has become economically and physically untenable. A single NVIDIA H100-class GPU with 80 GB of HBM can cost upwards of thirty thousand dollars---roughly \\$375 per gigabyte of attached memory---yet the majority of its transistor budget and thermal headroom is spent not on computation, but on moving data across hierarchical memory caches and network interfaces{c(2)}. For Mixture-of-Experts (MoE) transformers, where hundreds of billions of parameters remain idle during any given forward pass{c(3,4)}, purchasing monolithic GPUs solely for their aggregate memory capacity is fundamentally broken: it imposes massive capital expenditure, extreme power density, and an artificial capacity ceiling dictated by interposer reticle limits. The Results section quantifies the alternative: first-order cost modeling places the proposed PNM node at roughly \\$4 per gigabyte of attached memory, approximately two orders of magnitude cheaper per byte.

1.2 Hardware as a static graph

This paper advances an alternative philosophy inspired by Unix pipelines, operating-system microkernels, and pure functional programming{c(6,7,8)}. We treat the physical motherboard not as a passive substrate for a Von Neumann processor, but as an active, immutable dataflow graph. Computation should be a pure mapping of inputs to outputs---flits stream through hardware channels as byte sequences, and each hardware component does exactly one thing with zero state manipulation. There are no runtime page tables, no dynamic branch prediction, and no global memory coherency protocols. By enforcing functional immutability at the silicon level, the architecture eliminates entire classes of side-effects, race conditions, and operating-system scheduling overhead that plague conventional accelerators. This purity is not merely aesthetic: it is what makes bit-exact replay after faults (Section 4.1) and compile-time latency bounds (Section 4.3) possible at all.

1.3 Manufacturing realities: DUV versus EUV

A common objection to custom accelerator silicon is the perceived necessity of bleeding-edge process nodes. This architecture rejects that premise. Memory bandwidth, not transistor switching speed, is the binding constraint for inference and stencil workloads. The roofline analysis in the Results section makes this concrete: at the reference node's machine balance of approximately 1.5 FLOP/byte, both stencil neighborhoods and MoE expert weight-streaming sit deep in the bandwidth-bound regime{c(5)}, so a 14 nm MAC array is never the limiting resource. A 14 nm or 28 nm Deep Ultraviolet (DUV) ASIC is therefore perfectly sufficient to saturate a local LPDDR6 bus{c(17)}, and mature nodes offer incomparable advantages: dramatically lower mask costs, higher yields, established supply chains, and the freedom to use large die areas for MAC arrays without the exponential cost curve of EUV lithography. By pairing cheap, commodity LPDDR6 memory with mature-node logic, the system achieves cost-per-parameter ratios orders of magnitude below HBM-based monoliths.

The architecture described in this paper is the convergence of several distinct intellectual traditions in computer science and hardware engineering.

1.4 The Unix philosophy

The Unix philosophy holds that programs should do one thing well, accept streams as input, and compose via pipes{c(7)}. We extend this principle to silicon. Each Hardware Flit Repeater (HFR) does exactly one thing: it forwards a flit to the next node. The xyz\\_repeater compares a header bitmask and gates matching flits onto the local network. The MAC ASIC executes a tensor kernel on data present in its local LPDDR6 bank. There are no general-purpose cores, no speculative execution, and no dynamic reconfiguration on the hot path. The flit stream is the silicon analog of the Unix text stream: a universal, byte-oriented interface that decouples producers from consumers.

1.5 Functional and declarative programming

Functional programming treats computation as the evaluation of mathematical functions with no side-effects and no mutable state{c(6)}. Conventional hardware is ruthlessly imperative: mutable registers, speculative branch rollback, cache invalidation protocols, and operating-system interrupts violate functional purity at every level. Our architecture inverts this relationship. The hardware itself enforces functional immutability: flits are immutable once injected, HFRs are stateless functions of their input, and MAC ASICs produce deterministic outputs from static memory contents. There is no global mutable state anywhere in the system. The entire machine is a single, spatially distributed pure function---a physical instantiation of a dataflow graph---making it a natural substrate for first-order, statically allocated functional programs (Section 2.14).

1.6 Microkernel architecture

Microkernels advocate that privileged software should do as little as possible and isolate the rest{c(8)}. seL4 has been mathematically proven to enforce its security and isolation properties{c(9)}. We extend this principle from software to hardware. The xyz\\_repeater is a microkernel boundary implemented in combinational logic. It enforces a strict, non-bypassable physical separation between layers: traffic cannot reach a layer without passing through that layer's repeater, which evaluates a hardware bitmask rather than a software access-control list. There is no configuration register to misprogram, no firmware to exploit, and no driver to crash---the isolation is a physical property of the silicon.

1.7 Application-specific integrated circuits

General-purpose processors derive flexibility from massive instruction decoders, register files, branch predictors, and cache hierarchies. An ASIC burns transistors only on the logic that directly contributes to the target computation. Fixed-function tensor accelerators have demonstrated this principle at scale{c(10)}, but they still rely on advanced process nodes and monolithic fabrication. Our architecture applies the ASIC philosophy to mature DUV nodes and commodity memory: the DUV MAC ASIC contains no instruction decoder, no branch predictor, and no operating-system interface---only a fixed-function MAC array hard-wired to its local LPDDR6 bus.

1.8 Historical precedents: dataflow machines and the Transputer

The dataflow computing paradigm proposed machines where execution is triggered by data availability rather than a program counter{c(11)}. The INMOS Transputer embedded a simple processor with point-to-point communication links on each chip, enabling fine-grained parallelism without shared memory{c(12)}. Our architecture inherits the Transputer's philosophy of computing elements with direct, deterministic communication, but replaces its general-purpose processors with fixed-function MAC ASICs and its serial links with high-bandwidth LPDDR6 buses. The wormhole routing fabric draws on Dally and Seitz's work on deadlock-free routing: deterministic routing is deadlock-free if and only if the channel dependency graph is acyclic{c(13,14)}. Our fabric guarantees acyclicity by construction through monotonically ordered virtual-channel classes (Section 4.4).

Methods

2.1 The Z-axis spine and repeater nodes

The network topology is a strictly deterministic single-spine tree---a spine-and-leaf fabric with exactly one spine. A central Z-axis spine runs vertically through the chassis, bridging parallel horizontal X/Y motherboards with high-density mezzanine connectors. Traffic between nodes on the same layer follows exactly one dimension-ordered X/Y path; traffic between layers additionally enters the spine at its own layer's attachment, travels monotonically along the spine to the destination layer's attachment, and continues across the destination board's dimension-ordered path. Because there is exactly one legal route between any pair of nodes, routing requires no search algorithm, no arbitration, and no adaptive logic---only coordinate arithmetic.

At each layer, an xyz\\_repeater evaluates the incoming flit header against a local hardware ID bitmask. Implemented as a combinational tree of XOR and AND gates on a 14 nm DUV node, this comparator operates in approximately 50--100 picoseconds without clocks, queues, or software intervention in the compare path. The comparator's match decision is registered on the local Network-on-Board (NoB) clock edge; clock-domain crossings use standard source-synchronous forwarding between HFRs. Matching flits are gated onto the local X/Y NoB; non-matching flits proceed along the spine. The xyz\\_repeater boundary acts as a rigid physical microkernel barrier{c(9)}. Direction is decided ahead of time, never at runtime: the AOT compiler (Section 2.8) emits a deterministic, immutable routing table for every repeater, loaded into the repeaters beside each ASIC node during initialization; each xyz\\_repeater steers flits solely from its pre-loaded table, with nothing to adapt, arbitrate, or reconfigure on the data path.

The spine is the fabric's only bisection, and it is sized by arithmetic, not by assertion. Let $\\alpha$ be the cross-layer traffic fraction of the dominant workload---a compile-time constant derived by the AOT mapper from the resident placement of experts or stencil subdomains (Section 2.8). If the dominant cross-layer trip moves $S$ bytes (a kilobyte-class token plus its returned hidden state, $S \\approx 8$ KB), then a spine provisioned at $B$ bytes per second per direction sustains at most $R = B / (\\alpha S)$ cross-layer dispatches per second. The reference chassis provisions the spine at $\\approx$2 TB/s per direction ($\\approx$128 parallel 16 GB/s lanes), which sustains $\\approx$3$\\times10^{8}$ tokens/s under naive random expert placement ($\\alpha = 7/8$) and rises past $10^{9}$ tokens/s once hot-expert replication and layer-affine placement cut $\\alpha$ to $\\approx$1/4 (Section 2.12). The rule is exact because every route is known to the compiler. Intra-layer stencil halo traffic never enters the spine (Section 2.2). A fat-spine variant---adding lanes toward the root---scales this bound for larger stack heights at the cost of connector pins, which are the dominant spine cost.

The system therefore reduces to four kinds of hardware. Commodity DRAM (192-bit LPDDR6 CAMM2) holds all weights and state. A DUV MAC ASIC beside each module performs the only computation. Stateless Hardware Flit Repeaters (HFRs) and the combinational xyz\\_repeaters form the entire data path. And one central router chip---the only programmable silicon in the machine---owns everything that is not streaming data: it performs Power-On Self-Test and topology discovery (Section 2.5), terminates the host PCIe uplinks (Section 4.2), evaluates the coordinate mapping for dynamic MoE expert routing (Section 2.8), and injects every JIT-dispatched token into the fabric. Everything on the hot path is pure transport; everything with state lives in a single chip at the spine root.

2.2 The intra-layer fabric: dimension-order routing

Within a layer, HFRs form a direct X/Y grid that mirrors the motherboard's physical socket layout. On-board routes use X-then-Y dimension order: a flit travels along the X axis to the destination column, then along the Y axis to the destination socket{c(13,14)}. Dimension-order routes are deterministic, minimal, and free of cyclic channel dependencies by the standard results. A halo exchange between neighboring grid cells is a single-hop route between adjacent sockets that never touches a xyz\\_repeater or the spine.

Every fabric link---on-board and spine alike---is a 128-bit-wide source-synchronous channel at 1 GHz, providing $\\approx$16 GB/s per link. The HDL sketch and the co-simulation harness model the byte-oriented flit stream at one byte per cycle; because a 128-bit physical link moves sixteen bytes per cycle, the byte-serial model understates per-link bandwidth by 16$\\times$ and is therefore conservative, while preserving the routing-decision logic that is the point of the model. Cross-node traffic is bounded by these 16 GB/s links, which is deliberately separate from the $\\approx$256 GB/s each node can read from its own memory: the aggregate figure in Section 3.1 is a sum of node-local bandwidths, and any workload that must move data between nodes is fabric-bound at the link rate.

2.3 The motherboard and isothermal manifold

The horizontal plane consists of rigid X/Y motherboards populated with paired LPDDR6 CAMM2 memory sockets and DUV MAC ASIC sockets (Section 2.4). Stacked vertically, these boards create a severe thermal challenge: LPDDR6 modules throttle above 85$^\\circ$C. At the reference operating point, each node dissipates approximately 15 W (about 5 W DRAM, 9 W MAC array, 1 W fabric share), a fully populated 64-node board about 1 kW, and an eight-layer chassis about 8--10 kW including fabric and control losses. The chassis incorporates an Isothermal Parallel Manifold---rigid vertical fluid channels that inject identical-temperature coolant (30$^\\circ$C) simultaneously across all stacked layers. Balance is enforced, not assumed: each branch is fitted with a calibrated flow orifice sized during chassis assembly, holding each branch's coolant temperature rise within a $\\pm$2$^\\circ$C band. At approximately 15 L/min per chassis (water, 10$^\\circ$C coolant temperature rise), the worst-case DRAM junction temperature remains at or below 70$^\\circ$C---15$^\\circ$C below the throttling threshold.

2.4 CAMM2 integration, packaging, and sideband signaling

Each compute node centers on a JEDEC LPDDR6 CAMM2 memory module (the socketable form factor that succeeds JESD318's LPCAMM2){c(16,17)}. LPDDR6 (JESD209-6) organizes its bus as 24-bit channels, each made of two 12-bit sub-channels; the CAMM2 module is 8$\\times$24 bits (four 48-bit channel groups), i.e. a **192-bit** interface. The reference configuration assumes this 192-bit bus at 10.7 Gb/s/pin, yielding $\\approx$256 GB/s per node. The DUV MAC ASIC sits adjacent to---rather than inside---the DRAM die, making this Processing-Near-Memory (PNM) rather than true Processing-in-Memory (PIM). Two packaging variants define adjacency:

Variant A --- Socketed ASIC on the motherboard (reference design). Each CAMM2 socket is paired with an adjacent low-profile ASIC socket (land-grid-array or card-edge mezzanine). The ASIC is socketed rather than soldered: nodes can be populated, depopulated, and replaced in the field, matching the POST discovery sequence (Section 2.5) and the failure model (Section 4.1). The memory module remains an unmodified commodity part. Placing the two sockets within roughly 20 mm keeps the LPDDR6 interface short enough for commodity-grade signal integrity.

Variant B --- Module-integrated ASIC (high-density option). The DUV MAC ASIC is mounted directly on the CAMM module substrate beside the DRAM packages. This yields the shortest memory interface and lowest interface power, at three costs: the module becomes a custom part, ASIC heat sits adjacent to the DRAM, and a failed ASIC retires the entire module.

Direct BGA attachment of the ASIC to the motherboard was considered and rejected: a permanent solder joint defeats field serviceability and contradicts the reconfigurable-inventory philosophy of Section 2.5. The reference configuration in the Results section assumes Variant A.

Because the CAMM2 connector pins are fully occupied by the memory bus, four sideband signals travel on a separate low-pin-count board-level sideband header (in Variant B, a short flex tail from the module substrate). Each is a single wire from the node, and each runs as part of a daisy-chained control net that climbs the spine to the central router chip; the net is a low-speed control plane entirely separate from the data-path NoB:

DOORBELL\\_TRIG: asserted by the node's DMA engine only when (a) the received byte count equals the message-length field in the flit header, (b) the end-to-end message CRC validates, and (c) the CRC-protected destination field equals the node's own coordinate. Because HFR forwarding along a single path is strictly in-order, byte-count equality detects complete delivery; a stream aborted mid-message can never satisfy all three conditions. The full state machine is specified in Section 2.9.

DOORBELL\\_ACK: asserted by the same DMA engine in the same cycle as DOORBELL\\_TRIG, and forwarded up the sideband net. It is the source's completion signal, and its single-wire cost is the entire acknowledgment overhead of the design: there is no ACK packet, no sequence number, and no extra latency on the data path. A source that has not seen DOORBELL\\_ACK within its compile-time latency budget infers a lost or un-executable message and raises NODE\\_ERR for that destination (Section 4.1). The ACK wire is the loss detector that turns the doorbell's refusal-to-fire into a recoverable, observable event.

NODE\\_ERR: a fatal fault line asserted on the sideband control net, streaming directly to the central router chip (Section 4.1). It does not travel on the data path, so it remains usable when the node's NoB or DMA path is dead.

TOPOLOGY\\_RDY: asserted during Power-On Self-Test once voltage margins and link training succeed.

2.5 Initialization and the POST Discovery Sequence

Initialization begins when the central router chip pulses sequenced voltage rails down the Z-axis spine. The router emits a ping frame; each layer's xyz\\_repeater propagates it along the local X/Y NoB. Every populated node that completes link training and Built-In Self-Test asserts TOPOLOGY\\_RDY. The router aggregates responses into a live inventory of active Layer IDs and Module IDs.

This inventory is the Instruction Set Architecture for this boot instance. The router exports a topology schema describing physical coordinates, per-link bandwidth, and deterministic latency between each pair. That latency is a closed-form function of the two coordinate pairs (hop count $\\times$ per-hop delay, plus message serialization at the link rate of Section 2.2), not a search result. Because the compiler backend targets this exact physical graph, the motherboard layout becomes the executable program structure. Reconfiguring the hardware---adding a board, removing a faulty node, or changing stack height---automatically generates a new ISA schema.

Discovery is bounded, not open-ended: at the reference scale, 512 LPDDR6-class links train in milliseconds each and run in parallel, the ping/inventory sweep completes in microseconds, and the router aggregates the inventory in well under one second before any weight is loaded. The AOT compiler then lowers the user IR against the exported schema (Section 2.8), so the "ISA for this boot instance" exists within a second of power-on.

LPDDR6 is volatile, so static state must be loaded after discovery. The reference design supports streaming from the host over router uplinks (Section 4.2), loading a fully populated 64 TB chassis in under ten minutes at uplink line rate, or optional per-node boot flash on the sideband header (roughly two minutes through 512 parallel streams). Weight loading is a one-time DMA phase completed before execution begins.

2.6 Software Stack and Execution Model

2.7 IR compilation

High-level user code---whether a MoE transformer, a weather simulation stencil kernel, or a functional dataflow graph---is first lowered into a standard Intermediate Representation (IR) such as MLIR{c(18)}. The backend does not target CUDA, SIMD, or a conventional instruction set. It targets the physical topography schema exported during POST. Tensor operations, stencil neighborhoods, and functional dataflow nodes are mapped to specific CAMM2/DUV nodes as memory-resident weights and compute kernels.

2.8 Coordinate routing and dispatch

The compilation pipeline operates in two phases.

Ahead-of-Time (AOT) mapping. The compiler assigns weights, kernels, and grid subdomains to physical coordinates, then computes every route and latency in closed form: within a layer, X-then-Y between coordinates; across layers, a monotone spine traversal between layer attachments, bracketed by on-board paths. Both are $O(1)$ arithmetic functions of the [Layer ID | Module ID] pair---on a single-path tree there is exactly one route, so no pathfinding algorithm has anything to find.

Just-in-Time (JIT) dispatch. Dynamic tokens---such as MoE expert routing decisions---arrive at the central router chip. The router evaluates the same closed-form routing function, prepends a strict [Layer ID | Module ID] header, and injects. There is no runtime arbitration, no congestion sensing, and no adaptive routing. The router's 1 GHz dispatch stage issues one routing decision per clock, but the sustained dispatch rate is set by the fabric, not the decision stage: injection is bounded by the destination buffer credit rule of Section 4.3, cross-layer traffic by the spine sizing rule of Section 2.1, and per-link traffic by the 16 GB/s link rate. At the reference spine of Section 2.1 the sustained cross-layer dispatch rate is therefore on the order of $10^{8}$--$10^{9}$ tokens/s depending on expert placement---comparable to what 131 TB/s of node-local memory can serve, and far below the router's raw decision capacity. Optional per-layer dispatch replicas scale the decision rate linearly and remain deterministic because the routing function is pure; they do not raise the fabric-bound ceiling.

2.9 The doorbell mechanism

A flit's lifecycle exemplifies zero-overhead activation. The central router chip injects the payload into the fabric. The combinational comparator inside the xyz\\_repeater at the target layer gates the flit onto the X/Y NoB in sub-nanosecond time. Hardware Flit Repeaters pass the byte stream via DMA into the target node's local address space. The message header carries a length field and a CRC-protected destination coordinate; the node's DMA engine counts incoming bytes, computes the running message CRC over the protected body, and compares the protected destination to its own coordinate. When the byte count equals the length field, the CRC validates, and the destination matches, the DMA engine asserts DOORBELL\\_TRIG and DOORBELL\\_ACK. This physical pin transition wakes the DUV MAC ASIC instantly; there is no software interrupt handler, no software polling loop, and no operating-system context switch.

The hardware fabric decouples transport from computation. The deterministic repeater network connects to a modular Processing Element (PE) interface via standard AXI-Stream / Ready-Valid handshaking, allowing the underlying execution block (systolic array, FP16 MAC array, or ALU) to be swapped independently of the routing fabric. The companion PE tile stub in the HDL sketch (HDL/pe\\_tile\\_stub.v) implements this contract: it consumes a flit on its slave port, holds it for one to two clock cycles to model multiply-accumulate latency, and re-presents it on the master port, so the transport-level verification of Sections 3.4 and 4.3 is independent of which execution block sits behind the interface.

Every node---whether a MAC node or a repeater serving a CAMM slot---runs the same hardwired three-phase doorbell discipline. This is not software polling: no instructions are fetched and no program counter exists. The phases are the armed and drain states of a finite state machine burned into the doorbell logic:

WATCH (initial phase): continuously check the sentinel bit at the end address of the DMA target buffer. When the sentinel is set (byte count equals header length, CRC valid, and protected destination matches), interrupt WATCH and enter DISPATCH.

DISPATCH: fire the node's resident function. COMPUTE (PNM processor): execute the resident kernel, e.g., matrix multiplication over the landed payload and local weights. FORWARD (repeater at the CAMM slot): stream the payload onward to the next statically mapped node. DOORBELL\\_ACK is asserted with DOORBELL\\_TRIG at the fire edge.

DRAIN (reverse phase): while results egress, check the sentinel; when transfer completes, clear the sentinel (bit now empty) and clear the initial payload data; restart WATCH.

The buffer is rigorously empty before the next message can arrive, making back-to-back activations safe without software synchronization. Because every route is a single path of strictly in-order HFR stages, byte-count equality is a sound completion test. An aborted stream always fails the count, the CRC, or the destination check, so the doorbell never fires on a partial, corrupt, or misdelivered payload---and when it refuses, DOORBELL\\_ACK is withheld, which the source's watchdog converts into an observable NODE\\_ERR (Section 4.1).

2.10 Reliability and determinism

LPDDR6 provides on-die ECC; the MAC ASIC's memory controller adds conventional SECDED on the bus. Every fabric link carries a link-local CRC per flit that covers the full flit including its routing header bytes, so a bit error that would corrupt a route decision is detected before the consuming gate strips its header byte; a corrupt flit is discarded at the boundary rather than misrouted. Every message additionally carries an end-to-end CRC per message over the protected body---[CTRL, DEST, LEN, payload]---and the destination DMA refuses the doorbell unless the protected destination matches its own coordinate (Section 2.9).

Deterministic replay is claimed precisely, in two distinct senses. First, re-injecting an identical stimulus onto an identical fabric reproduces delivery bit-exactly: the fabric has no hidden state, and this property is machine-checked in the co-simulation (Section 4.3). Second, DRAM contents are not assumed to be bit-stable across arbitrarily long runs: LPDDR6 on-die ECC plus the bus SECDED protect every access, and a background scrub pass re-reads resident weights at a rate sized so the mean time to an undetected mis-correction exceeds the chassis lifetime. Post-fault recovery (Section 4.1) re-runs the work on a healthy replica; that is functional recomputation under the same doorbell discipline, not bit-exact replay of the failed node's memory contents. The machine guarantees determinism of the fabric and of computation given a memory snapshot; soft errors in memory are handled statistically by scrub and retry, not claimed away.

2.11 Target Workloads

2.12 Mixture-of-Experts transformers

Trillion-parameter MoE transformers present a capacity crisis for HBM-based systems: only a sparse subset of experts is active per token, yet the entire parameter set must be accessible{c(3,4)}. Our architecture distributes expert weights across hundreds of cheap LPDDR6 pools. A one-trillion-parameter model at INT8 occupies 1 TB---eight reference nodes---and at FP16, sixteen. A single 64 TB chassis holds tens of trillions of parameters with room for replication.

When a token requires a given expert, the central router chip evaluates the coordinate routing function, dispatches the token via wormhole routing to the holding node, and the doorbell fires. The local MAC executes and returns the updated hidden state. Because only the token travels to the expert---the expert's weights stay resident---the cross-layer traffic fraction $\\alpha$ of Section 2.1 is a direct consequence of expert placement: with random placement across eight layers, $\\alpha = 7/8$ of token dispatches cross the spine, and the honest spine-sizing rule sizes the fabric for exactly that. Three refinements matter in production: (i) hot-expert replication from offline activation histograms across $k$ nodes, which both cuts latency and---when replicas are placed layer-locally---shrinks $\\alpha$ toward the resident dense-component fraction, trading replication cost against spine provisioning; (ii) expert capacity via elastic input buffers sized to at least one full message burst, with compiler-set capacity factors; (iii) dense components (attention projections, embeddings, output head) replicated on dedicated dense nodes per layer under the same doorbell discipline. Idle experts draw no dynamic compute power---only DRAM refresh current.

2.13 Scientific HPC stencil workflows

Climate modeling, computational fluid dynamics, and seismic imaging rely on regular FP64 stencil operations over massive grids. These workloads map onto the rigid X/Y grid of sockets: each grid subdomain becomes a physical node, and halo exchanges become single-hop dimension-order routes between neighboring sockets that never enter the spine. Because the stencil neighborhood is known at compile time, the AOT compiler generates exact routes with no runtime indirection, replacing cluster middleware such as MPI{c(19)} with a coordinate function.

The roofline analysis of Section 3.2 shows why mature nodes suffice: a 7-point FP64 stencil has an arithmetic intensity of roughly 0.3--0.5 FLOP/byte, far below the reference node's machine balance of about 1.5 FLOP/byte{c(5)}. Where numerics permit, mixed-precision halo storage raises effective intensity further. Deterministic worst-case halo-exchange latency is a compile-time constant (Section 4.4).

2.14 Functional data-based workflows

The mappable subset is first-order dataflow graphs of pure kernels over statically allocated buffers{c(6,11)}. Within this subset, an actor is a node, a message is a flit, and a statically scheduled functional kernel is a doorbell activation. General lazy graph reduction with an unbounded dynamic heap is future work (the Conclusion section). Referential transparency is exactly what makes the replay guarantees of Sections 2.6 and 4.1 hold.

Results

All figures in this section are first-order engineering estimates intended to establish plausibility and sizing rules, not measured results; no prototype exists yet.

3.1 Reference chassis

Table 1 summarizes the reference configuration: 512 nodes, 64 TB aggregate capacity, approximately 131 TB/s aggregate node-local bandwidth, approximately 197 TFLOPS FP64, and 8--10 kW chassis power, with a spine provisioned at $\\approx$2 TB/s per direction from the cross-layer sizing rule of Section 2.1.

Table 1. Reference chassis configuration (first-order estimates).

Quantity | Reference value
Node | 128 GB LPDDR6 CAMM2 + 14 nm DUV MAC ASIC (192 FP64 FMA @ 1 GHz $\\approx$384 GFLOPS FP64; $\\approx$768 GFLOPS FP16; $\\approx$1.5 TOPS INT8)
Node memory bandwidth | $\\approx$256 GB/s (192-bit LPDDR6 CAMM2 @ 10.7 Gb/s/pin)
Node fabric link | $\\approx$16 GB/s (128-bit source-synchronous @ 1 GHz)
Node power | $\\approx$15 W
Board (1 layer) | 8$\\times$8 = 64 nodes; 8 TB; $\\approx$16 TB/s; $\\approx$1 kW
Chassis (8 layers) | 512 nodes; 64 TB; $\\approx$131 TB/s; $\\approx$197 TFLOPS FP64; $\\approx$8--10 kW
Spine | Parallel 16 GB/s lanes; $\\approx$2 TB/s per direction aggregate (cross-layer sizing rule, Section 2.1)

3.2 Roofline: why mature nodes suffice

The reference node's machine balance is precision-dependent, because the DUV MAC array packs INT8 and FP16 lanes at 4$\\times$ and 2$\\times$ the FP64 rate:
$$
B_{{\\mathrm{{machine}}}}^{(\\mathrm{{FP64}})} = \\frac{{384\\ \\mathrm{{GFLOP/s}}}}{{256\\ \\mathrm{{GB/s}}}} \\approx 1.5\\ \\mathrm{{FLOP/byte}}, \\qquad
B_{{\\mathrm{{machine}}}}^{(\\mathrm{{FP16}})} \\approx 3.0, \\qquad
B_{{\\mathrm{{machine}}}}^{(\\mathrm{{INT8}})} \\approx 6.0.
$$
A 7-point FP64 stencil has arithmetic intensity $\\approx$0.3--0.5 FLOP/byte, below the 1.5 FP64 balance (strongly bandwidth-bound){c(5)}. MoE expert weight-streaming sits near 1--2 FLOP/byte per token---below the 3.0 FP16 balance and far below the 6.0 INT8 balance, so MoE is bandwidth-bound on the precision it actually runs, even at the top of its intensity range. Performance is therefore limited by the LPDDR6 bus, never by the MAC array, for both flagship workloads. This is the load-bearing argument for DUV: a 14 nm or 28 nm array already saturates the memory it is attached to.

3.3 Cost model

First-order, volume-dependent node bill of materials: LPDDR6 CAMM2 module $\\approx$\\$400, 14 nm MAC ASIC $\\approx$\\$40, socket/board/assembly share $\\approx$\\$60, for a node total of $\\approx$\\$500 ($\\approx$\\$3.9/GB). A 512-node chassis is $\\approx$\\$256k for 64 TB. An H100-class GPU at $\\approx$\\$30k for 80 GB HBM is $\\approx$\\$375/GB{c(2)}. The architecture delivers roughly two orders of magnitude lower cost per gigabyte of attached memory.

3.4 Thermal and latency budgets

Thermal: $\\approx$15 W per node, $\\approx$1 kW per board, $\\approx$8--10 kW per chassis; 15 L/min of 30$^\\circ$C water with 10$^\\circ$C rise and orifice-balanced branches keeps worst-case DRAM junction $\\leq$70$^\\circ$C against an 85$^\\circ$C throttle.

Latency (bounded, not average): xyz\\_repeater compare $\\approx$0.1 ns; HFR hop $\\approx$1--2 ns; worst-case on-board route (8$\\times$8) 14 hops $\\approx$14--28 ns; spine traversal (7 layer hops) $\\approx$7--14 ns; link serialization for a 4 KB message at the 16 GB/s fabric link $\\approx$256 ns (the dominant term); doorbell wake $\\approx$1 ns. The end-to-end activation bound for a 4 KB cross-node message is therefore $\\approx$0.3 $\\mu$s, dominated by link serialization, and it scales linearly with message length ($\\approx$64 ns per KB). The closed form verified in Section 4.3 is the sum of these terms: hop count $\\times$ per-hop delay plus message bytes divided by the link rate; the co-simulation checks the hop-count and serialization terms exactly and treats contention as a separate, compile-time-scheduled term.

Discussion

4.1 Failure Model and Recovery

Losses are observable before they become failures. Every injected message has a compile-time latency budget, and its source expects DOORBELL\\_ACK within that window (Section 2.4). A missing ACK---whether the message was dropped, truncated, or refused at the doorbell---raises NODE\\_ERR for that destination; there is no silent hang. NODE\\_ERR assertion triggers a four-step protocol: (1) quarantine the node from the live topology schema; (2) discard in-flight flits destined for it (the affected set is exactly enumerable on a single-path fabric); (3) recompute---the source re-injects the work toward a healthy replica or the reinitialized node, under the same doorbell discipline; this is functional recomputation, not bit-exact replay of the failed node's memory (Section 2.10); (4) re-export the amended schema at the next batch boundary. Routing tables are immutable within a boot session, so step (4) is a controller-coordinated reload, not runtime adaptation: the router regenerates the AOT tables against the amended schema and loads them during the batch boundary, when the fabric is quiet. The chassis continues in degraded mode with no restart. A failed spine lane is handled at the physical layer---periodic link re-training excludes the dead lane and the remaining lanes re-lane transparently---so routing tables need no change for lane degradation; total spine failure partitions the chassis (the Conclusion section).

4.2 Host Interface and I/O

The central router chip terminates dual PCIe Gen5 x16-class uplinks ($\\approx$128 GB/s aggregate) or 100/200 GbE equivalents. The host streams initial weights at boot, injects input tokens, and drains outputs. Runtime token traffic is kilobyte-class at the dispatch rates of Section 2.6---well below uplink and spine capacity. The host never touches the compute fabric directly.

4.3 Verification and Formal Properties

Deadlock freedom (sketch). Every flit is assigned one of four virtual-channel classes in strictly increasing order: (0) on-board egress (X-then-Y dimension order), (1) spine ascent, (2) spine descent, (3) on-board delivery (X-then-Y from spine attachment to destination). Upward and downward spine flows are separate virtual channels (classes 1 and 2), which is why the count is four, not three. Intra-class dependencies are acyclic by standard results; cross-class dependencies only point from lower to higher classes. The global channel dependency graph is therefore acyclic, and by Dally and Seitz the fabric is deadlock-free{c(13,14)}.

The buffering that virtual channels require lives only at the two kinds of state points in the design: the xyz\\_repeater spine attachments (per-class elastic buffers) and the node DMA ports (Section 2.9). HFRs remain stateless re-timers: they carry no per-VC state and never decide a route, which is what keeps the "no queues on the data path" claim true for the forwarding elements. The per-VC attachment buffers are credited in the flow-control sense below, so a blocked flit occupies its class's buffer and cannot block another class.

Livelock freedom follows from minimal single-path routes. Consumption is enforced structurally: the per-VC elastic buffers at spine attachments and node ports hold at least one maximum-length message, and sources may not inject without destination buffer credit, so no class ever exhausts and blocks a lower class. Worst-case latency for any coordinate pair is a closed-form expression---hop count $\\times$ per-hop delay plus message length divided by link rate (Section 3.4)---and contention is absent by construction because the AOT scheduler (Section 2.8) assigns message schedules that respect every buffer's credit budget; the co-simulation verifies the hop-count and serialization terms exactly and treats the scheduler's credit feasibility as a compile-time property. Given identical inputs onto an identical fabric, every computation and message schedule reproduces bit-exactly (Section 2.10).

4.4 Limitations and Future Work

LPDDR6 (JESD209-6){c(17)} CAMM2 parts and high-capacity modules are forward-looking; the current JEDEC socketable module class, LPCAMM2 (JESD318), is LPDDR5X and trims per-node bandwidth to $\\approx$136--153 GB/s with 48--64 GB modules today{c(16,17)}. The architecture accommodates both module classes with no change to the MAC ASIC or routing fabric. Manifold balancing requires CFD and hardware validation. Multi-chassis scale-out needs a second routing level and one additional virtual-channel class. General lazy evaluation needs a dynamic heap this design omits. A dual-spine variant eliminates single-chassis partition mode. The claims of Section 4.3 are argued, not yet machine-checked{c(9)}.

The central router chip is a single point of failure, and this paper treats that fact explicitly rather than designing around it. Chassis availability is bounded by the router's availability multiplied by the fabric's: the router is socketed and cold-swappable, POST re-discovers the chassis in under a second (Section 2.5), and all in-flight traffic drains through the stateless fabric while the spare boots, so a router replacement costs a sub-second dispatch outage. There is no live router failover---dual-router handover of the JIT tables is future work---and the reference design accepts the resulting availability bound in exchange for a single programmable silicon. An HFR, xyz\\_repeater, or node failure degrades the machine by exactly that node (Section 4.1); a router failure halts dispatch until the spare is in place.

Conclusion

This paper has specified a distributed spatial Processing-Near-Memory architecture that bypasses the HBM capacity wall through commodity 192-bit LPDDR6 CAMM2 memory, mature-node DUV logic, and deterministic wormhole routing{c(13,15,17)}. By treating the physical motherboard as an immutable dataflow graph and exporting its topography as a bespoke ISA, the system eliminates runtime scheduling, cache coherency, and operating-system overhead. Routing is coordinate arithmetic on a single-spine tree with dimension-order on-board paths; deadlock freedom follows from four monotonically ordered virtual-channel classes with credited per-class buffers at the two state points in the design; the hardened doorbell makes activation atomic, idle-free, and loss-observable through a single ACK wire; and the isothermal parallel manifold sustains thermal viability with enforced flow balance. The reference chassis---64 TB, 131 TB/s aggregate node-local bandwidth, approximately 197 TFLOPS FP64, approximately \\$4/GB---demonstrates that the economics of memory capacity favour radical simplicity by roughly two orders of magnitude per byte. Target workloads---MoE transformer inference, FP64 stencil computation, and functional data-based evaluation---sit in the bandwidth-bound regime on the precision they actually run, where mature-node silicon is already sufficient{c(3,4,5)}, and they inherit deterministic fabric replay, compile-time latency bounds, and an honest availability model with a single swappable router as the only point of state.

The full repository, including Verilog HDL sources, build scripts, and this manuscript, is available at https://github.com/im-BowenGu/PNM-Arch. All hardware schematics, topology specifications, and PCB layouts described herein are intended for release under the CERN Open Hardware Licence Version 2 Strongly Reciprocal (CERN-OHL-S){c(20)}.

Acknowledgments

The author thanks their research mentor for guidance throughout this project, the anonymous referees for their constructive feedback, and the open-source community for developing the tools and ethos that made this work possible.
