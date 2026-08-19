package pnm

import (
	"bytes"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"reflect"
	"runtime"
	"strconv"
	"strings"
)

// NodeID is a (layer, x, y) chassis coordinate.
type NodeID struct {
	L int
	X int
	Y int
}

func (n NodeID) String() string { return fmt.Sprintf("(%d, %d, %d)", n.L, n.X, n.Y) }

// LXPair keys the Y-lane residual streams by (layer, x).
type LXPair struct {
	L int
	X int
}

// Dims is the chassis shape (layers, board_x, board_y).
type Dims struct {
	Layers int
	Bx     int
	By     int
}

func (d Dims) String() string { return fmt.Sprintf("(%d, %d, %d)", d.Layers, d.Bx, d.By) }

// SimDir locates the sim/ directory — the harness working directory. The
// recorded source path of this file at build time points into
// <sim>/internal/pnm/, so three Dirnames reach sim/. Falls back to "." (run
// from sim/) when the build path is relative or trimmed.
func SimDir() string {
	if _, file, _, ok := runtime.Caller(0); ok {
		d := filepath.Dir(filepath.Dir(filepath.Dir(file)))
		if _, err := os.Stat(filepath.Join(d, "go.mod")); err == nil {
			return d
		}
	}
	return "."
}

var FABRIC = []string{"flit_gate.v", "hfr.v", "xyz_repeater.v", "xy_turn.v",
	"node_eject.v", "vc_merge.v", "crc16.v", "bf16_fma.v", "pe_tile_stub.v"}

// PE_PIPE_DELAY: the generated node MAC stub (pe_tile_stub.v,
// MULT_LATENCY=2) adds two pipe cycles between the eject and the node DMA
// port; the closed-form latency checks account for it (Paper.MD 2.5/3.4 +
// Section 2.9 MAC latency).
const PE_PIPE_DELAY = 2

// CTRL field: {vc_class[7:6], op[5:4], rsvd[3:0]}  (HDL/pnm_defs.vh)
//
// The CTRL field carries the class a flit was ASSEMBLED with (its origin
// class, paper §4.3): 2 for router-injected requests and pass-through
// (spine descent), 0 for node-egress results. rsvd[0] is the return flag:
// when set, pe_tile_stub re-emits the transformed body as a result flit
// (paper §2.9 result egress).
const (
	CTRL_COMPUTE_SPINE = 0x80 // vc_class=2 (descent) | OP_COMPUTE
	CTRL_FORWARD_SPINE = 0x90 // vc_class=2 (descent) | OP_FORWARD (pass-through)
	CTRL_ECHO_SPINE    = 0x81 // vc_class=2 (descent) | OP_COMPUTE | return flag
)

// VC classes (HDL/pnm_defs.vh) carried on the per-link 2-bit sideband.
const (
	VC_BOARD_EGRESS    = 0 // class 0: node TX onto the board egress merge
	VC_SPINE_ASCENT    = 1 // class 1: up-spine after the repeater merge
	VC_SPINE_DESCENT   = 2 // class 2: spine descent (router injection)
	VC_ONBOARD_DELIVER = 3 // class 3: on-board X/Y lanes after the 2->3 cut
)

// StreamByte is one wire byte plus its SOP/EOP framing bits and the
// per-link 2-bit VC sideband (paper §4.3) the byte travels on.
type StreamByte struct {
	Data byte
	Sop  bool
	Eop  bool
	Vc   byte
}

// Flit encodes one wire flit as [(data, sop, eop), ...].
//
// Wire layout (HDL/pnm_defs.vh):
//
//	LAYER_ID | MODULE_ID | CTRL | LEN_LO | LEN_HI | payload | CRC_HI | CRC_LO
//
// The CRC is CRC-16/CCITT over [MODULE_ID, CTRL, LEN_LO, LEN_HI, payload]:
// the eject forwards MODULE_ID as the DEST byte instead of stripping it, so
// the destination field is inside the end-to-end CRC coverage and the
// doorbell rejects a misdelivered message (Paper.MD section 2.4/2.10).
//
// corrupt=true flips a payload byte *after* the CRC is computed: delivery
// still happens (the fabric is pure transport), but the destination
// doorbell must refuse to fire (Paper.MD section 2.9).
func Flit(layer, mod, ctrl int, payload []byte, corrupt bool) []StreamByte {
	body := make([]byte, 0, 4+len(payload))
	body = append(body, byte(mod), byte(ctrl), byte(len(payload)&0xFF), byte((len(payload)>>8)&0xFF))
	body = append(body, payload...)
	hi, lo := crcBytes(body)
	if corrupt && len(payload) > 0 {
		body[4+len(payload)/2] ^= 0xFF // mid-payload, post-CRC
	}
	wire := make([]byte, 0, len(body)+3)
	wire = append(wire, byte(layer))
	wire = append(wire, body...)
	wire = append(wire, hi, lo)
	out := make([]StreamByte, len(wire))
	for i, b := range wire {
		out[i] = StreamByte{Data: b, Sop: i == 0, Eop: i == len(wire)-1}
	}
	return out
}

// WithVC tags every byte of a flit with the given VC sideband class.
func WithVC(wf []StreamByte, vc byte) []StreamByte {
	for i := range wf {
		wf[i].Vc = vc
	}
	return wf
}

// StubOutput is the pe_tile_stub's DMA output for a landed wire stream.
//
// The stub is the node's MAC pipe with a resident bias-add kernel
// (KERNEL_CONST): it adds bias to every payload byte in silicon and
// re-emits CRC-16/CCITT-FALSE over the transformed body, so what the
// node software sees differs from the wire bytes only in exactly those
// two ways (head [DEST, CTRL, LEN] passes through untouched).
func StubOutput(dma []byte, bias int) []byte {
	if bias == 0 {
		return append([]byte(nil), dma...)
	}
	if len(dma) < 4 {
		return append([]byte(nil), dma...)
	}
	plen := int(dma[2]) | (int(dma[3]) << 8)
	body := dma[:4]
	payload := make([]byte, plen)
	for i := 0; i < plen; i++ {
		if 4+i < len(dma) {
			payload[i] = byte((int(dma[4+i]) + bias) & 0xFF)
		}
	}
	transformed := make([]byte, 0, len(body)+plen)
	transformed = append(transformed, body...)
	transformed = append(transformed, payload...)
	hi, lo := crcBytes(transformed)
	return append(append(transformed, hi), lo)
}

// WriteStimulus writes a stimulus hex file; returns total byte count.
// Each word: [7:0] data, [8] sop, [9] eop, [11:10] vc sideband.
func WriteStimulus(stream []StreamByte, path string) int {
	var sb strings.Builder
	for _, w := range stream {
		word := int(w.Data)
		if w.Sop {
			word |= 1 << 8
		}
		if w.Eop {
			word |= 1 << 9
		}
		word |= int(w.Vc) << 10
		fmt.Fprintf(&sb, "%04x\n", word)
	}
	if err := os.WriteFile(path, []byte(sb.String()), 0o644); err != nil {
		panic("WriteStimulus: " + err.Error())
	}
	return len(stream)
}

