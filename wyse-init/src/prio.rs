//! Top priority for remote access over the apps, for every resource.
//!
//! Two cgroups (made once at boot, before the services start):
//!   vpn   NetBird, Tailscale, SSH, vpn-guard, the watchdog and ntpd
//!         (service.rs puts each one in it)
//!   apps  everything in the Alpine subsystem (alpine.rs)
//!
//!   CPU      vpn weight 10000, apps 1: when both want the CPU, vpn gets
//!            about all of it. Apps can't use real-time priority (alpine.rs),
//!            and real-time programs leave 20% of the CPU to the rest
//!            (fair_server).
//!   memory   vpn keeps 128 MB the kernel never takes away for apps; apps
//!            may use at most RAM - 256 MB; the vpn programs are never killed
//!            when RAM runs out (service.rs).
//!   disk     vpn weight 10000, apps 1 (the kernel's iocost on each disk).
//!   processes  apps at most 4096, so the VPNs can always start threads.
//!   network  packets from apps leave by the low band of a "prio" queue on
//!            each network interface; the rest (VPN, SSH) by the high band,
//!            which always goes first. An nftables rule marks app packets
//!            (socket cgroup "apps" -> priority 1:2).
use crate::sys;
use std::ffi::c_int;
use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;

const CG: &str = "/sys/fs/cgroup"; // mounted from /etc/fstab
pub const VPN: &str = "/sys/fs/cgroup/vpn";
const APPS: &str = "/sys/fs/cgroup/apps";
/// Handle of the prio queue (1:) and the band for app packets (1:2).
const QDISC: u32 = 0x0001_0000;
const LOW_BAND: u32 = 0x0001_0002;

/// `wyse-init boot`: the cgroups, the disk weights and the nftables rule.
pub fn setup() {
    sys::put(&format!("{CG}/cgroup.subtree_control"), "+memory +cpu +pids +io");
    for d in [VPN, APPS] {
        let _ = fs::create_dir_all(d);
    }
    sys::put(&format!("{VPN}/cpu.weight"), "10000");
    sys::put(&format!("{VPN}/memory.min"), "128M");
    sys::put(&format!("{VPN}/io.weight"), "default 10000");

    let ram_kb: u64 = fs::read_to_string("/proc/meminfo")
        .unwrap_or_default()
        .lines()
        .find_map(|l| l.strip_prefix("MemTotal:"))
        .and_then(|v| v.split_whitespace().next())
        .and_then(|v| v.parse().ok())
        .unwrap_or(0);
    let max_mb = (ram_kb / 1024).saturating_sub(256);
    sys::put(&format!("{APPS}/memory.max"), &format!("{max_mb}M"));
    sys::put(&format!("{APPS}/cpu.weight"), "1");
    sys::put(&format!("{APPS}/io.weight"), "default 1");
    // A fork bomb in an app would otherwise fill the kernel's thread table
    // (about 15000 on the 3040) and the VPNs could not start threads.
    sys::put(&format!("{APPS}/pids.max"), "4096");

    fair_server();
    iocost();
    if let Err(e) = nft_rule() {
        sys::kmsg(&format!("wyse-init: nftables rule for app packets: {e}"));
    }
}

/// Put this process (and what it starts) in the vpn cgroup.
pub fn join_vpn() {
    sys::put(&format!("{VPN}/cgroup.procs"), &std::process::id().to_string());
}

/// Normal programs (the VPNs, SSH) get at least 20 ms of every 100 ms on
/// each CPU, even when real-time programs want it all. The kernel's
/// default is 50 ms of every 1 s, so under a real-time load an SSH check
/// took 6-13 s; with this, 2-3 s. (Since kernel 6.12 this "fair server"
/// does the job of sched_rt_runtime_us.) It is set in debugfs.
fn fair_server() {
    let d = "/sys/kernel/debug";
    let mine = !sys::mounted(d) && sys::mount_fs("debugfs", d, "debugfs", 0, "").is_ok();
    if let Ok(rd) = fs::read_dir(format!("{d}/sched/fair_server")) {
        for e in rd.flatten() {
            let p = e.path();
            // Period first: 50 ms of 100 ms is allowed, 20 ms of 1 s too.
            sys::put(&format!("{}/period", p.display()), "100000000");
            sys::put(&format!("{}/runtime", p.display()), "20000000");
        }
    }
    if mine {
        let _ = sys::umount(d);
    }
}

