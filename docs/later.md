# Ideas for later

Not planned yet. Each item says what it gains and what it costs.

## Copy the root partition to RAM at boot

preinit copies the squashfs root (p2, about 25 MB) into RAM and runs from
there instead of from the disk.

- Gain: if the disk fails while the device runs, the system keeps working
  and remote login (SSH, NetBird, Tailscale) still works, so you can see
  what happened and plan a replacement.
- Not a gain: speed or priority. The vpn cgroup already has memory.min
  128M (it uses about 97 MB, no program pages re-read from disk) and io
  weight 10000 against the apps' 1 (checked on the 3040, 2026-11-18).
- Cost: about 25 MB of RAM (taken from the apps' share), about a second
  more at boot, a change in preinit.
- Also needed: vpn-guard reboots when both VPNs are down for 30 min. With
  a failing disk that reboot loses the device, so it should not reboot
  then.
- Copying only the VPN programs is worse: about 59 MB, and remote login
  also needs dropbear, the shell, busybox, wyse-init and musl from disk.
