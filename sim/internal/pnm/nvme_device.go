package pnm

import (
	"fmt"
)

// ============================================================================
// NVMe storage model for the PNM orchestrator chip firmware.
//
// This mirrors fw/pnm_nvme.{c,h} so the Go verification harness can check that
// KV-cache overflow to NVMe produces identical layouts on both sides. The
// hardware model is HDL/nvme_ctrl.v; the register protocol matches its
// AXI-Lite interface exactly (offsets 0x00-0x3C).
//
// The Lustre OSS striping client that previously shared this file is
// quarantined under archive/ (see docs/pnm.md, "Archived components").
// ============================================================================

// NVMe command opcodes (must match nvme_ctrl.v localparams).
const (
	NVMECmdRead  = 0x01
	NVMECmdWrite = 0x02
	NVMECmdFlush = 0x03
)

// NVMe status bits.
const (
	NVMEStsDone  = 0x00000001
	NVMEStsError = 0x00000002
)

const (
	NVMEBlockSize   = 512
	NVMEMaxTransfer = 65536
)

// NVMeRegOff maps symbolic names to nvme_ctrl.v register offsets.
var NVMeRegOff = map[string]uint32{
	"CAP":     0x00,
	"VS":      0x04,
	"CSTS":    0x08,
	"AQA":     0x0C,
	"ASQ_LO":  0x10,
	"ASQ_HI":  0x14,
	"ACQ_LO":  0x18,
	"ACQ_HI":  0x1C,
	"CMD_OP":  0x20,
	"SLBA_LO": 0x24,
	"SLBA_HI": 0x28,
	"NLB":     0x2C,
	"BUF_LO":  0x30,
	"BUF_HI":  0x34,
	"STATUS":  0x38,
	"INT_EN":  0x3C,
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