// Golden computes what the node's kernel *should* produce for this payload.
//
// bias is the node's hardware bias-add constant (pe_tile_stub KERNEL_CONST):
// the MAC stub has already added it to every payload byte in silicon, so the
// golden model applies it before the resident kernel runs.
func Golden(kernel string, payload []byte, weights []int, gstate map[string]uint64, bias int) interface{} {
	if bias != 0 {
		payload = append([]byte(nil), payload...)
		for i := range payload {
			payload[i] = byte((int(payload[i]) + bias) & 0xFF)
		}
	}
	switch kernel {
	case "echo":
		return append([]byte(nil), payload...)
	case "sum":
		var s uint64
		for _, b := range payload {
			s += uint64(b)
		}
		return s & 0xFFFFFFFF
	case "accum":
		var s uint64
		for _, b := range payload {
			s += uint64(b)
		}
		gstate["acc"] = (gstate["acc"] + s) & 0xFFFFFFFF
		return gstate["acc"]
	case "dot":
		n := max(len(payload), len(weights))
		var acc uint64
		for i := 0; i < n; i++ {
			var pv, wv uint64
			if i < len(payload) {
				pv = uint64(payload[i])
			}
			if i < len(weights) {
				wv = uint64(weights[i])
			}
			acc += pv * wv
		}
		return acc & 0xFFFFFFFF
	}
	panic("unknown kernel: " + kernel)
}

// ManifestNode is the per-node program manifest: resident kernel, weights,
// bias-add constant, and the routed packets destined to the node.
type ManifestNode struct {
	Kernel  string
	Weights []int
	Bias    int
	Packets []*PacketEntry
}

// PacketEntry records one injected packet. Routed entries carry DMA bytes
// (wire bytes minus the stripped LAYER byte), the golden kernel result, and
// the corrupt flag; pass-through entries carry the full wire bytes. Echo
// entries additionally carry the golden echo wire (the transformed body
// re-emitted to the AOT-fixed requester, paper §2.9 result egress).
type PacketEntry struct {
	Idx     int
	WireLen int
	DMA     []byte
	Corrupt bool
	Golden  interface{}
	Wire    []byte
	Echo    []byte // golden result-egress flit for return-flag requests
	Vc      byte   // origin class on the wire (sideband)
	Sidx    *int
}

// OrderEntry is one record in the injection order: destination layer (or
// pass-through), the wire flit, and its manifest entry.
type OrderEntry struct {
	IsPT bool
	Key  int
	WF   []StreamByte
	Ref  *PacketEntry
}

// Program is a scenario under construction: stream + per-node manifest + tail.
type Program struct {
	Name      string
	Latency   string // "exact" | "bounded"
	Stream    []StreamByte
	Manifest  map[NodeID]*ManifestNode
	GState    map[NodeID]map[string]uint64
	Tail      []*PacketEntry
	BP        map[NodeID]int
	NInjected int
	Order     []OrderEntry
	DESExact  bool // cross-check the gate-level cycles against the DES model
	MixedVC   bool // skip the blanket vc==2 inject assertion (vcsweep)
}

// NewProgram mirrors Program.__init__.
func NewProgram(name string, nodes []NodeID, latency string) *Program {
	p := &Program{
		Name:     name,
		Latency:  latency,
		Manifest: make(map[NodeID]*ManifestNode),
		GState:   make(map[NodeID]map[string]uint64),
		BP:       make(map[NodeID]int),
	}
	for _, n := range nodes {
		p.Manifest[n] = &ManifestNode{Kernel: "dot", Weights: []int{}, Bias: 0, Packets: []*PacketEntry{}}
		p.GState[n] = map[string]uint64{}
	}
	return p
}

// ProgramNode mirrors Program.program_node.
func (p *Program) ProgramNode(n NodeID, kernel string, weights []int, bias int) {
	m := p.Manifest[n]
	m.Kernel = kernel
	m.Weights = append([]int(nil), weights...)
	m.Bias = bias
}

// InjectRouted mirrors Program.inject_routed: a class-2 compute flit.
func (p *Program) InjectRouted(n NodeID, ctrl int, payload []byte, corrupt bool) {
	p.InjectRoutedVC(n, ctrl, payload, corrupt, VC_SPINE_DESCENT)
}

// InjectRoutedVC injects a routed flit carrying the given origin class.
func (p *Program) InjectRoutedVC(n NodeID, ctrl int, payload []byte, corrupt bool, vc byte) {
	wf := WithVC(Flit(n.L+1, (n.X<<4)|n.Y, ctrl, payload, corrupt), vc)
	p.Stream = append(p.Stream, wf...)
	entry := &PacketEntry{Idx: p.NInjected, WireLen: len(wf), DMA: dmaOf(wf), Corrupt: corrupt, Vc: vc}
	if !corrupt {
		m := p.Manifest[n]
		entry.Golden = Golden(m.Kernel, payload, m.Weights, p.GState[n], m.Bias)
	}
	m := p.Manifest[n]
	m.Packets = append(m.Packets, entry)
	p.Order = append(p.Order, OrderEntry{IsPT: false, Key: n.L, WF: wf, Ref: entry})
	p.NInjected++
}

// InjectEcho injects a compute flit with the return flag set: the node's
// MAC stub transforms the payload and re-emits it to the AOT-fixed requester
// (paper §2.9 result egress, class 0 on the wire). entry.Echo holds the
// golden echo flit for verification.
func (p *Program) InjectEcho(n NodeID, payload []byte) {
	m := p.Manifest[n]
	wf := WithVC(Flit(n.L+1, (n.X<<4)|n.Y, CTRL_ECHO_SPINE, payload, false), VC_SPINE_DESCENT)
	p.Stream = append(p.Stream, wf...)
	entry := &PacketEntry{Idx: p.NInjected, WireLen: len(wf), DMA: dmaOf(wf), Vc: VC_SPINE_DESCENT}
	m.Packets = append(m.Packets, entry)
	p.Order = append(p.Order, OrderEntry{IsPT: false, Key: n.L, WF: wf, Ref: entry})
	p.NInjected++
	entry.Echo = goldenEcho(payload, m.Bias)
	entry.Golden = Golden(m.Kernel, payload, m.Weights, p.GState[n], m.Bias)
}

// goldenEcho is what pe_tile_stub re-emits for a return-flag message:
// [REQ_MODULE, CTRL&0x30, LEN_LO, LEN_HI, payload+bias, CRC'] (paper §2.9:
// DEST rewritten to the requester, origin class cleared, CRC recomputed).
func goldenEcho(payload []byte, bias int) []byte {
	transformed := make([]byte, len(payload))
	for i := range payload {
		transformed[i] = byte((int(payload[i]) + bias) & 0xFF)
	}
	body := []byte{0xEE, 0x00, byte(len(payload) & 0xFF), byte((len(payload) >> 8) & 0xFF)}
	body = append(body, transformed...)
	hi, lo := crcBytes(body)
	return append(body, hi, lo)
}

