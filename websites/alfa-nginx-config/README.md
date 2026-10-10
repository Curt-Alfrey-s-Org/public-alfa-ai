# Alfa Nginx Config

**Canonical source (Jul 2026):** this directory, tracked in the `alfa-ai` repo.
Runs on **`apps`** via a symlink: `/home/operator/alfa-nginx-config` ->
`/home/operator/alfa-ai/websites/alfa-nginx-config` (same pattern as
`alfa-wordpress-plugins`). Previously this was a standalone, untracked
directory directly under `/home/operator/alfa-nginx-config/` on `apps` — moved
into the repo so the live public-site nginx config is version-controlled and
`git pull` brings changes with it. (A stale README revision once pointed to
`/home/operator/alfa/` as a newer replacement — that path never existed; this
directory is the one actual running config.)

## Architecture

| Tunnel | Nginx Container | Serves |
|--------|-----------------|--------|
| **cf-alfa** | **alfa-nginx** | www.example.com, rankings-bot.alfa..., market.alfa..., etc. |
| **cf-probilliards** | **probilliards-nginx** | probilliardssoftware.com only |

This split ensures dev/deploy of probilliards does not take alfa offline.

## `/alfa-ai` routing (Jul 2026 edge migration)

The `location /alfa-ai` block proxies to the **`inference` edge** (`orchestrator`),
which itself reverse-proxies to the **brain on `hub`** (see
[deploy/nginx-edge/alfa-ai-edge.conf](../../deploy/nginx-edge/alfa-ai-edge.conf)).
It previously targeted the Docker service name `alfa-ai-api:8000`, which only
resolved while the `alfa-ai-api` container ran on `apps` itself — Docker's
embedded DNS cannot resolve container names across hosts. When the edge moved
to `inference`, this location broke silently (502 Bad Gateway / "could not be
resolved (2: Server failure)" in `alfa-wp-error.log`) until fixed here.
See [docs/DOCKGE_105_OPERATOR.md](../../docs/DOCKGE_105_OPERATOR.md) "Edge
moved to `inference`".

## Duplicate definition removed (2026-07-06)

`alfaqd-website`'s own `docker-compose.yml` on `apps` also declared an
`alfa-nginx` service (built from a bundled, stale copy of this config that
still pointed at the dead `alfa-ai-api:8000` backend). Since Docker container
names must be unique, only one definition could ever own the running
container — this repo's copy happened to be it, but `boot-all-stacks.sh` only
referenced `alfaqd-website`'s stale one, so a from-scratch reboot would have
recreated the broken config. The duplicate service was removed from
`alfaqd-website/docker-compose.yml` and `boot-all-stacks.sh` now brings up
this directory directly. See
[DOCKGE_105_OPERATOR.md](../../docs/DOCKGE_105_OPERATOR.md) "Duplicate
definition removed 2026-07-06".

## Prerequisites

- `tunnel_network` exists (created by `restore-docker-networks.sh` or `start-alfa-nginx.sh`)
- `alfa_wordpress_1` on `tunnel_network` (for www.example.com)
- Bot APIs/frontends on `tunnel_network` for subdomains
- `rv-auto-finder-network` exists (`docker network create rv-auto-finder-network`
  if the `rv-auto-finder` stack is currently stopped — it is declared
  `external: true` here purely for network attach, not a runtime dependency)
- Cloudflare Tunnel **cf-alfa** configured to route to `http://alfa-nginx:80`

## Usage

```bash
cd /home/operator/alfa-nginx-config   # symlink into this repo path
docker compose -f docker-compose.alfa-nginx.yml build alfa-nginx
docker compose -f docker-compose.alfa-nginx.yml up -d alfa-nginx
```

## Cloudflare Tunnel Config

In Cloudflare Zero Trust → Tunnels → cf-alfa → Public Hostnames, add or update routes:

| Public hostname | Service |
|-----------------|---------|
| www.example.com | HTTP → alfa-nginx:80 |
| example.com | HTTP → alfa-nginx:80 |
| rankings-bot.example.com | HTTP → alfa-nginx:80 |
| market-pie5-bot.example.com | HTTP → alfa-nginx:80 |
| contracts-bot.example.com | HTTP → alfa-nginx:80 |
| credit-check-bot.example.com | HTTP → alfa-nginx:80 |
| atems-api.example.com | HTTP → alfa-nginx:80 |
| **alfa-business-suite.example.com** | HTTP → **alfa-nginx:80** (proxies to **orchestrator**) |

## References

- [docs/DOCKGE_105_OPERATOR.md](../../docs/DOCKGE_105_OPERATOR.md) — `apps` apps host operator guide
- [deploy/nginx-edge/alfa-ai-edge.conf](../../deploy/nginx-edge/alfa-ai-edge.conf) — `inference` edge proxy config
- [docs/REPO_HOST_MAPPING.md](../../docs/REPO_HOST_MAPPING.md) — repo/host ownership (SSoT)
