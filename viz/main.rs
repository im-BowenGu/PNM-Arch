// pnm_viz — live terminal visualizer for the expert-loop co-simulation.
//
// Monitors the VCD stream that tb_expert_loop.v writes and renders a simple
// cuboid + line wireframe of the fabric: the spine, the lxy repeater, the
// XY turn, the three visited node cuboids, the gating chip, and the RAM
// stub.  The flit is drawn as a moving glyph along the route that the real
// RTL takes (spin -> nob -> y-lane -> node doorbell -> MAC), and the
// per-node doorbell fires flash as the simulation completes each token.
//
// Build:  rustc -O viz/main.rs -o viz/pnm_viz
// Run:    viz/pnm_viz [--vcd /tmp/expert_loop.vcd] [--fps 8]
//
// stdlib only — no external crates.

use std::collections::HashMap;
use std::env;
use std::fs::File;
use std::io::{Read, Seek, SeekFrom};
use std::thread;
use std::time::Duration;

// ---------------------------------------------------------------------------
// 3D -> 2D isometric-ish projection
// ---------------------------------------------------------------------------
const CX: i32 = 40; // character grid center
const CY: i32 = 16;
const SX: f32 = 5.5; // x scale (chars per unit)
const SY: f32 = 2.6; // y scale
const SZ: f32 = 3.2; // z scale (depth, into the screen)

fn proj(p: (f32, f32, f32)) -> (i32, i32) {
    // rotate 45deg around Y, then tilt:
    let x = p.0 - p.2; // iso X
    let z = (p.0 + p.2) * 0.58; // iso depth
    (
        CX + (x * SX - z * SZ * 0.5) as i32,
        CY - (p.1 * SY - z * SZ * 0.5) as i32,
    )
        .into()
}

// ---------------------------------------------------------------------------
// Canvas
// ---------------------------------------------------------------------------
struct Canvas {
    w: usize,
    h: usize,
    px: Vec<Vec<char>>,
    fg: Vec<Vec<u8>>, // ANSI color per cell (0 none)
}

impl Canvas {
    fn new(w: usize, h: usize) -> Self {
        Canvas {
            w,
            h,
            px: vec![vec![' '; w]; h],
            fg: vec![vec![0; w]; h],
        }
    }
    fn put(&mut self, x: i32, y: i32, c: char, color: u8) {
        let (x, y) = (x as usize, y as usize);
        if x < self.w && y < self.h {
            self.px[y][x] = c;
            self.fg[y][x] = color;
        }
    }
    fn line(&mut self, a: (f32, f32, f32), b: (f32, f32, f32), c: char, color: u8) {
        let (x0, y0) = proj(a);
        let (x1, y1) = proj(b);
        let steps = ((x1 - x0).abs().max((y1 - y0).abs())).max(1);
        for i in 0..=steps {
            let t = i as f32 / steps as f32;
            let x = (x0 as f32 + (x1 - x0) as f32 * t).round() as i32;
            let y = (y0 as f32 + (y1 - y0) as f32 * t).round() as i32;
            self.put(x, y, c, color);
        }
    }
    fn box3(&mut self, c: (f32, f32, f32), s: (f32, f32, f32), col: u8) {
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
        // bottom face
        self.line(cs[0], cs[1], '.', col);
        self.line(cs[1], cs[2], '.', col);
        self.line(cs[2], cs[3], '.', col);
        self.line(cs[3], cs[0], '.', col);
        // top face
        self.line(cs[4], cs[5], '.', col);
        self.line(cs[5], cs[6], '.', col);
        self.line(cs[6], cs[7], '.', col);
        self.line(cs[7], cs[4], '.', col);
        // verticals
        self.line(cs[0], cs[4], '|', col);
        self.line(cs[1], cs[5], '|', col);
        self.line(cs[2], cs[6], '|', col);
        self.line(cs[3], cs[7], '|', col);
    }
    fn label(&mut self, p: (f32, f32, f32), s: &str, col: u8) {
        let (x, y) = proj(p);
        let (x, y) = (x as usize, y as usize);
        for (i, ch) in s.chars().enumerate() {
            let xx = x + i;
            if xx < self.w && y < self.h {
                self.px[y][xx] = ch;
                self.fg[y][xx] = col;
            }
        }
    }
    fn render(&self, status: &[String]) -> String {
        let mut out = String::new();
        out.push_str("\x1b[H\x1b[2J");
        for line in status {
            out.push_str(line);
            out.push('\n');
        }
        for _ in 0..2 {
            out.push('\n');
        }
        for y in 0..self.h {
            for x in 0..self.w {
                let c = self.px[y][x];
                let f = self.fg[y][x];
                if f == 0 {
                    out.push(c);
                } else {
                    out.push_str(&format!("\x1b[{}m{}\x1b[0m", f, c));
                }
            }
            out.push('\n');
        }
        out
    }
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
    // latest values
    time: u64,
    vals: HashMap<Sig, u64>,
    // level-triggered latches
    fired0: bool,
    fired1: bool,
    fired2: bool,
}

