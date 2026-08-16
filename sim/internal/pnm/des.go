package pnm

// des.go — a discrete-event simulation of the PNM fabric, cycle-exact against
// the gate-level model (gen_topology.v + the HDL modules) and used for
// virtual-channel sweeps and latency studies that would be too slow in vvp
// (paper §4.3 VC isolation, §2.5 closed-form latency).
//
// Model. The fabric is a pipeline network: pipe REGISTERS (the HFRs, the PE
// MAC pipe, the up-spine HFRs) separated by COMBINATIONAL gate clouds (the
// xyz_repeater demux+strip, xy_turn, node_eject, and the vc_merge
// arbitration trees). A byte occupying a register is presented to its gate
// cloud every cycle; the cloud routes it to the next register, which latches
// it at the next cycle. This reproduces the closed-form latency exactly:
// wire_len-1 body bytes + l spine hops + x X-lane hops + PE_PIPE_DELAY.
//
// Scheduling. The engine is activity-driven: a min-heap of (cycle, register)
// events. tryMove(reg, c) processes the register's occupying byte at cycle c,
// recursing downstream along the ready chain (a register accepts when it is
// empty or its own byte moves) and upstream along the wormhole (when a byte
// moves, the upstream register's byte latches into its slot at the same
// posedge). Rejects reschedule at c+1 — the backpressure stall. All posedge
// effects (register latches, flit_gate strip_next_q clears, vc_merge state
// transitions) are DEFERRED and applied at the cycle boundary, so every
// event of cycle c sees the same pre-posedge combinational state, exactly
// like the RTL. Merges are 0-delay combinational arbiters holding
// per-packet grant state (round-robin), so their state updates only at
// acceptance boundaries.
//
// Cycle convention. DES cycle c is the interval after posedge c before
// posedge c+1: a register "holds" its byte during cycle c and the cloud
// latches the next register at posedge c (arrived at c+1). The first
// injection is accepted at cycle 0; the RTL delivery-log cycles are offset
// by the tb's reset sequence (CrossCheckDES calibrates from the first I
// record, exactly as the harness's latency closed form is measured on RTL
// cycles). The node-DMA duty backpressure is modeled as ready(c) = c % d ==
// 0 in DES cycles; scenarios that cross-check the RTL use d = 1 (no
// backpressure), where the two timelines coincide.

import (
	"container/heap"
	"fmt"
)

// ---------------------------------------------------------------------------
// event queue

type desEvt struct {
	c   int
	reg int
}

type desHeap []desEvt

func (h desHeap) Len() int            { return len(h) }
func (h desHeap) Less(i, j int) bool  { return h[i].c < h[j].c }
func (h desHeap) Swap(i, j int)       { h[i], h[j] = h[j], h[i] }
func (h *desHeap) Push(x interface{}) { *h = append(*h, x.(desEvt)) }
func (h *desHeap) Pop() interface{} {
	old := *h
	n := len(old)
	e := old[n-1]
	*h = old[:n-1]
	return e
}

// ---------------------------------------------------------------------------
// merge arbitration state (vc_merge.v: state_q = IDLE/A/B, pri_q round-robin)

const (
	mergeIdle = iota
	mergeA
	mergeB
)

type mergeKind int

const (
	mkYm mergeKind = iota // Y-up column chain: a = txe[y] / ym(k-1), b = txe[y+1]
	mkXm                  // X-up row chain:   a = colWire[k] / xm(k-1), b = colWire[k+1]
	mkUp                  // repeater upmerge: a = nobu chain, b = spup_in (up HFR or tie-off)
)

type desMerge struct {
	st, pri  int
	kind     mergeKind
	li, x, k int
}

type mergeUpd struct {
	mid     int
	st, pri int
}

// ---------------------------------------------------------------------------
// registers

type regKind int

const (
	rkInj      regKind = iota // spine injector (source register)
	rkSpineHFR                // down-spine HFR:      (li, -1, -2)
	rkUpHFR                   // up-spine HFR:        (li, -1, -1), li < nl-1
	rkXHFR                    // X-lane HFR:          (li,  x, -1), x < bx-1
	rkPE0                     // node MAC pipe stage 0 (li, x, y)
	rkPE1                     // node MAC pipe stage 1 (li, x, y)
	rkTXE                     // result-egress emitter (source register, li, x, y)
	rkTail                    // spine tail sink
	rkTailUp                  // spine root egress sink
	rkXres                    // X-lane residual sink (li, -1, -1)
	rkYres                    // Y-lane residual sink (li, x, -1)
)

type desReg struct {
	kind     regKind
	li, x, y int
	occ      *desByte // byte presented during the current cycle (pre-posedge)
	arrived  int      // cycle occ became visible
	pending  *desByte // byte to hold from the next cycle (posedge latch)
	pendSet  bool
	decAt    int // memo: cycle this register's fate was decided
	decided  bool
}

