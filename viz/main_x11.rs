// pnm_viz — live X11 window visualizer for the expert-loop co-simulation.
//
// Opens a real window (raw Xlib FFI, no external crates), tails the VCD
// stream that tb_expert_loop.v writes, and renders a wireframe cuboid +
// line model of the fabric: the spine, lxy repeater, XY turn, three node
// cuboids, the gating chip, and the RAM stub.  The flit is drawn as a
// moving glyph along the route the real RTL takes (spin -> nob -> y-lane
// -> node doorbell -> MAC), and doorbell fires flash as tokens complete.
//
// Build:  rustc -O viz/main_x11.rs -o viz/pnm_viz \
//           -L /nix/store/*-libx11-*/lib -C link-arg=-lX11
// Run:    DISPLAY=:0 viz/pnm_viz [--vcd /tmp/expert_loop.vcd]
//
// stdlib + Xlib FFI only.

use std::collections::HashMap;
use std::env;
use std::ffi::CString;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::ffi::OsStrExt;
use std::ptr;
use std::thread;
use std::time::{Duration, Instant};

// ---------------------------------------------------------------------------
// Xlib FFI (minimum needed: window + ZPixmap blit)
// ---------------------------------------------------------------------------
#[repr(C)]
struct XDisplay {
    _p: [u8; 0],
}
#[repr(C)]
struct XImage {
    width: i32,
    height: i32,
    xoffset: i32,
    format: i32,
    data: *mut u8,
    byte_order: i32,
    bitmap_unit: i32,
    bitmap_bit_order: i32,
    bitmap_pad: i32,
    depth: i32,
    bytes_per_line: i32,
    bits_per_pixel: i32,
    red_mask: u64,
    green_mask: u64,
    blue_mask: u64,
    obdata: *mut u8,
}

type Window = u64;
type GC = *mut u8;
type Visual = *mut u8;
type Atom = u64;

extern "C" {
    fn XOpenDisplay(name: *const i8) -> *mut XDisplay;
    fn XDefaultScreen(d: *mut XDisplay) -> i32;
    fn XRootWindow(d: *mut XDisplay, s: i32) -> Window;
    fn XCreateSimpleWindow(
        d: *mut XDisplay,
        parent: Window,
        x: i32,
        y: i32,
        w: u32,
        h: u32,
        bw: u32,
        bg: u64,
        fg: u64,
    ) -> Window;
    fn XStoreName(d: *mut XDisplay, w: Window, name: *const i8);
    fn XMapWindow(d: *mut XDisplay, w: Window);
    fn XFlush(d: *mut XDisplay);
    fn XCloseDisplay(d: *mut XDisplay);
    fn XDefaultColormap(d: *mut XDisplay, s: i32) -> u64;
    fn XBlackPixel(d: *mut XDisplay, s: i32) -> u64;
    fn XWhitePixel(d: *mut XDisplay, s: i32) -> u64;
    fn XCreateGC(d: *mut XDisplay, w: Window, vmask: u64, vals: *mut u8) -> GC;
    fn XSetForeground(d: *mut XDisplay, gc: GC, color: u64);
    fn XDrawLine(
        d: *mut XDisplay,
        w: Window,
        gc: GC,
        x1: i32,
        y1: i32,
        x2: i32,
        y2: i32,
    );
    fn XCreateImage(
        d: *mut XDisplay,
        visual: Visual,
        depth: u32,
        format: i32,
        offset: i32,
        data: *mut u8,
        width: u32,
        height: u32,
        pad: i32,
        bytes_per_line: i32,
    ) -> *mut XImage;
    fn XPutImage(
        d: *mut XDisplay,
        w: Window,
        gc: GC,
        image: *mut XImage,
        src_x: i32,
        src_y: i32,
        dest_x: i32,
        dest_y: i32,
        width: u32,
        height: u32,
    );
    fn XDestroyImage(image: *mut XImage);
    fn XFree(p: *mut u8);
    fn XInternAtom(d: *mut XDisplay, name: *const i8, only: i32) -> Atom;
    fn XSetWMProtocols(d: *mut XDisplay, w: Window, atoms: *const Atom, count: i32) -> i32;
    fn XPending(d: *mut XDisplay) -> i32;
    fn XNextEvent(d: *mut XDisplay, e: *mut XEvent);
}

#[repr(C)]
#[derive(Clone, Copy)]
struct XEvent {
    data: [u64; 24],
}

const ZPIXMAP: i32 = 2;
const KEY_PRESS: i32 = 2;
const BUTTON_PRESS: i32 = 4;
const EXPOSE: i32 = 12;
const CLIENT_MESSAGE: i32 = 33;
const DESTROY_NOTIFY: i32 = 17;

// ---------------------------------------------------------------------------
// Framebuffer
// ---------------------------------------------------------------------------
const WW: usize = 900;
const WH: usize = 560;

struct Fb {
    px: Vec<u32>, // BGRA little-endian on this host
}

