# NetBird server

The self-hosted NetBird server: Docker Compose on Alpine (`root@192.168.10.199`).
The local copy is `netbird_server_config/` (git-ignored: it holds secrets).
`netbird_server_config/push.sh` copies the changed files to the server and
sets their owner and modes; it does not pull images or restart anything.

## Projects

Each folder in `/root` is its own compose project, so a restart of one does
not touch the others:

| Folder | Containers | Other files |
|------|------|------|
| `step-ca/` | step-ca | `data/` (the CA, only on the server) |
| `traefik/` | traefik | `dynamic.yml` |
| `netbird/` | management, signal, relay, dashboard | `management/`, `dashboard.env`, `relay.env` |
| `netbird-client/` | netbird-client | `netbird_setup_key` |
| `simple-rtc/` | simple-rtc | |
| `arcane/` | arcane | `arcane.env` |

- All join the Docker network `netbird`, and use volumes with fixed names
  (`traefik-certs`, `netbird-client`, `rtc-diag`, `arcane-data`). Both are
  marked `external` in every project: a project never makes or deletes them.
  If the network is gone: `docker network create netbird`.
- Projects can't wait for each other (no `depends_on` between them). Every
  container has `restart: unless-stopped` and the NetBird parts retry, so the
  start order does not matter. The NetBird containers have no `depends_on`
  either, so recreating one of them leaves the others running.
- traefik and netbird-client read step-ca's root certificate from
  `../step-ca/data/certs`.
- Restart only what changed: in Arcane, or
  `cd /root/<folder> && docker compose up -d`.
- Backup before the split (2026-11-20): `/var/backups/server-before-split-2026-11-20.tar.gz`
  on the server, and a copy in `netbird_server_config/`.

## Ports

All traffic goes through Traefik.

| Port | Open to the internet | What |
|------|------|------|
| 4478 TCP | yes | Management gRPC, passed through to `management:33073` |
| 4477 TCP | yes | Signal, relay, logins (`/oauth2`) |
| 4477 UDP | yes | STUN (relay) |
| 443 | no | Dashboard, management API, web socket, video, Arcane |
| 80 | no | Redirect to 443 |

Through 4477, `/api` and Arcane give 404: they only answer on 443.

Devices use `netbird_url = https://netbird.sentryvault.com:4478`
(`config/network`). The server's own client (`netbird-client`) uses the same
URL, with `netbird.sentryvault.com` pointing to 127.0.0.1.

## Management gRPC on 4478

The management server checks each device every 5 s and gives it 2 s to
answer (gRPC keepalive). This check only runs on its gRPC-only port 33073,
not on port 80, where it serves web and gRPC together
(`management/internals/server/server.go`: `serveGRPC` for 33073,
`serveGRPCWithHTTP` for the main port).

So Traefik passes port 4478 to 33073 as TCP: it does the TLS and forwards the
bytes without reading them, so the check reaches the device. Expected: a
device that loses its network shows offline in about 7 s. Not timed yet.

Before this, device traffic went through Traefik's HTTP router to port 80.
Traefik answered the check itself, and the dashboard showed a dead device
connected for 15–20 minutes (until Linux gave up resending, 15 tries).
`net.ipv4.tcp_retries2=6` on the Traefik container cut that to about 2
minutes (tested 2026-11-18). It is kept as a backup.

The 4478 route is in `traefik/dynamic.yml` (Traefik's file provider), not in
management's Docker labels. Labels disappear while management restarts.
A client that connected in that gap got a 404 page from Traefik (TLS still
worked, since the certificate is shared) and stayed stuck on that
connection: its health check failed, but it did not reconnect. With the route
in the file, the connection just fails and the client tries again. Tested:
after a management restart, the server's client reconnected in 3.5 s.

## Settings

- `netbird/management/config.json`: `"ReverseProxy": {"TrustedPeers": ["127.0.0.1/32"]}`.
  With no value, management trusts `X-Forwarded-For` from anyone (0.0.0.0/0)
  and logs a warning. Nothing here needs it, so only 127.0.0.1 is trusted.
- Management runs with `--disable-anonymous-metrics=true` (no usage data sent
  to NetBird).
- Every image has a fixed version except `simple_rtc:latest`.
- Log levels: info for NetBird, error for Traefik.

## Secrets

Not in this repo. On the server, all are root only (mode 600):
- `netbird-client/netbird_setup_key` (Docker secret for the server's client)
- `netbird/relay.env` (`NB_AUTH_SECRET`) and `netbird/management/config.json` (relay secret,
  `DataStoreEncryptionKey`)
- `arcane/arcane.env` (`ARCANE_ENCRYPTION_KEY`)
- `step-ca/data/password`, `step-ca/data/secrets/password` (owned by uid
  1000, the user step-ca runs as)

## Arcane

Docker web UI at `https://arcane.sentryvault.com`, local only (port 443).
It runs as root and mounts `/root` (its projects folder), so it can edit the
projects above. Arcane only edits a project in a subfolder of `/root`, not a
compose file in `/root` itself ("project path is outside projects directory").
Image: `getarcaneapp/manager` from Docker Hub.

Image updates:
- For a fixed tag (`0.83.1`), Arcane by default only checks for a rebuild
  of that same tag, never a newer version. Every container except
  simple-rtc and Arcane has the label
  `com.getarcaneapp.arcane.updater.strategy=tag`, so Arcane shows newer
  version tags and writes the new tag into the compose file when it updates.
- simple-rtc (`:latest`) shows an update when a new image is pushed.
- The Updates page has one row per project (the 4 NetBird containers are one
  row). One container alone: its page, Actions, Update Container.
- After updating in Arcane, the server's compose files are newer than
  `netbird_server_config/`: copy them back before running `push.sh`, or it
  puts the old tags back.

## Router

Netgear Nighthawk R7000P, firmware V1.3.3.154_10.1.86. This firmware has no
Remote Management option (Web Services Management shows only local HTTPS).
Tested from outside (2026-11-20): ports 80 and 8443 on the public IP time
out; 4477 answers.

## Related

- The device runs `netbird up --network-monitor`
  (`wyse-init/src/guard.rs`), so it reconnects as soon as its network
  comes back. Tested: back about 16 s after the link returned.
- Browser SSH from the NetBird dashboard needs the relay server. NetBird's
  browser client always uses the relay (`client/internal/peer/env.go`,
  `IsForceRelayed`); no setting changes that. Removing the relay broke it.