type desPkt struct {
	li, x, y  int // slice-local destination (li = index in lids)
	pt        bool
	delivered []byte // stub output seen by the node DMA (nodes); nil for pass-through
	echo      []byte // golden result-egress flit (return-flag requests)
	corrupt   bool
	wireLen   int
	dmaLen    int
}

type desByte struct {
	data byte
	sop  bool // spine-wire sop (the segment the byte currently rides)
	bsop bool // on-board sop: set by the strip at the xyz_repeater (NoB head)
	eop  bool
	vc   byte
	pkt  *desPkt
	dma  int // index in the DMA stream (0 = MODULE_ID); -1 pre-strip / pass-through
}

// ---------------------------------------------------------------------------
// the model

type desModel struct {
	lids []int
	nl   int
	bx   int
	by   int
	bp   map[NodeID]int

	stim  []StreamByte
	pktAt []*desPkt // pktAt[i] = packet of stimulus byte i
	dmaAt []int     // dmaAt[i] = dma index of stimulus byte i (-1 pre-strip)
	pos   int

	regs []desReg

	inj    int
	sp     []int // down-spine HFR output registers
	xh     [][]int
	pe0    [][][]int
	pe1    [][][]int
	txe    [][][]int
	up     []int // up-spine HFR registers: up[li] feeds rpt(li).spup_in (li < nl-1)
	tail   int
	tailUp int
	xresID []int
	yresID [][]int

	merges []desMerge
	ymID   [][][]int
	xmID   [][]int
	upID   []int
	pmerge []mergeUpd

	// per-repeater / per-gate decision state (flit_gate route_match_q,
	// strip_next_q). rptStrip clears are deferred to the cycle boundary.
	rptMatch   []bool
	rptStrip   []bool
	stripClear []int
	turnMatch  [][]bool
	ejectMatch [][][]bool

	echoStart map[NodeID]int
	busyEnd   map[NodeID]int

	evq desHeap
	now int

	out *Delivery
}

func (m *desModel) sched(c, reg int) { heap.Push(&m.evq, desEvt{c: c, reg: reg}) }

func (m *desModel) regAt(id int) *desReg {
	if id < 0 || id >= len(m.regs) {
		return nil
	}
	return &m.regs[id]
}

func (m *desModel) regID(r *desReg) int {
	for i := range m.regs {
		if &m.regs[i] == r {
			return i
		}
	}
	return -1
}

func (m *desModel) addReg(kind regKind, li, x, y int) int {
	m.regs = append(m.regs, desReg{kind: kind, li: li, x: x, y: y, decAt: -1, arrived: -1})
	return len(m.regs) - 1
}

func (m *desModel) addMerge(kind mergeKind, li, x, k int) int {
	m.merges = append(m.merges, desMerge{kind: kind, li: li, x: x, k: k})
	return len(m.merges) - 1
}

func (m *desModel) nodeDuty(n NodeID) int {
	if d, ok := m.bp[n]; ok && d > 0 {
		return d
	}
	return 1
}

// echoBusy reports whether the node's MAC pipe is frozen by an in-flight TX
// echo (pe_tile_stub tx_emit_q): the freeze spans the echo's emission cycles
// and ends the cycle after its last byte is accepted.
func (m *desModel) echoBusy(n NodeID, c int) bool {
	return m.echoStart[n] >= 0 && c >= m.echoStart[n] && c < m.busyEnd[n]
}

// NoBsource returns the register whose byte feeds repeater li's NoB port.
func (m *desModel) NoBsource(li int) int {
	if li == 0 {
		return m.inj
	}
	return m.sp[li-1]
}

// ---------------------------------------------------------------------------
// construction

