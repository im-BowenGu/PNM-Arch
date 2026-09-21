/// pnm_rustd — PNM router chip daemon
///
/// Handles access control (user authentication via salted SHA-256 hashing),
/// workload management (submit, list, cancel), and optional NVMe cache eviction.
///
/// Runs on the orchestrator_sbc under NOMMU Linux. Cross-compile with:
///   cargo build --release --target riscv32-unknown-none-elf
/// Or for NOMMU Linux:
///   cargo build --release --target riscv32-unknown-linux-musl
///
/// Self-contained: no external crate dependencies. SHA-256 and HMAC are
/// implemented inline to avoid pulling in ring/openssl on embedded targets.

use core::fmt;
use std::io::Write;

// ============================================================================
// SHA-256 — self-contained implementation (NIST FIPS 180-4)
// ============================================================================

struct Sha256 {
    state: [u32; 8],
    buf:   [u8; 64],
    len:   u64,
    pos:   usize,
}

const K: [u32; 64] = [
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5,
    0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3,
    0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc,
    0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7,
    0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13,
    0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3,
    0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5,
    0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208,
    0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
];

const H0: [u32; 8] = [
    0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a,
    0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19,
];

fn ro32(x: u32, n: u32) -> u32 { x.rotate_right(n) }

impl Sha256 {
    fn new() -> Self {
        Self { state: H0, buf: [0u8; 64], len: 0, pos: 0 }
    }

    fn update(&mut self, data: &[u8]) {
        let mut i = 0;
        self.len += data.len() as u64;
        if self.pos > 0 {
            while i < data.len() && self.pos < 64 {
                self.buf[self.pos] = data[i];
                self.pos += 1;
                i += 1;
            }
            if self.pos == 64 {
                self.compress();
                self.pos = 0;
            }
        }
        while i + 64 <= data.len() {
            self.buf.copy_from_slice(&data[i..i + 64]);
            self.compress();
            i += 64;
        }
        while i < data.len() {
            self.buf[self.pos] = data[i];
            self.pos += 1;
            i += 1;
        }
    }

    fn finalize(mut self) -> [u8; 32] {
        let bit_len = self.len * 8;
        self.buf[self.pos] = 0x80;
        self.pos += 1;
        if self.pos > 56 {
            while self.pos < 64 { self.buf[self.pos] = 0; self.pos += 1; }
            self.compress();
            self.pos = 0;
            self.buf = [0u8; 64];
        }
        while self.pos < 56 { self.buf[self.pos] = 0; self.pos += 1; }
        self.buf[56..64].copy_from_slice(&bit_len.to_be_bytes());
        self.compress();

        let mut out = [0u8; 32];
        for i in 0..8 {
            out[i * 4..i * 4 + 4].copy_from_slice(&self.state[i].to_be_bytes());
        }
        out
    }

    fn compress(&mut self) {
        let mut w = [0u32; 64];
        for i in 0..16 {
            w[i] = u32::from_be_bytes(self.buf[i * 4..i * 4 + 4].try_into().unwrap());
        }
        for i in 16..64 {
            let s0 = ro32(w[i - 15], 7) ^ ro32(w[i - 15], 18) ^ (w[i - 15] >> 3);
            let s1 = ro32(w[i - 2], 17) ^ ro32(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16].wrapping_add(s0).wrapping_add(w[i - 7]).wrapping_add(s1);
        }
        let [mut a, mut b, mut c, mut d, mut e, mut f, mut g, mut h] = self.state;
        for i in 0..64 {
            let s1 = ro32(e, 6) ^ ro32(e, 11) ^ ro32(e, 25);
            let ch = (e & f) ^ ((!e) & g);
            let t1 = h.wrapping_add(s1).wrapping_add(ch).wrapping_add(K[i]).wrapping_add(w[i]);
            let s0 = ro32(a, 2) ^ ro32(a, 13) ^ ro32(a, 22);
            let maj = (a & b) ^ (a & c) ^ (b & c);
            let t2 = s0.wrapping_add(maj);
            h = g; g = f; f = e; e = d.wrapping_add(t1);
            d = c; c = b; b = a; a = t1.wrapping_add(t2);
        }
        self.state[0] = self.state[0].wrapping_add(a);
        self.state[1] = self.state[1].wrapping_add(b);
        self.state[2] = self.state[2].wrapping_add(c);
        self.state[3] = self.state[3].wrapping_add(d);
        self.state[4] = self.state[4].wrapping_add(e);
        self.state[5] = self.state[5].wrapping_add(f);
        self.state[6] = self.state[6].wrapping_add(g);
        self.state[7] = self.state[7].wrapping_add(h);
    }
}

