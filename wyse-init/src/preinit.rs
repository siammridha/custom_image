//! First program the kernel runs (init=/sbin/preinit, a link to wyse-init).
//! The kernel has mounted partition 2 (read-only squashfs) as /.
//!
//!   partition 3 "persist"  -> /persist   kept; only the files listed in
//!                                        KEEP survive a boot
//!   partition 4 "data"     -> /data      apps and their files; never wiped
//!                                        (except by wyse-wipe-data)
//!   RAM (tmpfs)            -> overlayfs upper layer: every change outside
//!                                        /data and /persist is gone at reboot
//!
//! Builds the overlay root, moves into it and starts BusyBox init.
use crate::sys::{self, MS_MOVE, MS_NOATIME};
use std::convert::Infallible;
use std::fs::{self, File};
use std::io::{Read, Seek, SeekFrom};
use std::os::unix::fs::MetadataExt;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::Command;

/// What may stay on /persist: VPN identity (tailscale, netbird), SSH host
/// keys (dropbear), the settings written by setup-os (wyse.conf) and the
/// wipe-data request.
const KEEP: &[&str] = &[
    "tailscale",
    "netbird",
    "dropbear",
    "wyse.conf",
    ".wipe-data",
    "lost+found",
];

fn log(m: &str) {
    sys::kmsg(&format!("preinit: {m}"));
}

fn fail(m: &str) -> ! {
    log(m);
    log("dropping to shell");
    let e = Command::new("/bin/sh").exec();
    log(&format!("cannot start /bin/sh: {e}"));
    // PID 1 exiting makes the kernel panic, and panic=10 reboots.
    std::process::exit(1);
}

pub fn main() -> ! {
    std::env::set_var("PATH", "/sbin:/bin:/usr/sbin:/usr/bin");
    let _ = sys::mount_fs("proc", "/proc", "proc", 0, "");
    let _ = sys::mount_fs("sysfs", "/sys", "sysfs", 0, "");
    let _ = sys::mount_fs("devtmpfs", "/dev", "devtmpfs", 0, "");
    match run() {
        Err(m) => fail(&m),
        Ok(never) => match never {},
    }
}

fn dev_major(d: u64) -> u64 {
    ((d >> 32) & 0xffff_f000) | ((d >> 8) & 0xfff)
}

fn dev_minor(d: u64) -> u64 {
    ((d >> 12) & 0xffff_ff00) | (d & 0xff)
}

/// Name of partition number `n` on `disk` (e.g. mmcblk1p3, sda3).
fn part_name(disk: &str, n: u32) -> Option<String> {
    let want = n.to_string();
    fs::read_dir(format!("/sys/block/{disk}"))
        .ok()?
        .flatten()
        .find(|e| sys::read_trim(&format!("{}/partition", e.path().display())) == want)
        .map(|e| e.file_name().to_string_lossy().into_owned())
}

fn read_at(dev: &str, off: u64, len: usize) -> Option<Vec<u8>> {
    let mut f = File::open(format!("/dev/{dev}")).ok()?;
    f.seek(SeekFrom::Start(off)).ok()?;
    let mut b = vec![0; len];
    f.read_exact(&mut b).ok()?;
    Some(b)
}

/// ext2/3/4 superblock magic 0xef53 at byte 1080.
fn has_ext4(dev: &str) -> bool {
    read_at(dev, 1080, 2).as_deref() == Some(&[0x53, 0xef][..])
}

/// ext4 volume label (superblock byte 1144, 16 bytes). "" if not ext4.
fn ext4_label(dev: &str) -> String {
    if !has_ext4(dev) {
        return String::new();
    }
    let b = read_at(dev, 1144, 16).unwrap_or_default();
    let end = b.iter().position(|&c| c == 0).unwrap_or(b.len());
    String::from_utf8_lossy(&b[..end]).into_owned()
}