/// io.weight only works on disks where iocost is on. Every disk except
/// loop, RAM and the eMMC boot areas.
fn iocost() {
    let Ok(rd) = fs::read_dir("/sys/block") else { return };
    for e in rd.flatten() {
        let n = e.file_name().to_string_lossy().into_owned();
        if ["loop", "ram", "zram"].iter().any(|p| n.starts_with(p)) || n.contains("boot") {
            continue;
        }
        let dev = sys::read_trim(&format!("/sys/block/{n}/dev"));
        if !dev.is_empty() {
            sys::put(&format!("{CG}/io.cost.qos"), &format!("{dev} enable=1"));
        }
    }
}

// ---- netlink -------------------------------------------------------------

extern "C" {
    fn socket(domain: c_int, ty: c_int, proto: c_int) -> c_int;
    fn send(fd: c_int, buf: *const u8, len: usize, flags: c_int) -> isize;
    fn recv(fd: c_int, buf: *mut u8, len: usize, flags: c_int) -> isize;
    fn close(fd: c_int) -> c_int;
}

const AF_NETLINK: c_int = 16;
const SOCK_RAW: c_int = 3;
const SOCK_CLOEXEC: c_int = 0o2000000;
const NETLINK_ROUTE: c_int = 0;
const NETLINK_NETFILTER: c_int = 12;
const NLM_F_REQUEST: u16 = 1;
const NLM_F_ACK: u16 = 4;
const NLM_F_REPLACE: u16 = 0x100;
const NLM_F_CREATE: u16 = 0x400;
const NLMSG_ERROR: u16 = 2;
const NLA_F_NESTED: u16 = 0x8000;

/// A netlink message being built: header, fixed part, attributes.
struct Msg {
    b: Vec<u8>,
    nests: Vec<usize>,
}

impl Msg {
    fn new(ty: u16, flags: u16, seq: u32, fixed: &[u8]) -> Msg {
        let mut b = Vec::new();
        b.extend(0u32.to_ne_bytes()); // length, set in done()
        b.extend(ty.to_ne_bytes());
        b.extend(flags.to_ne_bytes());
        b.extend(seq.to_ne_bytes());
        b.extend(0u32.to_ne_bytes()); // port: the kernel fills it in
        b.extend(fixed);
        let mut m = Msg { b, nests: Vec::new() };
        m.pad();
        m
    }
    fn pad(&mut self) {
        while self.b.len() % 4 != 0 {
            self.b.push(0);
        }
    }
    fn attr(&mut self, ty: u16, data: &[u8]) -> &mut Self {
        self.b.extend(((4 + data.len()) as u16).to_ne_bytes());
        self.b.extend(ty.to_ne_bytes());
        self.b.extend(data);
        self.pad();
        self
    }
    fn str(&mut self, ty: u16, s: &str) -> &mut Self {
        let mut d = s.as_bytes().to_vec();
        d.push(0);
        self.attr(ty, &d)
    }
    /// nftables numbers are big-endian.
    fn be32(&mut self, ty: u16, v: u32) -> &mut Self {
        self.attr(ty, &v.to_be_bytes())
    }
    fn begin(&mut self, ty: u16) -> &mut Self {
        self.nests.push(self.b.len());
        self.b.extend(0u16.to_ne_bytes());
        self.b.extend((ty | NLA_F_NESTED).to_ne_bytes());
        self
    }
    fn end(&mut self) -> &mut Self {
        let at = self.nests.pop().expect("end() without begin()");
        let len = (self.b.len() - at) as u16;
        self.b[at..at + 2].copy_from_slice(&len.to_ne_bytes());
        self
    }
    fn done(mut self) -> Vec<u8> {
        let len = self.b.len() as u32;
        self.b[0..4].copy_from_slice(&len.to_ne_bytes());
        self.b
    }
}

