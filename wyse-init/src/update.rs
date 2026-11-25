//! Image updates with two roots (A/B) and automatic rollback.
//!
//!   p1  GRUB and grubenv: slot=a|b (the root that works), try=a|b (boot
//!       that root once; GRUB clears it before booting, grub.cfg)
//!   p2  root a, p3 root b: each a whole image with its own kernel
//!
//! `wyse-init run update` (service):
//!   - Trial boot (booted root is not `slot`): wait up to 15 min for NetBird
//!     or Tailscale. Up: set slot to this root. Not up: clean reboot, which
//!     lands on the old root.
//!   - Then polls the update server with hawkBit's device API (DDI v1;
//!     raptor). An assigned image is written to the other root while its
//!     SHA-256 is computed, read back, mounted and checked (kernel, host,
//!     version), then try is set and the device reboots.
//!   - After the reboot, the server is told the result: success once this
//!     version runs (and is kept), failure after 3 trial boots that ended
//!     back on the old root.
//!
//! `wyse-init install-slot <size> <sha256> <version>`: the same install with
//! the image on stdin (scripts/deploy.sh); reboot afterwards.
//! `wyse-init update-status`: roots, versions, grubenv.
use crate::json::{self, Json};
use crate::sha256::Sha256;
use crate::{config, guard, http, preinit, sys};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::unix::fs::{FileExt, MetadataExt, OpenOptionsExt};
use std::path::Path;
use std::process::exit;

const STATE: &str = "/data/wyse-update";
/// "<action id or manual> <version>": the image the last install booted.
const TRYING: &str = "/data/wyse-update/trying";
/// "<action id> <count>": trial boots of that action that failed.
const FAILED: &str = "/data/wyse-update/failed";
const RUN: &str = "/run/wyse-update";
const MNT: &str = "/run/wyse-update/mnt";
const LOCK: &str = "/run/wyse-update/lock";
/// Trial boot: time for a VPN to come up.
const TRIAL_SECS: u64 = 15 * 60;
const MAX_TRIES: u32 = 3;
const ENV_SIG: &[u8] = b"# GRUB Environment Block\n";
const ENV_SIZE: usize = 1024;

fn log(m: &str) {
    sys::log(m);
    eprintln!("{m}");
}

// --- disk and roots ---------------------------------------------------------

struct Disk {
    disk: String,
    /// Partition number of the running root: 2 (a) or 3 (b).
    running: u32,
}

fn letter(part: u32) -> &'static str {
    if part == 3 {
        "b"
    } else {
        "a"
    }
}

fn part_of(letter: &str) -> Option<u32> {
    match letter {
        "a" => Some(2),
        "b" => Some(3),
        _ => None,
    }
}

impl Disk {
    /// From the running root's device (/rom, the read-only image).
    fn find() -> Result<Disk, String> {
        let root = if Path::new("/rom/sbin").exists() { "/rom" } else { "/" };
        let dev = fs::metadata(root).map_err(|e| format!("{root}: {e}"))?.dev();
        let blk = format!("/sys/dev/block/{}:{}", preinit::dev_major(dev), preinit::dev_minor(dev));
        let sysp = fs::canonicalize(&blk).map_err(|e| format!("{blk}: {e}"))?;
        let running = sys::read_num(&format!("{}/partition", sysp.display())) as u32;
        let disk = sysp
            .parent()
            .and_then(Path::file_name)
            .map(|s| s.to_string_lossy().into_owned())
            .ok_or("cannot find the root disk")?;
        if running != 2 && running != 3 || preinit::part_name(&disk, 4).is_none() {
            return Err(format!("root is partition {running} of {disk} and there is no partition 4: old disk layout (reinstall with scripts/install.sh)"));
        }
        Ok(Disk { disk, running })
    }

    fn dev(&self, n: u32) -> Result<String, String> {
        preinit::part_name(&self.disk, n)
            .map(|p| format!("/dev/{p}"))
            .ok_or(format!("partition {n} not found on {}", self.disk))
    }

    fn bytes(&self, n: u32) -> u64 {
        preinit::part_name(&self.disk, n)
            .map(|p| sys::read_num(&format!("/sys/block/{}/{p}/size", self.disk)) * 512)
            .unwrap_or(0)
    }

