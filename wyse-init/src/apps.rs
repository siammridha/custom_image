//! Prepares the app environment before the Alpine subsystem starts
//! (alpine.rs). Safe to run again (skips what is done).
//!
//! The apps cgroup and its limits are made at boot (prio.rs).
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