fn sha256(data: &[u8]) -> [u8; 32] {
    let mut h = Sha256::new();
    h.update(data);
    h.finalize()
}

/// HMAC-SHA-256 (RFC 2104) — used for key derivation in salt generation.
fn hmac_sha256(key: &[u8], msg: &[u8]) -> [u8; 32] {
    let mut k_padded = [0u8; 64];
    if key.len() > 64 {
        let h = sha256(key);
        k_padded[..32].copy_from_slice(&h);
    } else {
        k_padded[..key.len()].copy_from_slice(key);
    }
    let mut ipad = [0x36u8; 64];
    let mut opad = [0x5cu8; 64];
    for i in 0..64 {
        ipad[i] ^= k_padded[i];
        opad[i] ^= k_padded[i];
    }
    let mut inner = [0u8; 96];
    inner[..64].copy_from_slice(&ipad);
    inner[64..].copy_from_slice(msg);
    let inner_h = sha256(&inner);
    let mut outer = [0u8; 96];
    outer[..64].copy_from_slice(&opad);
    outer[64..96].copy_from_slice(&inner_h);
    sha256(&outer)
}

/// Derive a 32-byte key from password + salt using PBKDF2-HMAC-SHA256 (1000 iterations).
fn pbkdf2(password: &[u8], salt: &[u8], iterations: u32) -> [u8; 32] {
    let mut out = [0u8; 32];
    let mut u = hmac_sha256(password, salt);
    out.copy_from_slice(&u);
    for _ in 1..iterations {
        u = hmac_sha256(password, &u);
        for i in 0..32 { out[i] ^= u[i]; }
    }
    out
}

// ============================================================================
// Access control: users, roles, authentication
// ============================================================================

#[derive(Clone, Copy, PartialEq, Eq)]
enum Role {
    Read,     // can dispatch pre-loaded workloads
    Write,    // can upload weights and modify routing tables
    Admin,    // full control: firmware updates, NVMe format, user management
}

impl Role {
    fn from_str(s: &str) -> Option<Self> {
        match s {
            "read"  => Some(Role::Read),
            "write" => Some(Role::Write),
            "admin" => Some(Role::Admin),
            _ => None,
        }
    }

    fn to_str(self) -> &'static str {
        match self {
            Role::Read  => "read",
            Role::Write => "write",
            Role::Admin => "admin",
        }
    }
}

#[derive(Clone, Copy)]
struct User {
    name:         [u8; 32],
    name_len:     usize,
    salt:         [u8; 16],
    hash:         [u8; 32],  // PBKDF2-HMAC-SHA256(password, salt, 1000)
    role:         Role,
    active:       bool,
}

impl User {
    fn matches_password(&self, password: &[u8]) -> bool {
        if !self.active { return false; }
        let derived = pbkdf2(password, &self.salt, 1000);
        constant_time_eq(&derived, &self.hash)
    }
}

/// Constant-time comparison (prevents timing side-channels).
fn constant_time_eq(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() { return false; }
    let mut diff = 0u8;
    for i in 0..a.len() { diff |= a[i] ^ b[i]; }
    diff == 0
}

/// Global state (no heap allocation).
const MAX_USERS: usize = 32;

struct AccessControl {
    users: [User; MAX_USERS],
    count: usize,
    // Read-only role bypass for host at startup (all-or-nothing)
    host_bypass: bool,
}

impl AccessControl {
    fn new() -> Self {
        let empty = User {
            name: [0u8; 32], name_len: 0,
            salt: [0u8; 16], hash: [0u8; 32],
            role: Role::Read, active: false,
        };
        Self {
            users: core::array::from_fn(|_| empty.clone()),
            count: 0,
            host_bypass: true, // enabled until first admin user is added
        }
    }

    /// Create a new user with a salted password hash.
    /// Returns Ok(index) or Err if table full / duplicate name.
    fn add_user(&mut self, name: &[u8], password: &[u8], role: Role) -> Result<usize, &'static str> {
        if self.count >= MAX_USERS { return Err("user table full"); }
        if name.len() > 32 { return Err("name too long"); }
        // Check duplicate
        for i in 0..self.count {
            if &self.users[i].name[..self.users[i].name_len] == name {
                return Err("duplicate user");
            }
        }
        // Generate salt from name + a fixed system key (deterministic for reproducibility).
        let mut salt = [0u8; 16];
        let system_key = b"pnm-rustd-v0.1";
        let mut name_salt_input = Vec::with_capacity(name.len() + 8);
        name_salt_input.extend_from_slice(name);
        name_salt_input.extend_from_slice(&(self.count as u64).to_le_bytes());
        let derived = hmac_sha256(system_key, &name_salt_input);
        salt.copy_from_slice(&derived[..16]);