    fn other(&self) -> u32 {
        5 - self.running
    }
}

fn running_version() -> String {
    sys::read_trim(&config::image_file("/etc/wyse/version"))
}

// --- grubenv ----------------------------------------------------------------
// GRUB's environment block (grub-core/lib/envblk.c): the signature line,
// "name=value" lines, padded with '#' to 1024 bytes. It is a file on p1, but
// it is changed in place on the disk, the way GRUB's save_env does it, so p1
// is never mounted.

fn env_parse(b: &[u8]) -> Result<Vec<(String, String)>, String> {
    if b.len() != ENV_SIZE || !b.starts_with(ENV_SIG) {
        return Err("not a GRUB environment block".into());
    }
    let text = String::from_utf8_lossy(&b[ENV_SIG.len()..]);
    let mut vars = Vec::new();
    for l in text.split('\n') {
        if l.starts_with('#') || l.is_empty() {
            break;
        }
        let (k, v) = l.split_once('=').ok_or(format!("bad grubenv line {l:?}"))?;
        vars.push((k.to_string(), v.to_string()));
    }
    Ok(vars)
}

fn env_format(vars: &[(String, String)]) -> Result<Vec<u8>, String> {
    let mut b = ENV_SIG.to_vec();
    for (k, v) in vars {
        if format!("{k}{v}").contains(['\n', '\\', '#']) || k.contains('=') || k.is_empty() {
            return Err(format!("bad grubenv value {k}={v}"));
        }
        b.extend_from_slice(format!("{k}={v}\n").as_bytes());
    }
    if b.len() > ENV_SIZE {
        return Err("grubenv full".into());
    }
    b.resize(ENV_SIZE, b'#');
    Ok(b)
}

fn env_get<'a>(vars: &'a [(String, String)], k: &str) -> &'a str {
    vars.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str()).unwrap_or("")
}

fn env_put(vars: &mut Vec<(String, String)>, k: &str, v: &str) {
    vars.retain(|(n, _)| n != k);
    if !v.is_empty() {
        vars.push((k.to_string(), v.to_string()));
    }
}

/// Offset of the one environment block on `dev` (512-byte aligned).
fn env_find(dev: &str) -> Result<u64, String> {
    let mut f = File::open(dev).map_err(|e| format!("{dev}: {e}"))?;
    let mut buf = vec![0u8; 1 << 20];
    let (mut off, mut found) = (0u64, Vec::new());
    loop {
        let mut n = 0;
        while n < buf.len() {
            match f.read(&mut buf[n..]) {
                Ok(0) => break,
                Ok(k) => n += k,
                Err(e) => return Err(format!("{dev}: {e}")),
            }
        }
        for s in (0..n).step_by(512) {
            if buf[s..n].starts_with(ENV_SIG) {
                found.push(off + s as u64);
            }
        }
        if n < buf.len() {
            break;
        }
        off += n as u64;
    }
    match found[..] {
        [o] => Ok(o),
        [] => Err(format!("no grubenv on {dev}")),
        _ => Err(format!("{} grubenv blocks on {dev}: can't tell which is used", found.len())),
    }
}

struct Env {
    dev: String,
    off: u64,
    vars: Vec<(String, String)>,
}

impl Env {
    fn read(d: &Disk) -> Result<Env, String> {
        let dev = d.dev(1)?;
        let off = env_find(&dev)?;
        let mut b = vec![0u8; ENV_SIZE];
        File::open(&dev).and_then(|f| f.read_exact_at(&mut b, off)).map_err(|e| format!("{dev}: {e}"))?;
        Ok(Env { vars: env_parse(&b)?, dev, off })
    }

    fn get(&self, k: &str) -> &str {
        env_get(&self.vars, k)
    }

