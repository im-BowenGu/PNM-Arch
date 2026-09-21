// pnm_pi.rs — PNM router host driver for Raspberry Pi Compute Modules over SPI.
//
// Rust alternative to pnm_pi.py (same wire protocol, same register API).
// Zero external crates: raw extern "C" ioctl against the stable spidev ABI,
// builds with plain rustc on the Pi or any cross toolchain:
//
//	rustc -O --edition 2021 pnm_pi.rs -o pnm_pi_rs
//
// Targets CM0/CM1/CM3/CM4 class modules where pi_bridge (HDL/pi_bridge.v)
// is wired to a full SPI bus. Frame format (48 bits, MSB first, mode 0):
//
//	byte 0   : header {rw(1b) << 7 | sel[6:0]}   rw=1 read, rw=0 write
//	bytes 1-4: 32-bit data field, MSB first (sent on MOSI / returned on MISO)
//	byte 5   : status byte echoed back (0x01 write-ack, 0x00 read-ok)

use std::fs::OpenOptions;
use std::io;
use std::os::raw::{c_int, c_ulong, c_void};
use std::os::unix::io::AsRawFd;

const SEL_CTRL: u8 = 0x00;
const SEL_LAYER: u8 = 0x01;
const SEL_MODULE: u8 = 0x02;
const SEL_LEN: u8 = 0x03;
const SEL_DATA: u8 = 0x04;
const SEL_STATUS: u8 = 0x05;
#[allow(dead_code)]
const SEL_RESULT: u8 = 0x06;
#[allow(dead_code)]
const SEL_ERRORS: u8 = 0x07;
const SEL_DISPATCHES: u8 = 0x08;
#[allow(dead_code)]
const SEL_WEIGHTS: u8 = 0x09;

const CTRL_INJECT: u32 = 1 << 0;
const CTRL_BOOT_DONE: u32 = 1 << 2;

const STATUS_BUSY: u32 = 1 << 0;

const FRAME_LEN: usize = 6;

extern "C" {
    fn ioctl(fd: c_int, request: c_ulong, ...) -> c_int;
}

// Linux ioctl encoding (asm-generic), matching linux/spi/spidev.h.
const IOC_WRITE: c_ulong = 1;

const fn ioc(dir: c_ulong, typ: c_ulong, nr: c_ulong, size: c_ulong) -> c_ulong {
    (dir << 30) | (typ << 8) | (nr << 0) | (size << 16)
}

/// Mirrors struct spi_ioc_transfer (32 bytes, kernel ABI).
#[repr(C)]
#[derive(Default, Clone, Copy)]
struct SpiIocTransfer {
    tx_buf: u64,
    rx_buf: u64,
    len: u32,
    speed_hz: u32,
    delay_usecs: u16,
    bits_per_word: u8,
    cs_change: u8,
    tx_nbits: u8,
    rx_nbits: u8,
    pad: u16,
}

const SPI_IOC_TRANSFER_SIZE: c_ulong =
    core::mem::size_of::<SpiIocTransfer>() as c_ulong;

fn spi_ioc_message(n: usize) -> c_ulong {
    let mut size = (n as c_ulong) * SPI_IOC_TRANSFER_SIZE;
    const MAX: c_ulong = 1 << 14;
    if size > MAX {
        size = MAX;
    }
    ioc(IOC_WRITE, b'k' as c_ulong, 0, size)
}

const SPI_IOC_WR_MODE: c_ulong = ioc(IOC_WRITE, b'k' as c_ulong, 1, 1);
const SPI_IOC_WR_BITS_PER_WORD: c_ulong = ioc(IOC_WRITE, b'k' as c_ulong, 3, 1);
const SPI_IOC_WR_MAX_SPEED_HZ: c_ulong = ioc(IOC_WRITE, b'k' as c_ulong, 4, 4);

pub struct PnmSpi {
    file: std::fs::File,
    speed_hz: u32,
}

impl PnmSpi {
    pub fn open(bus: u8, dev: u8, speed_hz: u32) -> io::Result<Self> {
        let path = format!("/dev/spidev{}.{}", bus, dev);
        let file = OpenOptions::new().read(true).write(true).open(&path)?;
        let mut mode: u8 = 0; // SPI_MODE_0
        let mut bits: u8 = 8;
        let fd = file.as_raw_fd();
        unsafe {
            if ioctl(fd, SPI_IOC_WR_MODE, &mut mode as *mut u8 as *mut c_void) < 0 {
                return Err(io::Error::last_os_error());
            }
            if ioctl(fd, SPI_IOC_WR_BITS_PER_WORD, &mut bits as *mut u8 as *mut c_void) < 0 {
                return Err(io::Error::last_os_error());
            }
            let mut speed = speed_hz;
            if ioctl(
                fd,
                SPI_IOC_WR_MAX_SPEED_HZ,
                &mut speed as *mut u32 as *mut c_void,
            ) < 0
            {
                return Err(io::Error::last_os_error());
            }
        }
        Ok(PnmSpi { file, speed_hz })
    }

