//! wyse-init: one program for everything the Wyse does at boot, so no boot
//! step is a shell script.
//!
//!   /sbin/preinit (link)            first program the kernel runs: disks,
//!                                   RAM overlay, then BusyBox init
//!   wyse-init boot                  once from inittab: drivers, host name,
//!                                   network
//!   wyse-init run <service>         from inittab (respawn): starts one service
//!   wyse-init stop-apps             from inittab at shutdown: stops the apps
//!   wyse-init install-slot <size> <sha256> <version>
//!                                   image on stdin into the unused root
//!                                   (scripts/deploy.sh; update.rs)
//!   wyse-init update-status         roots, versions, grubenv
//!   alpine (link)                   run a command in the Alpine subsystem
//!   udhcpc-event (link)             udhcpc's lease handler
mod alpine;
mod apps;
mod boot;
mod config;
mod dhcp;
mod guard;
mod http;
mod json;
mod net;
mod preinit;
mod prio;
mod service;
mod sha256;
mod sys;
mod update;

use std::process::exit;

fn main() {
    let args: Vec<String> = std::env::args().collect();
    let name = args
        .first()
        .map(|a| a.rsplit('/').next().unwrap_or(a).to_string())
        .unwrap_or_default();

    match name.as_str() {
        "preinit" => preinit::main(),
        "alpine" => alpine::enter(&args[1..]),
        "udhcpc-event" => exit(dhcp::main(args.get(1).map(String::as_str).unwrap_or(""))),
        _ => {}
    }

    let arg = |i: usize| args.get(i).map(String::as_str).unwrap_or("");
    match arg(1) {
        "boot" => boot::main(),
        "run" => service::main(arg(2)),
        "stop-apps" => alpine::stop(),
        "install-slot" => update::install_slot(&args[2..]),
        "update-status" => update::status(),
        _ => {
            eprintln!("usage: wyse-init boot | run <service> | stop-apps | install-slot <size> <sha256> <version> | update-status");
            exit(1);
        }
    }
}