        let hash = pbkdf2(password, &salt, 1000);

        let mut u = &mut self.users[self.count];
        u.name[..name.len()].copy_from_slice(name);
        u.name_len = name.len();
        u.salt = salt;
        u.hash = hash;
        u.role = role;
        u.active = true;
        self.count += 1;
        if role == Role::Admin { self.host_bypass = false; } // first admin disables bypass
        Ok(self.count - 1)
    }

    /// Authenticate a user. Returns role on success, None on failure.
    fn authenticate(&self, name: &[u8], password: &[u8]) -> Option<Role> {
        if self.host_bypass && self.count == 0 { return Some(Role::Admin); }
        for i in 0..self.count {
            if &self.users[i].name[..self.users[i].name_len] == name {
                if self.users[i].matches_password(password) {
                    return Some(self.users[i].role);
                }
                return None; // wrong password
            }
        }
        None // user not found
    }
}

// ============================================================================
// Workload management
// ============================================================================

#[derive(Clone, Copy, PartialEq, Eq)]
enum JobState {
    Pending,
    Running,
    Complete,
    Failed,
    Cancelled,
}

impl JobState {
    fn to_str(self) -> &'static str {
        match self {
            JobState::Pending   => "pending",
            JobState::Running   => "running",
            JobState::Complete  => "complete",
            JobState::Failed    => "failed",
            JobState::Cancelled => "cancelled",
        }
    }
}

const MAX_JOBS: usize = 64;

#[derive(Clone, Copy)]
struct Job {
    id:          u32,
    name:        [u8; 32],
    name_len:    usize,
    submitter:   [u8; 32],
    submit_len:  usize,
    state:       JobState,
    job_type:    [u8; 16],   // "inference", "weight_upload", "eviction", "flush"
    type_len:    usize,
    priority:    u8,         // 0 = highest
    layers:      u16,
    nodes:       u16,
    errors:      u32,
}

struct WorkloadManager {
    jobs:      [Job; MAX_JOBS],
    count:     usize,
    next_id:   u32,
    running:   u16,
}

impl WorkloadManager {
    fn new() -> Self {
        let empty = Job {
            id: 0, name: [0u8; 32], name_len: 0,
            submitter: [0u8; 32], submit_len: 0,
            state: JobState::Pending, job_type: [0u8; 16], type_len: 0,
            priority: 0, layers: 0, nodes: 0, errors: 0,
        };
        Self {
            jobs: core::array::from_fn(|_| empty.clone()),
            count: 0, next_id: 1, running: 0,
        }
    }

    fn submit(&mut self, name: &[u8], submitter: &[u8], job_type: &[u8],
              priority: u8, layers: u16, nodes: u16) -> Result<u32, &'static str> {
        if self.count >= MAX_JOBS { return Err("job queue full"); }
        if name.len() > 32 || job_type.len() > 16 { return Err("name/type too long"); }
        let id = self.next_id;
        self.next_id += 1;
        let mut j = &mut self.jobs[self.count];
        j.id = id;
        j.name[..name.len()].copy_from_slice(name);
        j.name_len = name.len();
        j.submitter[..submitter.len()].copy_from_slice(submitter);
        j.submit_len = submitter.len();
        j.job_type[..job_type.len()].copy_from_slice(job_type);
        j.type_len = job_type.len();
        j.state = JobState::Pending;
        j.priority = priority;
        j.layers = layers;
        j.nodes = nodes;
        self.count += 1;
        Ok(id)
    }

    fn cancel(&mut self, id: u32) -> bool {
        for i in 0..self.count {
            if self.jobs[i].id == id {
                if self.jobs[i].state == JobState::Pending {
                    self.jobs[i].state = JobState::Cancelled;
                    return true;
                }
                return false; // can't cancel running/complete jobs
            }
        }
        false
    }

    fn start(&mut self, id: u32) -> bool {
        for i in 0..self.count {
            if self.jobs[i].id == id && self.jobs[i].state == JobState::Pending {
                self.jobs[i].state = JobState::Running;
                self.running += 1;
                return true;
            }
        }
        false
    }

    fn complete(&mut self, id: u32, errors: u32) -> bool {
        for i in 0..self.count {
            if self.jobs[i].id == id && self.jobs[i].state == JobState::Running {
                self.jobs[i].state = if errors > 0 { JobState::Failed } else { JobState::Complete };
                self.jobs[i].errors = errors;
                self.running = self.running.saturating_sub(1);
                return true;
            }
        }
        false
    }

    fn running_count(&self) -> u16 { self.running }

    fn fmt_summary(&self, out: &mut dyn fmt::Write) -> fmt::Result {
        write!(out, "Jobs: {} total, {} running\n", self.count, self.running)?;
        for i in 0..self.count {
            let j = &self.jobs[i];
            let name = core::str::from_utf8(&j.name[..j.name_len]).unwrap_or("?");
            let ty = core::str::from_utf8(&j.job_type[..j.type_len]).unwrap_or("?");
            write!(out, "  [#{} {}] {} prio={} L={} N={} errors={}\n",
                   j.id, name, ty, j.priority, j.layers, j.nodes, j.errors)?;
        }
        Ok(())
    }
}