func newDES(lids []int, bx, by int, bp map[NodeID]int, stim []StreamByte, pktAt []*desPkt, dmaAt []int) *desModel {
	nl := len(lids)
	m := &desModel{
		lids: lids, nl: nl, bx: bx, by: by, bp: bp,
		stim: stim, pktAt: pktAt, dmaAt: dmaAt,
		out:       &Delivery{Nodes: map[NodeID][]Entry4{}, XRes: map[int][]Entry4{}, YRes: map[LXPair][]Entry4{}, Corrupt: map[NodeID][]int{}},
		echoStart: map[NodeID]int{}, busyEnd: map[NodeID]int{},
		rptMatch: make([]bool, nl), rptStrip: make([]bool, nl),
	}
	m.inj = m.addReg(rkInj, -1, -1, -1)
	m.sp = make([]int, nl)
	for li := range m.sp {
		m.sp[li] = m.addReg(rkSpineHFR, li, -1, -2)
	}
	m.xh = make([][]int, nl)
	m.turnMatch = make([][]bool, nl)
	for li := 0; li < nl; li++ {
		m.xh[li] = make([]int, max(bx-1, 0))
		m.turnMatch[li] = make([]bool, bx)
		for x := 0; x < bx-1; x++ {
			m.xh[li][x] = m.addReg(rkXHFR, li, x, -1)
		}
	}
	m.pe0 = make([][][]int, nl)
	m.pe1 = make([][][]int, nl)
	m.txe = make([][][]int, nl)
	m.ejectMatch = make([][][]bool, nl)
	for li := 0; li < nl; li++ {
		m.pe0[li] = make([][]int, bx)
		m.pe1[li] = make([][]int, bx)
		m.txe[li] = make([][]int, bx)
		m.ejectMatch[li] = make([][]bool, bx)
		for x := 0; x < bx; x++ {
			m.pe0[li][x] = make([]int, by)
			m.pe1[li][x] = make([]int, by)
			m.txe[li][x] = make([]int, by)
			m.ejectMatch[li][x] = make([]bool, by)
			for y := 0; y < by; y++ {
				m.pe0[li][x][y] = m.addReg(rkPE0, li, x, y)
				m.pe1[li][x][y] = m.addReg(rkPE1, li, x, y)
				m.txe[li][x][y] = m.addReg(rkTXE, li, x, y)
			}
		}
	}
	m.up = make([]int, max(nl-1, 0))
	for li := 0; li < nl-1; li++ {
		m.up[li] = m.addReg(rkUpHFR, li, -1, -1)
	}
	m.tail = m.addReg(rkTail, -1, -1, -1)
	m.tailUp = m.addReg(rkTailUp, -1, -1, -1)
	m.xresID = make([]int, nl)
	m.yresID = make([][]int, nl)
	for li := 0; li < nl; li++ {
		m.xresID[li] = m.addReg(rkXres, li, -1, -1)
		m.yresID[li] = make([]int, bx)
		for x := 0; x < bx; x++ {
			m.yresID[li][x] = m.addReg(rkYres, li, x, -1)
		}
	}
	// egress merge trees
	m.ymID = make([][][]int, nl)
	m.xmID = make([][]int, nl)
	m.upID = make([]int, nl)
	for li := 0; li < nl; li++ {
		m.ymID[li] = make([][]int, bx)
		for x := 0; x < bx; x++ {
			m.ymID[li][x] = nil
			if by > 1 {
				m.ymID[li][x] = make([]int, by-1)
				for k := 0; k < by-1; k++ {
					m.ymID[li][x][k] = m.addMerge(mkYm, li, x, k)
				}
			}
		}
		if bx > 1 {
			m.xmID[li] = make([]int, bx-1)
			for k := 0; k < bx-1; k++ {
				m.xmID[li][k] = m.addMerge(mkXm, li, 0, k)
			}
		}
		m.upID[li] = m.addMerge(mkUp, li, 0, 0)
	}
	return m
}

// ---------------------------------------------------------------------------
// routing (the combinational gate clouds)

// rptCloud routes a byte presented to repeater cloud li at cycle c. Returns
// (target, drop): drop=true consumes the byte (LAYER_ID stripped on match).
// The head decision is combinational (flit_gate route_match = in_sop ?
// cmp : q); body bytes use the registered rptMatch decision.
func (m *desModel) rptCloud(li int, b *desByte, c int) (int, bool) {
	if b.sop {
		match := b.pkt != nil && !b.pkt.pt && b.pkt.li == li && b.vc == VC_SPINE_DESCENT
		m.rptMatch[li] = match
		if match {
			m.rptStrip[li] = true // the next byte is presented on the NoB as sop
			return -1, true
		}
	} else if m.rptMatch[li] && b.pkt != nil && b.pkt.li == li {
		// matched-packet body: the first byte after the strip carries the NoB
		// sop and the 2->3 class cut (xyz_repeater nob_vc, paper §4.3)
		b.bsop = m.rptStrip[li]
		if b.bsop {
			b.vc = VC_ONBOARD_DELIVER
		}
		return m.boardRoute(li, 0, b, c), false
	}
	// every non-matched byte (pass-through, or a layer above/below this
	// repeater) rides down the spine HFR -- including the slice's bottom
	// repeater, whose HFR output IS the tail (gen_topology: q_<last>)
	return m.sp[li], false
}

// boardRoute routes a byte presented to the board (turn column xin's input,
// xin==0 from the repeater NoB, else from xh[li][xin-1]) at cycle c.
func (m *desModel) boardRoute(li, xin int, b *desByte, c int) int {
	if b.bsop {
		m.turnMatch[li][xin] = !b.pkt.pt && b.pkt.x == xin && b.vc == VC_ONBOARD_DELIVER
	}
	if m.turnMatch[li][xin] {
		return m.yLane(li, xin, b, c)
	}
	if xin == m.bx-1 {
		return m.xresID[li]
	}
	return m.xh[li][xin]
}

// yLane walks the combinational Y-lane of column x: eject gates compare the
// full MODULE_ID, rows above the destination pass, the matching row ejects.
func (m *desModel) yLane(li, x int, b *desByte, c int) int {
	for y := 0; y < m.by; y++ {
		if b.bsop {
			m.ejectMatch[li][x][y] = !b.pkt.pt && b.pkt.y == y && b.vc == VC_ONBOARD_DELIVER
		}
		if m.ejectMatch[li][x][y] {
			return m.pe0[li][x][y]
		}
	}
	return m.yresID[li][x]
}

