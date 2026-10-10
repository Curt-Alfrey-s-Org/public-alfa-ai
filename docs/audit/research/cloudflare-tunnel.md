# Cloudflare Tunnel (`cloudflared`)

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` to check `/home/operator/alfa-ai/` against upstream guidance.

## Official documentation

- **Primary docs URL:** https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/ (Zero Trust / private-network framing)
- **Public-app tunnel docs:** https://developers.cloudflare.com/tunnel/ (publishing public web apps via tunnel)
- **Get started:** https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/
- **Configure tunnels:** https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/
- **Run as a service (Linux):** https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/as-a-service/linux/
- **Tunnel run parameters:** https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/cloudflared-parameters
- **Cipher suites:** https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/cipher-suites/
- **Source repo:** https://github.com/cloudflare/cloudflared
- **Releases:** https://github.com/cloudflare/cloudflared/releases
- **Release notes file:** https://github.com/cloudflare/cloudflared/blob/master/RELEASE_NOTES

## Current stable / supported version (as of 2026-05-13)

- **Latest stable:** `2026.3.0` (released 2026-03-09). Source: https://github.com/cloudflare/cloudflared/releases/latest/.
- **Recent releases:**
  - `2026.3.0` (2026-03-09) — adds management-token command (TUN-10292); updates `go-sentry` and `go-oidc` for CVE fixes; updates mods to fix CVE GO-2026-4394; tail uses `/management/logs`. Source: https://github.com/cloudflare/cloudflared/blob/master/RELEASE_NOTES.
  - `2026.2.0` (2026-02-06) — Cloudflare-vulnerability fixes; **`proxy-dns` feature removed**.
  - `2026.1.0` (2026-01-13) — Go upgraded to 1.24.11; Debian distroless to debian13.
- **Versioning:** `cloudflared` uses **CalVer** (`YYYY.M.MICRO`); each release is supported for ~3 months on the rolling cadence. Source: https://github.com/cloudflare/cloudflared/releases (consistent monthly cadence).
- **EOL policy:** older versions still work but receive no security backports; track latest. Auto-update is supported via package manager and (on Linux) the systemd unit `cloudflared` ships.

## Key official best practices

- **Outbound-only:** the entire Cloudflare Tunnel model is **outbound-only** — `cloudflared` initiates a connection from the origin to Cloudflare's edge, then traffic flows bidirectionally over that persistent tunnel. No inbound port needs to be open on the origin firewall. Source: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/ ("How it works").
- **Zero inbound firewall rules:** "**You can configure your firewall to allow only these outbound connections and block all inbound traffic, effectively blocking access to your origin from anything other than Cloudflare.**" Source: same page.
- **TLS / post-quantum:** all tunnel traffic is TLS 1.3 with post-quantum encryption by default. Source: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/ ("Secure your tunnel").
- **Run as a service (Linux):** install with `cloudflared service install` (requires sudo). When sudo is used, `$HOME` becomes `/root`, so pass the config explicitly:
  ```bash
  sudo cloudflared --config /home/<user>/.cloudflared/config.yml service install
  systemctl start cloudflared
  systemctl status cloudflared
  ```
  Source: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/as-a-service/linux/.
- **Run as a service (Windows):** `cloudflared.exe service install` registers a Windows service — preferred over Task Scheduler for unattended boot. Source: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/as-a-service/.
- **Multiple connectors per tunnel:** a tunnel is a UUID, and multiple `cloudflared` processes (called *connectors*) can serve the same tunnel for HA. Source: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/ ("How it works") and https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/.
- **Health metrics:** `cloudflared --metrics localhost:36500` exposes Prometheus-format metrics. Source: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/cloudflared-parameters.
- **Least privilege:** run `cloudflared` as a non-root user. The systemd unit on Linux runs as a dedicated `cloudflared` user when installed via the official `.deb`/`.rpm`. Source: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/ ("Secure your tunnel").
- **`proxy-dns` removed in 2026.2.0** — if you used `cloudflared` for DNS-over-HTTPS, switch to a DoH client. Source: https://github.com/cloudflare/cloudflared/blob/master/RELEASE_NOTES (2026.2.0 entry).
- **Locally-managed vs remotely-managed tunnels:**
  - **Locally-managed:** uses `config.yml` + a credentials JSON. Operator owns the file. Restart needed on config change.
  - **Remotely-managed:** dashboard-driven, no `config.yml` on the host; `cloudflared` reads tunnel config over the API. Recommended for fleets. Source: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/.

## Canonical configuration examples

**Locally-managed `config.yml`** (verbatim shape from https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/configuration-file/):

```yaml
tunnel: <TUNNEL-UUID>
credentials-file: /home/<user>/.cloudflared/<TUNNEL-UUID>.json

ingress:
  # public hostname → local container service
  - hostname: chat.example.com
    service: http://alfa-ai-nginx:80
  - hostname: api.example.com
    service: http://alfa-ai-api:8000

  # catch-all (required as the LAST rule)
  - service: http_status:404
```

**Systemd service install (Linux, post-2025 cadence):**

```bash
# 1. Install the binary (Debian/Ubuntu example)
curl -L https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64.deb \
  -o /tmp/cloudflared.deb
sudo dpkg -i /tmp/cloudflared.deb

# 2. Authenticate + create / connect a tunnel
cloudflared tunnel login
cloudflared tunnel create alfa-ai-prod