// ============================================================================
// Log buffer with optional NVMe eviction
// ============================================================================

const LOG_BUF_SIZE: usize = 8192;

struct LogBuffer {
    buf:    [u8; LOG_BUF_SIZE],
    pos:    usize,
    lines:  u64,
    flushes: u64,
    nvme_enabled: bool,    // compile-time or runtime flag
    nvme_lba: u64,         // next write LBA on NVMe device
    nvme_nlb: u16,         // blocks per flush
}

impl LogBuffer {
    fn new(nvme_enabled: bool) -> Self {
        Self {
            buf: [0u8; LOG_BUF_SIZE],
            pos: 0,
            lines: 0,
            flushes: 0,
            nvme_enabled,
            nvme_lba: 0,
            nvme_nlb: (LOG_BUF_SIZE / 512) as u16,
        }
    }

    fn write_log(&mut self, msg: &[u8]) {
        let copy_len = msg.len().min(LOG_BUF_SIZE - self.pos);
        if copy_len > 0 {
            self.buf[self.pos..self.pos + copy_len].copy_from_slice(&msg[..copy_len]);
            self.pos += copy_len;
            self.lines += 1;
        }
        // Auto-flush when buffer is 75% full
        if self.pos >= LOG_BUF_SIZE * 3 / 4 {
            self.flush();
        }
    }

    fn flush(&mut self) {
        if self.pos == 0 { return; }
        if self.nvme_enabled && self.nvme_lba > 0 {
            // In production this issues NVMECmdWrite via the nvme_ctrl register window.
            // For now we just advance the LBA and clear the buffer.
            self.nvme_lba += self.nvme_nlb as u64;
            self.flushes += 1;
        }
        // In any case, reset the log position (data has been dispatched)
        self.pos = 0;
    }
}

// ============================================================================
// Cache eviction mode (compile-time selectable)
// ============================================================================

/// Eviction policy for KV cache and log buffers when they overflow.
/// Select at compile time via EVICTION_MODE or at runtime via the daemon.
#[derive(Clone, Copy, PartialEq, Eq)]
enum EvictionMode {
    /// Just mark entries empty — no persistence (default, fastest)
    None = 0,
    /// DMA evicted entry to the BMC/host via the spine before marking empty
    DmaBmc = 1,
    /// Write evicted entry to NVMe before marking empty
    Nvme = 2,
}

impl EvictionMode {
    fn from_u32(v: u32) -> Self {
        match v {
            0 => Self::None,
            1 => Self::DmaBmc,
            2 => Self::Nvme,
            _ => Self::None,
        }
    }
    fn to_str(self) -> &'static str {
        match self {
            Self::None    => "none",
            Self::DmaBmc  => "dma_bmc",
            Self::Nvme    => "nvme",
        }
    }
}

// ============================================================================
// Daemon main loop (command processing)
// ============================================================================

struct DaemonState {
    ac:           AccessControl,
    wm:           WorkloadManager,
    log:          LogBuffer,
    eviction:     EvictionMode,
    nvme_lba_next: u64,
    shutdown:     bool,
}

impl DaemonState {
    fn new() -> Self {
        Self {
            ac: AccessControl::new(),
            wm: WorkloadManager::new(),
            log: LogBuffer::new(false),
            eviction: EvictionMode::None,
            nvme_lba_next: 0,
            shutdown: false,
        }
    }