// dstOf resolves the full combinational route of byte b presented by
// register src at cycle c: (target, drop). The egress path (merges) is
// resolved separately by egressResolve.
func (m *desModel) dstOf(src int, b *desByte, c int) (int, bool) {
	r := &m.regs[src]
	switch r.kind {
	case rkInj:
		return m.rptCloud(0, b, c)
	case rkSpineHFR:
		if r.li == m.nl-1 {
			return m.tail, false
		}
		return m.rptCloud(r.li+1, b, c)
	case rkXHFR:
		return m.boardRoute(r.li, r.x+1, b, c), false
	case rkPE0:
		return m.pe1[r.li][r.x][r.y], false
	case rkPE1:
		return -1, false // delivery handled inline in tryMove
	}
	return -1, false
}

// routesTo reports whether byte b presented by register src latches into
// register tg at posedge c (the fill mirror of dstOf).
func (m *desModel) routesTo(src int, b *desByte, tg int, c int) bool {
	d, drop := m.dstOf(src, b, c)
	return !drop && d == tg
}

// ---------------------------------------------------------------------------
// egress merge tree resolution (vc_merge.v)

// an input of a merge is either a register or an upstream merge
type eIn struct {
	reg int
	mid int
}

func (m *desModel) mrg(mid int) *desMerge { return &m.merges[mid] }

// colWire returns the merged column wire (ym(by-2).out or the raw txe).
func (m *desModel) colWire(li, x int) eIn {
	if m.by > 1 {
		return eIn{reg: -1, mid: m.ymID[li][x][m.by-2]}
	}
	return eIn{reg: m.txe[li][x][0], mid: -1}
}

func (m *desModel) mergeSrc(mid int, portB bool) eIn {
	mg := m.mrg(mid)
	switch mg.kind {
	case mkYm:
		if !portB {
			if mg.k == 0 {
				return eIn{reg: m.txe[mg.li][mg.x][0], mid: -1}
			}
			return eIn{reg: -1, mid: m.ymID[mg.li][mg.x][mg.k-1]}
		}
		return eIn{reg: m.txe[mg.li][mg.x][mg.k+1], mid: -1}
	case mkXm:
		if !portB {
			if mg.k == 0 {
				return m.colWire(mg.li, 0)
			}
			return eIn{reg: -1, mid: m.xmID[mg.li][mg.k-1]}
		}
		return m.colWire(mg.li, mg.k+1)
	default: // mkUp
		if !portB {
			if m.bx > 1 {
				return eIn{reg: -1, mid: m.xmID[mg.li][m.bx-2]}
			}
			return m.colWire(mg.li, 0)
		}
		if mg.li == m.nl-1 {
			return eIn{reg: -1, mid: -1} // tied off (spupi)
		}
		return eIn{reg: m.up[mg.li], mid: -1}
	}
}

// gAgB mirrors vc_merge's combinational grant: which port presents during c.
func (m *desModel) gAgB(mid int, av, bv bool) (bool, bool) {
	switch m.mrg(mid).st {
	case mergeA:
		return true, false
	case mergeB:
		return false, true
	}
	if m.mrg(mid).pri == 0 { // A first
		if av {
			return true, false
		}
		return false, bv
	}
	// B first
	if bv {
		return false, true
	}
	return av, false
}

// presented returns the byte register id presents during cycle c (pre-posedge).
func (m *desModel) presented(id, c int) *desByte {
	if id < 0 {
		return nil
	}
	r := &m.regs[id]
	if r.occ == nil || r.arrived > c {
		return nil
	}
	return r.occ
}

// inputByte resolves the byte at merge mid's input port at cycle c (nil if
// none) and the merge path from the source register up to mid.
func (m *desModel) inputByte(mid, c int, portB bool) (*desByte, []int) {
	src := m.mergeSrc(mid, portB)
	if src.reg < 0 && src.mid < 0 {
		return nil, nil // tied-off port
	}
	if src.reg >= 0 {
		b := m.presented(src.reg, c)
		if b == nil {
			return nil, nil
		}
		return b, nil
	}
	return m.mergeOutByte(src.mid, c)
}

// mergeOutByte resolves the byte presented at merge mid's output at cycle c
// (nil if neither input presents) plus the merge path from the source
// register to mid.
func (m *desModel) mergeOutByte(mid, c int) (*desByte, []int) {
	ab, ap := m.inputByte(mid, c, false)
	bb, bp := m.inputByte(mid, c, true)
	gA, gB := m.gAgB(mid, ab != nil, bb != nil)
	if gA {
		return ab, append(ap, mid)
	}
	if gB {
		return bb, append(bp, mid)
	}
	return nil, nil
}

// egressResolve resolves the terminal of a byte routed up the egress tree of
// board li at cycle c: the upmerge's output feeds tailUp (slice bottom) or
// the up[li-1] HFR register. ok=false when the merge tree grants another
// source (the byte stalls in place).
func (m *desModel) egressResolve(li int, b *desByte, c int) (tg int, path []int, ok bool) {
	tg = m.tailUp
	if li > 0 {
		tg = m.up[li-1]
	}
	ob, path := m.mergeOutByte(m.upID[li], c)
	if ob == b && path != nil {
		return tg, path, true
	}
	return -1, nil, false
}

