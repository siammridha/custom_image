# NetBird server: slow "offline" in the dashboard

Status: open. A workaround is on the server; the real fix (port 33073) is
not done yet.

## The problem

When a device loses its network (cable pulled, power cut, internet down),
the NetBird dashboard kept showing it connected for 15–20 minutes.
Tailscale shows it offline at once.

## Why

The server setup (Docker Compose): Traefik takes all traffic on port 4478
and sends it to signal, relay and management by path. Device traffic goes
to `management:80`, together with the dashboard API and logins.

1. The management server checks each device every 5 s (gRPC keepalive,
   5 s, then 2 s to answer). This check only runs on its separate gRPC
   port, 33073. On port 80 it serves web and gRPC on one port through Go's
   web server (`ServeHTTP`), and the check does not run there.
   Source: `management/internals/server/server.go` (`serveGRPC` for 33073,
   `serveGRPCWithHTTP` for the main port). Same in 0.66.4 and 0.83.1.
2. Traefik sits between the device and management. Even on the right port,
   Traefik would answer the check itself, so management would never learn
   that the device is gone.
3. A device that loses its network sends nothing. Traefik only notices
   when Linux gives up resending data to it: 15 tries, about 15 minutes
   (`net.ipv4.tcp_retries2`). Then Traefik closes its connection to
   management, and management marks the device offline.

## Workaround in place (tested)

In `server.yml`, `traefik` service:

```yaml
    sysctls:
      - net.ipv4.tcp_retries2=6
```

Linux in the Traefik container gives up after 6 tries (about 25 s) instead
of 15. It only affects the Traefik container.

Test (2026-11-18): device network cut at 04:54:46 UTC; dashboard showed it
offline at about 04:56:45, so about 2 minutes. The 25 s only starts once
Traefik has something to send to the device.

## Planned fix: port 33073

Send device traffic to management's port 33073 through a Traefik TCP
router. A TCP router passes the bytes through without reading them, so the
server's 5 s check reaches the device. Expected: offline after about 7 s.

It needs its own port: a TCP router for `netbird.sentryvault.com` on 4478
would take all traffic on that port, and signal, relay and the API would
stop working. (Another way: a second host name on 4478, for example
`mgmt.sentryvault.com`, passed through by name. That needs DNS, a
certificate and a hosts entry on the devices.)

Management already listens on 33073 (it opens it by itself next to port
80). It has no TLS certificate in this setup, so 33073 is plain gRPC;
Traefik does the TLS.

1. `traefik` service:

   ```yaml
       ports:
         - "33073:33073"   # TCP — Management gRPC, passed through
       command:
         - --entrypoints.mgmt.address=:33073
   ```

   Both numbers must be 33073: `"33073:4478"` would send the traffic to the
   existing HTTP entry point, and nothing would change.

2. `management` service, labels (keep the existing ones):

   ```yaml
         - traefik.tcp.routers.netbird-mgmt-tcp.rule=HostSNI(`netbird.sentryvault.com`)
         - traefik.tcp.routers.netbird-mgmt-tcp.entrypoints=mgmt
         - traefik.tcp.routers.netbird-mgmt-tcp.tls=true
         - traefik.tcp.routers.netbird-mgmt-tcp.tls.certresolver=stepca
         - traefik.tcp.routers.netbird-mgmt-tcp.service=netbird-mgmt-tcp
         - traefik.tcp.services.netbird-mgmt-tcp.loadbalancer.server.port=33073
   ```

3. Router/firewall: forward TCP 33073 to the server, like 4478.

4. Devices: in `.env` set `NETBIRD_URL=https://netbird.sentryvault.com:33073`,
   then build and deploy. post-build.sh writes it to the device as
   `NB_MANAGEMENT_URL`. The device keeps its NetBird identity. Signal and
   relay stay on 4478 (management tells the device their addresses).

5. Optional: the server's own client (`netbird-client` in `server.yml`)
   can use `NB_MANAGEMENT_URL=https://netbird.sentryvault.com:33073` too.

Not tested yet. To check:
- The device connects on 33073 (`netbird status`: Management Connected).
- gRPC needs HTTP/2 agreed during TLS (ALPN `h2`); check that Traefik's
  TCP router offers it.
- Cut the device's network (`alpine ip link set eth0 down; sleep 300;
  alpine ip link set eth0 up`, run in the background on the device) and
  time the dashboard. Expected: offline in about 7 s.
- After it works, `tcp_retries2=6` can stay as a backup or be removed.

## Related

- The device runs `netbird up --network-monitor`
  (`wyse-init/src/guard.rs`), so it reconnects as soon as its network
  comes back. Tested: back about 16 s after the link returned.
- Browser SSH from the NetBird dashboard needs the relay server. NetBird's
  browser client always uses the relay (`client/internal/peer/env.go`,
  `IsForceRelayed`); no setting changes that. Removing the relay broke it.
