# Wyse backlog

- A/B updates with automatic rollback. Two root partitions; an update goes to
  the one not running. GRUB boots the new one once (try_slot in grubenv). It
  becomes the default only after NetBird or Tailscale connects; otherwise the
  next reboot goes back to the old one. Changes the partition layout, so it
  needs one full reinstall. On hold: the update process is not decided yet.
