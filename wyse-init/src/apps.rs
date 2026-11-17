//! Prepares the app environment before the Alpine subsystem starts
//! (alpine.rs). Safe to run again (skips what is done).
//!
//! cgroup /sys/fs/cgroup/apps: every app runs in it. All apps together may
//! use at most (RAM - 256 MB) and 4096 processes, and get a low CPU share,
//! so the system and the VPNs always have room.
//!
//! Alpine folder /data/alpine: apk and the packages it installs live only
//! there. It is unpacked from the image when missing (also after
//! wyse-wipe-data). /proc, /sys, /dev and /tmp are shared with the system
//! (mounts in /etc/fstab); /run is its own (alpine.rs).
use crate::sys;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::process::Command;

const A: &str = "/data/alpine";
const TARBALL: &str = "/usr/share/wyse/alpine-minirootfs.tar";

pub fn setup() -> Result<(), String> {
    if !sys::mounted("/data") {
        return Err("/data is not mounted".into());
    }
    cgroup();
    let apk = format!("{A}/sbin/apk");
    let ok = fs::metadata(&apk).map(|m| m.is_file() && m.permissions().mode() & 0o111 != 0).unwrap_or(false);
    if !ok {
        unpack()?;
        // Its mounts are in /etc/fstab. They were skipped at boot while the
        // folder did not exist; "mount -a" only does the missing ones.
        for d in ["proc", "sys", "dev", "tmp", "run"] {
            let _ = fs::create_dir_all(format!("{A}/{d}"));
        }
        sys::run_quiet("mount", &["-a"]);
    }
    Ok(())
}

fn cgroup() {
    let c = "/sys/fs/cgroup"; // mounted from /etc/fstab
    sys::put(&format!("{c}/cgroup.subtree_control"), "+memory +cpu +pids");
    let _ = fs::create_dir_all(format!("{c}/apps"));
    let ram_kb: u64 = fs::read_to_string("/proc/meminfo")
        .unwrap_or_default()
        .lines()
        .find_map(|l| l.strip_prefix("MemTotal:"))
        .and_then(|v| v.split_whitespace().next())
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let max_mb = (ram_kb / 1024).saturating_sub(256);
    sys::put(&format!("{c}/apps/memory.max"), &format!("{max_mb}M"));
    sys::put(&format!("{c}/apps/cpu.weight"), "20");
    // A fork bomb in an app would otherwise fill the kernel's thread table
    // (about 15000 on the 3040) and the VPNs could not start threads.
    sys::put(&format!("{c}/apps/pids.max"), "4096");
}

/// Unpack into /data/alpine.new, then rename: a power cut halfway never
/// leaves a broken /data/alpine (the next run starts over).
fn unpack() -> Result<(), String> {
    let new = format!("{A}.new");
    let _ = fs::remove_dir_all(&new);
    fs::create_dir_all(&new).map_err(|e| format!("{new}: {e}"))?;
    let ok = Command::new("tar")
        .args(["-xf", TARBALL, "-C", &new])
        .status()
        .map(|s| s.success())
        .unwrap_or(false);
    if !ok {
        return Err("unpacking Alpine failed".into());
    }
    fs::rename(&new, A).map_err(|e| format!("rename {new}: {e}"))
}
