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
    coldplug();
    hostname();
    network();
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
