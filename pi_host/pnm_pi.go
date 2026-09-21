// pnm_pi.go — PNM orchestrator host driver for Raspberry Pi Compute Modules over SPI.
//
// Go alternative to pnm_pi.py (same wire protocol, same register API).
// Standard library only: talks to spidev through raw ioctl, no cgo, so it
// cross-compiles to the Pi with GOOS=linux GOARCH=arm64 from any host:
//
//	go build -o pnm_pi_go pnm_pi.go
//
// Targets CM0/CM1/CM3/CM4 class modules where pi_bridge (HDL/pi_bridge.v)
// is wired to a full SPI bus. Frame format (48 bits, MSB first, mode 0):
//
//	byte 0   : header {rw(1b) << 7 | sel[6:0]}   rw=1 read, rw=0 write
//	bytes 1-4: 32-bit data field, MSB first (sent on MOSI / returned on MISO)
//	byte 5   : status byte echoed back (0x01 write-ack, 0x00 read-ok)
package main

import (
	"encoding/binary"
	"flag"
	"fmt"
	"os"
	"runtime"
	"syscall"
	"unsafe"
)

const (
	selCtrl       = 0x00
	selLayer      = 0x01
	selModule     = 0x02
	selLen        = 0x03
	selData       = 0x04
	selStatus     = 0x05
	selResult     = 0x06
	selErrors     = 0x07
	selDispatches = 0x08
	selWeights    = 0x09

	ctrlInject   = 1 << 0
	ctrlBootDone = 1 << 2

	statusBusy = 1 << 0

	frameLen = 6
)

// Linux ioctl encoding (asm-generic): 14-bit size, 8-bit type, 8-bit nr,
// 2-bit dir. Matches linux/spi/spidev.h on all Pi targets.
const (
	iocNrbits   = 8
	iocTypebits = 8
	iocSizebits = 14

	iocNrshift   = 0
	iocTypeshift = iocNrshift + iocNrbits
	iocSizeshift = iocTypeshift + iocTypebits
	iocDirshift  = iocSizeshift + iocSizebits

	iocWrite = 1
	iocRead  = 2

	spiIocMagic = 'k'
)

func ioc(dir, typ, nr, size uint) uint {
	return dir<<iocDirshift | typ<<iocTypeshift | nr<<iocNrshift | size<<iocSizeshift
}

// spiIocTransfer mirrors struct spi_ioc_transfer (32 bytes, kernel ABI).
type spiIocTransfer struct {
	txBuf       uint64
	rxBuf       uint64
	length      uint32
	speedHz     uint32
	delayUsecs  uint16
	bitsPerWord uint8
	csChange    uint8
	txNBits     uint8
	rxNBits     uint8
	pad         uint16
}

const spiIocTransferSize = uint(unsafe.Sizeof(spiIocTransfer{}))

func spiIocMessage(n int) uint {
	size := uint(n) * spiIocTransferSize
	const max = 1 << iocSizebits
	if size > max {
		size = max
	}
	return ioc(iocWrite, spiIocMagic, 0, size)
}

var (
	spiIocWrMode        = ioc(iocWrite, spiIocMagic, 1, 1)
	spiIocWrBitsPerWord = ioc(iocWrite, spiIocMagic, 3, 1)
	spiIocWrMaxSpeedHz  = ioc(iocWrite, spiIocMagic, 4, 4)
)

// PNM is a host-side handle for one pi_bridge SPI device.
type PNM struct {
	f     *os.File
	speed uint32
}

// Open claims /dev/spidev<bus>.<dev> and configures mode 0 @ speedHz.
func Open(bus, dev int, speedHz uint32) (*PNM, error) {
	path := fmt.Sprintf("/dev/spidev%d.%d", bus, dev)
	f, err := os.OpenFile(path, os.O_RDWR, 0)
	if err != nil {
		return nil, err
	}
	p := &PNM{f: f, speed: speedHz}
	mode := uint8(0) // SPI_MODE_0
	bits := uint8(8)
	for _, c := range []struct {
		cmd uint
		val unsafe.Pointer
	}{{spiIocWrMode, unsafe.Pointer(&mode)},
		{spiIocWrBitsPerWord, unsafe.Pointer(&bits)},
		{spiIocWrMaxSpeedHz, unsafe.Pointer(&p.speed)}} {
		if _, _, errno := syscall.Syscall(syscall.SYS_IOCTL, f.Fd(),
			uintptr(c.cmd), uintptr(c.val)); errno != 0 {
			f.Close()
			return nil, errno
		}
	}
	return p, nil
}

