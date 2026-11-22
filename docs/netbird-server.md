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
| `step-ca/` | step-ca | `password` (only on the server) |
| `traefik/` | traefik | `dynamic.yml` |
| `netbird/` | management, signal, relay, dashboard | `management/config.json`, `dashboard.env`, `relay.env` |
| `netbird-client/` | netbird-client | `netbird_setup_key` |
| `simple-rtc/` | simple-rtc | |
| `arcane/` | arcane | `arcane.env` |

- Each app has its own Docker network: `netbird`, `step-ca`, `simple-rtc`,
  `arcane`, `netbird-client`. Only traefik joins them all, so the apps can't reach each other,
  only traefik (tested: simple-rtc and management can't open each other or
  Arcane). No port is opened on the server except traefik's; Docker also
  drops traffic from other machines to container addresses.
- `netbird`, `step-ca` and `simple-rtc` are internal networks: their
  containers reach traefik but not the internet (tested 2026-11-21).
  This also stops NetBird management's release check (`pkgs.netbird.io`
  every 30 min, no setting turns it off). Only arcane and netbird-client
  can go out. traefik's open ports and its own outside traffic use its own
  normal network `traefik` (`gw_priority: 1`; without it Docker picked
  `arcane`).
- On each network, traefik has an alias for the public name of the app there
  (`netbird.sentryvault.com` on `netbird`, ...), so NetBird's own calls to
  its public address go to traefik. On `step-ca` it has all 3 names: step-ca
  checks each certificate by connecting to its name, and without the alias
  the name resolves to a public address and renewals fail.
  Certificates last 24 h.
- All traefik routes are in `traefik/dynamic.yml` (file provider); apps have
  no `traefik.*` labels. traefik has no Docker socket, so a break-in to
  traefik can't control Docker. It reaches each app by container name
  (`http://simple-rtc:3000`) on the app's network. A new app: add its
  router and service to that file and its network to traefik. After
  changing the file, restart traefik: push.sh replaces the file, and the
  container keeps reading the old copy (tested 2026-11-21). traefik runs
  with `no-new-privileges` (tested 2026-11-21).
- traefik keeps nothing on disk: its certificates are in `/tmp/acme.json`
  inside the container. A new container (recreate, update) gets new ones
  from step-ca: about 30 s after the start, and until then clients get a
  certificate error and try again. A plain `docker restart` keeps them.
  So traefik is killed at once (`stop_signal: SIGKILL`) instead of waiting
  10 s for open connections. traefik doesn't make the folder for
  `acme.json`, so it must be one that exists (`/certificates` without a
  volume failed). Tested 2026-11-21.
- Networks and the volumes (`step-ca-data`, `netbird-management`,
  `netbird-client`, `rtc-diag`,
  `arcane-data`) are marked `external` in every project: a project never makes
  or deletes them. If one is gone: `docker volume create <name>`, or
  `docker network create --internal <name>` for `netbird`, `step-ca`,
  `simple-rtc` and without `--internal` for `traefik`, `arcane`
  (`netbird-client`: see below).
- Projects can't wait for each other (no `depends_on` between them). Every
  container has `restart: unless-stopped` and the NetBird parts retry, so the
  start order does not matter. The NetBird containers have no `depends_on`
  either, so recreating one of them leaves the others running.
- Data is in volumes, not folders, so Arcane can back it up: `step-ca-data`
  (the CA) and `netbird-management` (NetBird's database). They were moved
  from `step-ca/data` and `netbird/management/data` on 2026-11-20; those
  folders were deleted on 2026-11-21 (both are in the backups below).
- traefik and netbird-client read step-ca's root certificate from the
  `certs` folder of `step-ca-data` (volume `subpath`, read-only).
- Logs: every container keeps one file of at most 5 MB (`docker logs <name>`
  or Arcane), level info where the program has a setting.
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
URL; on its network the name points to traefik.

Only the home network (192.168.0.0/16) may open the dashboard, its API and
Arcane: traefik middleware `lan-only` in `traefik/dynamic.yml`. Video has no
such limit.

## The server's NetBird client

`netbird-client` runs on its own Docker network (`netbird-client`), not on the
server's network, so NetBird peers that connect to it (100.80.169.56) reach
nothing on the server. Its one job: routing peer for video.

- NetBird dashboard: Network `Simple-RTC`, routing peer `docker-host` (this
  client), resource `172.22.0.10/32` port 443: traefik's fixed address on the
  `netbird-client` network (`ipv4_address` in `traefik/docker-compose.yml`;
  the network was made with `docker network create --subnet 172.22.0.0/16
  netbird-client`). The client passes that traffic on to traefik, which sees
  it from the client's 172.22.x address, so `lan-only` lets only video through.
- The server itself is not reachable over NetBird. SSH to it on the home
  network.
- fdstower (remote site, Alpine, NetBird 0.83.2) uses this route. Devices on
  its local network reach `video.sentryvault.com`: their DNS points the name
  to fdstower, where a relay on port 443 sends it to `172.22.0.10:443`.
  Tested 2026-11-20.
- The client sets `src_valid_mark` and `rp_filter` through compose
  (`sysctls`, and `com.docker.network.endpoint.sysctls` for its own
  interface): NetBird wants these values and can't write `/proc/sys` in a
  container.
- Harmless errors in its log at every start: relay over QUIC can't read the
  relay address (`.../4477/relay`) and uses WebSocket; "failed to restore host
  DNS settings" (DNS management is off for it, and it never changed
  `/etc/resolv.conf`).

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

