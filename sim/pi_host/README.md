# pi_host — Raspberry Pi Compute Module host drivers

Host-side tooling for talking to a PNM chassis through the SPI-to-PNM bridge
(`HDL/pi_bridge.v`). The same 48-bit frame protocol and register API is
implemented four times so any Pi image can drive the chassis, plus a separate
PCIe driver for CM5-class modules:

| File | Language | Deps | Transport | Target |
|------|----------|------|-----------|--------|
| `pnm_pi.py` | Python 3 | `spidev` | GPIO SPI | CM0/CM1/CM3/CM4 |
| `pnm_pi.go` | Go (stdlib only) | none | raw spidev ioctl | CM0/CM1/CM3/CM4 |
| `pnm_pi.rs` | Rust (no crates) | none | raw spidev ioctl | CM0/CM1/CM3/CM4 |
| `pnm_pi_spi.c` | C (no deps) | libc only | raw spidev ioctl | CM0/CM1/CM3/CM4 |
| `pnm_pi_cm5.c` + `pnm_pi.h` | C | libc only | PCIe BAR0 mmap | CM5 |

All five share identical semantics: `reg_read` / `reg_write` / `boot_done` /
`dispatch_count` / `inject`.

## Wiring (GPIO SPI path)

Bridge side signals map to the Pi's SPI0 header as follows (physical pins for
the 40-pin connector):

| Pi signal | Pin | Bridge pin |
|-----------|-----|------------|
| MOSI (GPIO10) | 19 | `mosi` |
| MISO (GPIO9)  | 21 | `miso` |
| SCLK (GPIO11) | 23 | `sclk` |
| CE0 (GPIO8)   | 24 | `cs_n` |
| 3V3           | 1  | logic supply rail |
| GND           | 6  | ground |

Enable the SPI overlay (`dtparam=spi=on`) so `/dev/spidev0.0` exists.
SPI mode 0; keep `--speed` at or below what the FPGA-side system clock can
settle (bridge needs roughly 10x the SCLK rate internally).

## Frame format

48 bits per frame, MSB first, full duplex:

```
byte 0   : header { rw(1b) << 7 | sel[6:0] }    rw=1 read, rw=0 write
bytes 1-4: 32-bit data field, MSB first
           write: value shifted in on MOSI
           read : register value returned on MISO
byte 5   : status byte returned by the bridge
           0x01 = write acknowledged, 0x00 = read ok
```

Register selectors (match the router-chip PNM window):

```
sel 0=CTRL 0x00  1=LAYER 0x04  2=MODULE 0x08   3=LEN 0x0C   4=DATA 0x10
sel 5=STATUS 0x14  6=RESULT 0x18  7=ERRORS 0x1C  8=DISPATCHES 0x20
sel 9=WEIGHT_FLITS 0x24
```

CTRL bits: bit 0 = INJECT (send the staged flit), bit 2 = BOOTDONE.

## Usage

Python:

```python
from pnm_pi import PNMPi, SEL_LAYER

with PNMPi(0, 0, 10_000_000) as pnm:
    pnm.reg_write(SEL_LAYER, 1)
    print(pnm.reg_read(SEL_LAYER))
    pnm.inject(layer=1, module=5, payload=b"\xaa\x55")
    pnm.boot_done()
```

Go:

```bash
go build -o pnm_pi_go pnm_pi.go        # or GOOS=linux GOARCH=arm64 go build ...
./pnm_pi_go -bus 0 -dev 0 -speed 10000000
```

Rust:

```bash
rustc -O --edition 2021 pnm_pi.rs -o pnm_pi_rs
./pnm_pi_rs --bus 0 --dev 0 --speed 10000000
```

C (SPI):

```bash
make demo CROSS=aarch64-linux-gnu-     # builds pnm_pi_spi_demo + pnm_pi_demo
./pnm_pi_spi_demo 0 0 10000000         # bus dev speed
```

C (CM5 PCIe): the PNM endpoint enumerates on the CM5's FPC Gen3 link; BAR0 is
the router register window. No kernel module needed:

```bash
./pnm_pi_demo /sys/bus/pci/devices/0001:01:00.0
```

Each CLI binary runs the same smoke test: write `0xDEADBEEF` to LAYER, read it
back, report the dispatch counter.
