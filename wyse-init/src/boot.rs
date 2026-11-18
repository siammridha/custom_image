//! `wyse-init boot`: the one-time setup after the overlay root is up
//! (run once by init, before the services). Only what can't be fixed in the
//! image: /etc/hosts, root's SSH keys and the mounts are in the image.
use crate::config;
use crate::net;
use crate::prio;
use crate::sys;
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

pub fn main() {
    std::env::set_var("PATH", "/usr/sbin:/usr/bin:/sbin:/bin");
    prio::setup();
    logs();
    coldplug();
    hostname();
    network();
}

/// syslogd writes to /data/log (inittab). If /data is not mounted, the
/// folder is in RAM and logging still works. Kernel crash records that
/// pstore kept in EFI variables (the last messages before a panic) are
/// moved there; deleting them frees the BIOS's space for the next crash.
fn logs() {
    let dir = "/data/log";
    let _ = fs::create_dir_all(dir);
    if !sys::mounted("/data") || sys::mount_fs("pstore", "/sys/fs/pstore", "pstore", 0, "").is_err() {
        return;
    }
    // The kernel splits one crash into 1 KB records, "Panic#1 Part1" being
    // the end. Joined into one file, oldest part first.
    let mut parts: Vec<(u32, String, std::path::PathBuf)> = Vec::new();
    if let Ok(rd) = fs::read_dir("/sys/fs/pstore") {
        for e in rd.flatten() {
            if let Ok(t) = fs::read_to_string(e.path()) {
                parts.push((part_no(&t), t, e.path()));
            }
        }
    }
    if parts.is_empty() {
        let _ = sys::umount("/sys/fs/pstore");
        return;
    }
    parts.sort_by(|a, b| b.0.cmp(&a.0));
    let text: String = parts.iter().map(|p| p.1.as_str()).collect();
    // pstore gives each record the time of the crash (Unix seconds).
    let when = fs::metadata(&parts[0].2)
        .and_then(|m| m.modified())
        .ok()
        .and_then(|t| t.duration_since(std::time::UNIX_EPOCH).ok())
        .map_or(0, |d| d.as_secs());
    let to = format!("{dir}/crash-{when}");
    if fs::write(&to, text).is_ok() {
        for p in &parts {
            let _ = fs::remove_file(&p.2);
        }
    }
    let _ = sys::umount("/sys/fs/pstore");
}

/// "Panic#1 Part3\n..." -> 3.
fn part_no(record: &str) -> u32 {
    record.lines().next().and_then(|l| l.rsplit("Part").next()).and_then(|n| n.trim().parse().ok()).unwrap_or(0)
}

/// Load the kernel modules for the hardware found at boot: every `modalias`
/// under /sys/devices, and the model's drivers (config::MODULES, also for
/// hardware plugged in later), in one `modprobe -a`.
fn coldplug() {
    let mut aliases = BTreeSet::new();
    find_modalias(Path::new("/sys/devices"), &mut aliases);
    aliases.extend(config::MODULES.split_whitespace().map(String::from));
    if aliases.is_empty() {
        return;
    }
    let mut args = vec!["-a", "-q"];
    args.extend(aliases.iter().map(String::as_str));
    sys::run_quiet("modprobe", &args);
}

fn find_modalias(dir: &Path, out: &mut BTreeSet<String>) {
    let Ok(rd) = fs::read_dir(dir) else { return };
    for e in rd.flatten() {
        // file_type() does not follow links, like `find` by default.
        let Ok(ft) = e.file_type() else { continue };
        if ft.is_dir() {
            find_modalias(&e.path(), out);
        } else if ft.is_file() && e.file_name() == "modalias" {
            if let Ok(s) = fs::read_to_string(e.path()) {
                out.extend(s.lines().map(str::trim).filter(|l| !l.is_empty()).map(String::from));
            }
        }
    }
}

/// The kernel's host name (built into this program).
fn hostname() {
    let h = config::HOSTNAME;
    if let Err(e) = sys::sethostname(h) {
        eprintln!("hostname {h}: {e}");
    }
}

/// Loopback up, then DHCP on every eth*/en* interface.
fn network() {
    if let Err(e) = net::link_up("lo") {
        eprintln!("lo: {e}");
    }
    let mut ifaces: Vec<String> = fs::read_dir("/sys/class/net")
        .map(|rd| {
            rd.flatten()
                .map(|e| e.file_name().to_string_lossy().into_owned())
                .filter(|n| n.starts_with("eth") || n.starts_with("en"))
                .collect()
        })
        .unwrap_or_default();
    ifaces.sort();
    for i in &ifaces {
        if let Err(e) = net::link_up(i) {
            eprintln!("{i}: {e}");
        }
        // The lease handler (/usr/libexec/wyse/udhcpc-event) is udhcpc's
        // built-in default script (busybox.config), so no -s. -O ntpsrv
        // asks the router for its NTP servers.
        sys::run("udhcpc", &["-b", "-S", "-O", "ntpsrv", "-i", i]);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn part() {
        assert_eq!(part_no("Panic#1 Part11\n<4>[ 43.7] RIP"), 11);
        assert_eq!(part_no("Oops#2 Part1\n"), 1);
        assert_eq!(part_no(""), 0);
    }
}
