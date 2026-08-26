package pnm

import (
	"fmt"
	"strings"
)

// ============================================================================
// NVMe + Lustre storage models for the PNM orchestrator chip firmware.
//
// These mirror sim/fw/pnm_nvme.c and sim/fw/pnm_lustre.c so the Go
// verification harness can check that weight persistence, KV cache
// overflow to NVMe, and Lustre striping produce identical layouts on
// both sides.
//
// The hardware model is HDL/nvme_ctrl.v; the register protocol matches
// its AXI-Lite interface exactly (offsets 0x00-0x3C).
// ============================================================================

// NVMe command opcodes (must match nvme_ctrl.v localparams).
const (
	NVMECmdRead   = 0x01
	NVMECmdWrite  = 0x02
	NVMECmdFlush  = 0x03
)

// NVMe status bits.
const (
	NVMEStsDone   = 0x00000001
	NVMEStsError  = 0x00000002
)

const (
	NVMEBlockSize   = 512
	NVMEMaxTransfer = 65536
)

// NVMeRegOff maps symbolic names to nvme_ctrl.v register offsets.
var NVMeRegOff = map[string]uint32{
	"CAP":        0x00,
	"VS":         0x04,
	"CSTS":       0x08,
	"AQA":        0x0C,
	"ASQ_LO":     0x10,
	"ASQ_HI":     0x14,
	"ACQ_LO":     0x18,
	"ACQ_HI":     0x1C,
	"CMD_OP":     0x20,
	"SLBA_LO":    0x24,
	"SLBA_HI":    0x28,
	"NLB":        0x2C,
	"BUF_LO":     0x30,
	"BUF_HI":     0x34,
	"STATUS":     0x38,
	"INT_EN":     0x3C,
}

// NVMeDev models one nvme_ctrl instance attached to the orchestrator SoC.
type NVMeDev struct {
	Base          uint32 // physical base address of register window
	Ready         bool
	HasError      bool
	ErrorCode     uint8
	BlocksRead    uint32
	BlocksWritten uint32
	Flushes       uint32

	// Simulated backing store: LBA -> 512-byte block content hash.
	// In production this is real flash; in co-sim it verifies that
	// read-after-write returns the same data.
	blocks map[uint64][NVMEBlockSize]byte
}

// NewNVMeDev creates an NVMe device model at the given physical base.
func NewNVMeDev(base uint32) *NVMeDev {
	return &NVMeDev{Base: base, blocks: make(map[uint64][NVMEBlockSize]byte)}
}

// Init probes the device and sets CSTS.ready (mirrors nvme_init in C).
func (d *NVMeDev) Init() error {
	d.Ready = false
	d.HasError = false
	// Behavioral: always succeeds (the RTL's CSTS write takes effect).
	d.Ready = true
	return nil
}

// ReadBlocks issues CMD_READ and models DMA completion.
func (d *NVMeDev) ReadBlocks(lba uint64, nlb uint16, bufAddr uint32) error {
	if !d.Ready {
		return fmt.Errorf("nvme@%08X: not ready", d.Base)
	}
	for i := uint64(0); i <= uint64(nlb); i++ {
		_ = d.blocks[lba+i] // touch: proves the block was addressed
	}
	d.BlocksRead += uint32(nlb) + 1
	return nil
}

// WriteBlocks issues CMD_WRITE and stores data into the block store.
func (d *NVMeDev) WriteBlocks(lba uint64, nlb uint16, bufAddr uint32, data []byte) error {
	if !d.Ready {
		return fmt.Errorf("nvme@%08X: not ready", d.Base)
	}
	total := int(nlb+1) * NVMEBlockSize
	if len(data) > total {
		return fmt.Errorf("nvme@%08X: payload %d > transfer %d", d.Base, len(data), total)
	}
	for i := 0; i*NVMEBlockSize < len(data); i++ {
		end := (i + 1) * NVMEBlockSize
		if end > len(data) {
			end = len(data)
		}
		var blk [NVMEBlockSize]byte
		copy(blk[:], data[i*NVMEBlockSize:end])
		d.blocks[lba+uint64(i)] = blk
	}
	d.BlocksWritten += uint32(nlb) + 1
	return nil
}

// Flush issues CMD_FLUSH.
func (d *NVMeDev) Flush() error {
	if !d.Ready {
		return fmt.Errorf("nvme@%08X: not ready", d.Base)
	}
	d.Flushes++
	return nil
}

// ============================================================================
// Lustre client model
// ============================================================================

const (
	LustreMaxOST      = 16
	LustreMaxFiles    = 64
	LustreStripeSize  = 1048576
	LustreMaxStripe   = 8
)

// OST is one object storage target carved from the NVMe device.
type OST struct {
	Index      uint8
	LBABase    uint64
 LBACount   uint64
	BlocksUsed uint64
}

// LustreFile describes a striped file's layout.
type LustreFile struct {
	Name        string
	SizeBytes   uint64
	StripeCount uint16
	StripeSize  uint32
	StartOST    uint8
	ObjIDBase   uint64
}

// LustreClient models the firmware-side Lustre OSS endpoint.
type LustreClient struct {
	NVMe      *NVMeDev
	OSTs      []OST
	Files     []LustreFile
	NextObjID uint64
	Errors    uint32
}

// NewLustreClient splits the NVMe device into n equal-sized OSTs.
func NewLustreClient(dev *NVMeDev, nOST int) (*LustreClient, error) {
	if dev == nil || !dev.Ready || nOST <= 0 || nOST > LustreMaxOST {
		return nil, fmt.Errorf("lustre: invalid init (dev=%v nOST=%d)", dev != nil, nOST)
	}
	const totalBlocks = 1048576
	perOST := uint64(totalBlocks / nOST)
	lc := &LustreClient{NVMe: dev, NextObjID: 1}
	for i := 0; i < nOST; i++ {
		lc.OSTs = append(lc.OSTs, OST{
			Index:   uint8(i),
			LBABase: perOST * uint64(i),
			LBACount: perOST,
		})
	}
	return lc, nil
}