    /// Set (or with "" remove) names and write the block back in place.
    fn set(&mut self, kv: &[(&str, &str)]) -> Result<(), String> {
        for (k, v) in kv {
            env_put(&mut self.vars, k, v);
        }
        let b = env_format(&self.vars)?;
        let f = OpenOptions::new().write(true).open(&self.dev).map_err(|e| format!("{}: {e}", self.dev))?;
        f.write_all_at(&b, self.off).and_then(|_| f.sync_all()).map_err(|e| format!("{}: {e}", self.dev))?;
        let mut back = vec![0u8; ENV_SIZE];
        File::open(&self.dev)
            .and_then(|f| f.read_exact_at(&mut back, self.off))
            .map_err(|e| format!("{}: {e}", self.dev))?;
        if back != b {
            return Err("grubenv: read back differs".into());
        }
        Ok(())
    }
}

// --- installing an image ----------------------------------------------------

/// Why an install failed: Retry (network, can work next time) or Bad (the
/// image itself is wrong).
enum Fail {
    Retry(String),
    Bad(String),
}

impl Fail {
    fn text(&self) -> &str {
        match self {
            Fail::Retry(m) | Fail::Bad(m) => m,
        }
    }
}

/// Only one install at a time (service and install-slot).
struct Lock;

fn lock() -> Result<Lock, String> {
    let _ = fs::create_dir_all(RUN);
    for _ in 0..2 {
        match OpenOptions::new().write(true).create_new(true).mode(0o600).open(LOCK) {
            Ok(mut f) => {
                let _ = write!(f, "{}", std::process::id());
                return Ok(Lock);
            }
            Err(e) if e.kind() == io::ErrorKind::AlreadyExists => {
                let pid = sys::read_trim(LOCK);
                if !pid.is_empty() && Path::new(&format!("/proc/{pid}")).exists() {
                    return Err(format!("another install is running (pid {pid})"));
                }
                let _ = fs::remove_file(LOCK); // left by a process that died
            }
            Err(e) => return Err(format!("{LOCK}: {e}")),
        }
    }
    Err(format!("{LOCK}: can't take the lock"))
}

impl Drop for Lock {
    fn drop(&mut self) {
        let _ = fs::remove_file(LOCK);
    }
}

/// Write `size` bytes from `r` into the unused root and check it. Returns
/// the root's letter.
fn install(d: &Disk, r: &mut dyn Read, size: u64, sha: &str, version: &str) -> Result<&'static str, Fail> {
    let n = d.other();
    let dev = d.dev(n).map_err(Fail::Bad)?;
    let room = d.bytes(n);
    if size == 0 || size > room {
        return Err(Fail::Bad(format!("image is {size} bytes, root {} has {room}", letter(n))));
    }
    if sha.len() != 64 || !sha.bytes().all(|c| c.is_ascii_hexdigit()) {
        return Err(Fail::Bad(format!("bad sha256 {sha:?}")));
    }
    let sha = sha.to_ascii_lowercase();
    log(&format!("writing version {version} ({size} bytes) to root {} ({dev})", letter(n)));

    let mut out = OpenOptions::new().write(true).open(&dev).map_err(|e| Fail::Bad(format!("{dev}: {e}")))?;
    let mut h = Sha256::new();
    let mut buf = vec![0u8; 1 << 20];
    let mut done = 0u64;
    while done < size {
        let want = ((size - done) as usize).min(buf.len());
        let got = match r.read(&mut buf[..want]) {
            Ok(0) => return Err(Fail::Retry(format!("download ended after {done} of {size} bytes"))),
            Ok(k) => k,
            Err(e) if e.kind() == io::ErrorKind::Interrupted => continue,
            Err(e) => return Err(Fail::Retry(format!("download: {e} after {done} bytes"))),
        };
        h.update(&buf[..got]);
        out.write_all(&buf[..got]).map_err(|e| Fail::Bad(format!("{dev}: write: {e}")))?;
        done += got as u64;
    }
    out.sync_all().map_err(|e| Fail::Bad(format!("{dev}: sync: {e}")))?;
    drop(out);
    let got = h.hex();
    if got != sha {
        return Err(Fail::Bad(format!("sha256 is {got}, expected {sha}")));
    }

    // Read it back from the disk itself, not from the cache.
    sys::put("/proc/sys/vm/drop_caches", "1");
    let mut f = File::open(&dev).map_err(|e| Fail::Bad(format!("{dev}: {e}")))?;
    let mut h = Sha256::new();
    let mut left = size;
    while left > 0 {
        let want = (left as usize).min(buf.len());
        f.read_exact(&mut buf[..want]).map_err(|e| Fail::Bad(format!("{dev}: read back: {e}")))?;
        h.update(&buf[..want]);
        left -= want as u64;
    }
    if h.hex() != sha {
        return Err(Fail::Bad(format!("root {}: read back differs from what was written (disk fault?)", letter(n))));
    }
    check_image(&dev, version).map_err(Fail::Bad)?;
    log(&format!("root {} has version {version}, checked", letter(n)));
    Ok(letter(n))
}