/// Send the messages in one go and wait for `acks` answers. The first error
/// the kernel reports is returned.
fn talk(proto: c_int, msgs: &[u8], acks: usize) -> io::Result<()> {
    let fd = unsafe { socket(AF_NETLINK, SOCK_RAW | SOCK_CLOEXEC, proto) };
    if fd < 0 {
        return Err(io::Error::last_os_error());
    }
    let r = (|| {
        if unsafe { send(fd, msgs.as_ptr(), msgs.len(), 0) } < 0 {
            return Err(io::Error::last_os_error());
        }
        let mut buf = vec![0u8; 8192];
        let mut got = 0;
        while got < acks {
            let n = unsafe { recv(fd, buf.as_mut_ptr(), buf.len(), 0) };
            if n < 0 {
                return Err(io::Error::last_os_error());
            }
            let mut off = 0;
            let n = n as usize;
            while off + 16 <= n {
                let len = u32::from_ne_bytes(buf[off..off + 4].try_into().unwrap()) as usize;
                let ty = u16::from_ne_bytes(buf[off + 4..off + 6].try_into().unwrap());
                if len < 16 {
                    break;
                }
                if ty == NLMSG_ERROR && off + 20 <= n {
                    let err = i32::from_ne_bytes(buf[off + 16..off + 20].try_into().unwrap());
                    if err != 0 {
                        return Err(io::Error::from_raw_os_error(-err));
                    }
                    got += 1;
                }
                off += (len + 3) & !3;
            }
        }
        Ok(())
    })();
    unsafe { close(fd) };
    r
}

// ---- nftables rule ---------------------------------------------------------

// From include/uapi/linux/netfilter/nf_tables.h and nfnetlink.h.
const NFNL_SUBSYS_NFTABLES: u16 = 10;
const NFNL_MSG_BATCH_BEGIN: u16 = 16;
const NFNL_MSG_BATCH_END: u16 = 17;
const NFT_MSG_NEWTABLE: u16 = 0;
const NFT_MSG_NEWCHAIN: u16 = 3;
const NFT_MSG_NEWRULE: u16 = 6;
const NFT_MSG_DESTROYTABLE: u16 = 26;
const NFPROTO_IPV4: u8 = 2;
const NF_INET_LOCAL_OUT: u32 = 3;
const NF_ACCEPT: u32 = 1;
const NFTA_TABLE_NAME: u16 = 1;
const NFTA_CHAIN_TABLE: u16 = 1;
const NFTA_CHAIN_NAME: u16 = 3;
const NFTA_CHAIN_HOOK: u16 = 4;
const NFTA_CHAIN_POLICY: u16 = 5;
const NFTA_CHAIN_TYPE: u16 = 7;
const NFTA_HOOK_HOOKNUM: u16 = 1;
const NFTA_HOOK_PRIORITY: u16 = 2;
const NFTA_RULE_TABLE: u16 = 1;
const NFTA_RULE_CHAIN: u16 = 2;
const NFTA_RULE_EXPRESSIONS: u16 = 4;
const NFTA_LIST_ELEM: u16 = 1;
const NFTA_EXPR_NAME: u16 = 1;
const NFTA_EXPR_DATA: u16 = 2;
const NFTA_DATA_VALUE: u16 = 1;
const NFTA_SOCKET_KEY: u16 = 1;
const NFTA_SOCKET_DREG: u16 = 2;
const NFTA_SOCKET_LEVEL: u16 = 3;
const NFT_SOCKET_CGROUPV2: u32 = 3;
const NFTA_CMP_SREG: u16 = 1;
const NFTA_CMP_OP: u16 = 2;
const NFTA_CMP_DATA: u16 = 3;
const NFT_CMP_EQ: u32 = 0;
const NFTA_IMMEDIATE_DREG: u16 = 1;
const NFTA_IMMEDIATE_DATA: u16 = 2;
const NFTA_META_KEY: u16 = 2;
const NFTA_META_SREG: u16 = 3;
const NFT_META_PRIORITY: u32 = 2;
const NFT_REG_1: u32 = 1;

