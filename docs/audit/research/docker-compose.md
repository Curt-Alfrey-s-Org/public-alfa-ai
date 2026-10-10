# Docker Compose v2

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` to check `/home/operator/alfa-ai/` against upstream guidance.

## Official documentation

- **Primary docs URL:** https://docs.docker.com/compose/
- **Compose application model:** https://docs.docker.com/compose/intro/compose-application-model/
- **Compose Specification:** https://docs.docker.com/reference/compose-file/
- **Services reference:** https://docs.docker.com/reference/compose-file/services/
- **Networks reference:** https://docs.docker.com/reference/compose-file/networks/
- **Volumes reference:** https://docs.docker.com/reference/compose-file/volumes/
- **Secrets reference:** https://docs.docker.com/reference/compose-file/secrets/
- **Configs reference:** https://docs.docker.com/reference/compose-file/configs/
- **Compose Spec source:** https://github.com/compose-spec/compose-spec
- **CLI reference:** https://docs.docker.com/reference/cli/docker/compose/
- **Source repo (CLI):** https://github.com/docker/compose
- **Releases:** https://github.com/docker/compose/releases

## Current stable / supported version (as of 2026-05-13)

- **Latest stable:** `v2.40.3` (early 2026 — Ubuntu repo upload 2026-01-06, with backports through April 2026). Source: https://pkg.go.dev/github.com/docker/compose/v2@v2.40.3 and https://launchpad.net/ubuntu/+source/docker-compose-v2/+changelog.
- **Recent releases:**
  - `v2.40.2` (2025-10-22) — bug fixes for tar `uid:gid`, image digest checking. Source: https://github.com/docker/compose/releases/tag/v2.40.2.
  - `v2.40.0` (2025-10-03) — improvements to Compose application publishing, secrets fixes. Source: https://github.com/docker/compose/releases/tag/v2.40.0.
- **Toolchain:** built with Go 1.24.9.
- **EOL policy:** Compose v1 (`docker-compose` Python) is end-of-life and unsupported as of June 2023. Only Compose v2 (`docker compose` plugin) receives updates. Source: https://docs.docker.com/compose/migrate/.

## Key official best practices

- **No `version:` key** in modern Compose files. The Compose Specification has dropped the field — files starting with `services:` directly is now correct. Older files with `version: "3.8"` still parse but the field is ignored. Source: https://docs.docker.com/reference/compose-file/version-and-name/.
- **Filename:** `compose.yaml` (preferred) or `compose.yml`; `docker-compose.{yaml,yml}` is supported for backwards compat. If both exist, Compose prefers `compose.yaml`. Source: https://docs.docker.com/compose/intro/compose-application-model/ ("The Compose file").
- **Project name:** set top-level `name:` to give the deployment a stable identifier — used to namespace resources (containers, networks, volumes get `name_*` prefix). Source: https://docs.docker.com/reference/compose-file/version-and-name/.
- **Multiple files:** use `docker compose -f base.yaml -f override.yaml up` or `include:` to compose application slices. Lists merge by append; scalars override by last file in order. Source: https://docs.docker.com/compose/how-tos/multiple-compose-files/ and https://docs.docker.com/reference/compose-file/include/.
- **`networks:` declaration:** every cross-service connection should go over an explicit named network. Default network (`<project>_default`) exists if you don't declare any. For external networks, use `external: true`. Source: https://docs.docker.com/reference/compose-file/networks/.
- **Service-to-service DNS:** Compose's embedded DNS resolves service names to container IPs on the shared network. Use `http://service-name:port/`, not IP addresses. Source: https://docs.docker.com/reference/compose-file/services/#network_mode.
- **Volumes:** prefer named volumes over bind mounts for application state. Bind mounts are appropriate for config files / source code in dev. Source: https://docs.docker.com/reference/compose-file/volumes/.
- **Secrets:** use `secrets:` (reads from file or external secret manager) instead of putting credentials in env vars or images. Mounted as files at `/run/secrets/<name>`. Source: https://docs.docker.com/reference/compose-file/secrets/.
- **Configs:** use `configs:` for runtime configuration files (e.g. `nginx.conf`). Behave like volumes but with platform-specific delivery semantics. Source: https://docs.docker.com/reference/compose-file/configs/.
- **Healthchecks:** define `healthcheck:` per service (`test`, `interval`, `timeout`, `retries`, `start_period`). Other services can `depends_on: <svc>: condition: service_healthy`. Source: https://docs.docker.com/reference/compose-file/services/#healthcheck and https://docs.docker.com/reference/compose-file/services/#depends_on.
- **`restart:` policy:** for production, `restart: unless-stopped` (or `always`). `no` is a development-only choice. Source: https://docs.docker.com/reference/compose-file/services/#restart.
- **`init: true`** runs an init process (`tini`) so PID-1 reaping works for shell-style entrypoints. Source: https://docs.docker.com/reference/compose-file/services/#init.
- **Image pinning:** always pin image tags (`postgres:17-alpine`, not `postgres:latest`). For audited deploys, pin by digest (`postgres@sha256:...`). Source: https://docs.docker.com/reference/compose-file/services/#image.
- **`deploy.replicas`:** declarative scale-out (Swarm/k8s parser). For single-host Compose, use `docker compose up --scale svc=N` for runtime scaling. Source: https://docs.docker.com/reference/compose-file/deploy/.