// Close releases the SPI device.
func (p *PNM) Close() error { return p.f.Close() }

// xfer runs one full-duplex 48-bit frame and returns the MISO bytes.
func (p *PNM) xfer(frame []byte) ([]byte, error) {
	resp := make([]byte, frameLen)
	tr := spiIocTransfer{
		txBuf:       uint64(uintptr(unsafe.Pointer(&frame[0]))),
		rxBuf:       uint64(uintptr(unsafe.Pointer(&resp[0]))),
		length:      frameLen,
		speedHz:     p.speed,
		bitsPerWord: 8,
	}
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, p.f.Fd(),
		uintptr(spiIocMessage(1)), uintptr(unsafe.Pointer(&tr)))
	runtime.KeepAlive(frame)
	runtime.KeepAlive(resp)
	runtime.KeepAlive(tr)
	if errno != 0 {
		return nil, errno
	}
	return resp, nil
}

func (p *PNM) frame(rw bool, sel byte, data uint32) []byte {
	fr := make([]byte, frameLen)
	hdr := byte(sel & 0x7F)
	if rw {
		hdr |= 0x80
	}
	fr[0] = hdr
	binary.BigEndian.PutUint32(fr[1:5], data)
	return fr
}

// RegWrite stores value into register sel; errors on bad ack status.
func (p *PNM) RegWrite(sel byte, value uint32) error {
	resp, err := p.xfer(p.frame(false, sel, value))
	if err != nil {
		return err
	}
	if resp[5] != 0x01 {
		return fmt.Errorf("pi_bridge write-ack status 0x%02x", resp[5])
	}
	return nil
}

// RegRead fetches the current value of register sel.
func (p *PNM) RegRead(sel byte) (uint32, error) {
	resp, err := p.xfer(p.frame(true, sel, 0))
	if err != nil {
		return 0, err
	}
	if resp[5] != 0x00 {
		return 0, fmt.Errorf("pi_bridge read status 0x%02x", resp[5])
	}
	return binary.BigEndian.Uint32(resp[1:5]), nil
}

// BootDone signals the orchestrator that firmware boot completed.
func (p *PNM) BootDone() error { return p.RegWrite(selCtrl, ctrlBootDone) }

// DispatchCount reports the chip's dispatch counter.
func (p *PNM) DispatchCount() (uint32, error) { return p.RegRead(selDispatches) }

// Inject streams one flit into the chip (busy-waits while STATUS_BUSY).
func (p *PNM) Inject(layer, module byte, payload []byte) error {
	for {
		st, err := p.RegRead(selStatus)
		if err != nil {
			return err
		}
		if st&statusBusy == 0 {
			break
		}
	}
	if err := p.RegWrite(selLayer, uint32(layer)); err != nil {
		return err
	}
	if err := p.RegWrite(selModule, uint32(module)); err != nil {
		return err
	}
	if err := p.RegWrite(selLen, uint32(len(payload))); err != nil {
		return err
	}
	for _, b := range payload {
		if err := p.RegWrite(selData, uint32(b)); err != nil {
			return err
		}
	}
	return p.RegWrite(selCtrl, ctrlInject)
}

func main() {
	bus := flag.Int("bus", 0, "spidev bus number")
	dev := flag.Int("dev", 0, "spidev device number")
	speed := flag.Int("speed", 10_000_000, "SCLK rate in Hz")
	flag.Parse()

	pnm, err := Open(*bus, *dev, uint32(*speed))
	if err != nil {
		fmt.Fprintln(os.Stderr, "open:", err)
		os.Exit(1)
	}
	defer pnm.Close()

	const magic = uint32(0xDEADBEEF)
	if err := pnm.RegWrite(selLayer, magic); err != nil {
		fmt.Fprintln(os.Stderr, "write:", err)
		os.Exit(1)
	}
	got, err := pnm.RegRead(selLayer)
	if err != nil {
		fmt.Fprintln(os.Stderr, "read:", err)
		os.Exit(1)
	}
	status := "OK"
	if got != magic {
		status = "FAIL"
	}
	fmt.Printf("layer round-trip: wrote 0x%08x read 0x%08x -> %s\n",
		magic, got, status)
	n, _ := pnm.DispatchCount()
	fmt.Println("dispatches so far:", n)
}