// mergeAdvance computes the round-robin state transition of a path merge
// whose granted byte b is accepted at cycle c (vc_merge: state_nxt latched
// at the acceptance posedge, pri toggles when a packet completes).
func (m *desModel) mergeAdvance(mid int, b *desByte, c int) {
	mg := m.mrg(mid)
	ab, _ := m.inputByte(mid, c, false)
	bb, _ := m.inputByte(mid, c, true)
	stN := mg.st
	priN := mg.pri
	switch mg.st {
	case mergeA:
		// the granted port is a; transition when its EOP passes
		if b.eop {
			stN = mergeIdle
			if bb != nil {
				stN = mergeB
			}
			priN = 1
		}
	case mergeB:
		if b.eop {
			stN = mergeIdle
			if ab != nil {
				stN = mergeA
			}
			priN = 0
		}
	case mergeIdle:
		if ab == b {
			stN = mergeA
		} else {
			stN = mergeB
		}
	}
	m.pmerge = append(m.pmerge, mergeUpd{mid: mid, st: stN, pri: priN})
}

// ---------------------------------------------------------------------------
// target acceptance

func (m *desModel) accepts(tg int, b *desByte, c int) bool {
	t := m.regAt(tg)
	if t == nil {
		return false
	}
	switch t.kind {
	case rkTail, rkTailUp, rkXres, rkYres:
		return true
	case rkPE0, rkPE1:
		n := NodeID{L: m.lids[t.li], X: t.x, Y: t.y}
		if m.echoBusy(n, c) {
			return false
		}
		if t.occ == nil {
			return true
		}
		return m.tryMove(tg, c)
	default:
		if t.occ == nil {
			return true
		}
		return m.tryMove(tg, c)
	}
}

// ---------------------------------------------------------------------------
// the advance: tryMove(reg, c)

func (m *desModel) tryMove(id int, c int) bool {
	r := m.regAt(id)
	if r == nil || r.occ == nil || r.arrived > c {
		return false
	}
	if r.decAt == c {
		return r.decided
	}
	r.decAt = c
	r.decided = false
	b := r.occ

	// the inject record must capture the byte's wire VC as it entered the
	// injector: rptCloud later mutates matched bodies to class 3 (the 2->3
	// transition happens at the repeater NoB, downstream of the injector)
	injVc := -1
	if r.kind == rkInj {
		injVc = int(b.vc)
	}

	// -- node DMA sink: the pe1 stage delivers to the virtual unit ------
	if r.kind == rkPE1 {
		n := NodeID{L: m.lids[r.li], X: r.x, Y: r.y}
		if m.echoBusy(n, c) || c%m.nodeDuty(n) != 0 {
			m.sched(c+1, id)
			return false
		}
		r.decided = true
		d := b.pkt.delivered[b.dma]
		m.out.Nodes[n] = append(m.out.Nodes[n],
			Entry4{c, int(d), b2i(b.dma == 0), b2i(b.dma == b.pkt.dmaLen-1), VC_ONBOARD_DELIVER})
		if b.pkt.corrupt && b.dma == b.pkt.dmaLen-1 {
			m.out.Corrupt[n] = append(m.out.Corrupt[n], c+1)
		}
		if b.eop && b.pkt.echo != nil {
			m.armEcho(r, b.pkt, c)
		}
		m.fillFromUpstream(r, c)
		m.sched(c+1, id)
		return true
	}

	// -- egress (result echoes): the merge tree arbitrates --------------
	if r.kind == rkTXE || r.kind == rkUpHFR {
		li := r.li
		if r.kind == rkTXE {
			li = r.li
		}
		tg, path, ok := m.egressResolve(li, b, c)
		if !ok {
			if r.kind == rkTXE {
				m.extendBusy(r, b, c) // a stalled echo extends the MAC freeze
			}
			m.sched(c+1, id)
			return false
		}
		if !m.accepts(tg, b, c) {
			// the up-spine terminal register is full: the merge tree
			// backpressures and the granted byte stalls in place
			if r.kind == rkTXE {
				m.extendBusy(r, b, c)
			}
			m.sched(c+1, id)
			return false
		}
		r.decided = true
		m.onMoveEgress(r, b, tg, path, c)
		m.fillFromUpstream(r, c)
		return true
	}

	// -- down path: the combinational gate clouds ----------------------
	tg, drop := m.dstOf(id, b, c)
	if drop {
		// LAYER_ID consumed at the matching repeater (in_ready=1 always)
		r.decided = true
		if r.kind == rkInj {
			m.logInject(b, c, injVc) // the injector handshake completes this cycle
		}
		m.fillFromUpstream(r, c)
		if r.kind == rkInj || r.kind == rkSpineHFR {
			// the next byte inherits the NoB sop; clear happens at posedge
		}
		return true
	}
	if !m.accepts(tg, b, c) {
		m.sched(c+1, id)
		return false
	}
	r.decided = true
	if r.kind == rkInj {
		m.logInject(b, c, injVc)
	}
	if (r.kind == rkInj || r.kind == rkSpineHFR) && tg != m.tail {
		// a matched-packet body byte was accepted onto the NoB: the
		// strip_next_q flag clears at this posedge (deferred)
		m.stripClear = append(m.stripClear, liOfRpt(r))
	}
	m.onMove(r, b, tg, c)
	m.fillFromUpstream(r, c)
	return true
}