The 4478 route is in `traefik/dynamic.yml` (all routes are, now), not in
management's Docker labels, which disappeared while management restarted.
A client that connected in that gap got a 404 page from Traefik (TLS still
worked, since the certificate is shared) and stayed stuck on that
connection: its health check failed, but it did not reconnect. With the route
in the file, the connection just fails and the client tries again. Tested:
after a management restart, the server's client reconnected in 3.5 s.

## Settings

- `netbird/management/config.json`: `"ReverseProxy": {"TrustedPeers": ["127.0.0.1/32"]}`.
  With no value, management trusts `X-Forwarded-For` from anyone (0.0.0.0/0)
  and logs a warning. Nothing here needs it, so only 127.0.0.1 is trusted.
- STUN for peers (`Stuns` in `management/config.json`) and simple-rtc
  (`STUN_SERVER`): `stun:stun.cloudflare.com:3478`. With our own STUN
  (4477), peers on the home network reached it through the router and got
  a wrong outside address, so they could not connect P2P. With Cloudflare's
  they do (tested 2026-11-21). The relay still answers STUN on 4477; no one
  is told to use it.
- traefik: `aliasHeadersStrategy=delete` on every entry point. It drops
  request headers with `_` or `.` in the name (`X_Auth_User`), which some
  backends read as `X-Auth-User`. None of ours do; without the setting
  traefik 3.7 logs a warning per entry point at every start.
- Management runs with `--disable-anonymous-metrics=true` (no usage data sent
  to NetBird).
- Only Arcane checks for new releases. traefik has
  `--global.checknewversion=false`, Arcane `ARCANE_ANALYTICS_ENABLED=false`
  (no heartbeat to checkin.getarcane.app). Management's metrics port 9090
  can't be turned off; it only answers on the `netbird` network and sends
  nothing.
- Every image has a fixed version except `simple_rtc:latest`.
- Log levels: info for all.

## Secrets

Not in this repo. On the server, all are root only (mode 600):
- `netbird-client/netbird_setup_key` (Docker secret for the server's client)
- `netbird/relay.env` (`NB_AUTH_SECRET`) and `netbird/management/config.json` (relay secret,
  `DataStoreEncryptionKey`)
- `arcane/arcane.env` (`ARCANE_ENCRYPTION_KEY`)
- `step-ca/password` (used only when the CA is first made), and in the
  `step-ca-data` volume `password` and `secrets/password` (owned by uid
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

Vulnerability scans (Trivy, in Arcane):
- `netbird_server_config/security-report.sh` copies the latest scan into
  `security-report/<date>/`: `report.txt` (every finding with description),
  `findings.csv`, and Trivy's full JSON report per image. It reads only the
  vulnerability tables, from a copy of Arcane's database.
- The report lists every image on the server, old ones too: delete unused
  images to drop their findings.
- Trivy keeps its vulnerability list (about 1.7 GB) in the volume
  `arcane-trivy-cache`; it can be deleted and is downloaded again at the
  next scan.
- 2026-11-21: traefik v3.6.8 → v3.7.19 (no findings) and step-ca 0.29.0 →
  0.30.2 (newest, still 7 critical: old Alpine packages and Go libraries).
  CA data backup before the update:
  `/var/backups/step-ca-data-2026-11-20.tar.gz`.

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
