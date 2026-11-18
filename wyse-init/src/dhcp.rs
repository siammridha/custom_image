//! udhcpc's lease handler (/usr/libexec/wyse/udhcpc-event, a link to
//! wyse-init; udhcpc's default script, set in busybox.config). Does what
//! Buildroot's udhcpc default.script does, with the kernel calls of
//! ifconfig and route (see net.rs), so the image needs no `ip` command:
//!   deconfig       interface up, address 0.0.0.0, drop its DNS lines
//!   bound / renew  set address, routes and DNS from the lease
//! udhcpc passes the lease in environment variables.
use crate::net::{self, Route};
use crate::prio;
use std::env;
use std::fs;
use std::net::Ipv4Addr;

const RESOLV: &str = "/etc/resolv.conf";
const ANY: Ipv4Addr = Ipv4Addr::UNSPECIFIED;

fn var(k: &str) -> String {
    env::var(k).unwrap_or_default()
}

fn ip(k: &str) -> Option<Ipv4Addr> {
    var(k).parse().ok()
}

pub fn main(action: &str) -> i32 {
    let iface = var("interface");
    if action.is_empty() || iface.is_empty() {
        eprintln!("udhcpc-event: should be called from udhcpc");
        return 1;
    }
    match action {
        "deconfig" => {
            let _ = net::link_up(&iface);
            let _ = net::set_addr(&iface, ANY, None, None);
            write_resolv(&iface, &[]);
        }
        "bound" | "renew" => bound(&iface),
        _ => {} // leasefail, nak: nothing to do
    }
    0
}

fn report(what: &str, r: std::io::Result<()>) {
    if let Err(e) = r {
        eprintln!("udhcpc-event: {what}: {e}");
    }
}

fn bound(iface: &str) {
    let Some(addr) = ip("ip") else { return };
    prio::qdisc(iface);
    report("address", net::set_addr(iface, addr, ip("broadcast"), ip("subnet")));

    // RFC 3442: with classless static routes, the router option is ignored.
    let statics = var("staticroutes");
    if !statics.is_empty() {
        for (dst, gw, mask) in gateway_routes(iface) {
            let _ = net::route_del(iface, &Route { dst, mask, gw: Some(gw), metric: None });
        }
        for (dst, mask, gw) in parse_static(&statics) {
            let gw = Some(gw).filter(|g| !g.is_unspecified());
            report("route", net::route_add(iface, &Route { dst, mask, gw, metric: None }));
        }
    } else {
        let routers: Vec<Ipv4Addr> = var("router").split_whitespace().filter_map(|r| r.parse().ok()).collect();
        if !routers.is_empty() {
            let default = Route { dst: ANY, mask: ANY, gw: None, metric: None };
            for _ in 0..64 {
                if net::route_del(iface, &default).is_err() {
                    break;
                }
            }
            for (n, r) in routers.into_iter().enumerate() {
                let route = Route { dst: ANY, mask: ANY, gw: Some(r), metric: Some(n as u16) };
                report("default route", net::route_add(iface, &route));
            }
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

/// "net/len gw net/len gw ..." (udhcpc's staticroutes) -> (net, mask, gw).
fn parse_static(s: &str) -> Vec<(Ipv4Addr, Ipv4Addr, Ipv4Addr)> {
    let w: Vec<&str> = s.split_whitespace().collect();
    w.chunks(2)
        .filter_map(|p| {
            let (net, len) = p.first()?.split_once('/')?;
            let len: u32 = len.parse().ok().filter(|l| *l <= 32)?;
            let mask = Ipv4Addr::from(u32::MAX.checked_shl(32 - len).unwrap_or(0));
            Some((net.parse().ok()?, mask, p.get(1)?.parse().ok()?))
        })
        .collect()
}

/// Routes on `iface` that go through a gateway: (dest, gateway, mask).
fn gateway_routes(iface: &str) -> Vec<(Ipv4Addr, Ipv4Addr, Ipv4Addr)> {
    parse_routes(&fs::read_to_string("/proc/net/route").unwrap_or_default(), iface)
}

fn parse_routes(table: &str, iface: &str) -> Vec<(Ipv4Addr, Ipv4Addr, Ipv4Addr)> {
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
            (!gw.is_unspecified()).then_some((dest, gw, mask))
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
    fn static_routes() {
        let r = parse_static("10.0.0.0/8 192.168.80.1 0.0.0.0/0 192.168.80.2 1.2.3.4/32 0.0.0.0 bad");
        let a = |s: &str| s.parse::<Ipv4Addr>().unwrap();
        assert_eq!(
            r,
            [
                (a("10.0.0.0"), a("255.0.0.0"), a("192.168.80.1")),
                (a("0.0.0.0"), a("0.0.0.0"), a("192.168.80.2")),
                (a("1.2.3.4"), a("255.255.255.255"), a("0.0.0.0")),
            ]
        );
    }

    #[test]
    fn route_table() {
        let t = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n\
                 eth0\t00000000\t0150A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0\n\
                 eth0\t0050A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n\
                 eth1\t00000000\t0101A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0\n";
        assert_eq!(
            parse_routes(t, "eth0"),
            [(Ipv4Addr::UNSPECIFIED, Ipv4Addr::new(192, 168, 80, 1), Ipv4Addr::UNSPECIFIED)]
        );
    }
}
