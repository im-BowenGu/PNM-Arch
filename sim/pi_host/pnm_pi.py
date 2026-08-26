#!/usr/bin/env python3
"""pnm_pi.py — PNM router host driver for Raspberry Pi Compute Modules over SPI.

Targets CM0/CM1/CM3/CM4 class modules where the PNM pi_bridge is wired to a
full SPI bus (spidev). For CM5 prefer pnm_pi_cm5.c (PCIe BAR access); this
module still works there through the SPI pins if wired.

Frame format (48 bits, matches HDL/pi_bridge.v):
    byte 0   : header {rw(1b) << 7 | sel[6:0]}     rw=1 read, rw=0 write
    bytes 1-4: 32-bit data field, MSB first
               write: value sent to the bridge
               read : register value returned by the bridge on MISO
    byte 5   : status byte echoed back by the bridge (0x01 write-ack,
               0x00 read-ok)

Requires: spidev (kernel module spi_bcm2835 enabled, spidev device present).
The bridge needs the system clock >= ~10x SCLK; keep max_speed_hz at or
below what the FPGA side can settle.
"""

import time

SPI_MODE_0 = 0

SEL_CTRL = 0x00
SEL_LAYER = 0x01
SEL_MODULE = 0x02
SEL_LEN = 0x03
SEL_DATA = 0x04
SEL_STATUS = 0x05
SEL_RESULT = 0x06
SEL_ERRORS = 0x07
SEL_DISPATCHES = 0x08
SEL_WEIGHTS = 0x09

CTRL_INJECT = 1 << 0
CTRL_BOOTDONE = 1 << 2

STATUS_BUSY = 1 << 0


class PNMPi:
    """Host-side register access to a PNM chassis through pi_bridge."""

    def __init__(self, bus=0, device=0, speed_hz=10_000_000):
        import spidev

        self._spi = spidev.SpiDev()
        self._spi.open(bus, device)
        self._spi.mode = SPI_MODE_0
        self._spi.max_speed_hz = speed_hz
        self._spi.bits_per_word = 8

    def close(self):
        self._spi.close()

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def _frame(self, rw, sel, data=0):
        hdr = ((rw & 1) << 7) | (sel & 0x7F)
        return bytes([hdr]) + data.to_bytes(4, "big") + b"\x00"

    def reg_write(self, sel, value):
        resp = self._spi.xfer2(self._frame(0, sel, value & 0xFFFFFFFF))
        status = resp[5]
        if status != 0x01:
            raise IOError("pi_bridge write-ack status 0x%02x" % status)

    def reg_read(self, sel):
        resp = self._spi.xfer2(self._frame(1, sel))
        if resp[5] != 0x00:
            raise IOError("pi_bridge read status 0x%02x" % resp[5])
        return int.from_bytes(resp[1:5], "big")

    def boot_done(self):
        self.reg_write(SEL_CTRL, CTRL_BOOTDONE)

    def dispatch_count(self):
        return self.reg_read(SEL_DISPATCHES)

    def inject(self, layer, module, payload):
        while self.reg_read(SEL_STATUS) & STATUS_BUSY:
            time.sleep(0)
        self.reg_write(SEL_LAYER, layer & 0xFF)
        self.reg_write(SEL_MODULE, module & 0xFF)
        self.reg_write(SEL_LEN, len(payload))
        for b in payload:
            self.reg_write(SEL_DATA, b)
        self.reg_write(SEL_CTRL, CTRL_INJECT)


def main():
    import argparse

    ap = argparse.ArgumentParser(description="PNM pi_bridge smoke test")
    ap.add_argument("--bus", type=int, default=0)
    ap.add_argument("--dev", type=int, default=0)
    ap.add_argument("--speed", type=int, default=10_000_000)
    args = ap.parse_args()

    with PNMPi(args.bus, args.dev, args.speed) as pnm:
        magic = 0xDEADBEEF
        pnm.reg_write(SEL_LAYER, magic)
        got = pnm.reg_read(SEL_LAYER)
        print("layer round-trip: wrote 0x%08x read 0x%08x -> %s"
              % (magic, got, "OK" if got == magic else "FAIL"))
        print("dispatches so far:", pnm.dispatch_count())


if __name__ == "__main__":
    main()
