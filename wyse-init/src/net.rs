//! Network interface setup through the kernel's ioctl calls, the way
//! BusyBox ifconfig (networking/ifconfig.c, interface.c) does it, so the
//! image needs no `ip` command.
use std::ffi::CString;
use std::io;
use std::net::Ipv4Addr;
use std::os::raw::{c_char, c_int, c_short, c_ulong, c_ushort, c_void};

extern "C" {
    fn socket(domain: c_int, ty: c_int, proto: c_int) -> c_int;
    fn ioctl(fd: c_int, req: c_ulong, ...) -> c_int;
    fn close(fd: c_int) -> c_int;
}

const AF_INET: c_int = 2;
const SOCK_DGRAM: c_int = 2;
const SOCK_CLOEXEC: c_int = 0o2000000;
const SIOCGIFFLAGS: c_ulong = 0x8913;
const SIOCSIFFLAGS: c_ulong = 0x8914;
const SIOCSIFADDR: c_ulong = 0x8916;
const SIOCSIFBRDADDR: c_ulong = 0x891a;
const SIOCSIFNETMASK: c_ulong = 0x891c;
const SIOCADDRT: c_ulong = 0x890b;
const SIOCDELRT: c_ulong = 0x890c;
const IFF_UP: i16 = 1;
const RTF_UP: c_ushort = 1;
const RTF_GATEWAY: c_ushort = 2;
const RTF_HOST: c_ushort = 4;

/// struct ifreq (40 bytes on x86_64): the name, then a union. Only the
/// parts used here: flags (a short) or a struct sockaddr_in.
#[repr(C)]
pub(crate) struct IfReq {
    name: [u8; 16],
    data: [u8; 24],
}

impl IfReq {
    pub(crate) fn new(name: &str) -> IfReq {
        let mut r = IfReq { name: [0; 16], data: [0; 24] };
        let b = name.as_bytes();
        let n = b.len().min(15);
        r.name[..n].copy_from_slice(&b[..n]);
        r
    }

    fn flags(&self) -> i16 {
        i16::from_ne_bytes([self.data[0], self.data[1]])
    }

    fn set_flags(&mut self, f: i16) {
        self.data[..2].copy_from_slice(&f.to_ne_bytes());
    }

    /// Put `a` in the union as a struct sockaddr_in.
    pub(crate) fn set_addr(&mut self, a: Ipv4Addr) {
        self.data = [0; 24];
        self.data[..16].copy_from_slice(&sockaddr_in(a));
    }
}

/// struct sockaddr_in: family, port 0, address, zero padding.
pub(crate) fn sockaddr_in(a: Ipv4Addr) -> [u8; 16] {
    let mut s = [0u8; 16];
    s[..2].copy_from_slice(&(AF_INET as u16).to_ne_bytes());
    s[4..8].copy_from_slice(&a.octets());
    s
}

/// An AF_INET datagram socket for the ioctl calls; closed when dropped.
pub(crate) struct Sock(c_int);

impl Sock {
    pub(crate) fn new() -> io::Result<Sock> {
        let fd = unsafe { socket(AF_INET, SOCK_DGRAM | SOCK_CLOEXEC, 0) };
        if fd < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(Sock(fd))
    }

    pub(crate) fn ioctl<T>(&self, req: c_ulong, arg: &mut T) -> io::Result<()> {
        if unsafe { ioctl(self.0, req, arg as *mut T as *mut c_void) } < 0 {
            return Err(io::Error::last_os_error());
        }
        Ok(())
    }
}

impl Drop for Sock {
    fn drop(&mut self) {
        unsafe { close(self.0) };
    }
}

/// `ifconfig <name> up`: read the flags, add IFF_UP, write them back.
pub fn link_up(name: &str) -> io::Result<()> {
    let s = Sock::new()?;
    let mut r = IfReq::new(name);
    s.ioctl(SIOCGIFFLAGS, &mut r)?;
    r.set_flags(r.flags() | IFF_UP);
    s.ioctl(SIOCSIFFLAGS, &mut r)
}

/// `ifconfig <name> <addr> [broadcast <b>] netmask <m>`, in the same order
/// of calls. Setting the address replaces the old one (a renew with a new
/// address); 0.0.0.0 removes it.
pub fn set_addr(name: &str, addr: Ipv4Addr, bcast: Option<Ipv4Addr>, mask: Option<Ipv4Addr>) -> io::Result<()> {
    let s = Sock::new()?;
    let mut r = IfReq::new(name);
    r.set_addr(addr);
    s.ioctl(SIOCSIFADDR, &mut r)?;
    if let Some(b) = bcast {
        r.set_addr(b);
        s.ioctl(SIOCSIFBRDADDR, &mut r)?;
    }
    if let Some(m) = mask {
        r.set_addr(m);
        s.ioctl(SIOCSIFNETMASK, &mut r)?;
    }
    Ok(())
}

/// struct rtentry from <net/route.h> (x86_64), as BusyBox route uses it.
#[repr(C)]
struct RtEntry {
    pad1: c_ulong,
    dst: [u8; 16],
    gateway: [u8; 16],
    genmask: [u8; 16],
    flags: c_ushort,
    pad2: c_short,
    pad3: c_ulong,
    pad4: *mut c_void,
    metric: c_short,
    dev: *mut c_char,
    mtu: c_ulong,
    window: c_ulong,
    irtt: c_ushort,
}

/// An IPv4 route on `dev`. `gw` None = on the link. `metric` as `route`
/// shows it; for a delete, None matches any metric.
pub struct Route {
    pub dst: Ipv4Addr,
    pub mask: Ipv4Addr,
    pub gw: Option<Ipv4Addr>,
    pub metric: Option<u16>,
}

fn route(req: c_ulong, dev: &str, r: &Route) -> io::Result<()> {
    let dev = CString::new(dev).unwrap_or_default();
    let mut flags = RTF_UP;
    if r.mask == Ipv4Addr::BROADCAST {
        flags |= RTF_HOST;
    }
    if r.gw.is_some() {
        flags |= RTF_GATEWAY;
    }
    let mut e = RtEntry {
        pad1: 0,
        dst: sockaddr_in(r.dst),
        gateway: sockaddr_in(r.gw.unwrap_or(Ipv4Addr::UNSPECIFIED)),
        genmask: sockaddr_in(r.mask),
        flags,
        pad2: 0,
        pad3: 0,
        pad4: std::ptr::null_mut(),
        // The kernel takes the metric plus one; 0 means "not given".
        metric: r.metric.map_or(0, |m| m as c_short + 1),
        dev: dev.as_ptr() as *mut c_char,
        mtu: 0,
        window: 0,
        irtt: 0,
    };
    Sock::new()?.ioctl(req, &mut e)
}

/// `route add`.
pub fn route_add(dev: &str, r: &Route) -> io::Result<()> {
    route(SIOCADDRT, dev, r)
}

/// `route del`.
pub fn route_del(dev: &str, r: &Route) -> io::Result<()> {
    route(SIOCDELRT, dev, r)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn layout() {
        assert_eq!(std::mem::size_of::<IfReq>(), 40);
        assert_eq!(std::mem::size_of::<RtEntry>(), 120);
        let s = sockaddr_in(Ipv4Addr::new(192, 168, 80, 13));
        assert_eq!(&s[..8], &[2, 0, 0, 0, 192, 168, 80, 13]);
        assert_eq!(IfReq::new("a-very-long-interface-name").name[15], 0);
    }
}