// InjectPassthrough mirrors Program.inject_passthrough: class-2 spine
// pass-through (non-local traffic riding the spine to the chassis tail).
func (p *Program) InjectPassthrough(payload []byte) {
	p.InjectPassthroughVC(payload, VC_SPINE_DESCENT)
}

// InjectPassthroughVC injects a pass-through flit on the given origin class.
// Class-3 flits never eject (xyz_repeater vc_accept is class 2) — they ride
// to the chassis tail unchanged: the fabric's VC isolation check (paper §4.3).
func (p *Program) InjectPassthroughVC(payload []byte, vc byte) {
	wf := WithVC(Flit(0xFF, 0xEE, CTRL_FORWARD_SPINE, payload, false), vc)
	p.Stream = append(p.Stream, wf...)
	entry := &PacketEntry{Idx: p.NInjected, Wire: wireBytes(wf), Vc: vc}
	p.Tail = append(p.Tail, entry)
	p.Order = append(p.Order, OrderEntry{IsPT: true, Key: 0, WF: wf, Ref: entry})
	p.NInjected++
}

func dmaOf(wf []StreamByte) []byte {
	d := make([]byte, 0, len(wf)-1)
	for _, sb := range wf[1:] {
		d = append(d, sb.Data)
	}
	return d
}

func wireBytes(wf []StreamByte) []byte {
	d := make([]byte, 0, len(wf))
	for _, sb := range wf {
		d = append(d, sb.Data)
	}
	return d
}

// AllNodes returns [(l, x, y) ...] in spine order.
func AllNodes(layers, bx, by int) []NodeID {
	nodes := make([]NodeID, 0, layers*bx*by)
	for l := 0; l < layers; l++ {
		for x := 0; x < bx; x++ {
			for y := 0; y < by; y++ {
				nodes = append(nodes, NodeID{L: l, X: x, Y: y})
			}
		}
	}
	return nodes
}

// AllNodesIn returns the nodes of a layer slice [(l, x, y) for l in lids ...].
func AllNodesIn(lids []int, bx, by int) []NodeID {
	nodes := make([]NodeID, 0, len(lids)*bx*by)
	for _, l := range lids {
		for x := 0; x < bx; x++ {
			for y := 0; y < by; y++ {
				nodes = append(nodes, NodeID{L: l, X: x, Y: y})
			}
		}
	}
	return nodes
}

// -- scenarios --------------------------------------------------------------

// ScenarioSweep: one flit to every node; idle fabric (no backpressure).
// Every node runs a different resident kernel; with an idle fabric each
// packet's latency must equal the closed form exactly (Paper.MD 2.5):
// wire_len - 1 pipe stages + l spine hops + x X-lane hops.
func ScenarioSweep(layers, bx, by int, seed int64) *Program {
	nodes := AllNodes(layers, bx, by)
	rng := NewPyRand(uint64(seed))
	p := NewProgram("sweep", nodes, "exact")
	for i, n := range nodes {
		kernel := KERNEL_MIX[i%len(KERNEL_MIX)]
		weights := make([]int, 16)
		for j := range weights {
			weights[j] = rng.RandRange(0, 256)
		}
		p.ProgramNode(n, kernel, weights, (i%8)+1)
		p.BP[n] = 1
	}
	for i, n := range nodes {
		payload := make([]byte, 16)
		for k := 0; k < 16; k++ {
			payload[k] = byte((n.L*16 + n.X*4 + n.Y + k) & 0xFF)
		}
		// rsvd[0] is the TX-return flag (paper §2.9); the sweep never requests
		// echoes, so mask it off (echoes are exercised by ScenarioVCSweep).
		p.InjectRouted(n, CTRL_COMPUTE_SPINE|((i&0x0F)&^1), payload, false)
	}
	return p
}

// ScenarioVCSweep: virtual-channel isolation sweep (paper §4.3). One
// class-2 routed flit to every node — layer-0 nodes carry the TX-return
// flag, so the egress merge trees and the class 0->1 ascent deliver result
// echoes to the chassis root — interleaved with class-2 and class-3
// pass-through flits that must ride the spine to the tail unchanged (class
// 3 never ejects: xyz_repeater vc_accept is class 2). prog.MixedVC disables
// the blanket class-2 inject assertion; the per-port class checks in Verify
// cover the isolation claim. Echoes are layer-0 only: non-root slices'
// tail_up is a physical dead-end that must stay empty.
func ScenarioVCSweep(layers, bx, by int, seed int64) *Program {
	nodes := AllNodes(layers, bx, by)
	rng := NewPyRand(uint64(seed))
	p := NewProgram("vcsweep", nodes, "exact")
	p.MixedVC = true
	for _, n := range nodes {
		p.ProgramNode(n, "echo", nil, 3)
		p.BP[n] = 1
	}
	for i, n := range nodes {
		payload := make([]byte, 16)
		for k := 0; k < 16; k++ {
			payload[k] = byte((n.L*16 + n.X*4 + n.Y + k) & 0xFF)
		}
		if n.L == 0 {
			p.InjectEcho(n, payload)
		} else {
			// mask rsvd[0]: CTRL|1 == CTRL_ECHO_SPINE would echo these too
			p.InjectRouted(n, CTRL_COMPUTE_SPINE|((i&0x0F)&^1), payload, false)
		}
		if i%4 == 3 {
			p.InjectPassthrough(randBytes(rng, 16))                       // class 2
			p.InjectPassthroughVC(randBytes(rng, 16), VC_ONBOARD_DELIVER) // class 3
		}
	}
	return p
}

// ScenarioLoad: random destinations, mixed resident kernels, slow-DMA sinks.
func ScenarioLoad(layers, bx, by int, seed int64, flits int) *Program {
	nodes := AllNodes(layers, bx, by)
	rng := NewPyRand(uint64(seed))
	p := NewProgram("load", nodes, "bounded")
	for _, n := range nodes {
		p.ProgramNode(n, KERNEL_MIX[rng.ChoiceInt(len(KERNEL_MIX))],
			randBytesInt(rng, 64), rng.RandRange(1, 16))
		p.BP[n] = []int{1, 2, 4, 8}[rng.ChoiceInt(4)]
	}
	for i := 0; i < flits; i++ {
		if i%10 == 0 {
			p.InjectPassthrough([]byte{0xDE, 0xAD})
		} else {
			n := nodes[rng.ChoiceInt(len(nodes))]
			plen := rng.RandInt(1, 64)
			p.InjectRouted(n, CTRL_COMPUTE_SPINE|((i&0x0F)&^1), randBytes(rng, plen), false)
		}
	}
	return p
}