/// Mount the new root read-only and check that it can boot and is meant for
/// this device and version.
fn check_image(dev: &str, version: &str) -> Result<(), String> {
    let _ = fs::create_dir_all(MNT);
    if sys::mounted(MNT) {
        let _ = sys::umount_detach(MNT);
    }
    sys::mount_fs(dev, MNT, "squashfs", sys::MS_RDONLY | sys::MS_NODEV | sys::MS_NOSUID, "")
        .map_err(|e| format!("new root can't be mounted (not a squashfs image?): {e}"))?;
    let res = (|| {
        let kernel = fs::metadata(format!("{MNT}/boot/bzImage")).map(|m| m.len()).unwrap_or(0);
        if kernel < 1 << 20 {
            return Err("new root has no kernel (/boot/bzImage)".to_string());
        }
        for f in ["/boot/grub.cfg", "/sbin/wyse-init", "/sbin/init"] {
            if fs::symlink_metadata(format!("{MNT}{f}")).is_err() {
                return Err(format!("new root has no {f}"));
            }
        }
        let host = sys::read_trim(&format!("{MNT}/etc/wyse/host"));
        if host != config::HOSTNAME {
            return Err(format!("new root is for host {host:?}, this is {:?}", config::HOSTNAME));
        }
        let v = sys::read_trim(&format!("{MNT}/etc/wyse/version"));
        if v != version {
            return Err(format!("new root has version {v:?}, expected {version:?}"));
        }
        Ok(())
    })();
    let _ = sys::umount(MNT);
    res
}

/// Boot the new root once at the next boot.
fn set_try(d: &Disk, slot: &str, action: &str, version: &str) -> Result<(), String> {
    let _ = fs::create_dir_all(STATE);
    fs::write(TRYING, format!("{action} {version}\n")).map_err(|e| format!("{TRYING}: {e}"))?;
    sys::sync();
    let mut env = Env::read(d)?;
    env.set(&[("try", slot)])
}

// --- trial boot and results -------------------------------------------------

/// After an update: keep the new root only if a VPN comes up.
fn trial_boot(d: &Disk) {
    let me = letter(d.running);
    let mut env = match Env::read(d) {
        Ok(e) => e,
        Err(e) => {
            log(&format!("can't read grubenv: {e}"));
            return;
        }
    };
    if !env.get("try").is_empty() {
        // GRUB clears it before booting; if it couldn't, a crash here would
        // boot this root again and again instead of the old one.
        log(&format!("grubenv still has try={} (GRUB did not clear it): clearing it", env.get("try")));
        if let Err(e) = env.set(&[("try", "")]) {
            log(&format!("can't clear try: {e}"));
        }
    }
    let slot = env.get("slot").to_string();
    if slot == me {
        return;
    }
    if part_of(&slot).is_none() {
        log(&format!("grubenv has no valid slot ({slot:?}): setting slot={me}"));
        if let Err(e) = env.set(&[("slot", me)]) {
            log(&format!("can't set slot: {e}"));
        }
        return;
    }
    log(&format!("trial boot of root {me} (version {}); root {slot} is the working one", running_version()));
    while sys::uptime() < TRIAL_SECS {
        if guard::vpn_up() {
            match env.set(&[("slot", me)]) {
                Ok(()) => log(&format!("VPN is up: root {me} is now the working root")),
                Err(e) => log(&format!("VPN is up, but can't set slot={me}: {e}")),
            }
            return;
        }
        sys::sleep(10);
    }
    log(&format!("no VPN within {} min on root {me}: rebooting into root {slot}", TRIAL_SECS / 60));
    sys::clean_reboot();
}