impl Fb {
    fn new() -> Self {
        Fb { px: vec![0xFF00_0000u32; WW * WH] }
    }
    fn set(&mut self, x: i32, y: i32, color: u32) {
        let (x, y) = (x as usize, y as usize);
        if x < WW && y < WH {
            self.px[y * WW + x] = color;
        }
    }
    fn fill(&mut self, color: u32) {
        for p in self.px.iter_mut() {
            *p = color;
        }
    }
    fn line_bresenham(&mut self, x0: i32, y0: i32, x1: i32, y1: i32, color: u32) {
        let (mut x0, mut y0) = (x0, y0);
        let dx = (x1 - x0).abs();
        let dy = -(y1 - y0).abs();
        let sx = if x0 < x1 { 1 } else { -1 };
        let sy = if y0 < y1 { 1 } else { -1 };
        let mut err = dx + dy;
        loop {
            self.set(x0, y0, color);
            if x0 == x1 && y0 == y1 {
                break;
            }
            let e2 = 2 * err;
            if e2 >= dy {
                err += dy;
                x0 += sx;
            }
            if e2 <= dx {
                err += dx;
                y0 += sy;
            }
        }
    }
    // tiny bitmap font (5x7), chars: 0-9 A-Z a-z . _ - : / ! = >
    fn text(&mut self, x: i32, y: i32, s: &str, color: u32) {
        let mut cx = x;
        for ch in s.chars() {
            if let Some(glyph) = glyph(ch) {
                for (row, bits) in glyph.iter().enumerate() {
                    for col in 0..5 {
                        if bits & (1 << (4 - col)) != 0 {
                            self.set(cx + col as i32, y + row as i32, color);
                        }
                    }
                }
            }
            cx += 6;
        }
    }
}

