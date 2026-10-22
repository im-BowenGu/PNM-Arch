package pnm

// The dispatch plan as data.
//
// The paper's execution model is static: the compiler (Firmware.PlanInference)
// emits a per-token dispatch plan once, on the host, and the device executes
// it.  This file is the wire form of that plan -- a fixed-width binary
// encoding shared with the C firmware (fw/plan.h, fw/plan.c), so the host
// compiler and the device firmware are linked by bytes, not by two parallel
// implementations of the same planner.
//
// Layout (big-endian throughout):
//
//	header 16 bytes:
//	  0..3   magic "PNMP"
//	  4      version (1)
//	  5      num_hidden_layers  (0 = unknown)
//	  6      board_x
//	  7      board_y
//	  8      num_layers
//	  9      top_k
//	  10..11 reserved (0)
//	  12..15 record count (u32)
//	then count x 32-byte records:
//	  0..1   layer (u16)
//	  2      phase (u8: 0 dense, 1 moe, 2 kv_offload, 3 flash_attn, 4 norm)
//	  3      cu_type (u8, ComputeUnitType)
//	  4      target L (i8)
//	  5      target X (u8)
//	  6      target Y (u8)
//	  7      kv_action (u8: 0 none, 1 store, 2 load, 3 evict)
//	  8..9   expert (i16)
//	  10..11 flit_bytes (u16; the fabric's LEN field caps payloads at 65535)
//	  12..13 flash_tile_q (u16)
//	  14..15 flash_tile_kv (u16)
//	  16..17 flash_num_tiles (u16)
//	  18..19 window_start (i16)
//	  20..21 window_end (i16)
//	  22..23 group_size (u16)
//	  24     repeat_kv (u8)
//	  25..31 reserved (0)
//
// TensorRole, ChunkIndex and ChunkTotal are Go-side statistics only and are
// not carried on the wire.
import (
	"encoding/binary"
	"errors"
	"fmt"
)

// Wire phase codes.  Keep in lockstep with fw/plan.h.
const (
	PhaseDense     = 0
	PhaseMoe       = 1
	PhaseKVOffload = 2
	PhaseFlashAttn = 3
	PhaseNorm      = 4
)

// Wire KV-action codes.  Keep in lockstep with fw/plan.h.
const (
	KVActionNone  = 0
	KVActionStore = 1
	KVActionLoad  = 2
	KVActionEvict = 3
)

const (
	planMagic   = "PNMP"
	planVersion = 1
	planHdrLen  = 16
	planRecLen  = 32
)

// PlanHeader is the per-plan header: the model and chassis shape the plan
// was compiled for.  The executor applies it so a received plan validates
// itself without external configuration.
type PlanHeader struct {
	NumHiddenLayers int
	BoardX          int
	BoardY          int
	NumLayers       int
	TopK            int
}

// PlanHeaderFor derives the plan header from the compiling firmware.
func (fw *Firmware) PlanHeader() PlanHeader {
	tc := &fw.Driver.Config.TextConfig
	dims := fw.Driver.Dims
	return PlanHeader{
		NumHiddenLayers: tc.NumHiddenLayers,
		BoardX:          dims.Bx,
		BoardY:          dims.By,
		NumLayers:       dims.Layers,
		TopK:            tc.TopKExperts,
	}
}

func phaseCode(p string) (uint8, error) {
	switch p {
	case "dense":
		return PhaseDense, nil
	case "moe":
		return PhaseMoe, nil
	case "kv_offload":
		return PhaseKVOffload, nil
	case "flash_attn":
		return PhaseFlashAttn, nil
	case "norm":
		return PhaseNorm, nil
	}
	return 0, fmt.Errorf("plan: unknown phase %q", p)
}

func phaseName(c uint8) (string, error) {
	switch c {
	case PhaseDense:
		return "dense", nil
	case PhaseMoe:
		return "moe", nil
	case PhaseKVOffload:
		return "kv_offload", nil
	case PhaseFlashAttn:
		return "flash_attn", nil
	case PhaseNorm:
		return "norm", nil
	}
	return "", fmt.Errorf("plan: unknown phase code %d", c)
}

func kvCode(a string) (uint8, error) {
	switch a {
	case "":
		return KVActionNone, nil
	case "store":
		return KVActionStore, nil
	case "load":
		return KVActionLoad, nil
	case "evict":
		return KVActionEvict, nil
	}
	return 0, fmt.Errorf("plan: unknown kv_action %q", a)
}

func kvName(c uint8) (string, error) {
	switch c {
	case KVActionNone:
		return "", nil
	case KVActionStore:
		return "store", nil
	case KVActionLoad:
		return "load", nil
	case KVActionEvict:
		return "evict", nil
	}
	return "", fmt.Errorf("plan: unknown kv_action code %d", c)
}