/// The last install did not end up running: count it for its action.
fn check_last_try() {
    let t = sys::read_trim(TRYING);
    if t.is_empty() {
        return;
    }
    let (action, version) = t.split_once(' ').unwrap_or((&t, ""));
    if version == running_version() {
        return; // it runs; the server is told at the next poll
    }
    let _ = fs::remove_file(TRYING);
    if action == "manual" {
        log(&format!("version {version} (scripts/deploy.sh) did not stay up: back on {}", running_version()));
        return;
    }
    let n = failures(action) + 1;
    let _ = fs::write(FAILED, format!("{action} {n}\n"));
    log(&format!("version {version} (action {action}) did not stay up ({n} of {MAX_TRIES} tries): back on {}", running_version()));
}

fn failures(action: &str) -> u32 {
    let f = sys::read_trim(FAILED);
    match f.split_once(' ') {
        Some((a, n)) if a == action => n.parse().unwrap_or(0),
        _ => 0,
    }
}

// --- the update server (hawkBit DDI v1) -------------------------------------

struct Ddi {
    /// {update_url}/DEFAULT/controller/v1/{host}
    base: String,
    auth: String,
}

impl Ddi {
    fn new() -> Result<Ddi, String> {
        let url = config::UPDATE_URL.trim_end_matches('/');
        if url.is_empty() {
            return Err("no update server (update_url in config/network)".into());
        }
        let tf = config::image_file("/etc/wyse/update.token");
        let token = sys::read_trim(&tf);
        if token.is_empty() {
            return Err(format!("no token in {tf}"));
        }
        Ok(Ddi {
            base: format!("{url}/DEFAULT/controller/v1/{}", config::HOSTNAME),
            auth: format!("TargetToken {token}"),
        })
    }

    fn call(&self, method: &str, url: &str, body: Option<&str>) -> Result<Json, String> {
        let mut h = vec![("Authorization", self.auth.as_str()), ("Accept", "application/json")];
        if body.is_some() {
            h.push(("Content-Type", "application/json"));
        }
        let r = http::request(method, url, &h, body)?;
        let status = r.status;
        let text = r.text(1 << 20)?;
        if !(200..300).contains(&status) {
            let t: String = text.chars().take(200).collect();
            return Err(format!("{method} {url}: HTTP {status} {t}"));
        }
        if text.trim().is_empty() {
            return Ok(Json::Null);
        }
        json::parse(&text).map_err(|e| format!("{url}: {e}"))
    }

    fn feedback(&self, action: &str, execution: &str, finished: &str, msg: &str) {
        let body = format!(
            r#"{{"id":{},"status":{{"execution":"{execution}","result":{{"finished":"{finished}"}},"details":[{}]}}}}"#,
            json::quote(action),
            json::quote(msg)
        );
        let url = format!("{}/deploymentBase/{action}/feedback", self.base);
        match self.call("POST", &url, Some(&body)) {
            Ok(_) => log(&format!("server: action {action} {execution}/{finished}: {msg}")),
            Err(e) => log(&format!("can't send feedback: {e}")),
        }
    }

    fn send_attributes(&self, d: &Disk) -> Result<(), String> {
        let body = format!(
            r#"{{"mode":"merge","data":{{"version":{},"root":"{}"}}}}"#,
            json::quote(&running_version()),
            letter(d.running)
        );
        self.call("PUT", &format!("{}/configData", self.base), Some(&body)).map(|_| ())
    }

    /// The device asked to stop an action that was not started: confirm.
    fn cancel(&self, href: &str) {
        let Ok(j) = self.call("GET", href, None) else { return };
        let Some(id) = j.at("cancelAction/stopId").str().map(str::to_string).or(j.get("id").str().map(str::to_string)) else { return };
        let body = format!(
            r#"{{"id":{},"status":{{"execution":"closed","result":{{"finished":"success"}},"details":["canceled"]}}}}"#,
            json::quote(&id)
        );
        let url = format!("{}/cancelAction/{id}/feedback", self.base);
        if let Err(e) = self.call("POST", &url, Some(&body)) {
            log(&format!("can't confirm cancel: {e}"));
        }
    }