const TABLE: &str = "wyse";
const CHAIN: &str = "prio";

/// nfnetlink header: family, version 0, resource id (big-endian).
fn nfgen(family: u8, res_id: u16) -> [u8; 4] {
    let r = res_id.to_be_bytes();
    [family, 0, r[0], r[1]]
}

fn nft_ty(m: u16) -> u16 {
    (NFNL_SUBSYS_NFTABLES << 8) | m
}

/// The messages for, in nft syntax:
///   table ip wyse { chain prio { type filter hook output priority 0;
///     socket cgroupv2 level 1 "apps" meta priority set 1:2 } }
/// The table is removed first, so running it again gives the same result.
fn nft_batch(apps_id: u64) -> Vec<u8> {
    let f = NLM_F_REQUEST | NLM_F_ACK;
    let fam = nfgen(NFPROTO_IPV4, 0);
    let mut out = Msg::new(NFNL_MSG_BATCH_BEGIN, NLM_F_REQUEST, 1, &nfgen(0, NFNL_SUBSYS_NFTABLES)).done();

    let mut m = Msg::new(nft_ty(NFT_MSG_DESTROYTABLE), f, 2, &fam);
    m.str(NFTA_TABLE_NAME, TABLE);
    out.extend(m.done());

    let mut m = Msg::new(nft_ty(NFT_MSG_NEWTABLE), f | NLM_F_CREATE, 3, &fam);
    m.str(NFTA_TABLE_NAME, TABLE);
    out.extend(m.done());

    let mut m = Msg::new(nft_ty(NFT_MSG_NEWCHAIN), f | NLM_F_CREATE, 4, &fam);
    m.str(NFTA_CHAIN_TABLE, TABLE).str(NFTA_CHAIN_NAME, CHAIN);
    m.begin(NFTA_CHAIN_HOOK).be32(NFTA_HOOK_HOOKNUM, NF_INET_LOCAL_OUT).be32(NFTA_HOOK_PRIORITY, 0).end();
    m.be32(NFTA_CHAIN_POLICY, NF_ACCEPT).str(NFTA_CHAIN_TYPE, "filter");
    out.extend(m.done());

    let mut m = Msg::new(nft_ty(NFT_MSG_NEWRULE), f | NLM_F_CREATE, 5, &fam);
    m.str(NFTA_RULE_TABLE, TABLE).str(NFTA_RULE_CHAIN, CHAIN);
    m.begin(NFTA_RULE_EXPRESSIONS);
    // socket cgroupv2 level 1 -> reg 1 (the cgroup id, 8 bytes)
    m.begin(NFTA_LIST_ELEM).str(NFTA_EXPR_NAME, "socket").begin(NFTA_EXPR_DATA);
    m.be32(NFTA_SOCKET_KEY, NFT_SOCKET_CGROUPV2).be32(NFTA_SOCKET_DREG, NFT_REG_1).be32(NFTA_SOCKET_LEVEL, 1);
    m.end().end();
    // reg 1 == id of /sys/fs/cgroup/apps, else stop
    m.begin(NFTA_LIST_ELEM).str(NFTA_EXPR_NAME, "cmp").begin(NFTA_EXPR_DATA);
    m.be32(NFTA_CMP_SREG, NFT_REG_1).be32(NFTA_CMP_OP, NFT_CMP_EQ);
    m.begin(NFTA_CMP_DATA).attr(NFTA_DATA_VALUE, &apps_id.to_ne_bytes()).end();
    m.end().end();
    // reg 1 = 1:2
    m.begin(NFTA_LIST_ELEM).str(NFTA_EXPR_NAME, "immediate").begin(NFTA_EXPR_DATA);
    m.be32(NFTA_IMMEDIATE_DREG, NFT_REG_1);
    m.begin(NFTA_IMMEDIATE_DATA).attr(NFTA_DATA_VALUE, &LOW_BAND.to_ne_bytes()).end();
    m.end().end();
    // packet priority = reg 1
    m.begin(NFTA_LIST_ELEM).str(NFTA_EXPR_NAME, "meta").begin(NFTA_EXPR_DATA);
    m.be32(NFTA_META_KEY, NFT_META_PRIORITY).be32(NFTA_META_SREG, NFT_REG_1);
    m.end().end();
    m.end();
    out.extend(m.done());

    out.extend(Msg::new(NFNL_MSG_BATCH_END, NLM_F_REQUEST, 6, &nfgen(0, NFNL_SUBSYS_NFTABLES)).done());
    out
}