// ScenarioHotspot: MoE hot expert (Paper.MD 2.12): one corner node takes
// hotFrac of all traffic as kilobyte-class tokens, through the worst-case
// path in the chassis (last layer, last column, last row), with a slow
// 1-in-8 DMA. Remaining nodes take a Zipf-ish share of smaller messages.
func ScenarioHotspot(layers, bx, by int, seed int64, flits int, hotFrac float64) *Program {
	nodes := AllNodes(layers, bx, by)
	rng := NewPyRand(uint64(seed))
	hot := NodeID{L: layers - 1, X: bx - 1, Y: by - 1}
	cold := make([]NodeID, 0, len(nodes)-1)
	for _, n := range nodes {
		if n != hot {
			cold = append(cold, n)
		}
	}
	rng.Shuffle(len(cold), func(i, j int) { cold[i], cold[j] = cold[j], cold[i] })
	coldW := make([]float64, len(cold))
	for r := range coldW {
		coldW[r] = 1.0 / float64(r+1)
	}
	cum := make([]float64, len(cold))
	total := 0.0
	for i, w := range coldW {
		total += w
		cum[i] = total
	}
	p := NewProgram("hotspot", nodes, "bounded")
	p.ProgramNode(hot, "dot", randBytesInt(rng, 1024), rng.RandRange(1, 16))
	p.BP[hot] = 8
	for _, n := range cold {
		p.ProgramNode(n, KERNEL_MIX[rng.ChoiceInt(len(KERNEL_MIX))],
			randBytesInt(rng, 128), rng.RandRange(1, 16))
		p.BP[n] = []int{1, 2, 4}[rng.ChoiceInt(3)]
	}
	for i := 0; i < flits; i++ {
		if i%20 == 19 {
			plen := rng.RandInt(2, 16)
			p.InjectPassthrough(randBytes(rng, plen))
		} else if rng.random() < hotFrac {
			p.InjectRouted(hot, CTRL_COMPUTE_SPINE|((i&0x0F)&^1), randBytes(rng, 1024), false)
		} else {
			n := cold[rng.ChoicesWeighted(cum, total)]
			plen := rng.RandInt(16, 128)
			p.InjectRouted(n, CTRL_COMPUTE_SPINE|((i&0x0F)&^1), randBytes(rng, plen), false)
		}
	}
	return p
}

// ScenarioStress: full-chassis stress: scaled flit count, 4B..1KB payloads,
// ~3% corrupt-CRC messages (doorbell must reject, Paper.MD 2.9), ~5%
// pass-through, backpressure 1-in-{1,2,4,8} per node DMA.
func ScenarioStress(layers, bx, by int, seed int64, flits int) *Program {
	nodes := AllNodes(layers, bx, by)
	rng := NewPyRand(uint64(seed))
	if flits == 0 {
		flits = min(24*len(nodes), 3000)
	}
	p := NewProgram("stress", nodes, "bounded")
	for _, n := range nodes {
		p.ProgramNode(n, KERNEL_MIX[rng.ChoiceInt(len(KERNEL_MIX))],
			randBytesInt(rng, 1024), rng.RandRange(1, 16))
		p.BP[n] = []int{1, 2, 4, 8}[rng.ChoiceInt(4)]
	}
	for i := 0; i < flits; i++ {
		r := rng.random()
		if r < 0.05 {
			plen := rng.RandInt(2, 32)
			p.InjectPassthrough(randBytes(rng, plen))
			continue
		}
		n := nodes[rng.ChoiceInt(len(nodes))]
		s := rng.random()
		var plen int
		if s < 0.60 {
			plen = rng.RandInt(4, 32)
		} else if s < 0.90 {
			plen = rng.RandInt(33, 256)
		} else {
			plen = 1024 // kilobyte-class token (2.12)
		}
		payload := randBytes(rng, plen)
		corrupt := rng.random() < 0.03
		p.InjectRouted(n, CTRL_COMPUTE_SPINE|((i&0x0F)&^1), payload, corrupt)
	}
	return p
}

func randBytes(rng *PyRand, n int) []byte {
	b := make([]byte, n)
	for i := range b {
		b[i] = byte(rng.RandRange(0, 256))
	}
	return b
}

func randBytesInt(rng *PyRand, n int) []int {
	b := make([]int, n)
	for i := range b {
		b[i] = rng.RandRange(0, 256)
	}
	return b
}

// -- delivery.log parsing ----------------------------------------------------

// Entry4 is one cycle-stamped record: (cyc, d, s, e[, vc]).
type Entry4 struct {
	Cyc int
	D   int
	S   int
	E   int
	Vc  int
}

// Delivery reconstructs what the fabric delivered, with cycle stamps.
type Delivery struct {
	Inject  []Entry4
	Tail    []Entry4
	TailUp  []Entry4
	Nodes   map[NodeID][]Entry4
	XRes    map[int][]Entry4
	YRes    map[LXPair][]Entry4
	Corrupt map[NodeID][]int
}

// ParseDelivery mirrors parse_delivery().
func ParseDelivery(path string) *Delivery {
	d := &Delivery{
		Nodes:   map[NodeID][]Entry4{},
		XRes:    map[int][]Entry4{},
		YRes:    map[LXPair][]Entry4{},
		Corrupt: map[NodeID][]int{},
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return d
	}
	for _, line := range strings.Split(strings.ToValidUTF8(string(data), ""), "\n") {
		f := strings.Fields(line)
		if len(f) == 0 {
			continue
		}
		e4 := func(v []string) Entry4 {
			if len(v) < 5 {
				return Entry4{}
			}
			e := Entry4{atoi(v[1]), atoi(v[2]), atoi(v[3]), atoi(v[4]), 0}
			if len(v) > 5 {
				e.Vc = atoi(v[5])
			}
			return e
		}
		switch f[0] {
		case "I": // I cyc d s e vc
			d.Inject = append(d.Inject, e4(f))
		case "T": // T cyc d s e vc
			d.Tail = append(d.Tail, e4(f))
		case "U": // U cyc d s e vc (spine root result egress)
			d.TailUp = append(d.TailUp, e4(f))
		case "C": // C cyc l x y (MAC stub verdict)
			if len(f) < 5 {
				continue
			}
			n := NodeID{L: atoi(f[2]), X: atoi(f[3]), Y: atoi(f[4])}
			d.Corrupt[n] = append(d.Corrupt[n], atoi(f[1]))
		case "X": // X cyc l d s e
			if len(f) < 6 {
				continue
			}
			k := atoi(f[2])
			d.XRes[k] = append(d.XRes[k], Entry4{atoi(f[1]), atoi(f[3]), atoi(f[4]), atoi(f[5]), 0})
		case "Y": // Y cyc l x d s e
			if len(f) < 7 {
				continue
			}
			k := LXPair{L: atoi(f[2]), X: atoi(f[3])}
			d.YRes[k] = append(d.YRes[k], Entry4{atoi(f[1]), atoi(f[4]), atoi(f[5]), atoi(f[6]), 0})
		case "N": // N cyc l x y d s e vc
			if len(f) < 9 {
				continue // tolerate stale pre-VC logs
			}
			n := NodeID{L: atoi(f[2]), X: atoi(f[3]), Y: atoi(f[4])}
			d.Nodes[n] = append(d.Nodes[n], Entry4{atoi(f[1]), atoi(f[5]), atoi(f[6]), atoi(f[7]), atoi(f[8])})
		}
	}
	return d
}

