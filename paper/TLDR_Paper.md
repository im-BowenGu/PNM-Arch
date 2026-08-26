# Breaking the HBM wall — the architecture in brief

A rough-sketch overview of what the machine *is* and *how it computes*, deliberately
kept free of wire formats, register maps, and interface minutiae. Those live in
[`Paper.MD`](Paper.MD) (the specification), [`docs.md`](docs.md) (the working
documentation), and [`TLDR.md`](TLDR.md) (the project quick-start).

## The problem

Large models no longer fail on compute; they fail on *capacity*. The memory that would
hold them (HBM) sits behind silicon interposers whose area — and therefore capacity per
package — is fixed by lithography optics, and its manufacturing curve (EUV-class
lithography, stacked-die yield) is the most expensive in the industry. The result:
accelerators that dissipate hundreds of watts in a thumbnail-sized package to serve a
few dozen gigabytes, while the workloads that matter most — sparse expert models,
simulation state, image volumes — simply do not fit.

## The core idea

Stop treating memory as a peripheral. Build the computer *out of* memory:

- Every byte of state lives in ordinary, socketed commodity DRAM modules — the same
  modules laptops use, from the same fabs, at commodity prices.
- A small, dumb, fixed-function arithmetic die sits beside each module. No instruction
  decoder, no branch predictor, no caches, no OS. It multiplies and adds.
- Wires with repeaters connect everything in a fixed pattern that never changes at
  runtime. Routing a message anywhere is grade-school coordinate arithmetic, so the
  time any message takes is known before the machine is turned on.
- Exactly one chip in the whole chassis can run software: a small RISC-V management
  computer at the root of the wiring tree. It boots the machine, discovers what is
  plugged in, loads the program, and dispatches work. It also terminates a PCIe Gen5
  x16 host uplink and an NVMe storage controller in silicon, so it can boot standalone
  from local flash instead of re-streaming its OS from the host every power cycle.
  Everything else is pure transport.

The physical motherboard becomes an immutable dataflow graph, and the compiler's job is
to lay the program out on it like a circuit board — once, ahead of time.

## Physical shape

Thin boards carrying a grid of paired DRAM-module-plus-arithmetic-die "nodes" are
stacked vertically. A single shared trunk — the spine — runs up through the stack, and
each board taps into it through one gateway component. All long-haul traffic goes up or
down this trunk; all local traffic moves across a board in two dimension-ordered hops.
At the bottom of the trunk sit the management computer and the host connection. Boards
are cooled by a vertical coolant manifold that injects identical-temperature fluid into
every layer simultaneously, with calibrated flow restrictions so balance is enforced by
hardware rather than hoped for.

## How a computation runs

1. **Compile.** A compiler ingests the program or model, discovers the physical layout
   of the chassis, and decides *which node holds which weight* and *in what order*
   messages move. Because placement and schedule are computed once, nothing at runtime
   arbitrates, evicts, or guesses.
2. **Load.** At boot, weights stream out to their nodes over the same wiring that later
   carries computation. The machine is now a static dataflow graph etched in DRAM.
3. **Stream.** To run one step, the router injects tokens; the fabric delivers each to
   the node whose resident weights need them; the arithmetic die consumes the bytes as
   they arrive.
4. **Fire.** Completion is a hardware event, not an interrupt: a message counts as done
   only when the byte count, integrity check, and destination all agree — checked in
   silicon on every message. Wrong or corrupted messages are refused loudly and never
   trigger computation.

For sparse expert models this is the natural shape: every expert stays resident in its
private pool of cheap DRAM, and only the tiny token travels to whichever few experts
are selected. For grid simulations the board grid *is* the simulation grid, and
neighbor exchanges are single local hops.

## Why trust it

The transport claims are not argued, they are executed: a co-simulation harness drives
the real gate-level model of the fabric against independent software oracles, checking
byte-exact delivery under backpressure, refusal accounting for corrupted messages,
kernel results against golden values, and — because nothing on the data path holds
hidden state — bit-identical reproduction of entire runs. Static analysis covers the
remaining gate-level hygiene. What remains unproven (cooling fluid dynamics, DRAM
availability curves) is labeled as engineering estimate, not claimed away.

## Power and heat

Because nothing spends energy speculating — no caches re-fetching, no cores fetching
instructions, no coherence traffic — a node idles in the watt range and works at
roughly fifteen watts: about nine for the arithmetic die, five for its DRAM module,
one for its share of the wiring. Sixty-four nodes make about a kilowatt per board; a
full chassis lands in the eight-to-ten-kilowatt band including fabric, conversion, and
cooling losses — two orders of magnitude below the GPU fleet needed to hold the same
bytes.

## Scaling

Remove the spine and the same recipe shrinks to a single-board desk-side unit in the
multi-terabyte class. Replicate the chassis and join replicas through a second routing
level and the same recipe grows to warehouse scale — each chassis keeping its own
deterministic timing, with no coherence protocol appearing anywhere in between.
Memory generations ride the same property: the node's memory controller contract is
the only thing consumers see, so LPDDR5, LPDDR5X, and LPDDR6 module classes (and DDR4/5
SODIMMs at the deskside tier) swap by synthesis-time parameter with the fabric,
compute units, and firmware untouched — each variant verified by its own testbench.

## Key numbers (reference chassis, first-order estimates)

| Metric | Value |
|--------|-------|
| Nodes | 512 (8 layers × 8×8 grid) |
| Attached memory | 64 TB |
| Aggregate node-local bandwidth | ~131 TB/s |
| FP64 throughput | ~197 TFLOPS |
| Power | ~15 W per node; ~8–10 kW per chassis |
| Cost | ~$1M per chassis (~$16/GB), vs ~$24M+ of HBM-class hardware for the same bytes |

## Physical product readiness

The RTL is written as if tape-out mattered: latch-based clock-gating cells with scan
test override, two-flop reset synchronizers on every async crossing, JTAG + MBIST + PHY
loopback for bring-up, SDC timing constraints and a device tree shipped beside the
sources, and an assembly schema that composes verified modules into board netlists.
What remains between this repository and fabricated silicon is exactly the part no RTL
paper can claim: analog SerDes characterization, package bond maps, and floorplan
extraction — vendor work, labeled as such rather than papered over.

## Where to look next

- [`Paper.MD`](Paper.MD) — full specification with rationale and citations
- [`README.md`](README.md) — repository tour and build instructions
- [`docs.md`](docs.md) — module-by-module documentation of the RTL and harness
- [`HDL/`](HDL/) — the gate-level fabric, compute units, controllers, and links
- [`sim/`](sim/) — the Go co-simulation harness, compilers, and drivers