// EncodePlan serializes a dispatch plan to the wire format.
func EncodePlan(h PlanHeader, recs []DispatchRecord) ([]byte, error) {
	buf := make([]byte, planHdrLen+len(recs)*planRecLen)
	copy(buf[0:4], planMagic)
	buf[4] = planVersion
	buf[5] = byte(h.NumHiddenLayers)
	buf[6] = byte(h.BoardX)
	buf[7] = byte(h.BoardY)
	buf[8] = byte(h.NumLayers)
	buf[9] = byte(h.TopK)
	binary.BigEndian.PutUint32(buf[12:16], uint32(len(recs)))

	for i, r := range recs {
		o := planHdrLen + i*planRecLen
		if r.Layer < 0 || r.Layer > 0xFFFF {
			return nil, fmt.Errorf("plan: record %d layer %d out of range", i, r.Layer)
		}
		if r.FlitBytes < 0 || r.FlitBytes > 0xFFFF {
			return nil, fmt.Errorf("plan: record %d flit_bytes %d out of range", i, r.FlitBytes)
		}
		phase, err := phaseCode(r.Phase)
		if err != nil {
			return nil, fmt.Errorf("plan: record %d: %w", i, err)
		}
		kv, err := kvCode(r.KVAction)
		if err != nil {
			return nil, fmt.Errorf("plan: record %d: %w", i, err)
		}
		binary.BigEndian.PutUint16(buf[o:o+2], uint16(r.Layer))
		buf[o+2] = phase
		buf[o+3] = byte(r.CUType)
		buf[o+4] = byte(int8(r.TargetNode.L))
		buf[o+5] = byte(r.TargetNode.X)
		buf[o+6] = byte(r.TargetNode.Y)
		buf[o+7] = kv
		binary.BigEndian.PutUint16(buf[o+8:o+10], uint16(int16(r.ExpertIdx)))
		binary.BigEndian.PutUint16(buf[o+10:o+12], uint16(r.FlitBytes))
		binary.BigEndian.PutUint16(buf[o+12:o+14], uint16(r.FlashTileQ))
		binary.BigEndian.PutUint16(buf[o+14:o+16], uint16(r.FlashTileKV))
		binary.BigEndian.PutUint16(buf[o+16:o+18], uint16(r.FlashNumTiles))
		binary.BigEndian.PutUint16(buf[o+18:o+20], uint16(int16(r.WindowStart)))
		binary.BigEndian.PutUint16(buf[o+20:o+22], uint16(int16(r.WindowEnd)))
		binary.BigEndian.PutUint16(buf[o+22:o+24], uint16(r.GroupSize))
		if r.RepeatKV {
			buf[o+24] = 1
		}
	}
	return buf, nil
}

// DecodePlan parses a dispatch plan from the wire format.
func DecodePlan(b []byte) (PlanHeader, []DispatchRecord, error) {
	if len(b) < planHdrLen {
		return PlanHeader{}, nil, errors.New("plan: buffer shorter than header")
	}
	if string(b[0:4]) != planMagic {
		return PlanHeader{}, nil, errors.New("plan: bad magic")
	}
	if b[4] != planVersion {
		return PlanHeader{}, nil, fmt.Errorf("plan: unsupported version %d", b[4])
	}
	h := PlanHeader{
		NumHiddenLayers: int(b[5]),
		BoardX:          int(b[6]),
		BoardY:          int(b[7]),
		NumLayers:       int(b[8]),
		TopK:            int(b[9]),
	}
	count := int(binary.BigEndian.Uint32(b[12:16]))
	if len(b) < planHdrLen+count*planRecLen {
		return PlanHeader{}, nil, errors.New("plan: buffer shorter than records")
	}
	recs := make([]DispatchRecord, count)
	for i := 0; i < count; i++ {
		o := planHdrLen + i*planRecLen
		phase, err := phaseName(b[o+2])
		if err != nil {
			return PlanHeader{}, nil, fmt.Errorf("plan: record %d: %w", i, err)
		}
		kv, err := kvName(b[o+7])
		if err != nil {
			return PlanHeader{}, nil, fmt.Errorf("plan: record %d: %w", i, err)
		}
		recs[i] = DispatchRecord{
			Layer:         int(binary.BigEndian.Uint16(b[o : o+2])),
			Phase:         phase,
			TargetNode:    NodeID{L: int(int8(b[o+4])), X: int(b[o+5]), Y: int(b[o+6])},
			ExpertIdx:     int(int16(binary.BigEndian.Uint16(b[o+8 : o+10]))),
			FlitBytes:     int(binary.BigEndian.Uint16(b[o+10 : o+12])),
			KVAction:      kv,
			CUType:        ComputeUnitType(b[o+3]),
			FlashTileQ:    int(binary.BigEndian.Uint16(b[o+12 : o+14])),
			FlashTileKV:   int(binary.BigEndian.Uint16(b[o+14 : o+16])),
			FlashNumTiles: int(binary.BigEndian.Uint16(b[o+16 : o+18])),
			WindowStart:   int(int16(binary.BigEndian.Uint16(b[o+18 : o+20]))),
			WindowEnd:     int(int16(binary.BigEndian.Uint16(b[o+20 : o+22]))),
			GroupSize:     int(binary.BigEndian.Uint16(b[o+22 : o+24])),
			RepeatKV:      b[o+24] != 0,
		}
	}
	return h, recs, nil
}
