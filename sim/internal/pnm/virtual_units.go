package pnm

import "fmt"

// Virtual execution units — the node's MAC ASIC + LPDDR6 CAMM2 socket,
// ported from sim/virtual_units.py.
//
// Each (layer, x, y) node in the generated topology owns a VirtualUnit. The
// unit receives the DMA stream that *actually came through the Verilog fabric*
// (delivery.log, written by tb_pnm.v) and executes its resident kernel on it.
//
// This models the paper's per-node contract:
//
//   - the doorbell discipline (Paper.MD §2.9): the DMA engine counts incoming
//     bytes and keeps a running CRC; the node's resident function fires only
//     when the byte count equals the header length field *and* the end-to-end
//     CRC validates. A partial or corrupt message never fires the doorbell.
//   - resident kernels with local state (§2.5 weight loading, §2.9 COMPUTE):
//     each unit is programmed with a kernel and a local weight vector at
//     "boot" (scenario generation), exactly like MoE expert weights loaded
//     into the node's CAMM before execution begins.
type VirtualUnit struct {
	Node          NodeID
	KernelName    string
	Kernel        func(*Pkt, *UnitState) interface{}
	State         *UnitState
	Packets       []*Pkt        // decoded + accepted packets, arrival order
	Results       []interface{} // kernel results, arrival order
	Activations   int           // doorbell fires
	Rejections    int           // doorbell refused (corrupt / truncated)
	RejectReasons []string
}

// UnitState is the resident kernel's mutable local state (weight vector +
// accumulator), mirroring the Python per-unit state dict.
type UnitState struct {
	Weights []int
	Acc     uint64
}

// Pkt is one decoded node DMA stream:
// DEST, CTRL, LEN_LO, LEN_HI, payload..., CRC_HI, CRC_LO.
type Pkt struct {
	Dest    byte
	Ctrl    byte
	Length  int
	Payload []byte
	CRC     [2]byte
}

// decode mirrors virtual_units.py decode().
func decode(byteList []byte) *Pkt {
	p := &Pkt{}
	if len(byteList) > 0 {
		p.Dest = byteList[0]
	}
	if len(byteList) > 1 {
		p.Ctrl = byteList[1]
	}
	length := 0
	if len(byteList) > 3 {
		length = int(byteList[2]) | (int(byteList[3]) << 8)
	}
	p.Length = length
	end := 4 + length
	if end > len(byteList) {
		end = len(byteList)
	}
	if end <= 4 {
		p.Payload = nil
	} else {
		p.Payload = append([]byte(nil), byteList[4:end]...)
	}
	if len(byteList) >= 2 {
		p.CRC = [2]byte{byteList[len(byteList)-2], byteList[len(byteList)-1]}
	}
	return p
}

// -- resident kernels (the node's hard-wired functions) ------------------

// kEcho: identity — echo the payload back byte-for-byte (validation node).
func kEcho(pkt *Pkt, state *UnitState) interface{} {
	return append([]byte(nil), pkt.Payload...)
}

// kSum: reduction — byte checksum of the payload.
func kSum(pkt *Pkt, state *UnitState) interface{} {
	var s uint64
	for _, b := range pkt.Payload {
		s += uint64(b)
	}
	return s & 0xFFFFFFFF
}

// kAccum: stateful accumulator — fold payload bytes into running CAMM state.
func kAccum(pkt *Pkt, state *UnitState) interface{} {
	var s uint64
	for _, b := range pkt.Payload {
		s += uint64(b)
	}
	state.Acc = (state.Acc + s) & 0xFFFFFFFF
	return state.Acc
}

// kDot: MAC array (Paper.MD §2.9 COMPUTE) — dot product of the landed token
// against the node's resident weight vector (zero-padded / truncated).
func kDot(pkt *Pkt, state *UnitState) interface{} {
	p := pkt.Payload
	w := state.Weights
	n := max(len(p), len(w))
	var acc uint64
	for i := 0; i < n; i++ {
		var pv, wv uint64
		if i < len(p) {
			pv = uint64(p[i])
		}
		if i < len(w) {
			wv = uint64(w[i])
		}
		acc += pv * wv
	}
	return acc & 0xFFFFFFFF
}

// KERNEL_MIX is the resident-kernel menu; index 0..3 order must match
// virtual_units.py KERNELS and run.py KERNEL_MIX.
var KERNEL_MIX = []string{"dot", "sum", "accum", "echo"}

func kernelFunc(name string) func(*Pkt, *UnitState) interface{} {
	switch name {
	case "echo":
		return kEcho
	case "sum":
		return kSum
	case "accum":
		return kAccum
	case "dot":
		return kDot
	}
	panic("unknown kernel: " + name)
}

// NewVirtualUnit mirrors VirtualUnit.__init__.
func NewVirtualUnit(node NodeID, kernel string, weights []int) *VirtualUnit {
	return &VirtualUnit{
		Node:       node,
		KernelName: kernel,
		Kernel:     kernelFunc(kernel),
		State:      &UnitState{Weights: append([]int(nil), weights...)},
	}
}

// Consume mirrors VirtualUnit.consume(): fire the doorbell only when all
// three conditions of Paper.MD §2.4 hold — (a) byte-count equality, (b)
// end-to-end CRC, (c) DEST == own coordinate. Returns the decoded packet if
// the doorbell fired.
//
// hwCorrupt: the pe_tile_stub's in-silicon doorbell verdict for this message
// (its corrupt_out pulse). The stub validated the *incoming* CRC in Verilog
// and refused the message; the software unit records that refusal even
// though the stub re-emitted a CRC-consistent (bias-transformed) stream so
// transport accounting stays lossless.
func (u *VirtualUnit) Consume(byteList []byte, hwCorrupt bool) *Pkt {
	p := decode(byteList)
	if hwCorrupt {
		u.Rejections++
		u.RejectReasons = append(u.RejectReasons,
			"hardware doorbell: MAC stub CRC verdict")
		return nil
	}
	// (a) byte-count equality: complete delivery test (§2.9)
	if len(byteList) != p.Length+6 {
		u.Rejections++
		u.RejectReasons = append(u.RejectReasons,
			fmt.Sprintf("count %d != len %d + 6", len(byteList), p.Length))
		return nil
	}
	// (b) end-to-end CRC over [DEST, CTRL, LEN_LO, LEN_HI, payload]
	body := byteList[:len(byteList)-2]
	if (int(p.CRC[0])<<8 | int(p.CRC[1])) != int(crc16(body)) {
		u.Rejections++
		u.RejectReasons = append(u.RejectReasons, "CRC mismatch")
		return nil
	}
	// (c) CRC-protected DEST field == this node's own coordinate
	own := (u.Node.X << 4) | u.Node.Y
	if int(p.Dest) != own {
		u.Rejections++
		u.RejectReasons = append(u.RejectReasons,
			fmt.Sprintf("DEST %#04x != own %#04x", p.Dest, own))
		return nil
	}
	// doorbell fires: DISPATCH the resident kernel
	u.Packets = append(u.Packets, p)
	u.Results = append(u.Results, u.Kernel(p, u.State))
	u.Activations++
	return p
}