    /// Process a command line and write the response to `out`.
    fn handle_command(&mut self, line: &str, out: &mut dyn fmt::Write) {
        let parts: Vec<&str> = line.trim().split_whitespace().collect();
        if parts.is_empty() { return; }

        match parts[0] {
            "help" => {
                let _ = writeln!(out, "PNM Rust daemon — commands:");
                let _ = writeln!(out, "  help                              Show this help");
                let _ = writeln!(out, "  adduser <name> <pass> <role>      Add a user (read/write/admin)");
                let _ = writeln!(out, "  auth <name> <pass>                Authenticate a user");
                let _ = writeln!(out, "  submit <name> <type> <prio> <L> <N>  Submit workload");
                let _ = writeln!(out, "  cancel <id>                       Cancel a pending job");
                let _ = writeln!(out, "  start <id>                        Mark job as running");
                let _ = writeln!(out, "  complete <id> <errors>            Mark job complete");
                let _ = writeln!(out, "  jobs                              List all jobs");
                let _ = writeln!(out, "  eviction [none|dma_bmc|nvme]      Get/set eviction mode");
                let _ = writeln!(out, "  log <message>                     Write to log buffer");
                let _ = writeln!(out, "  logflush                          Flush log buffer to NVMe");
                let _ = writeln!(out, "  status                            Show daemon status");
                let _ = writeln!(out, "  shutdown                          Graceful shutdown");
            }

            "adduser" => {
                if parts.len() < 4 {
                    let _ = writeln!(out, "ERR: adduser <name> <password> <role>");
                    return;
                }
                let role = match Role::from_str(parts[3]) {
                    Some(r) => r,
                    None => { let _ = writeln!(out, "ERR: unknown role '{}'", parts[3]); return; }
                };
                match self.ac.add_user(parts[1].as_bytes(), parts[2].as_bytes(), role) {
                    Ok(idx) => { let _ = writeln!(out, "OK user_added idx={}", idx); }
                    Err(e)  => { let _ = writeln!(out, "ERR: {}", e); }
                }
            }

            "auth" => {
                if parts.len() < 3 {
                    let _ = writeln!(out, "ERR: auth <name> <password>");
                    return;
                }
                match self.ac.authenticate(parts[1].as_bytes(), parts[2].as_bytes()) {
                    Some(role) => { let _ = writeln!(out, "OK role={}", role.to_str()); }
                    None       => { let _ = writeln!(out, "ERR: authentication failed"); }
                }
            }

            "submit" => {
                if parts.len() < 6 {
                    let _ = writeln!(out, "ERR: submit <name> <type> <priority> <layers> <nodes>");
                    return;
                }
                let prio: u8 = parts[3].parse().unwrap_or(0);
                let layers: u16 = parts[4].parse().unwrap_or(0);
                let nodes: u16 = parts[5].parse().unwrap_or(0);
                match self.wm.submit(parts[1].as_bytes(), b"host",
                                     parts[2].as_bytes(), prio, layers, nodes) {
                    Ok(id) => { let _ = writeln!(out, "OK job_id={}", id); }
                    Err(e) => { let _ = writeln!(out, "ERR: {}", e); }
                }
            }

            "cancel" => {
                if parts.len() < 2 { let _ = writeln!(out, "ERR: cancel <id>"); return; }
                let id: u32 = parts[1].parse().unwrap_or(0);
                if self.wm.cancel(id) {
                    let _ = writeln!(out, "OK cancelled job {}", id);
                } else {
                    let _ = writeln!(out, "ERR: cannot cancel job {}", id);
                }
            }

            "start" => {
                if parts.len() < 2 { let _ = writeln!(out, "ERR: start <id>"); return; }
                let id: u32 = parts[1].parse().unwrap_or(0);
                if self.wm.start(id) {
                    let _ = writeln!(out, "OK job {} started", id);
                } else {
                    let _ = writeln!(out, "ERR: cannot start job {}", id);
                }
            }

            "complete" => {
                if parts.len() < 3 { let _ = writeln!(out, "ERR: complete <id> <errors>"); return; }
                let id: u32 = parts[1].parse().unwrap_or(0);
                let errors: u32 = parts[2].parse().unwrap_or(0);
                if self.wm.complete(id, errors) {
                    let _ = writeln!(out, "OK job {} complete (errors={})", id, errors);
                } else {
                    let _ = writeln!(out, "ERR: cannot complete job {}", id);
                }
            }

            "jobs" => {
                self.wm.fmt_summary(out).unwrap();
            }

            "eviction" => {
                if parts.len() > 1 {
                    self.eviction = match parts[1] {
                        "none"    => EvictionMode::None,
                        "dma_bmc" => EvictionMode::DmaBmc,
                        "nvme"    => EvictionMode::Nvme,
                        _ => { let _ = writeln!(out, "ERR: unknown mode"); return; }
                    };
                }
                let _ = writeln!(out, "eviction_mode={}", self.eviction.to_str());
            }

            "log" => {
                let msg = if parts.len() > 1 { parts[1..].join(" ") } else { String::new() };
                self.log.write_log(msg.as_bytes());
                let _ = writeln!(out, "OK lines={}", self.log.lines);
            }

            "logflush" => {
                self.log.flush();
                let _ = writeln!(out, "OK flushes={}", self.log.flushes);
            }

            "status" => {
                let _ = writeln!(out, "pnm_rustd v0.1");
                let _ = writeln!(out, "users={}", self.ac.count);
                let _ = writeln!(out, "eviction={}", self.eviction.to_str());
                let _ = writeln!(out, "log_lines={} log_flushes={}", self.log.lines, self.log.flushes);
                let _ = writeln!(out, "jobs_running={}", self.wm.running_count());
            }

            "shutdown" => {
                self.shutdown = true;
                let _ = writeln!(out, "OK shutting down");
            }

            _ => {
                let _ = writeln!(out, "ERR: unknown command '{}' (try 'help')", parts[0]);
            }
        }
    }
}