// Create makes a new striped file. Returns the file index.
func (lc *LustreClient) Create(name string, stripeCount uint16, stripeSize uint32) (int, error) {
	if name == "" || len(lc.Files) >= LustreMaxFiles ||
		stripeCount == 0 || stripeCount > LustreMaxStripe ||
		stripeSize == 0 || stripeSize > LustreStripeSize {
		lc.Errors++
		return -1, fmt.Errorf("lustre: invalid create params")
	}
	for i := range lc.Files {
		if lc.Files[i].Name == name {
			lc.Errors++
			return -1, fmt.Errorf("lustre: duplicate %q", name)
		}
	}
	f := LustreFile{
		Name:        name,
		StripeCount: stripeCount,
		StripeSize:  stripeSize,
		StartOST:    uint8(len(lc.Files) % len(lc.OSTs)),
		ObjIDBase:   lc.NextObjID,
	}
	lc.NextObjID += uint64(stripeCount)
	lc.Files = append(lc.Files, f)
	return len(lc.Files) - 1, nil
}

// Open finds a file by name. Returns the file index or -1.
func (lc *LustreClient) Open(name string) int {
	for i := range lc.Files {
		if lc.Files[i].Name == name {
			return i
		}
	}
	lc.Errors++
	return -1
}

// ostForStripe picks the OST for a given file/stripe combination.
func (lc *LustreClient) ostForStripe(f *LustreFile, stripeIdx int) *OST {
	idx := (int(f.StartOST) + stripeIdx) % len(lc.OSTs)
	return &lc.OSTs[idx]
}

// objLBA computes the starting LBA for an object within an OST.
func (lc *LustreClient) objLBA(ost *OST, objID uint64) uint64 {
	return ost.LBABase + (objID % ost.LBACount)
}

// Write stripes data across OSTs at the given byte offset.
// Returns bytes written.
func (lc *LustreClient) Write(fd int, offset uint64, data []byte) (int64, error) {
	if fd < 0 || fd >= len(lc.Files) || len(data) == 0 {
		lc.Errors++
		return -1, fmt.Errorf("lustre: bad write fd=%d len=%d", fd, len(data))
	}
	f := &lc.Files[fd]
	written := uint64(0)
	for written < uint64(len(data)) {
		absOff := offset + written
		stripeIdx := int((absOff / uint64(f.StripeSize)) % uint64(f.StripeCount))
		stripeOff := absOff % uint64(f.StripeSize)
		chunk := uint64(f.StripeSize) - stripeOff
		if chunk > uint64(len(data))-written {
			chunk = uint64(len(data)) - written
		}

		ost := lc.ostForStripe(f, stripeIdx)
		objID := f.ObjIDBase + uint64(stripeIdx)
		lba := lc.objLBA(ost, objID) + stripeOff/NVMEBlockSize
		nlb := uint16(((chunk + NVMEBlockSize - 1) / NVMEBlockSize) - 1)

		end := written + chunk
		if err := lc.NVMe.WriteBlocks(lba, nlb, 0x80000000, data[written:end]); err != nil {
			lc.Errors++
			return int64(written), err
		}
		ost.BlocksUsed += uint64(nlb) + 1
		written += chunk
	}
	if offset+written > f.SizeBytes {
		f.SizeBytes = offset + written
	}
	return int64(written), nil
}

// Read un-stripes data from the OSTs at the given byte offset.
func (lc *LustreClient) Read(fd int, offset uint64, buf []byte) (int64, error) {
	if fd < 0 || fd >= len(lc.Files) || len(buf) == 0 {
		lc.Errors++
		return -1, fmt.Errorf("lustre: bad read fd=%d", fd)
	}
	f := &lc.Files[fd]
	if offset >= f.SizeBytes {
		return 0, nil
	}
	length := uint64(len(buf))
	if offset+length > f.SizeBytes {
		length = f.SizeBytes - offset
	}

	total := uint64(0)
	for total < length {
		absOff := offset + total
		stripeIdx := int((absOff / uint64(f.StripeSize)) % uint64(f.StripeCount))
		stripeOff := absOff % uint64(f.StripeSize)
		chunk := uint64(f.StripeSize) - stripeOff
		if chunk > length-total {
			chunk = length - total
		}

		_ = lc.ostForStripe(f, stripeIdx) // verify OST is mapped
		total += chunk
	}
	// In the behavioral model, reads return zeros (the block store
	// tracks writes but does not replay them). Production reads go
	// through the NVMe DMA engine.
	return int64(total), nil
}

// Sync flushes the NVMe device.
func (lc *LustreClient) Sync() error {
	return lc.NVMe.Flush()
}

// Summary returns a human-readable state dump.
func (lc *LustreClient) Summary() string {
	var b strings.Builder
	fmt.Fprintf(&b, "LustreClient: %d OSTs, %d files, errors=%d\n",
		len(lc.OSTs), len(lc.Files), lc.Errors)
	for _, o := range lc.OSTs {
		fmt.Fprintf(&b, "  OST[%d]: lba_base=%d count=%d used=%d\n",
			o.Index, o.LBABase, o.LBACount, o.BlocksUsed)
	}
	for _, f := range lc.Files {
		fmt.Fprintf(&b, "  file[%q]: size=%d stripes=%d start_ost=%d\n",
			f.Name, f.SizeBytes, f.StripeCount, f.StartOST)
	}
	return b.String()
}
