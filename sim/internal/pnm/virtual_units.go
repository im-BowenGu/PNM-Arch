package pnm

import (
	"fmt"
	"math"
	"strings"
)

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

// kF64Add: FP64 addition — unpacks two FP64 values from the payload,
// adds them, and returns the 8-byte result.
func kF64Add(pkt *Pkt, state *UnitState) interface{} {
	p := pkt.Payload
	if len(p) < 16 {
		return []byte{0, 0, 0, 0, 0, 0, 0, 0}
	}
	a := bytesToFP64(p[0:8])
	b := bytesToFP64(p[8:16])
	result := a + b
	return fp64ToBytes(result)
}

// kF64Mul: FP64 multiplication — unpacks two FP64 values from the payload,
// multiplies them, and returns the 8-byte result.
func kF64Mul(pkt *Pkt, state *UnitState) interface{} {
	p := pkt.Payload
	if len(p) < 16 {
		return []byte{0, 0, 0, 0, 0, 0, 0, 0}
	}
	a := bytesToFP64(p[0:8])
	b := bytesToFP64(p[8:16])
	result := a * b
	return fp64ToBytes(result)
}

// kF64Fma: FP64 fused multiply-add — unpacks three FP64 values (a, b, c)
// from the payload and returns a*b + c as 8 bytes.
func kF64Fma(pkt *Pkt, state *UnitState) interface{} {
	p := pkt.Payload
	if len(p) < 24 {
		return []byte{0, 0, 0, 0, 0, 0, 0, 0}
	}
	a := bytesToFP64(p[0:8])
	b := bytesToFP64(p[8:16])
	c := bytesToFP64(p[16:24])
	result := a*b + c
	return fp64ToBytes(result)
}

// kF64Sub: FP64 subtraction — returns a - b as 8 bytes.
func kF64Sub(pkt *Pkt, state *UnitState) interface{} {
	p := pkt.Payload
	if len(p) < 16 {
		return []byte{0, 0, 0, 0, 0, 0, 0, 0}
	}
	a := bytesToFP64(p[0:8])
	b := bytesToFP64(p[8:16])
	return fp64ToBytes(a - b)
}

// kF64Div: FP64 division — returns a / b as 8 bytes. Division by zero
// yields IEEE 754 infinities/NaN via Go's float64 semantics.
func kF64Div(pkt *Pkt, state *UnitState) interface{} {
	p := pkt.Payload
	if len(p) < 16 {
		return []byte{0, 0, 0, 0, 0, 0, 0, 0}
	}
	a := bytesToFP64(p[0:8])
	b := bytesToFP64(p[8:16])
	return fp64ToBytes(a / b)
}

// kF64Min: FP64 minimum — returns the smaller of a and b (IEEE unordered
// handling: NaN operands yield a NaN result via math.Min semantics).
func kF64Min(pkt *Pkt, state *UnitState) interface{} {
	p := pkt.Payload
	if len(p) < 16 {
		return []byte{0, 0, 0, 0, 0, 0, 0, 0}
	}
	a := bytesToFP64(p[0:8])
	b := bytesToFP64(p[8:16])
	return fp64ToBytes(math.Min(a, b))
}

// kF64Max: FP64 maximum — returns the larger of a and b (see kF64Min).
func kF64Max(pkt *Pkt, state *UnitState) interface{} {
	p := pkt.Payload
	if len(p) < 16 {
		return []byte{0, 0, 0, 0, 0, 0, 0, 0}
	}
	a := bytesToFP64(p[0:8])
	b := bytesToFP64(p[8:16])
	return fp64ToBytes(math.Max(a, b))
}

// kF64Neg: FP64 negation — flips the sign bit of the single FP64 value.
func kF64Neg(pkt *Pkt, state *UnitState) interface{} {
	p := pkt.Payload
	if len(p) < 8 {
		return []byte{0, 0, 0, 0, 0, 0, 0, 0}
	}
	a := bytesToFP64(p[0:8])
	return fp64ToBytes(-a)
}

// kF64Cmp: FP64 comparison — payload is a(8) + b(8) + op(2 ASCII bytes).
// Returns 1.0 when the comparison holds, 0.0 otherwise. NaN operands make
// every ordered comparison false (IEEE 754 unordered semantics); the
// "==" / "!=" operators are the only ones that can see a NaN operand.
func kF64Cmp(pkt *Pkt, state *UnitState) interface{} {
	p := pkt.Payload
	if len(p) < 17 {
		return []byte{0, 0, 0, 0, 0, 0, 0, 0}
	}
	a := bytesToFP64(p[0:8])
	b := bytesToFP64(p[8:16])
	op := strings.TrimSpace(string(p[16:]))
	var holds bool
	switch op {
	case "==":
		holds = a == b
	case "!=", "/=":
		holds = a != b
	case "<":
		holds = a < b
	case ">":
		holds = a > b
	case "<=":
		holds = a <= b
	case ">=":
		holds = a >= b
	default:
		holds = false
	}
	if holds {
		return fp64ToBytes(1.0)
	}
	return fp64ToBytes(0.0)
}

// bytesToFP64 decodes a big-endian 8-byte slice into float64.
func bytesToFP64(b []byte) float64 {
	var bits uint64
	for i := 0; i < 8 && i < len(b); i++ {
		bits = (bits << 8) | uint64(b[i])
	}
	return math.Float64frombits(bits)
}

// fp64ToBytes encodes a float64 into a big-endian 8-byte slice.
func fp64ToBytes(v float64) []byte {
	bits := math.Float64bits(v)
	b := make([]byte, 8)
	for i := 7; i >= 0; i-- {
		b[i] = byte(bits & 0xFF)
		bits >>= 8
	}
	return b
}

// KERNEL_MIX is the resident-kernel menu; index 0..3 order must match
// virtual_units.py KERNELS and run.py KERNEL_MIX.
var KERNEL_MIX = []string{"dot", "sum", "accum", "echo"}

// KERNELS_ALL lists all known kernels (including FP64 extensions).
var KERNELS_ALL = []string{"dot", "sum", "accum", "echo", "f64_add", "f64_mul", "f64_fma", "f64_sub", "f64_div", "f64_min", "f64_max", "f64_neg", "f64_cmp"}

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
	case "f64_add":
		return kF64Add
	case "f64_mul":
		return kF64Mul
	case "f64_fma":
		return kF64Fma
	case "f64_sub":
		return kF64Sub
	case "f64_div":
		return kF64Div
	case "f64_min":
		return kF64Min
	case "f64_max":
		return kF64Max
	case "f64_neg":
		return kF64Neg
	case "f64_cmp":
		return kF64Cmp
	default:
		return nil // unknown kernel: caller must check for nil
	}
}

// NewVirtualUnit mirrors VirtualUnit.__init__.
func NewVirtualUnit(node NodeID, kernel string, weights []int) *VirtualUnit {
	kf := kernelFunc(kernel)
	if kf == nil {
		// Unknown kernel: use echo as fallback (passthrough)
		kf = kEcho
	}
	return &VirtualUnit{
		Node:       node,
		KernelName: kernel,
		Kernel:     kf,
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
