//! Small helpers: C library calls that std does not offer, running
//! programs, and reading/writing small files.
use std::ffi::{CStr, CString};
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::os::raw::{c_char, c_int, c_long, c_uint, c_ulong, c_void};
use std::os::unix::io::{FromRawFd, IntoRawFd};
use std::process::{Command, Stdio};
use std::sync::mpsc;
use std::thread;
use std::time::Duration;

extern "C" {
    fn mount(
        src: *const c_char,
        target: *const c_char,
        fstype: *const c_char,
        flags: c_ulong,
        data: *const c_void,
    ) -> c_int;
    fn umount2(target: *const c_char, flags: c_int) -> c_int;
    #[link_name = "chroot"]
    fn c_chroot(path: *const c_char) -> c_int;
    #[link_name = "sethostname"]
    fn c_sethostname(name: *const c_char, len: usize) -> c_int;
    fn setpriority(which: c_int, who: c_uint, prio: c_int) -> c_int;
    #[link_name = "reboot"]
    fn c_reboot(cmd: c_int) -> c_int;
    #[link_name = "sync"]
    fn c_sync();
    #[link_name = "kill"]
    fn c_kill(pid: c_int, sig: c_int) -> c_int;
    fn syscall(n: c_long, ...) -> c_long;
    fn prctl(op: c_int, ...) -> c_int;
    fn dup2(old: c_int, new: c_int) -> c_int;
    #[link_name = "umask"]
    fn c_umask(mask: c_uint) -> c_uint;
    fn signal(sig: c_int, handler: usize) -> usize;
    fn openlog(ident: *const c_char, opt: c_int, facility: c_int);
    #[link_name = "syslog"]
    fn c_syslog(pri: c_int, fmt: *const c_char, ...);
}

pub const MS_NOSUID: u64 = 2;
pub const MS_NODEV: u64 = 4;
pub const MS_NOATIME: u64 = 1024;
pub const MS_MOVE: u64 = 8192;
pub const SIGKILL: i32 = 9;
pub const SIGTERM: i32 = 15;
const MNT_DETACH: c_int = 2;
const SIG_IGN: usize = 1;
const SYS_PIVOT_ROOT: c_long = 155; // x86_64
const RB_AUTOBOOT: c_int = 0x0123_4567;
const LOG_USER: c_int = 8;
const LOG_NOTICE: c_int = 5;

fn cs(s: &str) -> CString {
    CString::new(s).unwrap_or_default()
}

fn check(r: c_int) -> io::Result<()> {
    if r == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}

/// mount(2). Empty `fstype` or `data` are passed as NULL.
pub fn mount_fs(src: &str, target: &str, fstype: &str, flags: u64, data: &str) -> io::Result<()> {
    let (s, t, f, d) = (cs(src), cs(target), cs(fstype), cs(data));
    let fp = if fstype.is_empty() { std::ptr::null() } else { f.as_ptr() };
    let dp = if data.is_empty() { std::ptr::null() } else { d.as_ptr() as *const c_void };
    check(unsafe { mount(s.as_ptr(), t.as_ptr(), fp, flags as c_ulong, dp) })
}

pub fn umount(target: &str) -> io::Result<()> {
    let t = cs(target);
    check(unsafe { umount2(t.as_ptr(), 0) })
}

/// umount -l
pub fn umount_detach(target: &str) -> io::Result<()> {
    let t = cs(target);
    check(unsafe { umount2(t.as_ptr(), MNT_DETACH) })
}

/// Ignore Ctrl-C and Ctrl-\ (while a child runs in the foreground).
pub fn ignore_interrupts() {
    unsafe {
        signal(2, SIG_IGN);
        signal(3, SIG_IGN);
    }
}

pub fn chroot(path: &str) -> io::Result<()> {
    let p = cs(path);
    check(unsafe { c_chroot(p.as_ptr()) })
}

pub fn pivot_root(new_root: &str, put_old: &str) -> io::Result<()> {
    let (n, o) = (cs(new_root), cs(put_old));
    let r = unsafe { syscall(SYS_PIVOT_ROOT, n.as_ptr(), o.as_ptr()) };
    check(r as c_int)
}

pub fn sethostname(name: &str) -> io::Result<()> {
    check(unsafe { c_sethostname(name.as_ptr() as *const c_char, name.len()) })
}

/// Set this process's nice value (like `nice -n N` started from nice 0).
pub fn nice(n: i32) {
    unsafe { setpriority(0, 0, n) };
}

/// Take a capability away from the programs this process starts (it stays
/// gone for their children too).
pub fn drop_cap(cap: c_ulong) {
    const PR_CAPBSET_DROP: c_int = 24;
    unsafe { prctl(PR_CAPBSET_DROP, cap) };
}

pub fn umask(mask: u32) {
    unsafe { c_umask(mask) };
}

pub fn sync() {
    unsafe { c_sync() };
}

/// Immediate reboot, without init (like `reboot -f`).
pub fn reboot_now() -> ! {
    sync();
    unsafe { c_reboot(RB_AUTOBOOT) };
    loop {
        thread::sleep(Duration::from_secs(1));
    }
}

pub fn kill(pid: i32, sig: i32) {
    unsafe { c_kill(pid, sig) };
}

/// Point stdin, stdout and stderr at `path` (/dev/null or /dev/console).
pub fn stdio_to(path: &str) -> io::Result<()> {
    let fd = OpenOptions::new().read(true).write(true).open(path)?.into_raw_fd();
    for n in 0..3 {
        unsafe { dup2(fd, n) };
    }
    if fd > 2 {
        drop(unsafe { File::from_raw_fd(fd) });
    }
    Ok(())
}