// logInject records the injector handshake (gen_tb: "I cyc d s e vc").
func (m *desModel) logInject(b *desByte, c, vc int) {
	m.out.Inject = append(m.out.Inject, Entry4{c, int(b.data), b2i(b.sop), b2i(b.eop), vc})
}

func liOfRpt(r *desReg) int {
	if r.kind == rkSpineHFR {
		return r.li + 1
	}
	return 0
}

// onMove handles a byte that left a down-path register at cycle c: sinks log,
// registers latch (deferred to the cycle boundary).
func (m *desModel) onMove(r *desReg, b *desByte, tg int, c int) {
	t := m.regAt(tg)
	if t == nil {
		return
	}
	switch t.kind {
	case rkTail:
		m.out.Tail = append(m.out.Tail, Entry4{c, int(b.data), b2i(b.sop), b2i(b.eop), int(b.vc)})
	case rkTailUp:
		m.out.TailUp = append(m.out.TailUp, Entry4{c, int(b.data), b2i(b.sop), b2i(b.eop), VC_SPINE_ASCENT})
	case rkXres:
		m.out.XRes[m.lids[r.li]] = append(m.out.XRes[m.lids[r.li]],
			Entry4{c, int(b.data), b2i(b.sop), b2i(b.eop), 0})
	case rkYres:
		m.out.YRes[LXPair{L: m.lids[r.li], X: r.x}] = append(m.out.YRes[LXPair{L: m.lids[r.li], X: r.x}],
			Entry4{c, int(b.data), b2i(b.sop), b2i(b.eop), 0})
	default:
		t.pending = b
		t.pendSet = true
		m.sched(c+1, tg)
	}
}

// onMoveEgress latches the byte into the up-spine terminal (or logs the root
// egress) and advances the granted merge path's round-robin state.
func (m *desModel) onMoveEgress(r *desReg, b *desByte, tg int, path []int, c int) {
	if tg == m.tailUp {
		m.out.TailUp = append(m.out.TailUp, Entry4{c, int(b.data), b2i(b.sop), b2i(b.eop), VC_SPINE_ASCENT})
	} else {
		t := m.regAt(tg)
		t.pending = b
		t.pendSet = true
		m.sched(c+1, tg)
	}
	for _, mid := range path {
		m.mergeAdvance(mid, b, c)
	}
}

// ---------------------------------------------------------------------------
// fill: the wormhole refills a register at the same posedge its byte moved

func (m *desModel) fillFromUpstream(r *desReg, c int) {
	switch r.kind {
	case rkInj:
		m.pos++
		if m.pos < len(m.stim) {
			r.pending = &desByte{data: m.stim[m.pos].Data, sop: m.stim[m.pos].Sop,
				eop: m.stim[m.pos].Eop, vc: m.stim[m.pos].Vc,
				pkt: m.pktAt[m.pos], dma: m.dmaAt[m.pos]}
			r.pendSet = true
			m.sched(c+1, m.inj)
		} else {
			r.pending = nil
			r.pendSet = true
		}
	case rkSpineHFR:
		src := m.inj
		if r.li > 0 {
			src = m.sp[r.li-1]
		}
		m.refillFrom(r, src, c)
	case rkXHFR:
		var src int
		if r.x == 0 {
			src = m.NoBsource(r.li)
		} else {
			src = m.xh[r.li][r.x-1]
		}
		m.refillFrom(r, src, c)
	case rkPE0:
		var src int
		if r.x == 0 {
			src = m.NoBsource(r.li)
		} else {
			src = m.xh[r.li][r.x-1]
		}
		m.refillFrom(r, src, c)
	case rkPE1:
		m.refillFrom(r, m.pe0[r.li][r.x][r.y], c)
	case rkTXE:
		m.txeAdvance(r, c)
	case rkUpHFR:
		// filled from the upmerge of the repeater above: rpt(li+1).spup
		ob, path := m.mergeOutByte(m.upID[r.li+1], c)
		if ob != nil {
			r.pending = ob
			r.pendSet = true
			for _, mid := range path {
				m.mergeAdvance(mid, ob, c)
			}
			m.sched(c+1, m.regID(r))
		} else {
			r.pending = nil
			r.pendSet = true
		}
	}
}

