//! Settings, all fixed in the image (build a new image to change them):
//!   - NetBird setup key and Tailscale auth key: files in /etc/wyse, root
//!     only (from config/network). NetBird and Tailscale read them themselves, so the
//!     keys are never on a command line, where apps could read them
//!   - everything else: below, in this program
//! Files are read from /rom, the read-only image, so a change in RAM is not
//! used.
use std::path::Path;

/// The host name, from the device file (config/devices/) at build time.
pub const HOSTNAME: &str = match option_env!("WYSE_HOSTNAME") {
    Some(v) if !v.is_empty() => v,
    _ => "localhost",
};

/// The model's drivers (board/wyse/modules-<model>), from the build. Loaded
/// at boot, also when the hardware is not plugged in yet.
pub const MODULES: &str = match option_env!("WYSE_MODULES") {
    Some(v) => v,
    None => "",
};

/// NetBird's management server, from config/network at build time
/// (netbird_url, required by the build).
pub const NB_MANAGEMENT_URL: &str = match option_env!("WYSE_NB_MANAGEMENT_URL") {
    Some(v) => v,
    None => "",
};

/// NetBird SSH on (root login). Exit node is set in the NetBird dashboard:
/// Network Routes, 0.0.0.0/0, this peer as routing peer.
/// --disable-dns: NetBird leaves /etc/resolv.conf alone (DNS from DHCP), so
/// name lookups work even when NetBird is down.
/// The same settings are in the image's default.json (scripts/device-keys.sh),
/// so the daemon connects with them at start; these are for vpn-guard's "up".
pub const NB_UP_ARGS: &[&str] = &["--allow-server-ssh", "--enable-ssh-root", "--disable-dns"];

/// Tailscale SSH on. No exit node. No Tailscale firewall rules: they drop
/// all traffic from 100.64.0.0/10 that does not come in over Tailscale, and
/// NetBird's addresses (100.80.0.0/16) are in that range.
pub const TS_UP_ARGS: &[&str] = &["--ssh", "--netfilter-mode=off"];

/// The image's own file: under /rom once the overlay root is up.
fn image_file(path: &str) -> String {
    let rom = format!("/rom{path}");
    if Path::new(&rom).exists() {
        rom
    } else {
        path.to_string()
    }
}

/// NetBird setup key file, if the image has one.
pub fn nb_key_file() -> Option<String> {
    Some(image_file("/etc/wyse/netbird.key")).filter(|f| Path::new(f).exists())
}

/// Tailscale auth key file, if the image has one.
pub fn ts_key_file() -> Option<String> {
    Some(image_file("/etc/wyse/tailscale.key")).filter(|f| Path::new(f).exists())
}
