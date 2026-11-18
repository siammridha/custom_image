//! vpn-guard: keeps NetBird (main) and Tailscale (backup) logged in and
//! connected. Every 30 s:
//!   - not connected or logged out: run "up" again (also the first login)
//!   - one down for 10 min: restart that daemon (init starts it again)
//!   - both down for 30 min: reboot (a fresh boot clears everything else)
//!   - no default route: ask udhcpc to renew the lease. The kernel drops
//!     the routes when the link goes down (cable out, switch restart) and
//!     udhcpc only adds them again at its next renew, which can be hours.
//! Once per boot it applies the locked settings from /rom/etc/wyse/vpn.conf.
//! It also keeps the NetBird log in RAM small.
use crate::config::Config;
use crate::sys;
use std::fs;

const NB_LOG: &str = "/var/log/netbird/client.log";

struct Guard<'a> {
    c: &'a Config,
    nb_on: bool,
    ts_on: bool,
}

impl Guard<'_> {
    fn cmd(&self, prog: &str, args: Vec<String>, secs: u64) -> (bool, String) {
        sys::output_timeout(prog, &args, secs)
    }

    fn nb_ok(&self) -> bool {
        self.nb_on
            && self
                .cmd("netbird", vec!["status".into()], 20)
                .1
                .lines()
                .any(|l| l.starts_with("Management: Connected"))
    }

    /// "up" does not apply new settings while connected ("Already
    /// connected"), so the first "up" of each boot disconnects first.
    fn nb_up(&self, first: bool) -> bool {
        let c = self.c;
        let mut a = vec!["up".to_string(), "--hostname".into(), c.get("HOSTNAME").into()];
        if !c.get("NB_SETUP_KEY").is_empty() {
            a.extend(["--setup-key".into(), c.get("NB_SETUP_KEY").into()]);
        }
        if !c.get("NB_MANAGEMENT_URL").is_empty() {
            a.extend(["--management-url".into(), c.get("NB_MANAGEMENT_URL").into()]);
        }
        a.extend(c.words("NB_UP_ARGS"));
        if first {
            self.cmd("netbird", vec!["down".into()], 30);
        }
        self.cmd("netbird", a, 60).0
    }

    fn ts_status(&self) -> String {
        self.cmd("tailscale", vec!["status".into(), "--json".into(), "--peers=false".into()], 20).1
    }

    fn ts_ok(&self) -> bool {
        self.ts_on && self.ts_status().contains("\"Online\": true")
    }

    fn ts_up(&self) {
        let c = self.c;
        let mut a = vec!["up".to_string(), "--timeout=45s".into(), format!("--hostname={}", c.get("HOSTNAME"))];
        if !c.get("TS_AUTHKEY").is_empty() {
            a.push(format!("--auth-key={}", c.get("TS_AUTHKEY")));
        }
        if !c.get("TS_LOGIN_SERVER").is_empty() {
            a.push(format!("--login-server={}", c.get("TS_LOGIN_SERVER")));
        }
        a.extend(c.words("TS_UP_ARGS"));
        self.cmd("tailscale", a, 60);
    }

    fn ts_set(&self) -> bool {
        let mut a = vec!["set".to_string(), format!("--hostname={}", self.c.get("HOSTNAME"))];
        a.extend(self.c.words("TS_UP_ARGS"));
        self.cmd("tailscale", a, 30).0
    }
}

/// `"BackendState": "Running"` -> "Running".
fn backend_state(json: &str) -> &str {
    let Some(i) = json.find("\"BackendState\"") else { return "" };
    let rest = &json[i + "\"BackendState\"".len()..];
    let rest = rest.trim_start().strip_prefix(':').unwrap_or("").trim_start();
    rest.strip_prefix('"').and_then(|r| r.split('"').next()).unwrap_or("")
}

/// Is there a default route (destination and mask 0) in /proc/net/route?
fn has_default_route(table: &str) -> bool {
    table.lines().skip(1).any(|l| {
        let f: Vec<&str> = l.split_whitespace().collect();
        f.len() >= 8 && f[1] == "00000000" && f[7] == "00000000"
    })
}