// refillFrom latches the upstream's byte into r at posedge c (wormhole).
// The upstream refills itself: its own tryMove event for cycle c runs at
// this same cycle (every occupied register has one), so it must NOT be
// cascaded here -- cascading double-advances source registers like the
// injector (pos++ per cascade AND per tryMove), skipping stimulus bytes.
func (m *desModel) refillFrom(r *desReg, src int, c int) {
	s := m.regAt(src)
	if s.occ != nil && s.arrived <= c && m.routesTo(src, s.occ, m.regID(r), c) {
		r.pending = s.occ
		r.pendSet = true
		m.sched(c+1, m.regID(r))
		return
	}
	r.pending = nil
	r.pendSet = true
}

// txeAdvance refills the echo emitter: the next byte of the golden echo
// stream, or idle when the echo completes.
func (m *desModel) txeAdvance(r *desReg, c int) {
	pos := r.occ.dma + 1
	if pos < len(r.occ.pkt.echo) {
		r.pending = &desByte{data: r.occ.pkt.echo[pos], sop: false,
			eop: pos == len(r.occ.pkt.echo)-1, vc: VC_BOARD_EGRESS,
			pkt: r.occ.pkt, dma: pos}
		r.pendSet = true
		m.sched(c+1, m.regID(r))
	} else {
		r.pending = nil
		r.pendSet = true
		n := NodeID{L: m.lids[r.li], X: r.x, Y: r.y}
		if c+1 > m.busyEnd[n] {
			m.busyEnd[n] = c + 1
		}
	}
}

// extendBusy keeps the node MAC frozen while a stalled echo waits.
func (m *desModel) extendBusy(r *desReg, b *desByte, c int) {
	n := NodeID{L: m.lids[r.li], X: r.x, Y: r.y}
	if end := c + (len(b.pkt.echo) - b.dma) + 1; end > m.busyEnd[n] {
		m.busyEnd[n] = end
	}
}

// armEcho arms the node's TXE emitter one cycle after the request EOP is
// delivered (pe_tile_stub tx_emit_q <= 1 at that posedge) and starts the
// MAC freeze window.
func (m *desModel) armEcho(r *desReg, pkt *desPkt, c int) {
	txe := m.regAt(m.txe[r.li][r.x][r.y])
	txe.occ = &desByte{data: pkt.echo[0], sop: true,
		eop: len(pkt.echo) == 1, vc: VC_BOARD_EGRESS, pkt: pkt, dma: 0}
	txe.arrived = c + 1
	m.sched(c+1, m.regID(txe))
	n := NodeID{L: m.lids[r.li], X: r.x, Y: r.y}
	m.echoStart[n] = c + 1
	m.busyEnd[n] = c + 1 + len(pkt.echo)
}

// ---------------------------------------------------------------------------
// the engine

// applyPending applies all posedge-c effects when the engine advances past
// cycle c: register latches, merge state transitions, strip flag clears.
func (m *desModel) applyPending(c int) {
	for _, u := range m.pmerge {
		m.mrg(u.mid).st = u.st
		m.mrg(u.mid).pri = u.pri
	}
	m.pmerge = m.pmerge[:0]
	for i := range m.regs {
		r := &m.regs[i]
		if r.pendSet {
			r.occ = r.pending
			if r.pending != nil {
				r.arrived = c
			} else {
				r.arrived = -1
			}
			r.pending = nil
			r.pendSet = false
		}
	}
	for _, li := range m.stripClear {
		m.rptStrip[li] = false
	}
	m.stripClear = m.stripClear[:0]
}

func (m *desModel) run() {
	watchdog := 64*len(m.stim) + 1000000
	for m.evq.Len() > 0 {
		e := heap.Pop(&m.evq).(desEvt)
		if e.c > m.now {
			m.applyPending(e.c)
			m.now = e.c
		} else if e.c < m.now {
			continue // stale event for an already-applied cycle
		}
		if m.now > watchdog {
			m.out.Corrupt[NodeID{L: -1}] = append(m.out.Corrupt[NodeID{L: -1}], m.now)
			break
		}
		m.tryMove(e.reg, e.c)
	}
}

func b2i(b bool) int {
	if b {
		return 1
	}
	return 0
}

// ---------------------------------------------------------------------------
// slice packetization

// slicePackets derives this slice's packet list and stimulus stream from the
// program: routed packets whose destination layer is in the slice, plus the
// pass-through traffic when tailOwner (the chassis-tail slice owns it).
func slicePackets(prog *Program, lids []int, tailOwner bool) ([]*desPkt, []StreamByte) {
	var pkts []*desPkt
	var stream []StreamByte
	for _, oe := range prog.Order {
		if oe.IsPT {
			if !tailOwner {
				continue
			}
			pkts = append(pkts, &desPkt{pt: true, wireLen: len(oe.WF)})
			stream = append(stream, oe.WF...)
			continue
		}
		li := -1
		for i, l := range lids {
			if l == oe.Key {
				li = i
				break
			}
		}
		if li < 0 {
			continue
		}
		n := NodeID{L: oe.Key, X: int(oe.Ref.DMA[0]) >> 4, Y: int(oe.Ref.DMA[0]) & 0xF}
		bias := 0
		if m := prog.Manifest[n]; m != nil {
			bias = m.Bias
		}
		pkt := &desPkt{
			li: li, x: n.X, y: n.Y,
			delivered: StubOutput(oe.Ref.DMA, bias),
			echo:      oe.Ref.Echo,
			corrupt:   oe.Ref.Corrupt,
			wireLen:   len(oe.WF), dmaLen: len(oe.WF) - 1,
		}
		pkts = append(pkts, pkt)
		stream = append(stream, oe.WF...)
	}
	return pkts, stream
}

