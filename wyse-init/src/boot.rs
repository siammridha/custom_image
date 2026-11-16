//! `wyse-init boot`: the one-time setup after the overlay root is up
//! (run once by init, before the services). Only what can't be fixed in the
//! image: /etc/hosts, root's SSH keys and the mounts are in the image.
use crate::config::Config;
use crate::net;
use crate::sys;
use std::collections::BTreeSet;
use std::fs::{self, DirBuilder};
use std::os::unix::fs::DirBuilderExt;
use std::path::Path;

pub fn main() {
    std::env::set_var("PATH", "/usr/sbin:/usr/bin:/sbin:/bin");
    let c = Config::load();
    persist_dirs();
    coldplug();
    hostname(&c);
    network(&c);
}

fn mkdir_mode(path: &str, mode: u32) {
    if !Path::new(path).is_dir() {
        let _ = DirBuilder::new().recursive(true).mode(mode).create(path);
    }
}

/// The folders on /persist that the built-in links point to
/// (/var/lib/tailscale, /var/lib/netbird, /etc/netbird, /etc/dropbear).
fn persist_dirs() {
    for d in ["/persist/tailscale", "/persist/netbird/state", "/persist/netbird/etc"] {
        let _ = fs::create_dir_all(d);
    }
    mkdir_mode("/persist/dropbear", 0o700);
}

/// Load the kernel modules for the hardware found at boot: every `modalias`
/// under /sys/devices, and the model's drivers (/etc/wyse/modules, also for
/// hardware plugged in later), in one `modprobe -a`.
fn coldplug() {
    let mut aliases = BTreeSet::new();
    find_modalias(Path::new("/sys/devices"), &mut aliases);
    if let Ok(s) = fs::read_to_string("/etc/wyse/modules") {
        aliases.extend(s.split_whitespace().map(String::from));
    }
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

/// Host name (kernel) and /etc/hostname. Also run by setup-os through
/// `wyse-init hostname`.
pub fn hostname(c: &Config) {
    let h = c.get("HOSTNAME");
    if let Err(e) = sys::sethostname(h) {
        eprintln!("hostname {h}: {e}");
    }
    let _ = fs::write("/etc/hostname", format!("{h}\n"));
}

/// Loopback up, then DHCP on the network interfaces.
fn network(c: &Config) {
    if let Err(e) = net::link_up("lo") {
        eprintln!("lo: {e}");
    }
    let mut ifaces = c.words("NET_IFACES");
    if ifaces == ["auto"] {
        ifaces = fs::read_dir("/sys/class/net")
            .map(|rd| {
                rd.flatten()
                    .map(|e| e.file_name().to_string_lossy().into_owned())
                    .filter(|n| n.starts_with("eth") || n.starts_with("en"))
                    .collect()
            })
            .unwrap_or_default();
        ifaces.sort();
    }
    for i in &ifaces {
        if let Err(e) = net::link_up(i) {
            eprintln!("{i}: {e}");
        }
        // The lease handler (/usr/libexec/wyse/udhcpc-event) is udhcpc's
        // built-in default script (busybox.config), so no -s.
        sys::run("udhcpc", &["-b", "-S", "-i", i]);
    }
}
