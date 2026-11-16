//! `wyse-init run <service>`: runs one service in the foreground for init
//! (respawn). When it exits, init starts it again.
//!   - never killed when RAM runs out (oom_score_adj -1000), except apps
//!   - remote access gets a higher CPU priority than apps (nice -10)
//! A service that is turned off in the settings just waits, so init does
//! not keep restarting it.
use crate::config::Config;
use crate::{alpine, guard, sys};
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
                sys::run("modprobe", &["softdog"]);
            }
            if !Path::new("/dev/watchdog").exists() {
                sys::idle();
            }
            // Reset after 60 s: the default of both watchdog -T and softdog.
            start(-20, "watchdog", &["-F", "-t", "10", "/dev/watchdog"]);
        }
        "netbird" => {
            on(&c, "NETBIRD");
            let _ = fs::create_dir_all("/var/log/netbird");
            // Logs to its default, /var/log/netbird/client.log.
            start(-10, "netbird", &["service", "run"]);
        }
        "tailscaled" => {
            on(&c, "TAILSCALE");
            // The socket is the default, /var/run/tailscale/tailscaled.sock
            // (tailscaled makes the folder).
            start(-10, "tailscaled", &["--statedir=/var/lib/tailscale"]);
        }
        "dropbear" => {
            on(&c, "SSH");
            sys::umask(0o077);
            // No password logins: built without them (dropbear-localoptions.h).
            start(-10, "dropbear", &["-F", "-R"]);
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
            // The Alpine subsystem, which starts the apps (alpine.rs).
            // Started after the VPNs.
            sys::sleep(20);
            alpine::run();
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