func atoi(s string) int {
	v, _ := strconv.Atoi(s)
	return v
}

// PktDelivered is one packet grouped from a (cyc, data, sop, eop) stream.
type PktDelivered struct {
	Bytes  []byte
	SopCyc int
	EopCyc int
}

// Packetize groups a (cyc, data, sop, eop) stream into packets with timing.
func Packetize(stream []Entry4) []PktDelivered {
	var pkts []PktDelivered
	var cur []byte
	sopCyc := -1
	for _, e := range stream {
		if e.S != 0 {
			cur = nil
			sopCyc = e.Cyc
		}
		cur = append(cur, byte(e.D))
		if e.E != 0 {
			pkts = append(pkts, PktDelivered{Bytes: append([]byte(nil), cur...), SopCyc: sopCyc, EopCyc: e.Cyc})
		}
	}
	return pkts
}

// InjectRec is one injection record: pkt idx -> {sop_cyc, eop_cyc, len}.
type InjectRec struct {
	SopCyc int
	EopCyc int
	Len    int
}

// InjectTable builds the indexed injection record from the I stream.
func InjectTable(stream []Entry4) []InjectRec {
	var tbl []InjectRec
	sopCyc, length := -1, 0
	for _, e := range stream {
		if e.S != 0 {
			sopCyc, length = e.Cyc, 0
		}
		length++
		if e.E != 0 {
			tbl = append(tbl, InjectRec{SopCyc: sopCyc, EopCyc: e.Cyc, Len: length})
		}
	}
	return tbl
}

// Stats aggregates verification counters across slices.
type Stats struct {
	Activations int
	Rejections  int
	Latencies   []int
	Pkts        int
	DmaBytes    int
}

func (s *Stats) add(o *Stats) {
	s.Activations += o.Activations
	s.Rejections += o.Rejections
	s.Latencies = append(s.Latencies, o.Latencies...)
	s.Pkts += o.Pkts
	s.DmaBytes += o.DmaBytes
}