/// Messages to syslog (like `logger -t <ident>`).
pub fn log_open(ident: &'static CStr) {
    unsafe { openlog(ident.as_ptr(), 0, LOG_USER) };
}

pub fn log(msg: &str) {
    let m = cs(msg);
    unsafe { c_syslog(LOG_USER | LOG_NOTICE, c"%s".as_ptr(), m.as_ptr()) };
}

/// Message to the kernel log (seen on the console and in dmesg).
pub fn kmsg(msg: &str) {
    if let Ok(mut f) = OpenOptions::new().write(true).open("/dev/kmsg") {
        let _ = f.write_all(format!("{msg}\n").as_bytes());
    }
}

pub fn read_trim(path: &str) -> String {
    fs::read_to_string(path).map(|s| s.trim().to_string()).unwrap_or_default()
}

pub fn read_num(path: &str) -> u64 {
    read_trim(path).parse().unwrap_or(0)
}

/// Write a small file (e.g. a /proc or /sys setting). Errors are ignored,
/// like `echo x > file 2>/dev/null` in the old scripts.
pub fn put(path: &str, value: &str) -> bool {
    fs::write(path, value).is_ok()
}

/// Seconds since boot.
pub fn uptime() -> u64 {
    read_trim("/proc/uptime")
        .split('.')
        .next()
        .and_then(|s| s.parse().ok())
        .unwrap_or(0)
}

pub fn sleep(secs: u64) {
    thread::sleep(Duration::from_secs(secs));
}

pub fn idle() -> ! {
    loop {
        sleep(3600);
    }
}

/// True if `path` is a mount point (from /proc/self/mountinfo).
pub fn mounted(path: &str) -> bool {
    let info = fs::read_to_string("/proc/self/mountinfo").unwrap_or_default();
    info.lines()
        .filter_map(|l| l.split(' ').nth(4))
        .any(|p| unescape_mount(p) == path)
}

/// mountinfo writes spaces etc. as \040 (octal).
fn unescape_mount(s: &str) -> String {
    let b = s.as_bytes();
    let mut out = Vec::with_capacity(b.len());
    let mut i = 0;
    while i < b.len() {
        if b[i] == b'\\' && i + 3 < b.len() && b[i + 1..i + 4].iter().all(|c| (b'0'..=b'7').contains(c)) {
            out.push((b[i + 1] - b'0') * 64 + (b[i + 2] - b'0') * 8 + (b[i + 3] - b'0'));
            i += 4;
        } else {
            out.push(b[i]);
            i += 1;
        }
    }
    String::from_utf8_lossy(&out).into_owned()
}

/// Run a program and wait. True if it exited with 0.
pub fn run(prog: &str, args: &[&str]) -> bool {
    Command::new(prog).args(args).status().map(|s| s.success()).unwrap_or(false)
}

/// Same, with its output thrown away.
pub fn run_quiet(prog: &str, args: &[&str]) -> bool {
    Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .status()
        .map(|s| s.success())
        .unwrap_or(false)
}

/// Run a program with `input` on its stdin.
pub fn run_input(prog: &str, args: &[&str], input: &str) -> bool {
    let Ok(mut child) = Command::new(prog).args(args).stdin(Stdio::piped()).spawn() else {
        return false;
    };
    if let Some(mut stdin) = child.stdin.take() {
        let _ = stdin.write_all(input.as_bytes());
    }
    child.wait().map(|s| s.success()).unwrap_or(false)
}

/// Run a program, killing it after `secs` (like BusyBox `timeout`).
/// Returns (exited with 0, its stdout). A timeout counts as a failure.
pub fn output_timeout(prog: &str, args: &[String], secs: u64) -> (bool, String) {
    let child = Command::new(prog)
        .args(args)
        .stdin(Stdio::null())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .spawn();
    let Ok(child) = child else {
        return (false, String::new());
    };
    let pid = child.id() as i32;
    let (tx, rx) = mpsc::channel();
    thread::spawn(move || {
        let _ = tx.send(child.wait_with_output());
    });
    let res = match rx.recv_timeout(Duration::from_secs(secs)) {
        Ok(r) => r,
        Err(_) => {
            kill(pid, SIGKILL);
            // Give the waiting thread a moment to reap it.
            let _ = rx.recv_timeout(Duration::from_secs(5));
            return (false, String::new());
        }
    };
    match res {
        Ok(o) => (o.status.success(), String::from_utf8_lossy(&o.stdout).into_owned()),
        Err(_) => (false, String::new()),
    }
}

/// Send SIGTERM to every process named exactly `name` (like `pkill -x`).
pub fn kill_name(name: &str) {
    let me = std::process::id().to_string();
    let Ok(rd) = fs::read_dir("/proc") else { return };
    for e in rd.flatten() {
        let pid = e.file_name().to_string_lossy().into_owned();
        if pid == me || !pid.bytes().all(|c| c.is_ascii_digit()) {
            continue;
        }
        let mut comm = String::new();
        if let Ok(mut f) = File::open(format!("/proc/{pid}/comm")) {
            let _ = f.read_to_string(&mut comm);
        }
        if comm.trim_end_matches('\n') == name {
            if let Ok(p) = pid.parse() {
                kill(p, SIGTERM);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn mountinfo_escapes() {
        assert_eq!(unescape_mount("/a\\040b"), "/a b");
        assert_eq!(unescape_mount("/data"), "/data");
        assert_eq!(unescape_mount("/x\\"), "/x\\");
    }
}