## Canonical configuration examples

**Modern Compose v2 file** (verbatim shape from https://docs.docker.com/compose/intro/compose-application-model/):

```yaml
name: myapp

services:
  frontend:
    image: example/webapp:1.2.3
    ports:
      - "443:8043"
    networks: [front-tier, back-tier]
    configs: [httpd-config]
    secrets: [server-certificate]
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "curl", "-f", "http://localhost:8043/healthz"]
      interval: 30s
      timeout: 5s
      retries: 3

  backend:
    image: example/database:5.6
    volumes:
      - db-data:/etc/data
    networks: [back-tier]
    restart: unless-stopped

volumes:
  db-data:
    driver: local

configs:
  httpd-config:
    file: ./httpd.conf

secrets:
  server-certificate:
    file: ./certs/server.crt

networks:
  front-tier: {}
  back-tier: {}
```

Source: https://docs.docker.com/compose/intro/compose-application-model/ ("Illustrative example").

**Common CLI commands** (https://docs.docker.com/reference/cli/docker/compose/):

```bash
docker compose up -d              # start all services in background
docker compose down               # stop and remove
docker compose logs -f svc        # tail logs
docker compose ps                 # status
docker compose pull               # refresh images
docker compose -f a.yaml -f b.yaml up -d   # merge multiple files
```

## Common pitfalls / gotchas

- **`version: "3.8"` does nothing** in Compose v2. Older docs still show it. Source: https://docs.docker.com/reference/compose-file/version-and-name/.
- **`docker-compose` (with hyphen, Python v1) is EOL.** Use `docker compose` (space, Go v2). Source: https://docs.docker.com/compose/migrate/.
- **Implicit project name = parent directory name.** If the directory rename or move, container names change. Pin with `name:` in the file or `-p <name>` on CLI. Source: https://docs.docker.com/reference/compose-file/version-and-name/.
- **`depends_on` without `condition: service_healthy`** does NOT wait for the service to become *ready*, only to *start*. Source: https://docs.docker.com/reference/compose-file/services/#depends_on.
- **Bind mounts on Windows / WSL** have very different I/O characteristics from native Linux — heavy DB workloads on bind-mounted volumes can be 10–100× slower. Use named volumes. Source: https://docs.docker.com/desktop/wsl/.
- **`network_mode: host`** disables Docker's network isolation and DNS — services can no longer resolve each other by name. Use only when truly required. Source: https://docs.docker.com/reference/compose-file/services/#network_mode.
- **`external: true` networks must already exist.** Compose won't create them; `docker network create <name>` first. Source: https://docs.docker.com/reference/compose-file/networks/#external.
- **`restart: always`** loops forever even on broken configurations — combine with healthchecks and an upstream alerting tool. Source: https://docs.docker.com/reference/compose-file/services/#restart.
- **Secrets in env vars** are visible via `docker inspect` and can leak in logs. Use `secrets:` mounted as files. Source: https://docs.docker.com/reference/compose-file/secrets/.

## Authoritative URLs to cite in our docs

- https://docs.docker.com/compose/
- https://docs.docker.com/compose/intro/compose-application-model/
- https://docs.docker.com/reference/compose-file/
- https://docs.docker.com/reference/compose-file/services/
- https://docs.docker.com/reference/compose-file/networks/
- https://docs.docker.com/reference/compose-file/volumes/
- https://docs.docker.com/reference/compose-file/secrets/
- https://docs.docker.com/reference/compose-file/configs/
- https://docs.docker.com/reference/compose-file/deploy/
- https://docs.docker.com/reference/cli/docker/compose/
- https://docs.docker.com/compose/migrate/
- https://github.com/docker/compose
- https://github.com/compose-spec/compose-spec

## AUDIT CHECKLIST for the Audit Agent

1. **Compose v2 only:** confirm every `deploy/*.sh` script and operator runbook calls `docker compose ...` (with space), NOT `docker-compose ...` (hyphen, EOL). Path: `deploy/cluster-members/*/deploy.sh`, `LLAMACPP_RPC_OPERATOR.md`, `DOCKGE_*_OPERATOR.md`.
2. **No `version:` key:** grep all `docker-compose.yml` files in `deploy/` for `^version:` and remove. The field is silently ignored. Path: `deploy/docker-compose.yml`, `deploy/petals/docker-compose.worker*.yml`, every `deploy/cluster-members/*/`.
3. **Image pinning:** flag any `:latest`, `:main`, or `:edge` tags in compose files. Examples to check:
   - `learningathome/petals:main` (per Petals research) — must pin by digest.
   - `ghcr.io/berriai/litellm:main-stable` — should be a specific stable release tag.
   - `nginx:latest` / `postgres:latest` / `redis:latest` — must be a pinned minor.
4. **`tunnel_network` external:** per workspace `.cursorrules` rule 1, network is named `tunnel_network` and is shared across multiple stacks. Confirm `networks: { tunnel_network: { external: true } }` in every service that needs to be reverse-proxied. The network is created out-of-band by Cloudflare tunnel deploy.
5. **Healthchecks:** confirm `healthcheck:` blocks exist for at least `alfa-ai-api`, `alfa-ai-litellm`, `alfa-ai-petals-gateway`, `alfa-ai-nginx`. Path: `deploy/docker-compose.yml`.
6. **`depends_on` conditions:** services that depend on the brain stack should use `condition: service_healthy`, not the default `condition: service_started`. Otherwise a healthy-looking deploy can race.
7. **Restart policy:** every production service should use `restart: unless-stopped` or `always`. Flag any `restart: no` in production compose.
8. **Port-binding rule** (workspace `.cursorrules` rule 2-3): every API port mapping must be `127.0.0.1:HOSTPORT:CONTAINERPORT`. Audit every `ports:` block in `deploy/`.
9. **Container internal binding** (workspace `.cursorrules` rule 4): every API process should bind `0.0.0.0` inside the container (e.g. `uvicorn --host 0.0.0.0`). Cross-check `command:` blocks.
10. **Container DNS proxy_pass** (workspace `.cursorrules` rule 5): nginx `proxy_pass` must use service name (`http://alfa-ai-api:8000/`), never `127.0.0.1` or LAN IP. Confirmed in `nginx.md` audit too.
11. **Secrets handling:** confirm `LITELLM_MASTER_KEY`, `LITELLM_SALT_KEY`, `HF_TOKEN`, DB passwords are loaded via env-from-file or `secrets:` blocks — not hard-coded in compose.
12. **`include:` vs duplication:** if `deploy/docker-compose.yml` and `apps-105/docker-compose.yml` both define the brain stack, prefer `include:` to keep them in sync rather than duplicating service definitions.
13. **Compose v2 minimum version:** confirm `v2.40.3` (or ≥ v2.40.0) is documented in `DOCKGE_111_OPERATOR.md` and `DOCKGE_105_OPERATOR.md`. Older Compose versions miss recent secrets/publish fixes.