fn run() -> Result<Infallible, String> {
    // Find the disk that holds the root partition (mmcblk1, sda, ...).
    let dev = fs::metadata("/").map_err(|e| format!("cannot read root device: {e}"))?.dev();
    let blk = format!("/sys/dev/block/{}:{}", dev_major(dev), dev_minor(dev));
    let rootsys = fs::canonicalize(&blk).map_err(|e| format!("{blk}: {e}"))?;
    let disk = rootsys
        .parent()
        .and_then(Path::file_name)
        .map(|s| s.to_string_lossy().into_owned())
        .ok_or("cannot find the root disk")?;
    let (p3, p4) = match (part_name(&disk, 3), part_name(&disk, 4)) {
        (Some(a), Some(b)) => (a, b),
        _ => return Err(format!("partitions 3/4 not found on {disk}")),
    };

    // First boot on a new disk: grow partition 4 to the end of the disk,
    // then reboot so the kernel sees the new size.
    let dsize = sys::read_num(&format!("/sys/block/{disk}/size"));
    let p4end = sys::read_num(&format!("/sys/block/{disk}/{p4}/start"))
        + sys::read_num(&format!("/sys/block/{disk}/{p4}/size"));
    if dsize > p4end + 8192 {
        log(&format!("growing partition 4 on {disk}"));
        let d = format!("/dev/{disk}");
        let q = ["-q", "--no-reread", "--no-tell-kernel"];
        sys::run("sfdisk", &[&q[..], &["--relocate", "gpt-bak-std", &d]].concat());
        sys::run_input("sfdisk", &[&q[..], &["-N", "4", &d]].concat(), ", +\n");
        sys::reboot_now();
    }

    // Persist partition. Only formatted when it has no ext4 at all (new disk).
    let d3 = format!("/dev/{p3}");
    if !has_ext4(&p3) {
        log(&format!("formatting persist partition {d3}"));
        if !sys::run("mke2fs", &["-q", "-F", "-t", "ext4", "-L", "persist", &d3]) {
            return Err("mke2fs persist".into());
        }
    }
    sys::run_quiet("e2fsck", &["-p", &d3]);
    sys::mount_fs(&d3, "/persist", "ext4", MS_NOATIME, "")
        .map_err(|e| format!("mount persist: {e}"))?;

    // Remove anything else that built up on persist.
    if let Ok(rd) = fs::read_dir("/persist") {
        for e in rd.flatten() {
            let name = e.file_name().to_string_lossy().into_owned();
            if KEEP.contains(&name.as_str()) {
                continue;
            }
            log(&format!("removing /persist/{name}"));
            let p = e.path();
            let r = match fs::symlink_metadata(&p) {
                Ok(m) if m.is_dir() => fs::remove_dir_all(&p),
                _ => fs::remove_file(&p),
            };
            if let Err(err) = r {
                log(&format!("cannot remove /persist/{name}: {err}"));
            }
        }
    }
    sys::sync();

    // Data partition. Formatted when wyse-wipe-data asked for it, or when it
    // is not a data partition yet (new disk, or the old overlay partition).
    // If it can't be mounted, the system still boots (without /data), so
    // NetBird and Tailscale keep working.
    let d4 = format!("/dev/{p4}");
    if Path::new("/persist/.wipe-data").exists() || ext4_label(&p4) != "data" {
        log(&format!("formatting data partition {d4}"));
        if !sys::run_quiet("mke2fs", &["-q", "-F", "-t", "ext4", "-E", "nodiscard", "-L", "data", &d4]) {
            log("mke2fs data failed");
        }
        let _ = fs::remove_file("/persist/.wipe-data");
        sys::sync();
    }
    if !sys::run_quiet("e2fsck", &["-p", &d4]) {
        sys::run_quiet("e2fsck", &["-y", &d4]);
    }
    let data = match sys::mount_fs(&d4, "/data", "ext4", MS_NOATIME, "") {
        Ok(()) => true,
        Err(e) => {
            log(&format!("cannot mount data partition ({e}), booting without /data"));
            false
        }
    };

    // Overlay upper layer in RAM: every boot starts from the clean read-only
    // image. Capped, so junk written outside /data can't fill the RAM.
    sys::mount_fs("overlay", "/media/overlay", "tmpfs", 0, "size=128m,mode=0755")
        .map_err(|e| format!("mount overlay tmpfs: {e}"))?;
    for d in ["/media/overlay/upper", "/media/overlay/work"] {
        fs::create_dir_all(d).map_err(|e| format!("{d}: {e}"))?;
    }
    sys::mount_fs(
        "overlay",
        "/mnt",
        "overlay",
        0,
        "lowerdir=/,upperdir=/media/overlay/upper,workdir=/media/overlay/work",
    )
    .map_err(|e| format!("mount overlayfs: {e}"))?;

    let mut moves = vec![("/persist", "/mnt/persist"), ("/media/overlay", "/mnt/media/overlay")];
    if data {
        moves.push(("/data", "/mnt/data"));
    }
    moves.push(("/dev", "/mnt/dev"));
    for (from, to) in moves {
        if let Err(e) = sys::mount_fs(from, to, "", MS_MOVE, "") {
            log(&format!("cannot move {from}: {e}"));
        }
    }
    let _ = sys::umount("/sys");
    let _ = sys::umount("/proc");

    std::env::set_current_dir("/mnt").map_err(|e| format!("cd /mnt: {e}"))?;
    sys::pivot_root(".", "rom").map_err(|e| format!("pivot_root: {e}"))?;
    let _ = sys::chroot(".");
    let _ = std::env::set_current_dir("/");
    let _ = sys::stdio_to("/dev/console");
    let e = Command::new("/sbin/init").exec();
    Err(format!("cannot start /sbin/init: {e}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn dev_numbers() {
        // 179:26 (mmcblk1p2) and 259:1 as the C library encodes them.
        assert_eq!((dev_major(0xb31a), dev_minor(0xb31a)), (179, 26));
        let d: u64 = (259 << 8) | 1;
        assert_eq!((dev_major(d), dev_minor(d)), (259, 1));
        let big: u64 = ((0x123u64 & !0xfff) << 32) | ((300u64 & !0xff) << 12) | (0x12 << 8) | (300 & 0xff);
        assert_eq!(dev_minor(big), 300);
    }
}
