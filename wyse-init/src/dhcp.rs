//! udhcpc's lease handler (udhcpc -s /usr/libexec/wyse/udhcpc-event, a link
//! to wyse-init). Does what Buildroot's udhcpc default.script did:
//!   deconfig       interface up, address 0.0.0.0, drop its DNS lines
//!   bound / renew  set address, routes and DNS from the lease
//! udhcpc passes the lease in environment variables. Uses `ip` (the image
//! has no ifconfig/route), as BusyBox's examples/udhcp/simple.script does.
use crate::sys;
use std::env;
use std::fs;
use std::net::Ipv4Addr;

const RESOLV: &str = "/etc/resolv.conf";

fn var(k: &str) -> String {
    env::var(k).unwrap_or_default()
}

pub fn main(action: &str) -> i32 {
    std::env::set_var("PATH", "/usr/sbin:/usr/bin:/sbin:/bin");
    let iface = var("interface");
    if action.is_empty() || iface.is_empty() {
        eprintln!("udhcpc-event: should be called from udhcpc");
        return 1;
    }
    match action {
        "deconfig" => {
            sys::run("ip", &["-4", "addr", "flush", "dev", &iface]);
            sys::run("ip", &["link", "set", "dev", &iface, "up"]);
            write_resolv(&iface, &[]);
        }
        "bound" | "renew" => bound(&iface),
        _ => {} // leasefail, nak: nothing to do
    }
    0
}

fn bound(iface: &str) {
    let ip = var("ip");
    let (bcast, mask) = (var("broadcast"), var("subnet"));
    let addr = format!("{ip}/{}", prefix_len(&mask).unwrap_or(32));
    // No broadcast in the lease: "+" works it out from the netmask, as
    // ifconfig did (simple.script does the same).
    let bcast = if bcast.is_empty() { "+".to_string() } else { bcast };
    let args = ["addr", "replace", addr.as_str(), "broadcast", bcast.as_str(), "dev", iface];
    sys::run("ip", &args);
    // ifconfig replaced the old address; "ip addr replace" adds a new one
    // next to it. Remove any other IPv4 address (a renew with a new IP).
    for old in addresses(iface) {
        if old != addr {
            sys::run("ip", &["addr", "del", &old, "dev", iface]);
        }
    }

    // RFC 3442: with classless static routes, the router option is ignored.
    let statics = var("staticroutes");
    let router = var("router");
    if !statics.is_empty() {
        for (dest, gw, mask) in gateway_routes(iface) {
            let net = format!("{dest}/{}", prefix_len(&mask).unwrap_or(32));
            sys::run("ip", &["route", "del", &net, "via", &gw, "dev", iface]);
        }
        let s: Vec<&str> = statics.split_whitespace().collect();
        for pair in s.chunks(2) {
            if let [net, gw] = pair {
                sys::run("ip", &["route", "replace", net, "via", gw, "dev", iface]);
            }
        }
    } else if !router.is_empty() {
        for _ in 0..64 {
            if !sys::run_quiet("ip", &["route", "del", "default", "dev", iface]) {
                break;
            }
        }
        for (n, r) in router.split_whitespace().enumerate() {
            let metric = n.to_string();
            sys::run("ip", &["route", "add", "default", "via", r, "dev", iface, "metric", &metric]);
        }
    }

    // Prefer the RFC 3397 search list (option 119) over the domain name.
    let search = Some(var("search")).filter(|s| !s.is_empty()).unwrap_or_else(|| var("domain"));
    let mut lines = Vec::new();
    if !search.is_empty() {
        lines.push(format!("search {search} # {iface}"));
    }
    for d in var("dns").split_whitespace() {
        lines.push(format!("nameserver {d} # {iface}"));
    }
    write_resolv(iface, &lines);
}

/// Replace this interface's lines in resolv.conf (marked "# <iface>").
fn write_resolv(iface: &str, add: &[String]) {
    let old = fs::read_to_string(RESOLV).unwrap_or_default();
    let _ = fs::write(RESOLV, resolv_update(&old, iface, add));
}