// Verify checks hardware delivery against the manifest; runs the doorbells.
//
// lBase: global id of this fabric slice's first layer. Hops on spine stages
// upstream of the slice are transparent pass-through, so latency checks use
// l_eff = l - lBase (Paper.MD 2.5: hop count x per-hop delay is a
// compile-time sum over segments).
//
// expectTail: only the slice owning the chassis tail (last layer group)
// expects pass-through traffic; all other slices must see none.
//
// expectRoot: only the slice owning global layer 0 has the physical
// chassis root egress (tail_up); other slices' tail_up is a dead-end
// that must stay empty.
//
// Returns (errors, stats).
func Verify(delivered *Delivery, prog *Program, nodes []NodeID, lBase int, expectTail, expectRoot bool) ([]string, *Stats) {
	var errors []string
	stats := &Stats{}
	inj := InjectTable(delivered.Inject)

	// injection <-> manifest agreement (this slice's routed + pass-through)
	nRouted := 0
	for _, n := range nodes {
		nRouted += len(prog.Manifest[n].Packets)
	}
	nTail := 0
	if expectTail {
		nTail = len(prog.Tail)
	}
	if len(inj) != nRouted+nTail {
		errors = append(errors, fmt.Sprintf("inject: %d packets on wire, manifest says %d", len(inj), nRouted+nTail))
	}

	// virtual-channel sideband: spine descent must carry class 2 (paper §4.3).
	// vcsweep mixes origin classes, so its own scenario-level checks cover it.
	if !prog.MixedVC {
		for _, e := range delivered.Inject {
			if e.Vc != VC_SPINE_DESCENT {
				errors = append(errors, fmt.Sprintf("inject: byte on vc %d, expected class %d (spine descent)", e.Vc, VC_SPINE_DESCENT))
				break
			}
		}
	}

	// byte conservation: every injected byte delivered exactly once or
	// stripped as a source-routing header byte (LAYER at the xyz_repeater --
	// the MODULE_ID is forwarded to the DMA as the CRC-protected DEST field,
	// so exactly 1 byte per routed packet is stripped)
	totalDelivered := 0
	for _, v := range delivered.Nodes {
		totalDelivered += len(v)
	}
	totalDelivered += len(delivered.Tail)
	totalDelivered += len(delivered.TailUp)
	for _, v := range delivered.XRes {
		totalDelivered += len(v)
	}
	for _, v := range delivered.YRes {
		totalDelivered += len(v)
	}
	// result echoes are generated in-fabric by the node MAC, so they add
	// one flit (len(wire) bytes) to both the injected and delivered sides
	if len(delivered.Inject)+len(delivered.TailUp) != totalDelivered+1*nRouted {
		errors = append(errors, fmt.Sprintf("byte conservation: %d injected + %d echoes, %d delivered + %d stripped",
			len(delivered.Inject), len(delivered.TailUp), totalDelivered, 1*nRouted))
	}

	// per-node: byte-exact delivery, then doorbell + resident kernel
	for _, n := range nodes {
		m := prog.Manifest[n]
		got := Packetize(delivered.Nodes[n])
		want := m.Packets
		// every byte landed on the node DMA port must carry class 3
		// (on-board delivery, the 2->3 transition at the repeater)
		for _, e := range delivered.Nodes[n] {
			if e.Vc != VC_ONBOARD_DELIVER {
				errors = append(errors, fmt.Sprintf("%s: byte landed on vc %d, expected class %d (on-board)", n, e.Vc, VC_ONBOARD_DELIVER))
				break
			}
		}
		// the node DMA sees the stub's output: bias-transformed payload,
		// CRC re-emitted over the transformed body (K=0 is a no-op)
		if !bytesEqualBytes(got, want, m.Bias) {
			errors = append(errors, fmt.Sprintf("%s: byte-exact delivery mismatch (%d pkts delivered, %d expected)",
				n, len(got), len(want)))
			continue
		}

		u := NewVirtualUnit(n, m.Kernel, m.Weights)
		hwCorrupt := delivered.Corrupt[n]
		corruptPktIdx := map[int]bool{}
		for i, w := range want {
			if w.Corrupt {
				corruptPktIdx[i] = true
			}
		}
		for i, g := range got {
			// corrupt packets must be refused: the hardware doorbell verdict
			// (pe_tile_stub corrupt_out) is the refusal of record, so the
			// software unit records it even though the stub re-emitted a
			// CRC-consistent (transformed) stream for accounting
			u.Consume(g.Bytes, corruptPktIdx[i])
		}
		stats.Activations += u.Activations
		stats.Rejections += u.Rejections
		stats.Pkts += len(want)
		for _, w := range want {
			stats.DmaBytes += len(w.DMA)
		}

		// doorbell accounting: corrupt messages rejected, good ones fired.
		// The hardware CRC verdict (stub corrupt_out) must flag exactly the
		// corrupt messages, cross-checking the stub's in-silicon CRC engine.
		nCorrupt := 0
		for _, w := range want {
			if w.Corrupt {
				nCorrupt++
			}
		}
		if len(hwCorrupt) != nCorrupt {
			errors = append(errors, fmt.Sprintf("%s: MAC stub flagged %d corrupt messages, manifest says %d",
				n, len(hwCorrupt), nCorrupt))
		}
		if u.Rejections != nCorrupt {
			reasons := u.RejectReasons
			if len(reasons) > 2 {
				reasons = reasons[:2]
			}
			errors = append(errors, fmt.Sprintf("%s: doorbell rejected %d, expected %d (%s)",
				n, u.Rejections, nCorrupt, pyStrList(reasons)))
		}
		if u.Activations != len(want)-nCorrupt {
			errors = append(errors, fmt.Sprintf("%s: %d activations, expected %d",
				n, u.Activations, len(want)-nCorrupt))
		}

		// resident kernel executed correctly on hardware-delivered data
		var goldenSeq []interface{}
		for _, w := range want {
			if !w.Corrupt {
				goldenSeq = append(goldenSeq, w.Golden)
			}
		}
		if !reflect.DeepEqual(u.Results, goldenSeq) {
			errors = append(errors, fmt.Sprintf("%s: kernel '%s' results mismatch (%d vs %d)",
				n, m.Kernel, len(u.Results), len(goldenSeq)))
		}

		// per-packet latency against the closed form (Paper.MD 2.5/3.4)
		l, x := n.L, n.X
		lEff := l - lBase // spine hops inside this slice
		for i, w := range want {
			g := got[i]
			if w.Sidx == nil {
				errors = append(errors, fmt.Sprintf("%s: slice inject idx None out of table", n))
				continue
			}
			if *w.Sidx < 0 || *w.Sidx >= len(inj) {
				errors = append(errors, fmt.Sprintf("%s: slice inject idx %d out of range (table has %d)",
					n, *w.Sidx, len(inj)))
				continue
			}
			t := inj[*w.Sidx]
			lat := g.EopCyc - t.SopCyc
			stats.Latencies = append(stats.Latencies, lat)
			if prog.Latency == "exact" {
				// idle fabric: wire_len-1 stages + l_eff spine + x X-hops
				// + the node MAC pipe (PE_PIPE_DELAY)
				expect := w.WireLen - 1 + lEff + x + PE_PIPE_DELAY
				if lat != expect {
					errors = append(errors, fmt.Sprintf("%s: latency %d != closed form %d", n, lat, expect))
				}
			} else {
				// cannot beat the pipe: last wire byte needs l_eff+x HFR hops
				// + the node MAC pipe
				lower := (t.EopCyc - t.SopCyc) + lEff + x + PE_PIPE_DELAY
				if lat < lower {
					errors = append(errors, fmt.Sprintf("%s: latency %d < pipe floor %d", n, lat, lower))
				}
			}
		}
	}

	// residual lanes must carry nothing (no misroutes)
	for k, v := range delivered.XRes {
		if len(v) > 0 {
			errors = append(errors, fmt.Sprintf("xres_%d: carried %d misrouted bytes", k, len(v)))
		}
	}
	for k, v := range delivered.YRes {
		if len(v) > 0 {
			errors = append(errors, fmt.Sprintf("yres_(%d, %d): carried %d misrouted bytes", k.L, k.X, len(v)))
		}
	}

	// spine tail: only the slice owning the chassis tail carries
	// pass-through traffic, and it must match byte-exactly with the
	// origin class riding each packet (VC isolation: class-3 flits never
	// eject, they pass to the tail unchanged)
	tailPkts := Packetize(delivered.Tail)
	if expectTail {
		if !tailBytesEqual(tailPkts, prog.Tail) {
			errors = append(errors, fmt.Sprintf("tail: %d pkts delivered, %d expected (or content mismatch)",
				len(tailPkts), len(prog.Tail)))
		}
		tailVcs := packetVcs(delivered.Tail)
		for i := range tailPkts {
			if i < len(tailVcs) && tailVcs[i] != int(prog.Tail[i].Vc) {
				errors = append(errors, fmt.Sprintf("tail pkt %d: vc %d, expected origin class %d",
					i, tailVcs[i], prog.Tail[i].Vc))
			}
		}
	} else if len(tailPkts) > 0 {
		errors = append(errors, fmt.Sprintf("tail: slice carried %d unexpected pass-through pkts (stream split bug?)",
			len(tailPkts)))
	}

	// spine root egress: the result echoes of this slice's return-flag
	// requests (paper §2.9), byte-exact against the golden echo flits and
	// all riding class 1 (spine ascent, the 0->1 transition at the repeater).
	// Only the slice owning global layer 0 has the real chassis root;
	// other slices' tail_up is a physical dead-end that must stay empty.
	upPkts := Packetize(delivered.TailUp)
	if !expectRoot {
		if len(upPkts) > 0 {
			errors = append(errors, fmt.Sprintf("root egress: non-root slice carried %d echo flits (dead-end must stay empty)", len(upPkts)))
		}
		return errors, stats
	}
	for _, e := range delivered.TailUp {
		if e.Vc != VC_SPINE_ASCENT {
			errors = append(errors, fmt.Sprintf("root egress: byte on vc %d, expected class %d (spine ascent)", e.Vc, VC_SPINE_ASCENT))
			break
		}
	}
	var wantEchoes [][]byte
	for _, n := range nodes {
		for _, w := range prog.Manifest[n].Packets {
			if w.Echo != nil {
				wantEchoes = append(wantEchoes, w.Echo)
			}
		}
	}
	if len(upPkts) != len(wantEchoes) {
		errors = append(errors, fmt.Sprintf("root egress: %d echo flits delivered, %d expected", len(upPkts), len(wantEchoes)))
	} else {
		used := make([]bool, len(wantEchoes))
		for i, u := range upPkts {
			matched := -1
			for j, w := range wantEchoes {
				if !used[j] && bytes.Equal(u.Bytes, w) {
					matched = j
					break
				}
			}
			if matched < 0 {
				errors = append(errors, fmt.Sprintf("root egress pkt %d: no golden echo matches (%d bytes)", i, len(u.Bytes)))
				break
			}
			used[matched] = true
		}
	}

	return errors, stats
}

func bytesEqualBytes(got []PktDelivered, want []*PacketEntry, bias int) bool {
	if len(got) != len(want) {
		return false
	}
	for i := range got {
		if !bytes.Equal(got[i].Bytes, StubOutput(want[i].DMA, bias)) {
			return false
		}
	}
	return true
}

