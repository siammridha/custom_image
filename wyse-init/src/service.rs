//! `wyse-init run <service>`: runs one service in the foreground for init
//! (respawn). When it exits, init starts it again.
//!   - never killed when RAM runs out (oom_score_adj -1000), except apps
//!   - remote access gets a higher CPU priority than apps (nice -10)
//! A service that is turned off in the settings just waits, so init does
//! not keep restarting it.
use crate::config::Config;
use crate::{apps, guard, sys};
use std::fs;
use std::os::unix::process::CommandExt;
use std::path::Path;
use std::process::{exit, Command};

pub fn main(name: &str) {
    let c = Config::load();
    std::env::set_var("PATH", "/usr/sbin:/usr/bin:/sbin:/bin");

    // Slow down restarts if a service keeps exiting at once.
    sys::sleep(2);
    sys::put("/proc/self/oom_score_adj", "-1000");
    let _ = sys::stdio_to("/dev/null");

    match name {
        "watchdog" => {
            // Hardware watchdog: if this stops feeding it (system frozen),
            // the hardware resets the device after 60 s.
            if !Path::new("/dev/watchdog").exists() {
                sys::run("modprobe", &["softdog", "soft_margin=60"]);
            }
            if !Path::new("/dev/watchdog").exists() {
                sys::idle();
            }
            start(-20, "watchdog", &["-F", "-T", "60", "-t", "10", "/dev/watchdog"]);
        }
        "netbird" => {
            on(&c, "NETBIRD");
            let _ = fs::create_dir_all("/var/log/netbird");
            start(-10, "netbird", &["service", "run", "--log-file", "/var/log/netbird/client.log"]);
        }
        "tailscaled" => {
            on(&c, "TAILSCALE");
            let _ = fs::create_dir_all("/run/tailscale");
            start(
                -10,
                "tailscaled",
                &["--statedir=/var/lib/tailscale", "--socket=/run/tailscale/tailscaled.sock"],
            );
        }
        "dropbear" => {
            on(&c, "SSH");
            sys::umask(0o077);
            start(-10, "dropbear", &["-F", "-R", "-s"]);
        }
        "ntpd" => {
            let servers = c.words("NTP_SERVERS");
            if servers.is_empty() {
                sys::idle();
            }
            let mut args = vec!["-n"];
            for s in &servers {
                args.extend(["-p", s.as_str()]);
            }
            start(0, "ntpd", &args);
        }
        "vpn-guard" => {
            sys::nice(-10);
            guard::main(&c);
        }
        "apps" => {
            // Apps: one folder per app in /data/services, each with an
            // executable "run" file that runs the app in the foreground
            // (runit style). Started after the VPNs, with low priority, first
            // to be killed when RAM runs out, and limited in RAM together.
            sys::sleep(20);
            if apps::setup(false).is_err() {
                sys::idle();
            }
            sys::put("/sys/fs/cgroup/apps/cgroup.procs", &std::process::id().to_string());
            sys::put("/proc/self/oom_score_adj", "500");
            let _ = fs::create_dir_all("/data/services");
            start(10, "runsvdir", &["-P", "/data/services"]);
        }
        _ => sys::idle(),
    }
}

/// Wait forever if the service is turned off.
fn on(c: &Config, key: &str) {
    if !c.is(key, "yes") {
        sys::idle();
    }
}

/// Replace this process with the service, at the given nice value.
fn start(nice: i32, prog: &str, args: &[&str]) -> ! {
    sys::nice(nice);
    let _ = Command::new(prog).args(args).exec();
    exit(1); // init starts it again
}