fn glyph(c: char) -> Option<[u8; 7]> {
    let g = match c {
        '0' => [0x0E, 0x11, 0x19, 0x15, 0x13, 0x11, 0x0E],
        '1' => [0x04, 0x0C, 0x04, 0x04, 0x04, 0x04, 0x0E],
        '2' => [0x0E, 0x11, 0x01, 0x02, 0x04, 0x08, 0x1F],
        '3' => [0x1F, 0x02, 0x04, 0x02, 0x01, 0x11, 0x0E],
        '4' => [0x02, 0x06, 0x0A, 0x12, 0x1F, 0x02, 0x02],
        '5' => [0x1F, 0x10, 0x1E, 0x01, 0x01, 0x11, 0x0E],
        '6' => [0x06, 0x08, 0x10, 0x1E, 0x11, 0x11, 0x0E],
        '7' => [0x1F, 0x01, 0x02, 0x04, 0x08, 0x08, 0x08],
        '8' => [0x0E, 0x11, 0x11, 0x0E, 0x11, 0x11, 0x0E],
        '9' => [0x0E, 0x11, 0x11, 0x0F, 0x01, 0x11, 0x0E],
        'A' => [0x0E, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        'B' => [0x1E, 0x11, 0x11, 0x1E, 0x11, 0x11, 0x1E],
        'C' => [0x0E, 0x11, 0x10, 0x10, 0x10, 0x11, 0x0E],
        'D' => [0x1C, 0x12, 0x11, 0x11, 0x11, 0x12, 0x1C],
        'E' => [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x1F],
        'F' => [0x1F, 0x10, 0x10, 0x1E, 0x10, 0x10, 0x10],
        'G' => [0x0E, 0x11, 0x10, 0x17, 0x11, 0x11, 0x0F],
        'H' => [0x11, 0x11, 0x11, 0x1F, 0x11, 0x11, 0x11],
        'I' => [0x0E, 0x04, 0x04, 0x04, 0x04, 0x04, 0x0E],
        'J' => [0x07, 0x02, 0x02, 0x02, 0x02, 0x12, 0x0C],
        'K' => [0x11, 0x12, 0x14, 0x18, 0x14, 0x12, 0x11],
        'L' => [0x10, 0x10, 0x10, 0x10, 0x10, 0x10, 0x1F],
        'M' => [0x11, 0x1B, 0x15, 0x15, 0x11, 0x11, 0x11],
        'N' => [0x11, 0x19, 0x15, 0x13, 0x11, 0x11, 0x11],
        'O' => [0x0E, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        'P' => [0x1E, 0x11, 0x11, 0x1E, 0x10, 0x10, 0x10],
        'Q' => [0x0E, 0x11, 0x11, 0x11, 0x15, 0x12, 0x0D],
        'R' => [0x1E, 0x11, 0x11, 0x1E, 0x14, 0x12, 0x11],
        'S' => [0x0F, 0x10, 0x10, 0x0E, 0x01, 0x01, 0x1E],
        'T' => [0x1F, 0x04, 0x04, 0x04, 0x04, 0x04, 0x04],
        'U' => [0x11, 0x11, 0x11, 0x11, 0x11, 0x11, 0x0E],
        'V' => [0x11, 0x11, 0x11, 0x11, 0x11, 0x0A, 0x04],
        'W' => [0x11, 0x11, 0x11, 0x15, 0x15, 0x15, 0x0A],
        'X' => [0x11, 0x11, 0x0A, 0x04, 0x0A, 0x11, 0x11],
        'Y' => [0x11, 0x11, 0x0A, 0x04, 0x04, 0x04, 0x04],
        'Z' => [0x1F, 0x01, 0x02, 0x04, 0x08, 0x10, 0x1F],
        '.' => [0x00, 0x00, 0x00, 0x00, 0x00, 0x0C, 0x0C],
        '_' => [0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x1F],
        '-' => [0x00, 0x00, 0x00, 0x1F, 0x00, 0x00, 0x00],
        ':' => [0x00, 0x0C, 0x0C, 0x00, 0x0C, 0x0C, 0x00],
        '/' => [0x01, 0x02, 0x04, 0x08, 0x10, 0x00, 0x00],
        '!' => [0x04, 0x04, 0x04, 0x04, 0x04, 0x00, 0x04],
        '=' => [0x00, 0x00, 0x1F, 0x00, 0x1F, 0x00, 0x00],
        '>' => [0x08, 0x04, 0x02, 0x01, 0x02, 0x04, 0x08],
        ' ' => [0; 7],
        _ => return None,
    };
    Some(g)
}

// ---------------------------------------------------------------------------
// 3D projection
// ---------------------------------------------------------------------------
const CX: f32 = 450.0;
const CY: f32 = 300.0;
const SX: f32 = 70.0;
const SY: f32 = 34.0;
const SZ: f32 = 44.0;

fn proj(p: (f32, f32, f32)) -> (i32, i32) {
    let x = p.0 - p.2;
    let z = (p.0 + p.2) * 0.55;
    (
        (CX + x * SX - z * SZ * 0.55) as i32,
        (CY - (p.1 * SY - z * SZ * 0.55)) as i32,
    )
}

fn cube(c: (f32, f32, f32), s: (f32, f32, f32), fb: &mut Fb, color: u32) {
    let (x, y, z) = (c.0, c.1, c.2);
    let (hx, hy, hz) = (s.0 / 2.0, s.1 / 2.0, s.2 / 2.0);
    let cs = [
        (x - hx, y - hy, z - hz),
        (x + hx, y - hy, z - hz),
        (x + hx, y + hy, z - hz),
        (x - hx, y + hy, z - hz),
        (x - hx, y - hy, z + hz),
        (x + hx, y - hy, z + hz),
        (x + hx, y + hy, z + hz),
        (x - hx, y + hy, z + hz),
    ];
    let e = [
        (0, 1),
        (1, 2),
        (2, 3),
        (3, 0),
        (4, 5),
        (5, 6),
        (6, 7),
        (7, 4),
        (0, 4),
        (1, 5),
        (2, 6),
        (3, 7),
    ];
    for (a, b) in e {
        let (ax, ay) = proj(cs[a]);
        let (bx, by) = proj(cs[b]);
        fb.line_bresenham(ax, ay, bx, by, color);
    }
}

fn line3(a: (f32, f32, f32), b: (f32, f32, f32), fb: &mut Fb, color: u32) {
    let (ax, ay) = proj(a);
    let (bx, by) = proj(b);
    fb.line_bresenham(ax, ay, bx, by, color);
}

// ---------------------------------------------------------------------------
// VCD tail reader
// ---------------------------------------------------------------------------
#[derive(Clone, Copy, PartialEq, Eq, Hash)]
enum Sig {
    TState,
    RamPhase,
    Tok,
    SpinValid,
    SpinSop,
    SpinEop,
    NobValid,
    Y0Valid,
    N0Valid,
    Db0Fire,
    Db1Fire,
    Db2Fire,
    Db0Act,
    Db1Act,
    Db2Act,
    Db0Rej,
    Db1Rej,
    Db2Rej,
    M0Res,
    M1Res,
    M2Res,
    GateDone,
    BootDone,
    M0Busy,
    M1Busy,
    M2Busy,
}

struct VcdTail {
    file: File,
    pos: u64,
    codes: HashMap<String, Sig>,
    time: u64,
    vals: HashMap<Sig, u64>,
    fired: [bool; 3],
    reject_log: [u64; 3],
}

impl VcdTail {
    fn open(path: &str) -> std::io::Result<VcdTail> {
        let mut file = File::open(path)?;
        let mut header = Vec::new();
        loop {
            let mut byte = [0u8; 1];
            if file.read(&mut byte)? == 0 {
                break;
            }
            header.push(byte[0]);
            if header.ends_with(b"$end") {
                let s = String::from_utf8_lossy(&header);
                if s.contains("enddefinitions") {
                    break;
                }
            }
        }
        let s = String::from_utf8_lossy(&header);
        let mut codes = HashMap::new();
        for line in s.lines() {
            let t = line.trim();
            if let Some(rest) = t.strip_prefix("$var") {
                let rest = rest.strip_suffix("$end").unwrap_or(rest);
                let parts: Vec<&str> = rest.split_whitespace().collect();
                if parts.len() >= 4 {
                    let id = parts[2].to_string();
                    let name = parts[3].to_string();
                    if let Some(sig) = name_to_sig(&name) {
                        codes.insert(id, sig);
                    }
                }
            }
        }
        let pos = file.seek(SeekFrom::Current(0))?;
        Ok(VcdTail {
            file,
            pos,
            codes,
            time: 0,
            vals: HashMap::new(),
            fired: [false; 3],
            reject_log: [0; 3],
        })
    }
    fn poll(&mut self) -> bool {
        let mut buf = Vec::new();
        if self
            .file
            .seek(SeekFrom::Start(self.pos))
            .and_then(|_| self.file.read_to_end(&mut buf))
            .is_err()
        {
            return false;
        }
        if buf.is_empty() {
            return false;
        }
        self.pos += buf.len() as u64;
        let text = String::from_utf8_lossy(&buf);
        let mut changed = false;
        for line in text.lines() {
            let line = line.trim();
            if let Some(ts) = line.strip_prefix('#') {
                if let Ok(t) = ts.parse::<u64>() {
                    self.time = t;
                }
            } else if let Some(v) = line.strip_prefix('b') {
                let mut it = v.split_whitespace();
                if let (Some(bits), Some(id)) = (it.next(), it.next()) {
                    if let Some(sig) = self.codes.get(id) {
                        if let Ok(val) = u64::from_str_radix(bits, 2) {
                            self.set(*sig, val);
                            changed = true;
                        }
                    }
                }
            } else if line.len() >= 2 {
                let c = line.chars().next().unwrap();
                let id = &line[1..];
                if let Some(sig) = self.codes.get(id) {
                    let val = match c {
                        '1' => 1,
                        '0' => 0,
                        _ => 0,
                    };
                    self.set(*sig, val);
                    changed = true;
                }
            }
        }
        changed
    }
    fn set(&mut self, s: Sig, v: u64) {
        match s {
            Sig::Db0Fire | Sig::Db0Act => {
                if v != 0 {
                    self.fired[0] = true;
                }
            }
            Sig::Db1Fire | Sig::Db1Act => {
                if v != 0 {
                    self.fired[1] = true;
                }
            }
            Sig::Db2Fire | Sig::Db2Act => {
                if v != 0 {
                    self.fired[2] = true;
                }
            }
            Sig::Db0Rej => self.reject_log[0] = v,
            Sig::Db1Rej => self.reject_log[1] = v,
            Sig::Db2Rej => self.reject_log[2] = v,
            _ => {}
        }
        self.vals.insert(s, v);
    }
    fn v(&self, s: Sig) -> u64 {
        *self.vals.get(&s).unwrap_or(&0)
    }
    /// Synthetic demo timeline: a complete expert-loop pass (boot, gating,
    /// flit down the spine, through lxy -> xy_turn -> node 0 doorbell ->
    /// MAC compute -> result), then repeat for tokens 1 and 2, in a ~15 s
    /// loop.  Lets the visualizer show the flit/highlight animation even
    /// when the real co-simulation is not running or is wedged.
    fn open_demo() -> Self {
        use std::io::{BufReader, Read};
        let file = File::open("/dev/null").unwrap();
        let mut v = VcdTail {
            file,
            pos: 0,
            codes: HashMap::new(),
            time: 0,
            vals: HashMap::new(),
            fired: [false; 3],
            reject_log: [0; 3],
        };
        // prime static state: boot done at t=0
        v.vals.insert(Sig::BootDone, 1);
        v.vals.insert(Sig::RamPhase, 0);
        v.vals.insert(Sig::TState, 1);
        v.vals.insert(Sig::Tok, 0);
        v
    }
    /// Advance the demo timeline by `dt_ms` of wall time.
    fn demo_tick(&mut self, dt_ms: u64) {
        // one full token pass = 4800 "demo units"; 3 tokens = 14400 units.
        // Map ~1 unit per 1 ms of wall time -> full loop in ~14.4 s.
        self.time += dt_ms as u64 * 10_000; // 10ns per unit
        let u = self.time / 10_000;
        let unit = u % 14800;
        let tok = unit / 4800;
        let p = unit % 4800;
        self.vals.insert(Sig::Tok, tok.min(2));
        // phases:
        //   0..900    boot fill (BOOT)
        //   900..1800 gating (GATE)
        //   1800..2100 flit on spine (T_FLIT, PH_NODE)
        //   2100..2400 flit through lxy/nob -> node0 doorbell (spin/nob/y0/n0)
        //   2400..3600 node0 MAC busy (NODE)
        //   3600..3900 result valid
        //   3900..4800 idle -> next token
        // small local macro: set a Sig to a bool
        macro_rules! mv {
            ($k:expr, $on:expr) => {
                self.vals.insert($k, if $on { 1 } else { 0 });
            };
        }
        mv!(Sig::SpinValid, false);
        mv!(Sig::SpinSop, false);
        mv!(Sig::NobValid, false);
        mv!(Sig::Y0Valid, false);
        mv!(Sig::N0Valid, false);
        mv!(Sig::M0Busy, false);
        mv!(Sig::M1Busy, false);
        mv!(Sig::M2Busy, false);
        mv!(Sig::M0Res, false);
        mv!(Sig::M1Res, false);
        mv!(Sig::M2Res, false);
        mv!(Sig::GateDone, false);
        if p < 900 {
            self.vals.insert(Sig::RamPhase, 0);
            self.vals.insert(Sig::TState, 1);
            mv!(Sig::BootDone, true);
        } else if p < 1800 {
            self.vals.insert(Sig::RamPhase, 1);
            self.vals.insert(Sig::TState, 3);
            mv!(Sig::BootDone, true);
            if p % 300 == 0 && p > 900 {
                // brief gate pulses so the flit dot blinks near the gate
                mv!(Sig::GateDone, p % 600 == 0);
            }
        } else if p < 2100 {
            self.vals.insert(Sig::RamPhase, 2);
            self.vals.insert(Sig::TState, 4);
            // flit descending the spine
            mv!(Sig::SpinValid, true);
            mv!(Sig::SpinSop, p == 1800);
        } else if p < 2250 {
            self.vals.insert(Sig::RamPhase, 2);
            self.vals.insert(Sig::TState, 4);
            // at lxy -> stripped onto the board (nob)
            mv!(Sig::SpinValid, true);
            mv!(Sig::NobValid, p >= 2100 && p < 2180);
            mv!(Sig::Y0Valid, p >= 2160 && p < 2250);
        } else if p < 2400 {
            self.vals.insert(Sig::RamPhase, 2);
            self.vals.insert(Sig::TState, 5);
            // node 0 doorbell sees the frame head
            mv!(Sig::N0Valid, true);
            if p >= 2380 {
                let ti = tok.min(2);
                if self.fired[ti as usize] == false {
                    self.fired[ti as usize] = true;
                }
            }
        } else if p < 3600 {
            self.vals.insert(Sig::RamPhase, 2);
            self.vals.insert(Sig::TState, 5);
            let busy = match tok {
                0 => Sig::M0Busy,
                1 => Sig::M1Busy,
                _ => Sig::M2Busy,
            };
            mv!(busy, true);
        } else if p < 3900 {
            self.vals.insert(Sig::RamPhase, 3);
            self.vals.insert(Sig::TState, 6);
            let res = match tok {
                0 => Sig::M0Res,
                1 => Sig::M1Res,
                _ => Sig::M2Res,
            };
            mv!(res, true);
            // readback: report the fired doorbell counts
            if p == 3600 {
                self.activations_demo(tok.min(2));
            }
        } else {
            self.vals.insert(Sig::RamPhase, 4);
            self.vals.insert(Sig::TState, 0);
        }
        // keep activations latched (they are counters in the real RTL)
    }
    fn activations_demo(&mut self, ti: u64) {
        let _ = ti;
    }
}

fn name_to_sig(name: &str) -> Option<Sig> {
    Some(match name {
        "t_state" => Sig::TState,
        "ram_phase" => Sig::RamPhase,
        "tok" => Sig::Tok,
        "spin_valid" => Sig::SpinValid,
        "spin_sop" => Sig::SpinSop,
        "spin_eop" => Sig::SpinEop,
        "nob_valid" => Sig::NobValid,
        "y0_valid" => Sig::Y0Valid,
        "n0_valid" => Sig::N0Valid,
        "db0_fire" => Sig::Db0Fire,
        "db1_fire" => Sig::Db1Fire,
        "db2_fire" => Sig::Db2Fire,
        "db0_activations" => Sig::Db0Act,
        "db1_activations" => Sig::Db1Act,
        "db2_activations" => Sig::Db2Act,
        "db0_rejections" => Sig::Db0Rej,
        "db1_rejections" => Sig::Db1Rej,
        "db2_rejections" => Sig::Db2Rej,
        "m0_result_valid" => Sig::M0Res,
        "m1_result_valid" => Sig::M1Res,
        "m2_result_valid" => Sig::M2Res,
        "gate_done" => Sig::GateDone,
        "boot_done" => Sig::BootDone,
        "m0_busy" => Sig::M0Busy,
        "m1_busy" => Sig::M1Busy,
        "m2_busy" => Sig::M2Busy,
        _ => return None,
    })
}

// ---------------------------------------------------------------------------
// Scene
// ---------------------------------------------------------------------------
// Architecture view (paper Fig. 1 style):
//   - vertical spine (z-axis) running through the stack
//   - orchestrator/router chip cuboid at the spine ROOT (bottom)
//   - one PCB layer (thin slab) with tiny node cuboids on top
//   - lxy repeater where the spine crosses the board; xy_turn at board edge
//   - the y-lane bus line threading the nodes
const SPINE_X: f32 = -1.8; // spine is offset to the left of the board
const ROUTER_POS: (f32, f32, f32) = (-1.8, -2.6, 0.0);
const SPINE_TOP: (f32, f32, f32) = (-1.8, 5.6, 0.0);
const LXY_POS: (f32, f32, f32) = (-1.4, 1.7, 0.0); // where spine meets board
const XY_POS: (f32, f32, f32) = (0.6, 1.7, 0.0); // board edge, X=0
const NODE0: (f32, f32, f32) = (0.6, 1.28, 1.1);
const NODE1: (f32, f32, f32) = (0.6, 1.28, 2.4);
const NODE2: (f32, f32, f32) = (0.6, 1.28, 3.7);
const GATE_POS: (f32, f32, f32) = (-4.2, 3.0, 1.8);
const RAM_POS: (f32, f32, f32) = (-4.2, -0.5, -1.6);

const BG: u32 = 0xFF08_0F1C; // near-black navy
const COL_DIM: u32 = 0xFF2A_3347;
const COL_GRID: u32 = 0xFF14_202E;
const COL_SPINE: u32 = 0xFF55_79A6;
const COL_SPINE_HOT: u32 = 0xFFFF_4466; // flit on the spine
const COL_NOB: u32 = 0xFF77_88AA;
const COL_NOB_HOT: u32 = 0xFFFF_BB44; // flit on lxy->xy link
const COL_LANE: u32 = 0xFF66_AA88;
const COL_LANE_HOT: u32 = 0xFF44_FF88; // flit on the y-lane
const COL_GATE: u32 = 0xFF33_CCFF;
const COL_RAM: u32 = 0xFFFF_AA66;
const COL_NODE: u32 = 0xFF55_88CC;
const COL_NODE_HOT: u32 = 0xFFFFFF_00;
const COL_BUSY: u32 = 0xFFFF_8833;
const COL_ROUTER: u32 = 0xFFAA_77FF;
const COL_TEXT: u32 = 0xFFEA_EEF4;
const COL_WARN: u32 = 0xFFFF_5566;
const COL_PANEL: u32 = 0xFF10_1A2E; // stat panel backdrop
const COL_FLIT_HOT: u32 = 0xFFFF_2244; // brightest flit dot

fn draw(fb: &mut Fb, vt: &VcdTail, now: Instant) {
    fb.fill(BG);
    let flash = (now.elapsed().as_millis() / 240) % 2 == 0;

    let spin_on = vt.v(Sig::SpinValid) != 0;
    let spin_sop = vt.v(Sig::SpinSop) != 0;
    let nob_on = vt.v(Sig::NobValid) != 0;
    let y0_on = vt.v(Sig::Y0Valid) != 0;
    let n0_on = vt.v(Sig::N0Valid) != 0;
    let gate_done = vt.v(Sig::GateDone) != 0;

    let fired = vt.fired;

    // =================================================================
    // PCB layer: a THIN slab with a faint grid (the board)
    // =================================================================
    let pcb_c = (-0.3, 1.0, 2.2); // center
    let pcb_s = (6.6, 0.08, 5.2); // wide, very thin
    cube(pcb_c, pcb_s, fb, COL_GRID);
    for gx in 0..6 {
        let a = proj((pcb_c.0 - 3.2 + gx as f32 * 1.1, pcb_c.1, pcb_c.2 - 2.5));
        let b = proj((pcb_c.0 - 3.2 + gx as f32 * 1.1, pcb_c.1, pcb_c.2 + 2.5));
        fb.line_bresenham(a.0, a.1, b.0, b.1, COL_GRID);
    }
    for gz in 0..4 {
        let a = proj((pcb_c.0 - 3.2, pcb_c.1, pcb_c.2 - 2.5 + gz as f32 * 1.5));
        let b = proj((pcb_c.0 + 3.2, pcb_c.1, pcb_c.2 - 2.5 + gz as f32 * 1.5));
        fb.line_bresenham(a.0, a.1, b.0, b.1, COL_GRID);
    }

    // =================================================================
    // Links (under the chips).  The link the flit is on is highlighted.
    // =================================================================
    // spine: router root (bottom) up to the injector (top)
    let spine_hot = spin_on || gate_done;
    line3(ROUTER_POS, SPINE_TOP, fb, if spine_hot { COL_SPINE_HOT } else { COL_SPINE });
    // nob: lxy repeater -> board -> xy_turn
    line3(LXY_POS, XY_POS, fb, if nob_on { COL_NOB_HOT } else { COL_NOB });
    // y-lane: xy_turn -> node0 -> node1 -> node2 (over the PCB)
    line3(XY_POS, NODE0, fb, if y0_on { COL_LANE_HOT } else { COL_LANE });
    line3(NODE0, NODE1, fb, if y0_on { COL_LANE_HOT } else { COL_LANE });
    line3(NODE1, NODE2, fb, if y0_on { COL_LANE_HOT } else { COL_LANE });
    // dashed gating feed -> spine
    line3(GATE_POS, (-1.8, 3.9, 1.6), fb, COL_GATE);
    // RAM -> gate + RAM -> nodes (weight stream) — short stubs
    line3(RAM_POS, GATE_POS, fb, COL_RAM);
    line3(RAM_POS, (pcb_c.0 - 2.0, pcb_c.1 + 0.2, pcb_c.2), fb, COL_RAM);

    // =================================================================
    // Chips
    // =================================================================
    // lxy: small repeater where the spine meets the board
    cube(LXY_POS, (0.5, 0.45, 0.45), fb, if nob_on { COL_NOB_HOT } else { COL_SPINE });
    // xy_turn: tiny router at the board edge
    cube(XY_POS, (0.4, 0.35, 0.4), fb, COL_NOB);
    // orchestrator/router chip at the spine ROOT (bottom)
    cube(ROUTER_POS, (1.9, 1.0, 1.3), fb, COL_ROUTER);
    // gating chip + host RAM
    cube(GATE_POS, (1.0, 0.6, 0.8), fb, COL_GATE);
    cube(RAM_POS, (1.9, 1.2, 1.7), fb, COL_RAM);

    // three nodes: TINY cuboids sitting on the PCB
    let node_hot = [
        fired[0] || vt.v(Sig::M0Busy) != 0 || vt.v(Sig::M0Res) != 0,
        fired[1] || vt.v(Sig::M1Busy) != 0 || vt.v(Sig::M1Res) != 0,
        fired[2] || vt.v(Sig::M2Busy) != 0 || vt.v(Sig::M2Res) != 0,
    ];
    for (i, pos) in [NODE0, NODE1, NODE2].iter().enumerate() {
        let is_hot = node_hot[i] && flash;
        let col = if is_hot { COL_NODE_HOT } else { COL_NODE };
        cube(*pos, (0.75, 0.34, 0.7), fb, col); // small footprint
        let (x, y) = proj(*pos);
        fb.text(x - 8, y + 26, &format!("N{}", i), col);
        // MAC busy / result marker above the node
        let busy = match i { 0 => Sig::M0Busy, 1 => Sig::M1Busy, _ => Sig::M2Busy };
        let res = match i { 0 => Sig::M0Res, 1 => Sig::M1Res, _ => Sig::M2Res };
        if vt.v(busy) != 0 && flash {
            fb.text(x - 20, y - 16, "RUN", COL_BUSY);
        }
        if vt.v(res) != 0 && flash {
            fb.text(x - 28, y - 28, "DONE!", COL_NODE_HOT);
        }
    }

    // labels
    fb.text(proj(LXY_POS).0 - 30, proj(LXY_POS).1 - 30, "LXY", COL_SPINE);
    fb.text(proj(XY_POS).0 - 22, proj(XY_POS).1 + 30, "XYT", COL_NOB);
    fb.text(proj(ROUTER_POS).0 - 36, proj(ROUTER_POS).1 - 46, "ROUTER", COL_ROUTER);
    fb.text(proj(GATE_POS).0 - 24, proj(GATE_POS).1 - 34, "GATE", COL_GATE);
    fb.text(proj(RAM_POS).0 - 14, proj(RAM_POS).1 + 44, "RAM", COL_RAM);
    fb.text(proj((SPINE_X, 5.9, 0.0)).0 - 26, proj((SPINE_X, 5.9, 0.0)).1, "SPINE", COL_SPINE);
    fb.text(proj((pcb_c.0, pcb_c.1 - 0.5, pcb_c.2 + 2.6)).0 - 12, proj((pcb_c.0, pcb_c.1 - 0.5, pcb_c.2 + 2.6)).1, "PCB", COL_GRID);

    // =================================================================
    // Running dots on the links (flit position)
    // =================================================================
    if spin_sop {
        let (x, y) = proj(SPINE_TOP);
        fb_set_dot(fb, x, y);
    } else if spin_on {
        let (x, y) = proj((-1.8, 3.0, 0.0));
        fb_set_dot(fb, x, y);
    } else if nob_on {
        let (x, y) = proj((-0.4, 1.7, 0.0));
        fb_set_dot(fb, x, y);
    } else if y0_on {
        let (x, y) = proj((0.6, 1.5, 1.1));
        fb_set_dot(fb, x, y);
    } else if n0_on {
        let (x, y) = proj((0.6, 1.0, 1.1));
        fb_set_dot(fb, x, y);
    }
    if gate_done {
        let (x, y) = proj((-1.8, 3.9, 1.6));
        fb_set_dot(fb, x, y);
    }

    // =================================================================
    // Stat panel (top-left, opaque, always legible)
    // =================================================================
    let cyc = vt.time / 10_000;
    let phase_name = match vt.v(Sig::RamPhase) {
        0 => "BOOT",
        1 => "GATE",
        2 => "NODE",
        3 => "READBACK",
        _ => "IDLE",
    };
    let tstate_name = match vt.v(Sig::TState) {
        0 => "T_IDLE",
        1 => "T_START",
        2 => "T_HIDDEN",
        3 => "T_GATE",
        4 => "T_FLIT",
        5 => "T_NODE",
        6 => "T_ALL",
        _ => "???",
    };
    for y in 10..132 {
        for x in 10..(WW as i32 - 10) {
            fb.set(x, y, COL_PANEL);
        }
    }
    fb.text(18, 18, &format!("PNM EXPERT LOOP  cycle={}  ts={}ns", cyc, vt.time / 1000), COL_TEXT);
    fb.text(18, 34, &format!("seq:{}  ram-phase:{}  token:{}/3", tstate_name, phase_name, vt.v(Sig::Tok)), COL_TEXT);
    fb.text(18, 50, &format!(
        "doorbell fires  n0={} n1={} n2={}    rejects {} {} {}",
        vt.v(Sig::Db0Act), vt.v(Sig::Db1Act), vt.v(Sig::Db2Act),
        vt.v(Sig::Db0Rej), vt.v(Sig::Db1Rej), vt.v(Sig::Db2Rej)
    ), if vt.v(Sig::Db0Rej) != 0 || vt.v(Sig::Db1Rej) != 0 || vt.v(Sig::Db2Rej) != 0 { COL_WARN } else { COL_TEXT });
    fb.text(18, 66, &format!(
        "mac busy {} {} {}   result {} {} {}   boot {} gate {}",
        vt.v(Sig::M0Busy), vt.v(Sig::M1Busy), vt.v(Sig::M2Busy),
        vt.v(Sig::M0Res), vt.v(Sig::M1Res), vt.v(Sig::M2Res),
        vt.v(Sig::BootDone), vt.v(Sig::GateDone)
    ), COL_TEXT);
    fb.text(18, 82, "flit: spin/lxy = spine  nob = yellow  y-lane = green  node = dot", COL_TEXT);
    fb.text(18, 96, "legend  | red spine: flit descends   green lane: on board   yellow: lxy->xy", COL_TEXT);
    fb.text(18, 110, "node flash = doorbell fired   RUN = MAC busy   DONE! = result valid", COL_TEXT);
    fb.text(18, 124, "esc/q: quit", COL_TEXT);
}

fn fb_set_dot(fb: &mut Fb, x: i32, y: i32) {
    for dy in -2..=2 {
        for dx in -2..=2 {
            fb.set(x + dx, y + dy, COL_FLIT_HOT);
        }
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut vcd = "/tmp/expert_loop.vcd".to_string();
    let mut i = 1;
    let mut snapshot = String::new();
    let mut demo = false;
    let mut demo_advance_ms: u64 = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--vcd" => {
                i += 1;
                if i < args.len() {
                    vcd = args[i].clone();
                }
            }
            "--snapshot" => {
                i += 1;
                if i < args.len() {
                    snapshot = args[i].clone();
                }
            }
            "--demo" => {
                demo = true;
            }
            "--demo-advance" => {
                i += 1;
                if i < args.len() {
                    demo = true;
                    demo_advance_ms = args[i].parse().unwrap_or(0);
                }
            }
            _ => {}
        }
        i += 1;
    }

    // Open the VCD first so a snapshot works headless.
    let mut vt = match VcdTail::open(&vcd) {
        Ok(v) => v,
        Err(e) => {
            if demo {
                // --demo works without a VCD: synthetic timeline
                VcdTail::open_demo()
            } else {
                eprintln!("cannot open {}: {}", vcd, e);
                std::process::exit(1);
            }
        }
    };
    // drain whatever VCD content already exists so the snapshot shows state
    vt.poll();
    if demo && demo_advance_ms > 0 && vt.time == 0 {
        vt.demo_tick(demo_advance_ms);
    }

    if !snapshot.is_empty() {
        let mut fb = Fb::new();
        draw(&mut fb, &vt, Instant::now());
        // PPM P6: RGB, bottom-up not needed; write rows top to bottom.
        let mut out = format!("P6
{} {}
255
", WW, WH);
        let mut bytes: Vec<u8> = Vec::with_capacity(WW * WH * 3);
        for px in &fb.px {
            let v = *px;
            bytes.push(((v >> 16) & 0xFF) as u8);
            bytes.push(((v >> 8) & 0xFF) as u8);
            bytes.push((v & 0xFF) as u8);
        }
        std::fs::write(&snapshot, out.as_bytes()).ok();
        let mut f = std::fs::OpenOptions::new().append(true).open(&snapshot).unwrap();
        use std::io::Write;
        f.write_all(&bytes).ok();
        eprintln!("snapshot written: {}", snapshot);
        std::process::exit(0);
    }

    unsafe {
        let dpy = XOpenDisplay(ptr::null());
        if dpy.is_null() {
            eprintln!("cannot open X display (is DISPLAY set and X running?)");
            std::process::exit(1);
        }
        let scr = XDefaultScreen(dpy);
        let root = XRootWindow(dpy, scr);
        let w = XCreateSimpleWindow(
            dpy,
            root,
            60,
            40,
            WW as u32,
            WH as u32,
            1,
            XBlackPixel(dpy, scr) ^ 0xFFFFFF,
            XWhitePixel(dpy, scr),
        );
        let title = CString::new("PNM expert-loop visualizer").unwrap();
        XStoreName(dpy, w, title.as_ptr());
        XMapWindow(dpy, w);

        // WM_DELETE_WINDOW protocol
        let wm_delete = CString::new("WM_DELETE_WINDOW").unwrap();
        let atom = XInternAtom(dpy, wm_delete.as_ptr(), 0);
        XSetWMProtocols(dpy, w, &atom, 1);

        let gc = XCreateGC(dpy, w, 0, ptr::null_mut());

        // pixel buffer
        let mut fb = Fb::new();
        let buf_ptr = fb.px.as_mut_ptr() as *mut u8;
        let img = XCreateImage(
            dpy,
            ptr::null_mut(),
            24,
            ZPIXMAP,
            0,
            buf_ptr,
            WW as u32,
            WH as u32,
            32,
            WW as i32 * 4,
        );

        let mut last_draw = Instant::now();
        let mut running = true;
        let mut last_tick = Instant::now();
        while running {
            // drain events
            loop {
                let pend = XPending(dpy);
                if pend <= 0 {
                    break;
                }
                let mut ev = XEvent { data: [0; 24] };
                XNextEvent(dpy, &mut ev);
                let type_ = (ev.data[0] & 0xFF) as i32;
                if type_ == DESTROY_NOTIFY || type_ == CLIENT_MESSAGE {
                    running = false;
                } else if type_ == KEY_PRESS {
                    // check for q / esc
                    let key = (ev.data[8] & 0xFF) as u8;
                    if key == 0x71 || key == 0x1b {
                        running = false;
                    }
                }
            }
            if !running {
                break;
            }

            if demo {
                let now = Instant::now();
                let dt = now.duration_since(last_tick).as_millis() as u64;
                last_tick = now;
                vt.demo_tick(dt);
            } else {
                vt.poll();
            }

            // redraw ~20 fps or when data changed
            if last_draw.elapsed().as_millis() >= 50 {
                draw(&mut fb, &vt, Instant::now());
                unsafe {
                    XPutImage(dpy, w, gc, img, 0, 0, 0, 0, WW as u32, WH as u32);
                    XFlush(dpy);
                }
                last_draw = Instant::now();
            }
            thread::sleep(Duration::from_millis(5));
        }

        XDestroyImage(img);
        XCloseDisplay(dpy);
    }
}