func tailBytesEqual(tailPkts []PktDelivered, want []*PacketEntry) bool {
	if len(tailPkts) != len(want) {
		return false
	}
	for i := range tailPkts {
		if !bytes.Equal(tailPkts[i].Bytes, want[i].Wire) {
			return false
		}
	}
	return true
}

// packetVcs groups a (data, sop, eop, vc) stream into the per-packet VC
// class (the class of the packet's head byte — the fabric never re-tags a
// packet mid-flight).
func packetVcs(stream []Entry4) []int {
	var out []int
	for _, e := range stream {
		if e.S != 0 {
			out = append(out, e.Vc)
		}
	}
	return out
}

// SpanCycles returns (first inject cycle, last activity cycle) across all ports.
func SpanCycles(delivered *Delivery) (int, int) {
	first := int(^uint(0) >> 1)
	for _, e := range delivered.Inject {
		if e.Cyc < first {
			first = e.Cyc
		}
	}
	last := 0
	streams := [][]Entry4{delivered.Tail, delivered.Inject}
	for _, v := range delivered.Nodes {
		streams = append(streams, v)
	}
	for _, v := range delivered.XRes {
		streams = append(streams, v)
	}
	for _, v := range delivered.YRes {
		streams = append(streams, v)
	}
	for _, v := range streams {
		for _, e := range v {
			if e.Cyc > last {
				last = e.Cyc
			}
		}
	}
	return first, last
}

// -- build / run (parallel layer-group slices) -------------------------------
//
// vvp is single-threaded. The chassis is therefore partitioned into
// contiguous layer groups; each group gets its own pnm_top slice, stimulus
// (the packets destined to its layers, in original relative order;
// pass-through traffic goes to the last group, which owns the chassis tail)
// and its own vvp process. Groups run concurrently, one vvp per CPU core.
//
// This is functionally exact for this fabric: spine stages upstream of the
// destination layer are transparent pass-through (they contribute fixed
// hops, never reorder or alter bytes), so every node receives the same bytes
// in the same order as in a monolithic simulation. What is NOT modeled is
// cross-group spine contention coupling (a slow board in one group stalling
// traffic bound for another group) — a compile-time scheduler concern
// (Paper.MD 2.8), not a gate-level correctness property.
//
// Latency checks remain physical per slice: l_eff = l - group_base (see
// Verify()); the global closed form is the compile-time sum of slice forms.

// PartitionLayers returns contiguous layer-id ranges, as equal as possible.
func PartitionLayers(layers, groups int) [][]int {
	groups = max(1, min(groups, layers))
	base, rem := layers/groups, layers%groups
	var out [][]int
	start := 0
	for g := 0; g < groups; g++ {
		n := base
		if g < rem {
			n++
		}
		lids := make([]int, n)
		for i := range lids {
			lids[i] = start + i
		}
		out = append(out, lids)
		start += n
	}
	return out
}

// GroupNames is the per-slice file-name set (mirrors group_names()).
type GroupNames struct {
	Top  string
	TB   string
	Stim string
	Log  string
	Out  string
}

func GroupNamesFor(gi, groups int) GroupNames {
	if groups == 1 {
		return GroupNames{Top: "pnm_top.v", TB: "tb_pnm.v", Stim: "stimulus.hex",
			Log: "delivery.log", Out: "tb_pnm.out"}
	}
	return GroupNames{Top: fmt.Sprintf("pnm_top_g%d.v", gi), TB: fmt.Sprintf("tb_pnm_g%d.v", gi),
		Stim: fmt.Sprintf("stimulus_g%d.hex", gi), Log: fmt.Sprintf("delivery_g%d.log", gi),
		Out: fmt.Sprintf("tb_pnm_g%d.out", gi)}
}

type job struct {
	GI   int
	Lids []int
	Nm   GroupNames
	NB   int
}