fn nft_rule() -> io::Result<()> {
    // The kernel compares the cgroup's id, which is its inode number.
    let id = fs::metadata(APPS)?.ino();
    talk(NETLINK_NETFILTER, &nft_batch(id), 4)
}

// ---- prio queue ------------------------------------------------------------

const RTM_NEWQDISC: u16 = 36;
const TC_H_ROOT: u32 = 0xffff_ffff;
const TCA_KIND: u16 = 1;
const TCA_OPTIONS: u16 = 2;

/// The message for `tc qdisc replace dev <if> root handle 1: prio bands 2
/// priomap 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0 0`: every packet in band 0 (first),
/// except those the nftables rule sets to 1:2 (app packets, band 1).
fn qdisc_msg(ifindex: i32) -> Vec<u8> {
    let mut tcm = vec![0u8; 4]; // family, pads
    tcm.extend(ifindex.to_ne_bytes());
    tcm.extend(QDISC.to_ne_bytes());
    tcm.extend(TC_H_ROOT.to_ne_bytes());
    tcm.extend(0u32.to_ne_bytes()); // info
    let mut opt = 2i32.to_ne_bytes().to_vec(); // struct tc_prio_qopt: bands
    opt.extend([0u8; 16]); // priomap
    let mut m = Msg::new(RTM_NEWQDISC, NLM_F_REQUEST | NLM_F_ACK | NLM_F_CREATE | NLM_F_REPLACE, 1, &tcm);
    m.str(TCA_KIND, "prio").attr(TCA_OPTIONS, &opt);
    m.done()
}

/// Put the prio queue on a network interface (when it gets its address).
pub fn qdisc(iface: &str) {
    let idx: i32 = sys::read_trim(&format!("/sys/class/net/{iface}/ifindex")).parse().unwrap_or(0);
    if idx == 0 {
        return;
    }
    if let Err(e) = talk(NETLINK_ROUTE, &qdisc_msg(idx), 1) {
        sys::kmsg(&format!("wyse-init: prio queue on {iface}: {e}"));
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn msg_layout() {
        let mut m = Msg::new(5, 1, 9, &[1, 2, 3]);
        m.str(1, "ab").begin(2).be32(3, 1).end();
        let b = m.done();
        // header 16 + fixed 3 (+1 pad) + "ab\0" attr 7 (+1) + nest 4 + be32 attr 8
        assert_eq!(b.len(), 16 + 4 + 8 + 4 + 8);
        assert_eq!(u32::from_ne_bytes(b[0..4].try_into().unwrap()) as usize, b.len());
        assert_eq!(&b[20..27], &[7, 0, 1, 0, b'a', b'b', 0][..]);
        assert_eq!(u16::from_ne_bytes([b[28], b[29]]), 12); // nest length
        assert_eq!(u16::from_ne_bytes([b[30], b[31]]), 2 | NLA_F_NESTED);
        assert_eq!(&b[36..40], &[0, 0, 0, 1]);
    }

    #[test]
    fn qdisc_layout() {
        let b = qdisc_msg(2);
        // header 16 + tcmsg 20 + "prio\0" 9 (+3) + options 4 + 20
        assert_eq!(b.len(), 16 + 20 + 12 + 24);
        assert_eq!(&b[20..24], &2i32.to_ne_bytes());
    }
}