// RunDES runs the discrete-event model of a layer slice and returns the
// Delivery it produced (cycle-stamped in DES cycle space; the gate-level
// delivery log is offset by the tb reset sequence, see CrossCheckDES).
func RunDES(prog *Program, lids []int, bx, by int, tailOwner bool) *Delivery {
	pkts, stream := slicePackets(prog, lids, tailOwner)
	pktAt := make([]*desPkt, len(stream))
	dmaAt := make([]int, len(stream))
	pi := 0
	established := 0
	for _, oe := range prog.Order {
		if oe.IsPT && !tailOwner {
			continue
		}
		if !oe.IsPT {
			li := -1
			for i, l := range lids {
				if l == oe.Key {
					li = i
					break
				}
			}
			if li < 0 {
				continue
			}
		}
		pkt := pkts[pi]
		for i := range oe.WF {
			idx := established + i
			pktAt[idx] = pkt
			if pkt.pt || i == 0 {
				dmaAt[idx] = -1
			} else {
				dmaAt[idx] = i - 1
			}
		}
		established += len(oe.WF)
		pi++
	}

	// record the injected stream words; injection acceptance logs I records
	m := newDES(lids, bx, by, prog.BP, stream, pktAt, dmaAt)
	if len(stream) > 0 {
		m.regs[m.inj].occ = &desByte{data: stream[0].Data, sop: stream[0].Sop,
			eop: stream[0].Eop, vc: stream[0].Vc, pkt: pktAt[0], dma: dmaAt[0]}
		m.regs[m.inj].arrived = 0
		m.sched(0, m.inj)
	}
	m.run()
	return m.out
}

// ---------------------------------------------------------------------------
// RTL cross-check

// CrossCheckDES compares the gate-level delivery log against the DES model:
// per-node byte streams, the spine tail and the root egress, aligned by the
// first injection handshake cycle (the tb reset offset). Returns problem
// strings, empty when the DES reproduces the RTL exactly.
func CrossCheckDES(rtl, des *Delivery, rngOffset *int) []string {
	var errors []string
	offset := 0
	if len(rtl.Inject) > 0 && len(des.Inject) > 0 {
		offset = rtl.Inject[0].Cyc - des.Inject[0].Cyc
	}
	if rngOffset != nil {
		*rngOffset = offset
	}
	shift := func(es []Entry4) []Entry4 {
		out := make([]Entry4, len(es))
		for i, e := range es {
			e.Cyc += offset
			out[i] = e
		}
		return out
	}
	same := func(a, b []Entry4) bool {
		if len(a) != len(b) {
			return false
		}
		for i := range a {
			if a[i] != b[i] {
				return false
			}
		}
		return true
	}
	if !same(shift(des.Inject), rtl.Inject) {
		errors = append(errors, fmt.Sprintf("DES: inject stream diverges (offset %d)", offset))
	}
	if !same(shift(des.Tail), rtl.Tail) {
		errors = append(errors, fmt.Sprintf("DES: spine tail diverges (%d vs %d bytes)", len(des.Tail), len(rtl.Tail)))
	}
	if !same(shift(des.TailUp), rtl.TailUp) {
		errors = append(errors, fmt.Sprintf("DES: root egress diverges (%d vs %d bytes)", len(des.TailUp), len(rtl.TailUp)))
	}
	for n, dn := range des.Nodes {
		if !same(shift(dn), rtl.Nodes[n]) {
			errors = append(errors, fmt.Sprintf("DES: node %s stream diverges (%d vs %d bytes)", n, len(dn), len(rtl.Nodes[n])))
		}
	}
	for n := range rtl.Nodes {
		if _, ok := des.Nodes[n]; !ok && len(rtl.Nodes[n]) > 0 {
			errors = append(errors, fmt.Sprintf("DES: node %s missing from model", n))
		}
	}
	for l, dl := range des.XRes {
		if !same(shift(dl), rtl.XRes[l]) {
			errors = append(errors, fmt.Sprintf("DES: xres_%d diverges (%d vs %d bytes)", l, len(dl), len(rtl.XRes[l])))
		}
	}
	for k, dl := range des.YRes {
		if !same(shift(dl), rtl.YRes[k]) {
			errors = append(errors, fmt.Sprintf("DES: yres_(%d,%d) diverges (%d vs %d bytes)", k.L, k.X, len(dl), len(rtl.YRes[k])))
		}
	}
	return errors
}