impl VcdTail {
    fn open(path: &str) -> std::io::Result<VcdTail> {
        let mut file = File::open(path)?;
        // parse header
        let mut header = Vec::new();
        loop {
            let mut byte = [0u8; 1];
            if file.read(&mut byte)? == 0 {
                break;
            }
            header.push(byte[0]);
            if header.ends_with(b"$end") && header.len() > 4 {
                // count $end depth: enddefinitions is the last big one
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
                    // $var <type> <width> <id> <name> [range]
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
            fired0: false,
            fired1: false,
            fired2: false,
        })
    }
    /// Read new body lines, update latest values. Returns true if anything changed.
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
                // b<bits> <id>
                let mut it = v.split_whitespace();
                if let (Some(bits), Some(id)) = (it.next(), it.next()) {
                    if let Some(sig) = self.codes.get(id) {
                        if let Ok(val) = u64::from_str_radix(bits, 2) {
                            self.vals.insert(*sig, val);
                            self.latch(*sig, val);
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
                    self.vals.insert(*sig, val);
                    self.latch(*sig, val);
                    changed = true;
                }
            }
        }
        changed
    }
    fn latch(&mut self, s: Sig, v: u64) {
        match s {
            Sig::Db0Fire | Sig::Db0Act => {
                if v != 0 {
                    self.fired0 = true;
                }
            }
            Sig::Db1Fire | Sig::Db1Act => {
                if v != 0 {
                    self.fired1 = true;
                }
            }
            Sig::Db2Fire | Sig::Db2Act => {
                if v != 0 {
                    self.fired2 = true;
                }
            }
            _ => {}
        }
    }
    fn v(&self, s: Sig) -> u64 {
        *self.vals.get(&s).unwrap_or(&0)
    }
    fn phase_name(&self) -> String {
        match self.v(Sig::RamPhase) {
            0 => "BOOT",
            1 => "GATE",
            2 => "NODE",
            3 => "READBACK",
            _ => "IDLE",
        }
        .to_string()
    }
    fn tstate_name(&self) -> String {
        match self.v(Sig::TState) {
            0 => "T_IDLE",
            1 => "T_START",
            2 => "T_HIDDEN",
            3 => "T_GATE",
            4 => "T_FLIT",
            5 => "T_NODE",
            6 => "T_ALL",
            _ => "???",
        }
        .to_string()
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
const SPINE_TOP: (f32, f32, f32) = (0.0, 4.0, 0.0);
const LXY_POS: (f32, f32, f32) = (0.0, 2.4, 0.0);
const XY_POS: (f32, f32, f32) = (1.6, 1.6, 0.0);
const NODE0: (f32, f32, f32) = (1.6, 0.6, 0.0);
const NODE1: (f32, f32, f32) = (3.2, 0.6, 0.0);
const NODE2: (f32, f32, f32) = (4.8, 0.6, 0.0);
const GATE_POS: (f32, f32, f32) = (-2.4, 2.6, 1.0);
const RAM_POS: (f32, f32, f32) = (-2.2, -0.2, -1.4);

fn draw_scene(c: &mut Canvas, v: &VcdTail) {
    // spine
    c.line(SPINE_TOP, LXY_POS, ':', 90);
    // lxy -> xy turn (the nob)
    c.line(LXY_POS, XY_POS, ':', 93);
    // y-lane through the three nodes
    c.line((1.6, 1.65, 0.0), (4.8, 1.65, 0.0), ':', 94);
    c.line(NODE0, NODE1, ':', 94);
    c.line(NODE1, NODE2, ':', 94);
    // gating -> spine
    c.line(GATE_POS, (0.0, 3.4, 0.0), ':', 95);

    // cuboids
    c.box3(LXY_POS, (0.7, 0.5, 0.7), 33);
    c.box3(XY_POS, (0.6, 0.5, 0.6), 34);
    c.box3(GATE_POS, (1.2, 0.8, 1.0), 36);
    c.box3(RAM_POS, (1.6, 1.0, 1.6), 37);

    // nodes: color by visit/fire state
    let (n0, n1, n2) = (
        if v.fired0 { 92 } else { 32 },
        if v.fired1 { 92 } else { 32 },
        if v.fired2 { 92 } else { 32 },
    );
    // highlight the node currently being serviced (node phase)
    let active = v.phase_name() == "NODE" && v.v(Sig::BootDone) != 0;
    let n0 = if active && v.fired0 { 93 } else { n0 };
    let n1 = if active && v.fired1 { 93 } else { n1 };
    let n2 = if active && v.fired2 { 93 } else { n2 };
    c.box3(NODE0, (1.0, 0.6, 0.8), n0);
    c.box3(NODE1, (1.0, 0.6, 0.8), n1);
    c.box3(NODE2, (1.0, 0.6, 0.8), n2);
    c.label((NODE0.0, NODE0.1 - 0.6, NODE0.2), "n0", n0);
    c.label((NODE1.0, NODE1.1 - 0.6, NODE1.2), "n1", n1);
    c.label((NODE2.0, NODE2.1 - 0.6, NODE2.2), "n2", n2);
    c.label((LXY_POS.0 - 0.5, LXY_POS.1 + 0.45, LXY_POS.2), "lxy", 33);
    c.label((XY_POS.0 + 0.5, XY_POS.1 + 0.4, XY_POS.2), "xy", 34);
    c.label((GATE_POS.0 - 0.3, GATE_POS.1 + 0.55, GATE_POS.2), "gate", 36);
    c.label((RAM_POS.0, RAM_POS.1 - 0.7, RAM_POS.2), "ram-stub", 37);

    // flit position: follow the real signal path
    // 0: injector, 1: spine, 2: lxy(match/nob), 3: xy-turn, 4: y-lane, 5: node doorbell
    let mut flit: Option<(f32, f32, f32)> = None;
    if v.v(Sig::SpinSop) != 0 && v.v(Sig::SpinValid) != 0 {
        flit = Some(SPINE_TOP);
    } else if v.v(Sig::SpinValid) != 0 {
        flit = Some((0.0, 3.2, 0.0)); // spine mid
    } else if v.v(Sig::NobValid) != 0 {
        flit = Some((0.9, 2.25, 0.0)); // lxy -> xy
    } else if v.v(Sig::Y0Valid) != 0 {
        flit = Some((1.6, 1.5, 0.0)); // turn -> y-lane
    } else if v.v(Sig::N0Valid) != 0 {
        flit = Some((1.6, 1.0, 0.0)); // at node 0
    } else if v.v(Sig::GateDone) != 0 {
        flit = Some((0.0, 3.4, 0.0)); // gating result into spine
    }
    if let Some(p) = flit {
        c.put(proj(p).0, proj(p).1, '*', 91);
    }
    // compute blink
    if v.v(Sig::M0Res) != 0 || v.v(Sig::M1Res) != 0 || v.v(Sig::M2Res) != 0 {
        let p = if v.v(Sig::M0Res) != 0 {
            NODE0
        } else if v.v(Sig::M1Res) != 0 {
            NODE1
        } else {
            NODE2
        };
        c.put(proj((p.0, p.1 + 0.4, p.2)).0, proj((p.0, p.1 + 0.4, p.2)).1, '!', 93);
    }
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut vcd = "/tmp/expert_loop.vcd".to_string();
    let mut fps = 8u64;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--vcd" => {
                i += 1;
                if i < args.len() {
                    vcd = args[i].clone();
                }
            }
            "--fps" => {
                i += 1;
                if i < args.len() {
                    fps = args[i].parse().unwrap_or(8);
                }
            }
            _ => {}
        }
        i += 1;
    }

    let mut vt = match VcdTail::open(&vcd) {
        Ok(v) => v,
        Err(e) => {
            eprintln!("cannot open {}: {}", vcd, e);
            std::process::exit(1);
        }
    };

    let period = Duration::from_millis(1000 / fps);
    loop {
        vt.poll();
        let mut c = Canvas::new(80, 26);
        draw_scene(&mut c, &vt);

        let cyc = vt.time / 10_000; // 10 ns per cycle @100MHz
        let status = vec![
            format!(
                "\x1b[1;33mPNM expert-loop\x1b[0m  cycle {:>10}  ts={:>8} ps  | {} -> {}",
                cyc,
                vt.time,
                vt.tstate_name(),
                vt.phase_name()
            ),
            format!(
                "token {:<4}  boot_done={}  gate_done={}",
                vt.v(Sig::Tok),
                vt.v(Sig::BootDone),
                vt.v(Sig::GateDone)
            ),
            format!(
                "\x1b[32mdoorbell fire:  n0={} n1={} n2={}\x1b[0m   \x1b[31mreject: {} {} {}\x1b[0m",
                vt.v(Sig::Db0Act),
                vt.v(Sig::Db1Act),
                vt.v(Sig::Db2Act),
                vt.v(Sig::Db0Rej),
                vt.v(Sig::Db1Rej),
                vt.v(Sig::Db2Rej)
            ),
            format!(
                "mac busy: {} {} {}    result: {} {} {}",
                vt.v(Sig::M0Busy),
                vt.v(Sig::M1Busy),
                vt.v(Sig::M2Busy),
                vt.v(Sig::M0Res),
                vt.v(Sig::M1Res),
                vt.v(Sig::M2Res)
            ),
        ];
        print!("{}", c.render(&status));
        use std::io::Write;
        std::io::stdout().flush().ok();
        thread::sleep(period);
    }
}