    /// One assigned image (deploymentBase): install it, or report on it.
    fn deployment(&self, d: &Disk, href: &str) {
        let j = match self.call("GET", href, None) {
            Ok(j) => j,
            Err(e) => return log(&e),
        };
        let Some(action) = j.get("id").str().map(str::to_string).or(j.get("id").u64().map(|n| n.to_string())) else {
            return log("deploymentBase without an id");
        };
        let chunk = j.at("deployment/chunks/0");
        let art = chunk.at("artifacts/0");
        let version = chunk.get("version").str().unwrap_or("").to_string();
        let size = art.get("size").u64().unwrap_or(0);
        let sha = art.at("hashes/sha256").str().unwrap_or("").to_string();
        let link = art.at("_links/download-http/href").str().or(art.at("_links/download/href").str()).unwrap_or("").to_string();

        if !version.is_empty() && version == running_version() {
            let _ = fs::remove_file(TRYING);
            let _ = fs::remove_file(FAILED);
            return self.feedback(&action, "closed", "success", &format!("running {version} on root {}", letter(d.running)));
        }
        if version.is_empty() || size == 0 || link.is_empty() || j.at("deployment/chunks/1") != &Json::Null || chunk.at("artifacts/1") != &Json::Null {
            return self.feedback(&action, "closed", "failure", "expected one module with one image file and a version");
        }
        let tries = failures(&action);
        if tries >= MAX_TRIES {
            return self.feedback(&action, "closed", "failure", &format!("version {version} did not stay up in {tries} trial boots; still on {}", running_version()));
        }
        if j.at("deployment/update").str() == Some("skip") {
            return; // download-only or outside its maintenance window
        }
        let lk = match lock() {
            Ok(l) => l,
            Err(e) => return log(&e),
        };
        let what = if tries > 0 { format!("try {} of {MAX_TRIES}: ", tries + 1) } else { String::new() };
        self.feedback(&action, "proceeding", "none", &format!("{what}downloading {version} into root {}", letter(d.other())));
        let res = http::request("GET", &link, &[("Authorization", self.auth.as_str())], None)
            .map_err(Fail::Retry)
            .and_then(|mut r| {
                if r.status != 200 {
                    return Err(Fail::Retry(format!("download: HTTP {}", r.status)));
                }
                if r.length.is_some_and(|l| l != size) {
                    return Err(Fail::Bad(format!("download is {:?} bytes, expected {size}", r.length)));
                }
                install(d, &mut r, size, &sha, &version)
            });
        match res {
            Ok(slot) => {
                if let Err(e) = set_try(d, slot, &action, &version) {
                    drop(lk);
                    return self.feedback(&action, "closed", "failure", &format!("can't switch to root {slot}: {e}"));
                }
                self.feedback(&action, "proceeding", "none", &format!("installed {version} in root {slot}, rebooting into it"));
                log(&format!("rebooting into root {slot} (version {version})"));
                sys::clean_reboot();
            }
            Err(Fail::Retry(m)) => self.feedback(&action, "proceeding", "none", &format!("{m}; trying again at the next poll")),
            Err(f) => self.feedback(&action, "closed", "failure", f.text()),
        }
    }
}

/// "HH:MM:SS" -> seconds.
fn hms(s: &str) -> Option<u64> {
    let p: Vec<u64> = s.split(':').map(|x| x.parse().ok()).collect::<Option<_>>()?;
    match p[..] {
        [h, m, s] => Some(h * 3600 + m * 60 + s),
        _ => None,
    }
}

pub fn main() -> ! {
    sys::log_open(c"update");
    let d = match Disk::find() {
        Ok(d) => d,
        Err(e) => {
            log(&e);
            sys::idle();
        }
    };
    trial_boot(&d);
    check_last_try();
    let ddi = match Ddi::new() {
        Ok(x) => x,
        Err(e) => {
            log(&format!("automatic updates off: {e}"));
            sys::idle();
        }
    };
    // First poll 2 min after boot, when the VPN is usually up.
    while sys::uptime() < 120 {
        sys::sleep(10);
    }
    let mut attrs_sent = false;
    loop {
        let mut sleep = 300;
        match ddi.call("GET", &ddi.base, None) {
            Ok(j) => {
                if let Some(s) = j.at("config/polling/sleep").str().and_then(hms) {
                    sleep = s.clamp(60, 24 * 3600);
                }
                if !attrs_sent || j.at("_links/configData/href").str().is_some() {
                    match ddi.send_attributes(&d) {
                        Ok(()) => attrs_sent = true,
                        Err(e) => log(&format!("can't send attributes: {e}")),
                    }
                }
                if let Some(h) = j.at("_links/cancelAction/href").str() {
                    ddi.cancel(h);
                } else if let Some(h) = j.at("_links/deploymentBase/href").str() {
                    ddi.deployment(&d, h);
                }
            }
            Err(e) => log(&format!("update server: {e}")),
        }
        sys::sleep(sleep);
    }
}