    /// Runs one full-duplex 48-bit frame and returns the MISO bytes.
    fn xfer(&self, frame: &[u8; FRAME_LEN]) -> io::Result<[u8; FRAME_LEN]> {
        let mut resp = [0u8; FRAME_LEN];
        let mut tr = SpiIocTransfer {
            tx_buf: frame.as_ptr() as u64,
            rx_buf: resp.as_mut_ptr() as u64,
            len: FRAME_LEN as u32,
            speed_hz: self.speed_hz,
            bits_per_word: 8,
            ..Default::default()
        };
        let rc = unsafe {
            ioctl(
                self.file.as_raw_fd(),
                spi_ioc_message(1),
                &mut tr as *mut SpiIocTransfer as *mut c_void,
            )
        };
        if rc < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(resp)
    }

    fn frame(rw: bool, sel: u8, data: u32) -> [u8; FRAME_LEN] {
        let mut fr = [0u8; FRAME_LEN];
        fr[0] = if rw { 0x80 | (sel & 0x7F) } else { sel & 0x7F };
        fr[1..5].copy_from_slice(&data.to_be_bytes());
        fr
    }

    pub fn reg_write(&self, sel: u8, value: u32) -> io::Result<()> {
        let resp = self.xfer(&Self::frame(false, sel, value))?;
        if resp[5] != 0x01 {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                format!("pi_bridge write-ack status 0x{:02x}", resp[5]),
            ));
        }
        Ok(())
    }

    pub fn reg_read(&self, sel: u8) -> io::Result<u32> {
        let resp = self.xfer(&Self::frame(true, sel, 0))?;
        if resp[5] != 0x00 {
            return Err(io::Error::new(
                io::ErrorKind::Other,
                format!("pi_bridge read status 0x{:02x}", resp[5]),
            ));
        }
        Ok(u32::from_be_bytes([resp[1], resp[2], resp[3], resp[4]]))
    }

    pub fn boot_done(&self) -> io::Result<()> {
        self.reg_write(SEL_CTRL, CTRL_BOOT_DONE)
    }

    pub fn dispatch_count(&self) -> io::Result<u32> {
        self.reg_read(SEL_DISPATCHES)
    }

    pub fn inject(&self, layer: u8, module: u8, payload: &[u8]) -> io::Result<()> {
        while self.reg_read(SEL_STATUS)? & STATUS_BUSY != 0 {}
        self.reg_write(SEL_LAYER, layer as u32)?;
        self.reg_write(SEL_MODULE, module as u32)?;
        self.reg_write(SEL_LEN, payload.len() as u32)?;
        for b in payload {
            self.reg_write(SEL_DATA, *b as u32)?;
        }
        self.reg_write(SEL_CTRL, CTRL_INJECT)
    }
}

fn arg_u32(name: &str, default: u32) -> u32 {
    let args: Vec<String> = std::env::args().collect();
    for (i, a) in args.iter().enumerate() {
        if a == name {
            if let Some(v) = args.get(i + 1) {
                if let Ok(n) = v.parse() {
                    return n;
                }
            }
        }
    }
    default
}

fn main() {
    let bus = arg_u32("--bus", 0) as u8;
    let dev = arg_u32("--dev", 0) as u8;
    let speed = arg_u32("--speed", 10_000_000);

    let pnm = match PnmSpi::open(bus, dev, speed) {
        Ok(p) => p,
        Err(e) => {
            eprintln!("open: {}", e);
            std::process::exit(1);
        }
    };

    const MAGIC: u32 = 0xDEADBEEF;
    if let Err(e) = pnm.reg_write(SEL_LAYER, MAGIC) {
        eprintln!("write: {}", e);
        std::process::exit(1);
    }
    match pnm.reg_read(SEL_LAYER) {
        Ok(got) => {
            println!(
                "layer round-trip: wrote 0x{:08x} read 0x{:08x} -> {}",
                MAGIC,
                got,
                if got == MAGIC { "OK" } else { "FAIL" }
            );
        }
        Err(e) => {
            eprintln!("read: {}", e);
            std::process::exit(1);
        }
    }
    if let Ok(n) = pnm.dispatch_count() {
        println!("dispatches so far: {}", n);
    }
}
