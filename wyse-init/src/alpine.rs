//! The Alpine subsystem in /data/alpine: a chroot that shares the main
//! system's process list and /proc, so ps and top in it see everything.
//! Alpine's OpenRC starts the apps; each runs under its own supervise-daemon,
//! which restarts it when it stops.
//!   wyse-init run apps   starts it (from the main system's inittab): runs
//!                        openrc sysinit, boot and default, as Alpine's
//!                        inittab would, then stays running
//!   wyse-init stop-apps  at shutdown (inittab): openrc shutdown, then kills
//!                        what is left in the apps cgroup
//!   alpine [cmd ...]     (link) runs a command inside it; no command: a shell
//! Everything in it runs as an app: in the apps cgroup (limited RAM), low
//! priority, no real-time priority, and first to be killed when RAM runs out.
use crate::{apps, sys};
use std::fs;
use std::os::unix::process::{CommandExt, ExitStatusExt};
use std::path::Path;
use std::process::{exit, Command};

const A: &str = "/data/alpine";
const CG: &str = "/sys/fs/cgroup/apps";
/// Process number of "wyse-init run apps", written once OpenRC's sysinit is
/// done (then "alpine <cmd>" may run).
const READY: &str = "/run/alpine.ready";
const PATH: &str = "/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin";

/// `wyse-init run apps`: start OpenRC in Alpine, then stay running (init
/// starts this again if it stops).
pub fn run() -> ! {
    let _ = fs::remove_file(READY);
    if let Err(e) = apps::setup() {
        sys::log(&format!("alpine: {e}"));
        sys::idle();
    }
    if !Path::new(&format!("{A}/sbin/openrc")).exists() {
        sys::log("alpine: /data/alpine has no OpenRC (made by an older image); move it away to get a new one");
        sys::idle();
    }
    // Anything left from an earlier start (this process was restarted).
    kill_apps();
    as_app();
    copy_net_files();
    // An empty /run: no OpenRC state left from an earlier start. /proc,
    // /sys, /dev and /tmp are the main system's (/etc/fstab).
    let run = format!("{A}/run");
    let _ = sys::umount_detach(&run);
    if let Err(e) = sys::mount_fs("run", &run, "tmpfs", sys::MS_NOSUID | sys::MS_NODEV, "size=32m,mode=0755") {
        sys::log(&format!("alpine: mount {run}: {e}"));
        exit(1);
    }
    for level in ["sysinit", "boot", "default"] {
        if !openrc(level, 0) {
            sys::log(&format!("alpine: openrc {level} failed"));
        }
        if level == "sysinit" {
            sys::put(READY, &std::process::id().to_string());
        }
    }
    sys::idle();
}

/// `wyse-init stop-apps`: stop the apps the normal way (at most a minute),
/// then kill what is left.
pub fn stop() -> ! {
    if running().is_some() {
        let _ = fs::remove_file(READY);
        if !openrc("shutdown", 60) {
            sys::log("alpine: openrc shutdown failed or took too long");
        }
    }
    kill_apps();
    exit(0);
}

/// `alpine [cmd ...]`: run a command (or a login shell) inside Alpine.
pub fn enter(args: &[String]) -> ! {
    wait_running();
    as_app();
    copy_net_files();
    let (prog, rest): (&str, &[String]) = match args.split_first() {
        Some((p, r)) => (p, r),
        None => ("/bin/sh", &[]),
    };
    let mut cmd = in_alpine(prog);
    if args.is_empty() {
        cmd.arg("-l");
    }
    cmd.args(rest)
        .env("HOME", "/root")
        .env("TERM", std::env::var("TERM").unwrap_or_else(|_| "vt100".into()));
    let mut child = match cmd.spawn() {
        Ok(c) => c,
        Err(e) => {
            eprintln!("alpine: {prog}: {e}");
            exit(127);
        }
    };
    // Ctrl-C is for the command, not for this process.
    sys::ignore_interrupts();
    let st = child.wait();
    exit(st.map(|s| s.code().unwrap_or_else(|| 128 + s.signal().unwrap_or(0))).unwrap_or(1));
}

/// A command that runs in the Alpine chroot with a clean environment.
fn in_alpine(prog: &str) -> Command {
    let mut cmd = Command::new(prog);
    cmd.env_clear().env("PATH", PATH);
    unsafe {
        cmd.pre_exec(|| {
            sys::chroot(A)?;
            std::env::set_current_dir("/")
        });
    }
    cmd
}

/// `openrc <level>` in Alpine. With `secs` > 0, killed after that long.
fn openrc(level: &str, secs: u64) -> bool {
    let mut child = match in_alpine("/sbin/openrc").arg(level).spawn() {
        Ok(c) => c,
        Err(e) => {
            sys::log(&format!("alpine: openrc: {e}"));
            return false;
        }
    };
    if secs == 0 {
        return child.wait().map(|s| s.success()).unwrap_or(false);
    }
    for _ in 0..secs * 10 {
        if let Ok(Some(s)) = child.try_wait() {
            return s.success();
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    let _ = child.kill();
    let _ = child.wait();
    false
}

/// Kill every process in the apps cgroup and wait (up to 5 s) until it is
/// empty.
fn kill_apps() {
    if !sys::put(&format!("{CG}/cgroup.kill"), "1") {
        return;
    }
    for _ in 0..50 {
        if sys::read_trim(&format!("{CG}/cgroup.procs")).is_empty() {
            return;
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
}

/// The process number of "wyse-init run apps" once OpenRC's sysinit is done.
fn running() -> Option<u32> {
    let pid: u32 = sys::read_trim(READY).parse().ok()?;
    let exe = fs::read_link(format!("/proc/{pid}/exe")).ok()?;
    exe.ends_with("wyse-init").then_some(pid)
}

/// Wait until Alpine is ready (up to a minute, e.g. right after boot).
fn wait_running() {
    for i in 0..60 {
        if running().is_some() {
            return;
        }
        if i == 0 {
            eprintln!("alpine: waiting for the Alpine subsystem to start...");
        }
        sys::sleep(1);
    }
    eprintln!("alpine: the Alpine subsystem is not running (see /var/log/messages)");
    exit(1);
}

/// In the apps cgroup (limited RAM), low priority, first to be killed when
/// RAM runs out. Without CAP_SYS_NICE the programs it starts can't use
/// real-time priority or raise their priority. Children inherit all of it.
fn as_app() {
    const CAP_SYS_NICE: u64 = 23;
    sys::put(&format!("{CG}/cgroup.procs"), &std::process::id().to_string());
    sys::put("/proc/self/oom_score_adj", "500");
    sys::nice(10);
    sys::drop_cap(CAP_SYS_NICE);
}

/// Name servers and host names come from the main system.
fn copy_net_files() {
    for f in ["resolv.conf", "hosts"] {
        let _ = fs::copy(format!("/etc/{f}"), format!("{A}/etc/{f}"));
    }
}