fn trim_logs() {
    if fs::metadata(NB_LOG).map(|m| m.len() > 5 * 1024 * 1024).unwrap_or(false) {
        let _ = fs::write(NB_LOG, "");
    }
    if let Ok(rd) = fs::read_dir("/var/log/netbird") {
        for e in rd.flatten() {
            if e.file_name().to_string_lossy().ends_with(".gz") {
                let _ = fs::remove_file(e.path());
            }
        }
    }
}

pub fn main(c: &Config) -> ! {
    sys::log_open(c"vpn-guard");
    let g = Guard { c, nb_on: c.is("NETBIRD", "yes"), ts_on: c.is("TAILSCALE", "yes") };

    let t = sys::uptime();
    let (mut nb_last, mut nb_restart, mut nb_done) = (t, t, false);
    let (mut ts_last, mut ts_restart, mut ts_done) = (t, t, false);
    let mut any_last = t;
    let mut no_route = false;
    loop {
        sys::sleep(30);

        if has_default_route(&fs::read_to_string("/proc/net/route").unwrap_or_default()) {
            no_route = false;
        } else {
            if !no_route {
                sys::log("no default route: asking udhcpc to renew the lease (every 30 s until it is back)");
                no_route = true;
            }
            sys::kill_name("udhcpc", sys::SIGUSR1);
        }

        if g.nb_on {
            if (!nb_done || !g.nb_ok()) && g.nb_up(!nb_done) {
                nb_done = true;
            }
            let t = sys::uptime();
            if g.nb_ok() {
                nb_last = t;
            } else if t - nb_last >= 600 && t - nb_restart >= 600 {
                sys::log("NetBird down for 10 min: restarting it");
                sys::kill_name("netbird", sys::SIGTERM);
                nb_restart = t;
            }
        }

        if g.ts_on {
            match backend_state(&g.ts_status()) {
                "Running" | "Starting" => {}
                _ => g.ts_up(), // NeedsLogin, Stopped (tailscale down), NoState
            }
            if !ts_done && g.ts_set() {
                ts_done = true;
            }
            let t = sys::uptime();
            if g.ts_ok() {
                ts_last = t;
            } else if t - ts_last >= 600 && t - ts_restart >= 600 {
                sys::log("Tailscale down for 10 min: restarting it");
                sys::kill_name("tailscaled", sys::SIGTERM);
                ts_restart = t;
            }
        }

        let t = sys::uptime();
        if !g.nb_on && !g.ts_on {
            // both turned off: nothing to guard
        } else if g.nb_ok() || g.ts_ok() {
            any_last = t;
        } else if t - any_last >= 1800 {
            sys::log("NetBird and Tailscale down for 30 min: rebooting");
            sys::sync();
            sys::kill(1, sys::SIGTERM); // BusyBox init: clean reboot
            sys::sleep(120);
            sys::put("/proc/sysrq-trigger", "b"); // normal reboot hung: force it
        }

        trim_logs();
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn state() {
        let j = "{\n  \"Version\": \"1.9\",\n  \"BackendState\": \"Running\",\n  \"Self\": {}}";
        assert_eq!(backend_state(j), "Running");
        assert_eq!(backend_state("{\"BackendState\":\"NeedsLogin\"}"), "NeedsLogin");
        assert_eq!(backend_state(""), "");
    }

    #[test]
    fn default_route() {
        let head = "Iface\tDestination\tGateway \tFlags\tRefCnt\tUse\tMetric\tMask\t\tMTU\tWindow\tIRTT\n";
        let lan = "eth0\t0050A8C0\t00000000\t0001\t0\t0\t0\t00FFFFFF\t0\t0\t0\n";
        let def = "eth0\t00000000\t0150A8C0\t0003\t0\t0\t0\t00000000\t0\t0\t0\n";
        assert!(!has_default_route(&format!("{head}{lan}")));
        assert!(has_default_route(&format!("{head}{def}{lan}")));
        assert!(!has_default_route(""));
    }
}