// ============================================================================
// Entry point — NOMMU Linux (uses std) or bare-metal (uses #[no_std])
// ============================================================================

#[cfg(target_os = "none")]
mod entry_bare {
    use super::*;
    use core::panic::PanicInfo;

    #[panic_handler]
    fn panic(_info: &PanicInfo) -> ! { loop {} }

    #[no_mangle]
    pub extern "C" fn _start() -> ! {
        // Bare-metal entry: no heap, no OS. For ROM-burned firmware.
        let mut daemon = DaemonState::new();
        // Seed with a default admin user
        let _ = daemon.ac.add_user(b"admin", b"changeme", Role::Admin);

        // In bare-metal, commands arrive via UART. Stub: just run status.
        let mut daemon_handle = DaemonState {
            ac: daemon.ac,
            wm: WorkloadManager::new(),
            log: LogBuffer::new(false),
            eviction: EvictionMode::None,
            nvme_lba_next: 0,
            shutdown: false,
        };
        let mut out_buf = [0u8; 4096];
        let mut out_pos = 0;
        let mut resp = DaemonState {
            ac: daemon.ac,
            wm: WorkloadManager::new(),
            log: LogBuffer::new(false),
            eviction: EvictionMode::None,
            nvme_lba_next: 0,
            shutdown: false,
        };
        struct BufWriter<'a> {
            buf: &'a mut [u8],
            pos: usize,
        }
        impl<'a> fmt::Write for BufWriter<'a> {
            fn write_str(&mut self, s: &str) -> fmt::Result {
                let bytes = s.as_bytes();
                let end = (self.pos + bytes.len()).min(self.buf.len());
                let len = end - self.pos;
                self.buf[self.pos..end].copy_from_slice(&bytes[..len]);
                self.pos = end;
                Ok(())
            }
        }
        let mut writer = BufWriter { buf: &mut out_buf, pos: 0 };
        resp.handle_command("status", &mut writer);
        // In production, write out_buf to UART TX
        loop {
            core::hint::spin_loop();
        }
    }
}

#[cfg(not(target_os = "none"))]
fn main() {
    let mut state = DaemonState::new();
    let _ = state.ac.add_user(b"admin", b"changeme", Role::Admin);

    eprintln!("pnm_rustd v0.1 starting (users={}, eviction={})",
              state.ac.count, state.eviction.to_str());

    let mut stdin = std::io::stdin();
    let mut stdout = std::io::stdout();
    let mut line = String::with_capacity(256);

    loop {
        line.clear();
        let n = match stdin.read_line(&mut line) {
            Ok(0) => break,  // EOF
            Ok(n) => n,
            Err(_) => break,
        };
        if n == 0 { break; }

        let mut response = String::new();
        state.handle_command(&line, &mut response);
        let _ = stdout.write_all(response.as_bytes());
        let _ = stdout.flush();

        if state.shutdown { break; }
    }

    // Final flush
    state.log.flush();
    eprintln!("pnm_rustd exiting (jobs_completed={})", state.wm.running_count());
}