# 3. Configure (config.yml + DNS routes)
# 4. Install + start the service
sudo cloudflared --config /home/operator/.cloudflared/config.yml service install
sudo systemctl enable --now cloudflared
sudo systemctl status cloudflared
```

Source: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/as-a-service/linux/.

**Run as a Docker container** (alternative to systemd service):

```yaml
services:
  cloudflared:
    image: cloudflare/cloudflared:2026.3.0
    restart: unless-stopped
    command: tunnel --no-autoupdate run
    environment:
      - TUNNEL_TOKEN=${CF_TUNNEL_TOKEN}   # for remotely-managed tunnels
    networks:
      - tunnel_network

networks:
  tunnel_network:
    external: true
```

Source: https://github.com/cloudflare/cloudflared (README) + Cloudflare blog deployment guides.

## Common pitfalls / gotchas

- **`proxy-dns` feature gone in 2026.2.0** — if your config relied on it, the tunnel won't start. Source: https://github.com/cloudflare/cloudflared/blob/master/RELEASE_NOTES.
- **`sudo cloudflared service install` reads `/root/.cloudflared/`** instead of the human user's. Always pass `--config` explicitly. Source: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/as-a-service/linux/.
- **Last `ingress:` rule must be a catch-all** (e.g. `service: http_status:404`). Without it, `cloudflared tunnel ingress validate` fails. Source: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/configuration-file/.
- **Single connector = single point of failure.** Run ≥ 2 `cloudflared` instances on different hosts for HA. Source: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/.
- **Cloudflare Tunnel terminates TLS at the edge** — the connection from `cloudflared` to the local origin is plain HTTP (or HTTPS with cert validation). Don't run a second TLS layer between `cloudflared` and nginx for no reason. Source: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/origin-parameters/.
- **Auto-update is on by default;** `--no-autoupdate` disables it. Pin a version for reproducible deploys. Source: https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/cloudflared-parameters.
- **CVE GO-2026-4394** affected `cloudflared < 2026.3.0` (golang module update). Source: 2026.3.0 release notes.
- **Tunnel token = full tunnel control.** Treat `TUNNEL_TOKEN` like a master password; rotate via `cloudflared tunnel token rotate`. Source: https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/remote-tunnel-permissions/.

## Authoritative URLs to cite in our docs

- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/get-started/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/tunnel-availability/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/run-parameters/
- https://developers.cloudflare.com/cloudflare-one/networks/connectors/cloudflare-tunnel/configure-tunnels/cipher-suites/
- https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/local-management/as-a-service/linux/
- https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/configure-tunnels/cloudflared-parameters
- https://github.com/cloudflare/cloudflared
- https://github.com/cloudflare/cloudflared/releases
- https://github.com/cloudflare/cloudflared/blob/master/RELEASE_NOTES

## AUDIT CHECKLIST for the Audit Agent

1. **Version pin:** confirm `cloudflared` is at **2026.3.0** (or later). Older versions are exposed to CVE GO-2026-4394 and the dependency CVEs patched in 2026.3.0. Path: any compose using `cloudflare/cloudflared:<tag>`, plus systemd-installed binaries on `hub`/`apps`. Run `cloudflared --version` on each host.
2. **`tunnel_network` cohesion:** per workspace `.cursorrules` rule 1, the tunnel uses a Docker network named `tunnel_network`. Confirm `cloudflared` is attached to this network and reaches every published service (`alfa-ai-nginx`, bot frontends) by Docker DNS, not by IP.
3. **Outbound-only firewall:** confirm the public-internet edge of the cluster (router, host firewalls) blocks all inbound traffic to the apps tier. Cloudflare Tunnel is the only documented ingress. Cross-check `NODE_INVENTORY.md` and any router firewall docs.
4. **HA / multiple connectors:** the cluster's stated architecture has a single `cf-alfa` connector. Audit Agent should confirm whether a second connector exists (recommended for HA) and document the failure mode if not.
5. **`proxy-dns` removal:** grep `config.yml` files for `proxy-dns:` keys — these will fail on 2026.2.0+. Path: `/etc/cloudflared/`, `~/.cloudflared/`, any Compose env.
6. **Catch-all `ingress` rule:** confirm the last `ingress:` rule is `service: http_status:404` (or similar). Run `cloudflared tunnel ingress validate` to verify.
7. **Service installation method:**
   - **`apps`** (Ubuntu): is `cloudflared` running via systemd unit (`systemctl status cloudflared`) or as a Docker container? Document one canonical method per `deployment-process-ownership.mdc`.
   - **`hub`** (hub): if running as a custom app, confirm restart-policy is `unless-stopped` and the network membership matches `tunnel_network`.
8. **Origin URLs:** every `service:` entry in `config.yml` should target a Docker service name on `tunnel_network` (e.g. `http://alfa-ai-nginx:80`), NOT `127.0.0.1:80` or LAN IPs. Same rule as workspace `.cursorrules` rule 5.
9. **Token rotation cadence:** confirm `TUNNEL_TOKEN` is sourced from a secret (not committed) and document rotation cadence in `deploy/cluster-members/<host>/`.
10. **Auto-update:** confirm `--no-autoupdate` is set on production hosts (so a surprise `cloudflared` upgrade doesn't drift production at 02:00). Pair with a documented manual upgrade cadence.
11. **Metrics endpoint:** if monitoring is in scope, confirm `--metrics localhost:36500` is set and scraped by Prometheus.
12. **Locally-managed vs remotely-managed:** document which model the cluster uses, in `cluster-members/<host>/` README. Mixing both for the same tunnel is undefined.
