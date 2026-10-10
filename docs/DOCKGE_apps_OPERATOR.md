# Apps-host operator guide — `apps` (Ubuntu)

**April 2026 architecture:** `apps` is **no longer the brain** — it has become
the **apps host**. The brain (ALFa AI orchestration, LiteLLM, Ollama agent
model) moved to `hub` (hub Scale 25.04 / Ryzen 9 7900X).

**Hardware (see [NODE_INVENTORY.md](NODE_INVENTORY.md)):** Proxmox VM 105 on
`pve-i5` / `hypervisor` — **5 vCPU / 32 GB**, **CPU-only** (1660S passthrough moved
to VM100). No GPU required. **`nvidia-smi` is not present** — do **not** install
the LACT daemon here; GPU tuning is on **`inference` / `pool-opt-in`** only
([GPU_OC_LACT_OPERATOR.md](GPU_OC_LACT_OPERATOR.md)).

`apps` (UBUNTU-PRO-WEBSITES) used to run almost everything. Many repos have moved to dedicated VMs (see [REPO_HOST_MAPPING.md](REPO_HOST_MAPPING.md)).

**Current reality on `apps` (after the split):**

- Websites + bots that have **not yet moved** off 105 (contracts-bot, alfaqd-website, shared postgres/redis pieces, edge proxy, etc.).
- Historical "everything" list (rankings-bot,
  contracts-bot, credit-check-bot, market-pie5-bot, atems, USPBF,
  alfaqd-website, rv-auto-finder.
- **Postgres** (authoritative DB for the brain and for bots that share it).
- **Redis** (sessions, queues, worker heartbeats).
- **Petals retired** — do not start `alfa-ai-petals-gateway` or `petals-worker`
  on `apps`. GPU passthrough moved to VM100; `apps` is CPU-only apps.
- **libvirt/KVM VMs** (operator-configured).
- **Dockge agent** at `:5001` — registers against primary Dockge on `orchestrator`.

**Moved elsewhere** (do not bring back up on `apps`):

- `alfa-ai-litellm`, `alfa-ai-nginx` (brain stack) → `hub`.
- Chat inference → inference on **`hub:31360`** (not Ollama on `apps` or `hub`).

**Edge moved to `inference` (Jul 2026):** `alfa-ai-edge-api` no longer runs on `apps`.
 admin login and LAN edge **`8420`** are on **`inference`** (`deploy/cluster-members/_common/start-edge-api.sh`).
Site nginx on `apps` (`alfa-nginx`, public `www.example.com`) targets
**`http://orchestrator`** for `/alfa-ai/*` — the `inference` edge, not the brain
directly, so public-surface filtering in
[alfa-ai-edge.conf](../deploy/nginx-edge/alfa-ai-edge.conf) (denies
`/admin`, `/operator`, `/docs`, `/api/admin`, etc.) stays in front of `hub`.

**Public WordPress + Cloudflare (2026-09):** **example.com** and **example-siteperch.com** are **not** stopped by cluster start/stop. If the public URL returns **Cloudflare 530** but LAN checks pass, **`cloudflared`** on `apps` (`cf-alfa`, `cf-example-site`) lost WAN — usually the same **island gateway** issue as `hub`. Verify:

```bash
ssh operator@apps 'bash ~/alfa-ai/deploy/cluster-members/apps/verify-public-sites-lan.sh'
```

Runbook: [LAN_ISLAND_GATEWAY_OUTAGE.md](LAN_ISLAND_GATEWAY_OUTAGE.md) (restore **`orchestrator`** from `br1`, then restart tunnels if needed). **LAN example-site:** `http://apps/`.

**Bug fixed 2026-07-05:** this location previously pointed at the Docker
service name `alfa-ai-api:8000`, which only resolved while that container ran
on `apps` itself. Docker embedded DNS cannot resolve container names across
hosts, so after the edge moved to `inference` every `/alfa-ai/*` request 502'd
(`alfa-ai-api could not be resolved (2: Server failure)` in
`alfa-wp-error.log`). Fixed by pointing at the `inference` LAN IP by address.

The `alfa-nginx` config is now tracked in-repo at
[websites/alfa-nginx-config/](../websites/alfa-nginx-config/) (previously an
untracked standalone directory on `apps`). On `apps`,
`/home/operator/alfa-nginx-config` is a symlink into the `alfa-ai` checkout
(same pattern as `alfa-wordpress-plugins` — see
[REPO_HOST_MAPPING.md](REPO_HOST_MAPPING.md)), so `git pull` brings config
changes with it; rebuild + recreate the container after pulling changes here.

**Duplicate definition removed 2026-07-06:** `alfaqd-website`'s own
`docker-compose.yml` (`/home/operator/alfaqd-website`, Dockge stack, symlinked
from `/opt/stacks/alfaqd-website`) also declared its own `alfa-nginx` service
built from a bundled, stale `nginx-config/` copy still pointing at the dead
`alfa-ai-api:8000` backend — a leftover from before the Jul 5 move above that
was never cleaned up. Docker container names must be unique per host (Compose
spec: `container_name` is not intended to be duplicated across projects), so
only one of the two definitions could ever actually own the running
`alfa-nginx` container; the live one happened to be the correct
`alfa-nginx-config` repo copy, but `boot-all-stacks.sh` only ever referenced
`alfaqd-website`'s (stale, broken) copy. Fixed by removing the `alfa-nginx`
service from `alfaqd-website/docker-compose.yml` (backed up alongside it) and
adding `websites/alfa-nginx-config` to `boot-all-stacks.sh` directly, so a
fresh boot recreates the correct, current config instead of the dead one.
`alfaqd-website`'s own `wordpress`/`db` services are unaffected.

See [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md) for the brain side and [ai-148/README.md](../deploy/cluster-members/inference-coordinator/README.md) for the hub.
Postgres and Redis on `apps` are **protected shared infrastructure** — cluster stop/start never downs them (see CLUSTER_START_STOP_OPERATOR.md and stacksapps.yml). They serve multiple sites/repos (rankings, uspbf, alfaqd/alfa website, probilliards, alfa-ai, contracts, etc.).
For Redis vs rankings-bot Redis and shared Postgres vs per-bot Postgres, see
[**DOT105_SHARED_DATA_PLANE.md**](DOT105_SHARED_DATA_PLANE.md).
For the in-progress migration, see
[history/BRAIN_MIGRATION_105_TO_111.md](history/BRAIN_MIGRATION_105_TO_111.md).

## Port map summary on `apps`

```
apps (Ubuntu 26.04.1)
├── 5432  → postgres (protected dedicated stack — alfa-postgres, shared with bots)     LAN-only firewall
├── 6379  → redis (protected dedicated stack — alfa-redis)                                LAN-only firewall
├── 5001  → Dockge agent                          LAN
│   (edge :8420 retired here — see inference hub)
│   (Petals :8013 / :31330 / :31331 retired — do not bind)
│
├── 80/443 → nginx for public websites (USPBF, alfaqd-website, …)
└── 3000+ → individual bot services still on this host
```

## First-time setup (post-migration)

**Prereqs:**

- NFS mount from `hub` at `/mnt/cluster`: `sudo bash scripts/mount_nfs_models.sh`
  then `bash scripts/verify_hub_hub.sh` (see
  [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) § 3 — `showmount` may
  be empty on hub Scale; the mount script probes paths).
- Docker installed (`apps` is CPU-only; no nvidia toolkit required).
- `/etc/docker/daemon.json` points at the LAN registry mirror
  (`http://hub/`).

### 1. Pull the repo

```bash
cd /home/operator/alfa-ai
git pull --ff-only origin main
```

### 2. Configure `deploy/.env.apps` (new file — apps-only subset)

```bash
cd /home/operator/alfa-ai/deploy
cp cluster-members/apps/env.apps.example .env.apps
# Edit secrets and URLs — see comments inside env.apps.example. Prefer this template
# over deploy/env.example (brain-focused) when populating apps-only vars.
# Key values for apps apps role:
#   ALFA_BRAIN_URL=http://hub
#   Do not set ALFA_AI_PETALS_GATEWAY_HOST_PORT (Petals retired)
#   ALFA_POSTGRES_* / REDIS_PASSWORD / HF_TOKEN as needed
#
# Consumer URLs for bots that use shared alfa-postgres / alfa-redis (when adopted):
#   DATABASE_URL=postgresql://alfaai@127.0.0.1:5432/alfaai
#   REDIS_URL=redis://127.0.0.1:6379/0
#
# NOT set on apps:
#   ALFA_AI_API_HOST_PORT     (brain API is on hub now)
#   ALFA_AI_LITELLM_HOST_PORT (LiteLLM is on hub now)
```

### 3. Bring up the apps role

```bash
bash deploy/cluster-members/apps/deploy.sh
```

This brings up stacks listed in **`deploy/cluster-members/apps/stacksapps.yml`**
(protected Postgres/Redis dedicated stacks, then bots). **`alfa-ai-edge-api` is skipped**
(retired on `apps` — use `inference` hub):

- `postgres` (protected dedicated) — `deploy/docker-compose.postgres.yml`
- `redis` (protected dedicated) — `deploy/docker-compose.redis.yml`
- Per-bot/site stacks listed in the manifest (`contracts-bot`, `credit-check-bot`, `example-site-perch`, `rv-auto-finder`, `alfaqd-website`, `dockge-agent`). Stacks that moved (atems → `atems`, market-pie5-bot → `market`, monitoring → `monitor`, USPBF → `probilliards`) were removed from the manifest on 2026-09-26; see [REPO_HOST_MAPPING.md](REPO_HOST_MAPPING.md). credit-check-bot and rv-auto-finder remain: they are still running on `apps`.

**Important:** Cluster stop/start does **not** down the postgres, redis, or alfa-ai-edge-api stacks. They are critical shared infra for multiple repos. See CLUSTER_START_STOP_OPERATOR.md.

Shortcut (same as `deploy.sh`):

```bash
bash deploy/cluster-members/apps/boot-all-stacks.sh
```

### 4. Start the Dockge agent bound to `:5001`

```bash
sudo mkdir -p /opt/dockge
sudo tee /opt/dockge/compose.yaml >/dev/null <<'YAML'
name: apps-dockge
services:
  dockge:
    image: louislam/dockge:1
    container_name: apps-dockge
    restart: unless-stopped
    ports: ["5001:5001"]
    volumes:
      - /var/run/docker.sock:/var/run/docker.sock
      - /opt/dockge/data:/app/data
      - /opt/stacks:/opt/stacks
    environment:
      - DOCKGE_STACKS_DIR=/opt/stacks
YAML
(cd /opt/dockge && docker compose up -d)
```

On `orchestrator`'s primary Dockge (`http://127.0.0.1:5002/`): **Settings → Remote
agents → Add** → `http://apps/`.

## Petals bootstrap node (RETIRED)

**Do not deploy.** `apps` is no longer a DHT bootstrap. Petals is retired
([history/](history/)). Leave `31330`/`31331`/`8013` closed. Live inference is
inference on `hub:31360`. Historical notes below are archive only.

### Get the current bootstrap multiaddr

```bash
# On apps:
sudo docker logs petals-worker 2>&1 \
  | grep -E 'Running a server on|Full list of visible multiaddresses' \
  | tail -1
# Expect a line containing /ip4/apps/tcp/31330/p2p/<peer-id>
```

**Peer-id stability:** when **`PETALS_IDENTITY_PATH`** lives on a **persisted volume**
(default in [`deploy/petals/docker-compose.worker.yml`](../deploy/docker-compose.worker.yml)),
the libp2p peer-id stays stable across **`docker compose up --force-recreate`**. Only
**deleting** the identity key (or starting with a fresh volume) yields a new peer-id —
refresh joiners and brain bootstrap registration if that happens.

Legacy note: if you operated **without** a persisted identity, every recreate could
advertise a new peer-id; the volume-backed layout is now canonical on `apps`.

### Firewall

```bash
cd /home/operator/alfa-ai
sudo ./scripts/petals_worker_ufw_allow.sh   # opens 31330/tcp + 31331/tcp from LAN
```

**hub `hub` (`enp11s0f0np0`):** multiple addresses (e.g. `hub`, `.157`, `storage`) on **np0** (`br0` removed Jun 2026). Host-network Petals workers may **source outbound** connections to `apps:31330` from **`storage`** (or another alias), not from `.157`. If joiners log `failed to connect to bootstrap peers` while `apps` is up, on hub run **`ip route get apps`**, note **`src`**, and on `apps` **`sudo ufw allow from <that-src> …`** for ports **31330** (and **31331** if applicable). See [DISTRIBUTED_AI.md](DISTRIBUTED_AI.md) § *hub `hub` and `enp11s0f0np0`*.

## What the apps-105 runner does

`deploy/cluster-members/apps/deploy.sh` reads `stacksapps.yml` and for
each stack:

1. Validates requirements (env files, NFS mount when the stack asks for it).
2. Runs `docker compose down` against any legacy project name listed in
   `stop_projects:` (e.g. stops the old `alfa-ai` brain project from `apps`).
3. Symlinks `/opt/stacks/<name> → <repo>/<path>` so compose derives the
   project name from the symlink folder (Dockge-compatible).
4. `cd /opt/stacks/<name> && docker compose -f <files> --env-file <env> up -d`.

Non-critical stacks that miss a requirement (e.g. a bot without a
populated `.env`) are skipped with a warning. **Critical** stacks
(`postgres`, `redis`, **`rankings-bot`**, **`probilliards-nginx`**) cause the
runner to exit non-zero so partial deploys don't silently succeed.
**`petals-gateway`** and **`petals-worker`** stay **off**. Petals is retired
([history/](history/)).

### Rankings public site (probilliardssoftware.com)

Full path (all must be up):

```text
Cloudflare -> cf-probilliards -> probilliards-nginx:80 -> rankings-bot-api:8003
```

| Piece | Managed by |
|-------|------------|
| API + Postgres + Redis + Celery | `stacksapps.yml` stack `rankings-bot` |
| Origin nginx | `stacksapps.yml` stack `probilliards-nginx` (`rankings-bot/nginx-config/`) |
| Cloudflare tunnel | `deploy.sh` post-step via `start-rankings-public-ingress-105.sh` |

**Manifest rule:** do not add a compose project to `stop_projects:` unless a stack
in the same deploy brings that project back up. Never stop `nginx-config` from the
`rankings-bot` stack alone (regression fixed 2026-06-29).

After `deploy.sh`, verify runs automatically via `verify-rankings-public-ingress-105.sh`.

## Verify

```bash
# Apps-role services up
docker compose ls --all
ls -l /opt/stacks

# Postgres + Redis respond (defaults: DB/user alfaai — see deploy/.env.apps)
docker exec -it alfa-postgres psql -U alfaai -d alfaai -c 'SELECT 1;'
cd /home/operator/alfa-ai/deploy && set -a && source .env.apps && set +a
docker exec -it alfa-redis redis-cli -a "$REDIS_PASSWORD" ping

# Petals gateway reachable from brain (hub → apps)
ssh operator@hub 'curl -fsS http://apps/health'

# Petals worker online
curl -fsS http://127.0.0.1:31331/health | jq .

# Dockge agent
curl -fsS http://apps/          # login page
curl -fsS http://hub/v2/       # registry mirror

# Rankings public ingress (local + public)
bash deploy/cluster-members/_common/verify-rankings-public-ingress-105.sh
curl -fsS -o /dev/null -w '%{http_code}\n' --max-time 20 https://www.probilliardssoftware.com/rankings

# Other websites (examples)
curl -fsS -I http://example.com    # via nginx
curl -fsS -I http://uspbf.com
```

## Bot env files — brain URL migration

Every bot/site on `apps` that calls the brain must now point at `hub`.
Audit each `.env` (rankings-bot, atems, USPBF, alfaqd-website, etc.) and
update:

| Key | Before (`apps` brain) | After (`hub` brain) |
|-----|-----------------------|----------------------|
| `ALFA_AI_API_URL` | `http://127.0.0.1:8420` or `http://orchestrator` | `http://hub` |
| `LITELLM_BASE_URL` | `http://127.0.0.1:8013` or `http://apps` | `http://hub` |
| `LITELLM_API_KEY` | (whatever key on apps) | (same master key as `/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/.env` on `hub`) |

The migration guide at [history/BRAIN_MIGRATION_105_TO_111.md](history/BRAIN_MIGRATION_105_TO_111.md)
§ "Bot env sweep" has the `grep` commands and batch-update pattern.

## Routine operations

### Code update (remaining apps)

```bash
cd /home/operator/alfa-ai
git pull --ff-only origin main
bash deploy/cluster-members/apps/deploy.sh     # idempotent full fleet
bash deploy/cluster-members/apps/deploy.sh --only=rankings-bot,probilliards-nginx
```

**`--only` / `--skip`:** use `--only=name1,name2` or `--only name1,name2` (no spaces after
commas). A targeted `--only` run skips `global_stop_projects` so unrelated stacks are not torn down.

### Restart just the Petals worker

**Do not.** Petals is retired. Do not `compose up petals-worker`.

### Restart just Postgres / Redis

```bash
docker compose -f deploy/docker-compose.postgres.yml restart
docker compose -f deploy/docker-compose.redis.yml restart
```

### Sanity checks (no rebuild)

Ampere host — **`cuda`** wheels (`bitsandbytes-0.41.1` is correct here, not
Blackwell `0.45.5`). Full checklist: [FLEET_HOST_READINESS.md](FLEET_HOST_READINESS.md).

```bash
cd /home/operator/alfa-ai
mountpoint -q /mnt/cluster && echo "OK: /mnt/cluster mounted"
curl -fsS http://hub/health
curl -fsS http://hub/health/liveliness
```

Do **not** curl `apps:8013` or `:31331` (retired Petals).

**2026-05-23 snapshot (historical Petals):** ignore for live ops. `apps` is
CPU-only apps; GPU passthrough moved to VM100.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| Bots on `apps` return 502 when asking ALFa | Bot `.env` still points at old brain on `apps` | Update to `http://hub` and restart bot |
|  `http://<inference--ip>:8420/alfa-ai/login` timeout | Wrong  IP, UFW blocks `8420` on `inference`, or edge not publishing | On `inference`: ` ip -4`; `sudo ufw allow from 100.64.0.0/10 to any port 8420 proto tcp`; `bash deploy/cluster-members/_common/start-edge-api.sh` |
| Chat 500 from a bot on `apps` | LiteLLM or inference down on `hub` | Check `hub:8413` liveliness and coordinator `:31360`; do not start Petals on `apps` |
| Registry mirror says 503 from `apps` | `hub`'s mirror container down | `ssh operator@hub 'sudo docker compose -f /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/docker-compose.registry.yml up -d'` |

## Related

- [FLEET_HOST_READINESS.md](FLEET_HOST_READINESS.md) — per-host sanity / verified status
- [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md) — brain + agent on `hub`
- [history/BRAIN_MIGRATION_105_TO_111.md](history/BRAIN_MIGRATION_105_TO_111.md) — migration runbook
- [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) — live inference (Petals swarm docs are historical)
- [DOCKGE_AGENTS_WORKERS.md](DOCKGE_AGENTS_WORKERS.md) — Dockge agent setup
- [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) — shared storage
- [CONTAINER_REBUILD_STRATEGY.md](CONTAINER_REBUILD_STRATEGY.md)
- [NODE_INVENTORY.md](NODE_INVENTORY.md)