// --- command line -----------------------------------------------------------

/// `wyse-init install-slot <size> <sha256> <version>`, image on stdin.
pub fn install_slot(args: &[String]) -> ! {
    let fail = |m: &str| -> ! {
        eprintln!("install-slot: {m}");
        exit(1)
    };
    let [size, sha, version] = args else { fail("usage: wyse-init install-slot <size> <sha256> <version> < rootfs.squashfs") };
    let size: u64 = size.parse().unwrap_or_else(|_| fail("bad size"));
    sys::log_open(c"update");
    let d = Disk::find().unwrap_or_else(|e| fail(&e));
    let _lk = lock().unwrap_or_else(|e| fail(&e));
    let mut stdin = io::stdin().lock();
    match install(&d, &mut stdin, size, sha, version) {
        Ok(slot) => {
            set_try(&d, slot, "manual", version).unwrap_or_else(|e| fail(&e));
            println!("installed {version} in root {slot}; it is booted once at the next reboot and kept when a VPN comes up");
            exit(0)
        }
        Err(f) => fail(f.text()),
    }
}

/// `wyse-init update-status`
pub fn status() -> ! {
    let d = Disk::find().unwrap_or_else(|e| {
        eprintln!("{e}");
        exit(1)
    });
    println!("running: root {} ({}), version {}", letter(d.running), d.dev(d.running).unwrap_or_default(), running_version());
    let other = d.other();
    let ov = match (lock(), d.dev(other)) {
        (Ok(_lk), Ok(dev)) => {
            let _ = fs::create_dir_all(MNT);
            if sys::mount_fs(&dev, MNT, "squashfs", sys::MS_RDONLY, "").is_ok() {
                let v = sys::read_trim(&format!("{MNT}/etc/wyse/version"));
                let _ = sys::umount(MNT);
                if v.is_empty() { "(no version)".to_string() } else { v }
            } else {
                "(empty or not an image)".to_string()
            }
        }
        (Err(e), _) | (_, Err(e)) => format!("({e})"),
    };
    println!("other:   root {} ({}), version {ov}", letter(other), d.dev(other).unwrap_or_default());
    match Env::read(&d) {
        Ok(e) => println!("grubenv: slot={} try={}", e.get("slot"), e.get("try")),
        Err(e) => println!("grubenv: {e}"),
    }
    let s = |f: &str| {
        let t = sys::read_trim(f);
        if t.is_empty() { "-".to_string() } else { t }
    };
    println!("last install: {}   failed tries: {}", s(TRYING), s(FAILED));
    println!("server: {}", if config::UPDATE_URL.is_empty() { "(none)" } else { config::UPDATE_URL });
    exit(0)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn block(text: &str) -> Vec<u8> {
        let mut b = text.as_bytes().to_vec();
        b.resize(ENV_SIZE, b'#');
        b
    }

    #[test]
    fn grubenv() {
        // As post-image.sh makes it, and as GRUB's save_env leaves it.
        let b = block("# GRUB Environment Block\nslot=a\n");
        let mut v = env_parse(&b).unwrap();
        assert_eq!(env_get(&v, "slot"), "a");
        assert_eq!(env_get(&v, "try"), "");
        env_put(&mut v, "try", "b");
        let f = env_format(&v).unwrap();
        assert_eq!(f, block("# GRUB Environment Block\nslot=a\ntry=b\n"));
        env_put(&mut v, "try", "");
        env_put(&mut v, "slot", "b");
        assert_eq!(env_format(&v).unwrap(), block("# GRUB Environment Block\nslot=b\n"));
        assert!(env_parse(&b[..1000]).is_err());
        assert!(env_parse(&block("# GRUB Env\n")).is_err());
        assert!(env_format(&[("a".into(), "x\ny".into())]).is_err());
        assert!(env_format(&[("a".into(), "x".repeat(1100))]).is_err());
        // An empty block (GRUB's grub-editenv create).
        assert!(env_parse(&block("# GRUB Environment Block\n")).unwrap().is_empty());
    }

    #[test]
    fn find_block() {
        let dir = std::env::temp_dir().join(format!("wyse-env-{}", std::process::id()));
        let mut img = vec![0u8; 3 << 20];
        let b = block("# GRUB Environment Block\nslot=b\n");
        let at = (1 << 20) + 512 * 7; // across the 1 MiB read size
        img[at..at + ENV_SIZE].copy_from_slice(&b);
        // Not at a sector start: ignored.
        img[100..100 + ENV_SIG.len()].copy_from_slice(ENV_SIG);
        fs::write(&dir, &img).unwrap();
        assert_eq!(env_find(dir.to_str().unwrap()).unwrap(), at as u64);
        img[4096..4096 + ENV_SIZE].copy_from_slice(&b);
        fs::write(&dir, &img).unwrap();
        assert!(env_find(dir.to_str().unwrap()).is_err());
        let _ = fs::remove_file(&dir);
    }

    #[test]
    fn times() {
        assert_eq!(hms("00:05:00"), Some(300));
        assert_eq!(hms("01:00:30"), Some(3630));
        assert_eq!(hms("5m"), None);
        assert_eq!(hms("1:2"), None);
    }
}