fn resolv_update(old: &str, iface: &str, add: &[String]) -> String {
    let tag = format!("# {iface}");
    let mut out: String = old
        .lines()
        .filter(|l| !l.ends_with(&tag))
        .map(|l| format!("{l}\n"))
        .collect();
    for l in add {
        out += l;
        out.push('\n');
    }
    out
}

/// 255.255.255.0 -> 24. None if it is not a valid netmask.
fn prefix_len(mask: &str) -> Option<u32> {
    let m = u32::from(mask.parse::<Ipv4Addr>().ok()?);
    (m.leading_ones() == m.count_ones()).then(|| m.count_ones())
}

/// The IPv4 addresses on `iface`, as "a.b.c.d/nn".
fn addresses(iface: &str) -> Vec<String> {
    let out = std::process::Command::new("ip")
        .args(["-4", "-o", "addr", "show", "dev", iface])
        .output()
        .map(|o| String::from_utf8_lossy(&o.stdout).into_owned())
        .unwrap_or_default();
    parse_addresses(&out)
}

fn parse_addresses(out: &str) -> Vec<String> {
    out.lines()
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            let i = f.iter().position(|w| *w == "inet")?;
            f.get(i + 1).map(|a| a.to_string())
        })
        .collect()
}

/// Routes on `iface` that go through a gateway: (dest, gateway, mask).
fn gateway_routes(iface: &str) -> Vec<(String, String, String)> {
    parse_routes(&fs::read_to_string("/proc/net/route").unwrap_or_default(), iface)
}

fn parse_routes(table: &str, iface: &str) -> Vec<(String, String, String)> {
    let ip = |h: &str| u32::from_str_radix(h, 16).map(|v| Ipv4Addr::from(v.to_le_bytes()));
    table
        .lines()
        .skip(1)
        .filter_map(|l| {
            let f: Vec<&str> = l.split_whitespace().collect();
            if f.len() < 8 || f[0] != iface {
                return None;
            }
            let (dest, gw, mask) = (ip(f[1]).ok()?, ip(f[2]).ok()?, ip(f[7]).ok()?);
            (!gw.is_unspecified()).then(|| (dest.to_string(), gw.to_string(), mask.to_string()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn resolv_keeps_other_interfaces() {
        let old = "nameserver 1.1.1.1 # eth0\nnameserver 9.9.9.9 # eth1\nsearch lan # eth0\n";
        let new = resolv_update(old, "eth0", &["nameserver 192.168.80.1 # eth0".into()]);
        assert_eq!(new, "nameserver 9.9.9.9 # eth1\nnameserver 192.168.80.1 # eth0\n");
        assert_eq!(resolv_update(old, "eth1", &[]), "nameserver 1.1.1.1 # eth0\nsearch lan # eth0\n");
    }

    #[test]
    fn netmask() {
        assert_eq!(prefix_len("255.255.255.0"), Some(24));
        assert_eq!(prefix_len("255.255.255.255"), Some(32));
        assert_eq!(prefix_len("0.0.0.0"), Some(0));
        assert_eq!(prefix_len("255.0.255.0"), None);
        assert_eq!(prefix_len(""), None);
    }

    #[test]
    fn ip_addr_output() {
        let out = "2: eth0    inet 192.168.80.13/24 brd 192.168.80.255 scope global eth0\\       valid_lft forever preferred_lft forever\n\
                   2: eth0    inet 10.0.0.5/8 scope global secondary eth0\n";
        assert_eq!(parse_addresses(out), ["192.168.80.13/24", "10.0.0.5/8"]);
    }

    #[test]
    fn route_table() {
        let t = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n\
                 eth0\t00000000\t0150A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0\n\
                 eth0\t0050A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n\
                 eth1\t00000000\t0101A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0\n";
        assert_eq!(
            parse_routes(t, "eth0"),
            [("0.0.0.0".to_string(), "192.168.80.1".to_string(), "0.0.0.0".to_string())]
        );
    }
}
