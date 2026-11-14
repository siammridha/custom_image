//! udhcpc's lease handler (udhcpc -s /usr/libexec/wyse/udhcpc-event, a link
//! to wyse-init). Does what Buildroot's udhcpc default.script did:
//!   deconfig       interface up, address 0.0.0.0, drop its DNS lines
//!   bound / renew  set address, routes and DNS from the lease
//! udhcpc passes the lease in environment variables.
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
            sys::run("ifconfig", &[&iface, "up"]);
            sys::run("ifconfig", &[&iface, "0.0.0.0"]);
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
    let mut args = vec![iface, ip.as_str()];
    if !bcast.is_empty() {
        args.extend(["broadcast", bcast.as_str()]);
    }
    if !mask.is_empty() {
        args.extend(["netmask", mask.as_str()]);
    }
    sys::run("ifconfig", &args);

    // RFC 3442: with classless static routes, the router option is ignored.
    let statics = var("staticroutes");
    let router = var("router");
    if !statics.is_empty() {
        for (dest, gw, mask) in gateway_routes(iface) {
            sys::run("route", &["del", "-net", &dest, "netmask", &mask, "gw", &gw, "dev", iface]);
        }
        let s: Vec<&str> = statics.split_whitespace().collect();
        for pair in s.chunks(2) {
            if let [net, gw] = pair {
                sys::run("route", &["add", "-net", net, "gw", gw, "dev", iface]);
            }
        }
    } else if !router.is_empty() {
        for _ in 0..64 {
            if !sys::run_quiet("route", &["del", "default", "gw", "0.0.0.0", "dev", iface]) {
                break;
            }
        }
        for r in router.split_whitespace() {
            sys::run("route", &["add", "default", "gw", r, "dev", iface]);
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