/// Against a running raptor with one image assigned (scripts/publish.sh):
///   WYSE_TEST_DDI=http://127.0.0.1:8088/DEFAULT/controller/v1/<host> \
///   WYSE_TEST_TOKEN=<update_token> cargo test ddi_server -- --ignored
#[cfg(test)]
mod server_test {
    use super::*;

    #[test]
    #[ignore]
    fn ddi_server() {
        let ddi = Ddi {
            base: std::env::var("WYSE_TEST_DDI").unwrap(),
            auth: format!("TargetToken {}", std::env::var("WYSE_TEST_TOKEN").unwrap()),
        };
        let j = ddi.call("GET", &ddi.base, None).unwrap();
        assert!(j.at("config/polling/sleep").str().and_then(hms).is_some());
        let body = r#"{"mode":"merge","data":{"version":"test","root":"a"}}"#;
        ddi.call("PUT", &format!("{}/configData", ddi.base), Some(body)).unwrap();
        let href = j.at("_links/deploymentBase/href").str().unwrap().to_string();
        let d = ddi.call("GET", &href, None).unwrap();
        let action = d.get("id").str().unwrap().to_string();
        let art = d.at("deployment/chunks/0/artifacts/0");
        let size = art.get("size").u64().unwrap();
        let link = art.at("_links/download-http/href").str().unwrap();
        let mut r = http::request("GET", link, &[("Authorization", ddi.auth.as_str())], None).unwrap();
        assert_eq!((r.status, r.length), (200, Some(size)));
        let mut h = Sha256::new();
        let mut buf = vec![0u8; 65536];
        let mut n = 0u64;
        loop {
            let k = r.read(&mut buf).unwrap();
            if k == 0 {
                break;
            }
            h.update(&buf[..k]);
            n += k as u64;
        }
        assert_eq!(n, size);
        assert_eq!(h.hex(), art.at("hashes/sha256").str().unwrap());
        // Someone else's token can't download it.
        let bad = http::request("GET", link, &[("Authorization", "TargetToken 00")], None).unwrap();
        assert!(bad.status == 401 || bad.status == 404, "{}", bad.status);
        ddi.feedback(&action, "proceeding", "none", "test: downloading");
        ddi.feedback(&action, "closed", "success", "test: running");
        let j = ddi.call("GET", &ddi.base, None).unwrap();
        assert!(j.at("_links/deploymentBase").str().is_none() && j.at("_links/deploymentBase") == &Json::Null);
    }
}