// RunOne generates per-slice inputs, simulates slices in parallel, verifies.
func RunOne(prog *Program, nodes []NodeID, dims Dims, groups, replays int) bool {
	layers, bx, by := dims.Layers, dims.Bx, dims.By
	layerGroups := PartitionLayers(layers, groups)
	simDir := SimDir()
	hdlDir, err := filepath.Abs(filepath.Join(simDir, "..", "HDL"))
	if err != nil {
		fmt.Printf("  HDL path resolution failed: %v\n", err)
		return false
	}

	// -- per-slice stimulus, topology, testbench -------------------------
	var jobs []*job
	for gi, lids := range layerGroups {
		nm := GroupNamesFor(gi, len(layerGroups))
		var stream []StreamByte
		sidx := 0 // injection index within this slice
		for _, oe := range prog.Order {
			if oe.IsPT {
				if gi == len(layerGroups)-1 { // chassis tail owner
					stream = append(stream, oe.WF...)
					s := sidx
					oe.Ref.Sidx = &s
					sidx++
				}
			} else if containsInt(lids, oe.Key) {
				stream = append(stream, oe.WF...)
				s := sidx
				oe.Ref.Sidx = &s
				sidx++
			}
		}
		nbytes := WriteStimulus(stream, filepath.Join(simDir, nm.Stim))
		gnodes := AllNodesIn(lids, bx, by)
		biases := map[NodeID]int{}
		for _, n := range gnodes {
			biases[n] = prog.Manifest[n].Bias
		}
		if err := os.WriteFile(filepath.Join(simDir, nm.Top), []byte(GenTopology(lids, bx, by, biases, false)), 0o644); err != nil {
			panic("GenTopology: " + err.Error())
		}
		if err := os.WriteFile(filepath.Join(simDir, nm.TB), []byte(GenTB(lids, bx, by, prog.BP, nbytes, nm.Stim, nm.Log)), 0o644); err != nil {
			panic("GenTB: " + err.Error())
		}
		jobs = append(jobs, &job{GI: gi, Lids: lids, Nm: nm, NB: nbytes})
	}

	// -- compile (parallel: one iverilog per slice, all at once) --------
	for _, j := range jobs {
		srcs := []string{j.Nm.TB, j.Nm.Top}
		for _, f := range FABRIC {
			srcs = append(srcs, filepath.Join(hdlDir, f))
		}
		args := []string{"-g2005", "-I" + hdlDir, "-s", "tb_pnm", "-o", j.Nm.Out}
		args = append(args, srcs...)
		cmd := exec.Command("iverilog", args...)
		cmd.Dir = simDir
		var stderr bytes.Buffer
		cmd.Stderr = &stderr
		if err := cmd.Run(); err != nil {
			e := stderr.String()
			if len(e) > 2000 {
				e = e[len(e)-2000:]
			}
			fmt.Printf("  group %d: iverilog failed:\n%s", j.GI, e)
			return false
		}
	}

	// -- simulate: one vvp process per slice, concurrently ----------------
	ok := true
	var logsPrev [][]byte
	for repl := 0; repl < replays; repl++ {
		procs := make([]*exec.Cmd, len(jobs))
		for i, j := range jobs {
			cmd := exec.Command("vvp", j.Nm.Out)
			cmd.Dir = simDir
			if err := cmd.Start(); err != nil {
				fmt.Printf("  group %d: vvp exited nonzero\n", j.GI)
				ok = false
				continue
			}
			procs[i] = cmd
		}
		for i, j := range jobs {
			if procs[i] == nil {
				continue
			}
			if err := procs[i].Wait(); err != nil {
				fmt.Printf("  group %d: vvp exited nonzero\n", j.GI)
				ok = false
			}
		}
		logs := make([][]byte, len(jobs))
		for i, j := range jobs {
			logs[i], _ = os.ReadFile(filepath.Join(simDir, j.Nm.Log))
		}
		if logsPrev != nil && !byteSlicesEqual(logs, logsPrev) {
			fmt.Println("  FAIL: replay divergence -- delivery logs differ between identical runs (determinism violated)")
			ok = false
		}
		logsPrev = logs
	}
	if replays == 2 && ok {
		n := 0
		for _, b := range logsPrev {
			n += len(b)
		}
		fmt.Printf("  replay: %d slice log(s) bit-identical across 2 runs (%d bytes)\n", len(jobs), n)
	}
	if !ok {
		return false
	}

	// -- verify per slice, aggregate --------------------------------------
	var allErrors []string
	stats := &Stats{}
	maxSpan := 1
	for _, j := range jobs {
		lids := j.Lids
		gnodes := AllNodesIn(lids, bx, by)
		delivered := ParseDelivery(filepath.Join(simDir, j.Nm.Log))
		errors, st := Verify(delivered, prog, gnodes, lids[0], j.GI == len(jobs)-1, lids[0] == 0)
		for _, e := range errors {
			allErrors = append(allErrors, fmt.Sprintf("[g%d] %s", j.GI, e))
		}
		stats.add(st)
		if j.NB > 0 {
			first, last := SpanCycles(delivered)
			if last-first > maxSpan {
				maxSpan = last - first
			}
		}
		if len(jobs) > 1 {
			fmt.Printf("  slice g%d: layers %d..%d, %d wire bytes\n", j.GI, lids[0], lids[len(lids)-1], j.NB)
		}
	}

	latS := "n/a"
	if len(stats.Latencies) > 0 {
		lo, hi, sum := stats.Latencies[0], stats.Latencies[0], 0
		for _, v := range stats.Latencies {
			if v < lo {
				lo = v
			}
			if v > hi {
				hi = v
			}
			sum += v
		}
		latS = fmt.Sprintf("min/mean/max %d/%d/%d cyc", lo, sum/len(stats.Latencies), hi)
	}
	fmt.Printf("  fabric: %d slice(s) in parallel, worst span %d cycles, %.2f wire bytes/cycle sustained\n",
		len(jobs), maxSpan, float64(len(prog.Stream))/float64(maxSpan))
	fmt.Printf("  nodes: %d doorbell activations, %d corrupt rejected, %d packets, %d DMA bytes\n",
		stats.Activations, stats.Rejections, stats.Pkts, stats.DmaBytes)
	fmt.Printf("  latency: %s\n", latS)

	if len(allErrors) > 0 {
		fmt.Printf("  FAIL (%d problems):\n", len(allErrors))
		n := len(allErrors)
		if n > 12 {
			n = 12
		}
		for _, e := range allErrors[:n] {
			fmt.Printf("    - %s\n", e)
		}
		return false
	}
	fmt.Println("  PASS: byte-exact delivery, kernels correct, zero drops, zero misroutes")
	return true
}

func containsInt(s []int, v int) bool {
	for _, x := range s {
		if x == v {
			return true
		}
	}
	return false
}

func byteSlicesEqual(a, b [][]byte) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if !bytes.Equal(a[i], b[i]) {
			return false
		}
	}
	return true
}

// pyStrList formats a string slice like Python's repr: "['a', 'b']".
func pyStrList(s []string) string {
	parts := make([]string, len(s))
	for i, v := range s {
		parts[i] = "'" + v + "'"
	}
	return "[" + strings.Join(parts, ", ") + "]"
}

// RunMain is the pnm harness entry point (formerly sim/run.py main()).
func RunMain(layers, bx, by int, scenarios []string, seed int64, flits *int, hotFrac float64, groups int) int {
	dims := Dims{Layers: layers, Bx: bx, By: by}
	nodes := AllNodes(layers, bx, by)
	if groups == 0 {
		groups = min(layers, runtime.NumCPU())
	}
	simDir := SimDir()
	if err := os.Chdir(simDir); err != nil {
		fmt.Fprintf(os.Stderr, "chdir %s: %v\n", simDir, err)
		return 1
	}

	params := "# AUTO-GENERATED by sim/internal/pnm/run.go -- do not edit by hand.\n" +
		fmt.Sprintf("LAYERS = %d\nBOARD_X = %d\nBOARD_Y = %d\nNODES = %d\nGROUPS = %d\n",
			layers, bx, by, layers*bx*by, groups)
	if err := os.WriteFile("pnm_top_params.py", []byte(params), 0o644); err != nil {
		panic("WriteParams: " + err.Error())
	}

	totalFail := 0
	for _, name := range scenarios {
		var prog *Program
		switch name {
		case "sweep":
			prog = ScenarioSweep(layers, bx, by, seed)
		case "vcsweep":
			prog = ScenarioVCSweep(layers, bx, by, seed)
		case "load":
			f := 500
			if flits != nil && *flits != 0 {
				f = *flits
			}
			prog = ScenarioLoad(layers, bx, by, seed, f)
		case "hotspot":
			f := 400
			if flits != nil && *flits != 0 {
				f = *flits
			}
			prog = ScenarioHotspot(layers, bx, by, seed, f, hotFrac)
		case "stress":
			var f int
			if flits != nil {
				f = *flits
			}
			prog = ScenarioStress(layers, bx, by, seed, f)
		case "replay":
			f := 300
			if flits != nil && *flits != 0 {
				f = *flits
			}
			prog = ScenarioStress(layers, bx, by, seed, f)
		default:
			fmt.Printf("unknown scenario: %s\n", name)
			return 2
		}
		nRouted := 0
		for _, m := range prog.Manifest {
			nRouted += len(m.Packets)
		}
		fmt.Printf("\n=== scenario '%s': %d routed + %d pass-through flits, %d wire bytes, %dx%dx%d = %d nodes, %d slice(s) ===\n",
			name, nRouted, len(prog.Tail), len(prog.Stream), layers, bx, by, len(nodes), groups)
		replays := 1
		if name == "replay" {
			replays = 2
		}
		if !RunOne(prog, nodes, dims, groups, replays) {
			totalFail++
		}
	}

	if totalFail == 0 {
		fmt.Println("\nALL SCENARIOS PASSED")
		return 0
	}
	fmt.Printf("\n%d SCENARIO(S) FAILED\n", totalFail)
	return 1
}
