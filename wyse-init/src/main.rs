//! wyse-init: one program for everything the Wyse does at boot, so no boot
//! step is a shell script.
//!
//!   /sbin/preinit (link)            first program the kernel runs: disks,
//!                                   RAM overlay, then BusyBox init
//!   wyse-init boot                  once from inittab: persist folders,
//!                                   drivers, host name, network, SSH keys
//!   wyse-init run <service>         from inittab (respawn): starts one service
//!   wyse-init hostname              apply the host name again (setup-os)
//!   wyse-init apps-setup [alpine]   prepare the apps cgroup and /data/alpine
//!   udhcpc-event (link)             udhcpc's lease handler
mod apps;
mod boot;
mod config;
mod dhcp;
mod guard;
mod preinit;
mod service;
mod sys;

use std::process::exit;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let name = args
        .first()
        .map(|a| a.rsplit('/').next().unwrap_or(a).to_string())
        .unwrap_or_default();

    match name.as_str() {
        "preinit" => preinit::main(),
        "udhcpc-event" => exit(dhcp::main(args.get(1).map(String::as_str).unwrap_or(""))),
        _ => {}
    }

    let arg = |i: usize| args.get(i).map(String::as_str).unwrap_or("");
    match arg(1) {
        "boot" => boot::main(),
        "run" => service::main(arg(2)),
        "hostname" => boot::hostname(&config::Config::load()),
        "apps-setup" => {
            if let Err(e) = apps::setup(arg(2) == "alpine") {
                eprintln!("apps-setup: {e}");
                exit(1);
            }
        }
        _ => {
            eprintln!("usage: wyse-init boot | run <service> | hostname | apps-setup [alpine]");
            exit(1);
        }
    }
}
