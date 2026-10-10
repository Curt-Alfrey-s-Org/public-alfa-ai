# Brain operator guide — `hub` (hub Scale 25.04)

**`hub` is the main brain.** It runs the `alfa-ai` orchestration stack
(API, LiteLLM, nginx, Postgres + Redis -- DB on the SSD pool per
[HOST_STORAGE_AND_NETWORK_STANDARDS.md](HOST_STORAGE_AND_NETWORK_STANDARDS.md)),
the inference **CPU coordinator** `:31360`, and the **RTX 3050** shard `:31353`.
**Petals / Hivemind is retired** (historical announce `orchestrator` -- do not use).

**Production chat** is Qwen3.6-27B on the llama.cpp RPC pool (`frontier-code` /
`frontier` via LiteLLM **`:8413`**). Compat aliases remap to the same pool.
**35B MoE and Ollama CPU chat are retired.** **Ollama was removed from `hub`
on 2026-07-05.**

**RAG** embed + rerank are on **`rag`** (`EMBED_BASE_URL` / `RERANK_BASE_URL`
in [deploy/env.example](../deploy/env.example)). `hub` is the artifact hub
(NFS `storage` / SMB / registry). Canonical routing:
[DOCUMENTATION_CANONICAL.md](DOCUMENTATION_CANONICAL.md),
[GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md),
[deploy/litellm_config.yaml](../deploy/litellm_config.yaml).

This guide covers day-to-day operation. For the initial one-shot migration
from `apps`, see [history/BRAIN_MIGRATION_105_TO_111.md](history/BRAIN_MIGRATION_105_TO_111.md).
For the NVMe pool setup, see [hub_111_NVME_POOL.md](hub_111_NVME_POOL.md).

For **canonical Git branch**, **`GIT_BRANCH`** on NAS pulls, and a **production
`deploy/.env` vs `deploy/env.example` checklist**, see [DOCUMENTATION_CANONICAL.md](DOCUMENTATION_CANONICAL.md).

**Hardware (Apr 2026):** Ryzen **9 7900X**, **~46 GiB** RAM (`free` — **2×24 GB**
DDR5 **ECC UDIMM** @ **4800 MT/s**, dual-channel **DIMM 1** on channels A/B; part
**`AVW723GUA1K0480P06-BAB7`**; board max **128 GB** / **4** slots per SMBIOS),
AsrockRack **B650D4U-2L2T/BCM**, **RTX 3050 6 GB** (Jul 2026 `nvidia-smi` — single
GPU). inference: **3050 rpc-server shard** `:31353` + **CPU coordinator** `:31360` on
7900X. **Petals retired.** Full line in [NODE_INVENTORY.md](NODE_INVENTORY.md).

### CPU thermal policy (default: boost off + 4.6 GHz cap)

Default for `hub`: **turbo disabled** and **`scaling_max_freq` capped at 4.6 GHz**
(4600000 kHz). Persistent across reboots via Post Init; hub Docker builds do not
change cpufreq on exit. Override MHz: `ALFA_CPU_MAX_FREQ_MHZ=4200` when running
the disable script.

Kernel references: [amd-pstate boost](https://docs.kernel.org/admin-guide/pm/amd-pstate.html),
[cpufreq scaling_max_freq](https://docs.kernel.org/admin-guide/pm/cpufreq.html).

**Install or refresh (on `hub` after `git pull`):**

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
bash deploy/cluster-members/hub/install-disable-cpu-boost-init.sh
```

Must run **`sudo bash disable-cpu-boost.sh`** (installer does this). Post Init
uses the same `sudo bash` on the HDD-pool copy under `/mnt/HDDs/Alfa-AI/scripts/`.

**Verify:**

```bash
cat /sys/devices/system/cpu/cpufreq/boost                                 # 0
cat /sys/devices/system/cpu/cpufreq/policy0/scaling_max_freq              # 4600000
grep MHz /proc/cpuinfo | head -4
```

On **amd_pstate**, verify **`policy0`**, not `cpu0/cpufreq` (the per-cpu node can
show a stale value).

**Undo:** `bash deploy/cluster-members/hub/install-disable-cpu-boost-init.sh --uninstall`
then restore boost and max freq manually if desired.

### Hub Docker builds (llama.cpp image compile)

Hub build scripts pass **`BUILD_JOBS=6`** (override: `ALFA_HUB_BUILD_JOBS=4`).
Cpufreq stays at the Post Init policy above; builds no longer apply/restore a
temporary MHz cap. On Ctrl+C / failed build they run abort cleanup (BuildKit +
hub `.tmp`). Weekly reclaim is a **hub Cron Job** (UI:
**System Settings -> Advanced -> Cron Jobs**):

```bash
bash deploy/cluster-members/hub/install-docker-cleanup-cron.sh
```

See [operations/DOCKER_HOST_CLEANUP.md](operations/DOCKER_HOST_CLEANUP.md).

### CPU max frequency cap with turbo on (optional, not default)

Alternative to boost-off: cap the 7900X at a fixed MHz (default **5.3 GHz** /
5300000 kHz) via cpufreq `scaling_max_freq` while leaving turbo enabled within
that ceiling. Prefer **boost disable** above for long compiles; use this only if
you need a higher ceiling than base but below full turbo.

Kernel reference: [cpufreq scaling_max_freq](https://docs.kernel.org/admin-guide/pm/cpufreq.html).

**Install:** `bash deploy/cluster-members/hub/install-cap-cpu-max-freq-init.sh`
(removes boost-off Post Init if present).

**Undo:** `bash deploy/cluster-members/hub/install-cap-cpu-max-freq-init.sh --uninstall`

## What runs on `hub`

| Service | Port (host) | Compose / install | Data dir |
|---------|-------------|-------------------|----------|
| `alfa-ai-api` (FastAPI) | `8420` (container `8000`) | `deploy/docker-compose.yml` | NVMe `/mnt/nvme/alfa-ai/app-state` |
| `alfa-ai-litellm` | `8413` (container `4000`) | `deploy/docker-compose.yml` | NVMe |
| `alfa-postgres` (protected dedicated stack) | `5432` (loopback) | `deploy/docker-compose.postgres.yml` (see stackshub.yml) | **SSD** (fast pool per HOST_STORAGE; volume or bind in dedicated stack) |
| `alfa-redis` (protected dedicated stack) | `6379` (loopback) | `deploy/docker-compose.redis.yml` (see stackshub.yml) | **SSD** (fast pool per HOST_STORAGE; volume or bind in dedicated stack) |
| `alfa-ai-nginx` | `8080` (HTTP), `8443` (HTTPS) | `deploy/docker-compose.yml` | — |
| Dockge (hub Apps) | `31014` | hub Apps catalog | hub-managed |
| Docker registry mirror | `5000` | `deploy/cluster-members/hub/docker-compose.registry.yml` | HDD `/mnt/HDDs/Alfa-AI/docker/registry` |
| NFS / SMB shares | 2049 / 445 | hub Shares UI | HDD `/mnt/HDDs/Alfa-AI` |
| **aria2** (`p3terx/aria2-pro`) | `6800` (JSON-RPC), `6888` (BT) | Dockge stack from [`deploy/aria2/`](../deploy/aria2/) — see [`deploy/aria2/README.md`](../deploy/aria2/README.md) | Host bind **`ARIA2_DOWNLOADS_HOST_PATH`** → `/downloads` (default `…/models/downloads`) |

### What does **not** run on `hub`

- **Petals** workers or gateways (retired cluster-wide). Do not start
  `alfa-ai-petals-gateway` or `petals-worker`.
- **Ollama chat** (CPU fleet on `gaming-c` / `orchestrator` is retired). `hub` has no Ollama App.
- **RAG embed/rerank** (production is **`rag:11435`** / **`:8360`**).
- **Websites / remaining bots** (`apps` and dedicated VMs — [REPO_HOST_MAPPING.md](REPO_HOST_MAPPING.md)).

### Network -- `br1` LAN (live 2026-09-04)

**SSoT:** **`br1` is the LAN** -- cabinet cables (Yuanley/92B, `inference` USB, i210 to `hypervisor`, both BCM, USB) are **one L2 domain**. Per [hub bridge setup](https://www.hub.com/docs/scale/network/interfaces/settingupbridge/) and [configuring interfaces](https://www.hub.com/docs/scale/network/interfaces/configuringinterfaces/), **IPv4 belongs only on `br1`**, not on bridge members ([ip-link(8)](https://man7.org/linux/man-pages/man8/ip-link.8.html)).

| IP | Notes |
|----|-------|
| `hub` | **Mgmt / API / LiteLLM / registry mirror / SMB / Dockge.** All docs, `deploy/.env`, and remote-agent URLs point here. On **`br1`** `/24` (default src). |
| `orchestrator` | **NFS bind VIP** on the **same** `br1` bridge (`/32` alias) -- not a separate physical NIC. Bind nfsd here; clients may mount **`storage` or `hub`** (same L2; `mount_nfs_models.sh` falls back to `hub`). |
| `orchestrator` | **Retired** (Petals swarm plane). Do not use for new traffic. May still appear as leftover on `enp7s0` until operator removes it. |
| `orchestrator` | **Retired** -- do not use. |

**`br1` members (2026-09-04 `bridge link`):** `enp6s0`, `enp7s0`, `enp11s0f0np0`, `enp11s0f1np1`, `enxc65a06c6ae7e` -- all L2 only; **no IPv4** on members.

**Known misconfig (2026-09-04):** Post Init assigned `storage/32` to `enp11s0f1np1` and `.157/32` to `enp7s0` while those interfaces are enslaved to `br1`. Remove member IPs; keep **`hub/24` + `storage/32` on `br1` only** ([CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md) br1 src bug).

**Stale docs (do not repeat):** Jun 2026 "aliases on `enp11s0f0np0` only / np1 not cabled"; Jul 2026 "triple-NIC split" -- defeated while NICs are `br1` members.

**Link reset (BCM at 1 G):** `sudo ethtool -r enp11s0f0np0` then recheck `Speed` -- [hub_NIC_SPEEDTEST.md](hub_NIC_SPEEDTEST.md) section 1.

**Throughput (Jun 2026, same-L2 / `br1`):** `iperf3` from `apps` shows **~937-948 Mbit/s** to **`hub`/`storage`/`.157`** (1 GbE-class until path negotiates 10G to AXE300).

## Port map summary

```
hub (hub 25.04)
├── 8420  → alfa-ai-api      (host)  ←── external callers + apps bots/sites
├── 4000  → alfa-ai-litellm  (host)
├── 8080  → alfa-ai-nginx    (host, HTTP)
├── 8443  → alfa-ai-nginx    (host, HTTPS)
├── 11434 → ollama           (host)  ←── LiteLLM inside the brain stack
├── 31014 → Dockge           (hub Apps)
├── 5000  → registry mirror  (HTTP, LAN-wide)
├── 2049  → NFS              (LAN)
├── 445   → SMB              (LAN)
├── 6800  → aria2 JSON-RPC  (LAN — `deploy/aria2/`, multi-connection downloads)
└── 22    → SSH              (admin)
```

### SSH — enable and keep on after reboot

**UI (preferred):** **System → Services → SSH** — turn the service **On**, set
**Start Automatically** (wording may vary slightly by release), and apply.

**CLI (persists in hub config — survives reboot):** run on the hub
host shell (local console, IPMI, or an **existing** SSH session — if SSH is
off, use the physical/console menu first):

```bash
midclt call service.update ssh '{"enable": true}'
midclt call service.start ssh
```

Check status:

```bash
midclt call service.query | jq '.[] | select(.service=="ssh")'
```

(`jq` optional — without it, inspect the `ssh` object for `"enable": true` and
`"state": "RUNNING"`.)

Further SSH options (password vs key login, port, root login) use **Services →
SSH → settings** or `midclt call ssh.update` — see
[hub SSH docs](https://www.hub.com/docs/scale/).

Firewall: allow `22 / 6800 / 8420 / 4000 / 11434 / 5000 / 2049 / 445` from
`orchestrator/24` (include **22** if you manage SSH from other LAN hosts).
Nothing on `hub` needs to talk out to the public internet at runtime except
HF downloads (aria2/hf-cli inside short-lived containers).

## First-time setup (after NVMe pool exists)

**Prereq:** NVMe pool mounted at `/mnt/nvme` with the layout from
[hub_111_NVME_POOL.md](hub_111_NVME_POOL.md):

```
/mnt/nvme/
├── docker/           ← Docker data root (set via /etc/docker/daemon.json)
├── ollama/           ← Ollama models (OLLAMA_MODELS bind)
├── alfa-ai/
│   ├── app-state/    ← LiteLLM SQLite, logs, small DBs
│   └── repo/         ← (optional) git clone if not kept on HDD
└── buildkit/         ← BuildKit cache
```

### 1. Clone the repo

`hub` uses `/mnt/HDDs/Alfa-AI/repo/alfa-ai` as the canonical clone (keeps
history out of the NVMe hot pool). This is the same path every deploy script
on `hub` references.

```bash
# On hub (SSH as root or a user in the docker group)
mkdir -p /mnt/HDDs/Alfa-AI/repo
cd /mnt/HDDs/Alfa-AI/repo
git clone operator@example.com:example/alfa-ai.git
cd alfa-ai
```

### 2. Docker CLI on hub SSH (`sudo` vs `docker` group)

Non-root SSH accounts often cannot use **`docker`** until they join the **`docker`** group (then **new SSH session**):

```bash
sudo usermod -aG docker "$USER"
# log out / log in again — or: newgrp docker
docker info
```

Until then, prefix Compose with **`sudo`**:

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy
sudo docker compose --env-file .env config >/dev/null
```

**`deploy/cluster-members/hub/deploy.sh`** tries plain **`docker`** first, then **`sudo docker`**, and exits with a short fix hint if neither works.

### 3. Configure `deploy/.env`

Copy the template and fill in values for the `hub` brain role:

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy
cp env.example .env
# Key values to set:
#   POSTGRES_PASSWORD=<strong-secret>   (for dedicated postgres stack if using in-compose defaults)
#   ALFA_AI_API_HOST_PORT=8420
#   ALFA_AI_LITELLM_HOST_PORT=8413   # host port; container listens on 4000
#   LLAMACPP_CODE27_URL=http://host.docker.internal:31360/v1
#   EMBED_BASE_URL=http://orchestrator
#   RERANK_BASE_URL=http://orchestrator
#   # Do not set PETALS_GATEWAY_* or OLLAMA_FLEET_* (retired)
#   # DBs (postgres/redis) are now managed as separate protected stacks (see stackshub.yml
#   # and docker-compose.postgres.yml / docker-compose.redis.yml). Configure their data
#   # paths/passwords in the stack env or dedicated .env; do not rely on brain stack DB services.
#   # Set DATABASE_URL/REDIS_URL to point at the dedicated stack containers (Docker DNS) or external.
#   REDIS_PASSWORD / LITELLM_MASTER_KEY / LITELLM_SALT_KEY (see env.example — required where applicable)
#   LITELLM_MASTER_KEY=sk-alfa-... (rotate before production)
#   ALFA_WORKER_HEARTBEAT_TOKEN=...  (same on every worker)
```

DB services are provided by the dedicated protected stacks (`postgres` and `redis` in stackshub.yml). The brain compose no longer defines `alfa-ai-postgres`/`alfa-ai-redis`. Set `DATABASE_URL`/`REDIS_URL` (and the corresponding passwords) to target the dedicated stack containers. The dedicated stack's compose file owns its Postgres/Redis service definitions and volumes.

### 4. Hub models (not live Ollama chat)

**`hub` runs no Ollama.** Seed GGUF / hub blobs with `hub_hub_models.sh`
([HTTP_DOWNLOADS.md](HTTP_DOWNLOADS.md)). Do **not** pull `qwen3.5:27b` or
`qwen3.6:35b-a3b` as a live chat backend — those CPU-fleet tags are retired.
Production RAG is **`rag`**, not Ollama embed on `gaming-c`.

**Do not** curl `/api/pull` from a worker — hub-first on `hub` only.

**HDD cold mirror + disk status** (run as root on `hub`):

**hub default shell is often tcsh.** In tcsh, **`#` is not always “rest of line is comment”** like in bash. Putting `# optional …` on the same line as **`git`** makes git see a bogus ref named `#` → `fatal: couldn't find remote ref #`. Put **`git pull` on its own line** with no trailing `#`, or run **`bash`** first (`bash` then paste bash-style commands).

Update repo (no comment on this line). Run as **`operator`** (not `sudo git` -- root has no GitHub SSH key):

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
git pull --ff-only origin main
```

If `git pull` or `git reset` fails with **Permission denied** on `deploy/aria2` or
`deploy/petals/build-contexts` (root-owned files from an earlier `sudo rsync` into
this clone), sync as `operator`:

```bash
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/_common/git-sync-repo-clone.sh
```

`sudo bash deploy.sh` runs that helper automatically when present. Do **not** run
`sudo git fetch` -- use the helper or `git fetch` as `operator` only.

Hub models (bash or `bash -lc '…'` from tcsh):

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
sudo bash scripts/hub_hub_models.sh ensure-dirs
sudo bash scripts/hub_hub_models.sh migrate-layout
sudo bash scripts/hub_hub_models.sh migrate-layout --yes
sudo bash scripts/hub_hub_models.sh status
sudo bash scripts/hub_hub_models.sh pull quality --stores cold,hot
sudo bash scripts/hub_hub_models.sh pull embed --stores cold
sudo bash scripts/hub_hub_models.sh pull gguf
sudo bash scripts/hub_hub_models.sh prune-legacy --stores both --dry-run
sudo bash scripts/hub_hub_models.sh prune-legacy --stores both --yes
```

If setup_hub_hub.sh created **`ollama/models`** or **`hf/hub`**, run **`migrate-layout`** (dry-run then `--yes`) before relying on **`models/ollama`** and **`models/huggingface/hub`**.

If your hub shell is **tcsh**, run each **`sudo bash …`** line alone, or use **`bash -lc 'cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && sudo bash scripts/hub_hub_models.sh status'`**.

`gaming-b` (gaming-worker-b) runs **no chat model** — it is the reranker + embed cold-standby
(`Qwen3-Reranker-0.6B` via llama.cpp sidecar; `qwen3-embedding:4b` stopped). The
quality chat model `qwen3.5:27b` is pulled on **`gaming-c`** (`pull-models.sh quality`);
the speed model `qwen3.6:35b-a3b` on **`orchestrator`** (`pull-models.ps1 -Role Speed`).
See [QWEN3_MIGRATION.md](QWEN3_MIGRATION.md) § "Tier matrix".

### 5. Bring up the brain stack

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
bash deploy/cluster-members/hub/deploy.sh
```

The deploy script:

1. Runs `nvidia_preflight.sh --role brain` to confirm the **RTX 5060** (Blackwell)
   GPU is visible and `nvidia-container-toolkit` is installed.
2. Pulls the latest git commit.
3. Configures `/etc/docker/daemon.json` to use the LAN registry mirror (this
   host hosts the mirror itself — it's a no-op but safe).
4. Creates `tunnel_network` if missing.
5. Syncs **cuda-blackwell** wheels from the local HDD hub into
   `deploy/petals/build-contexts/wheels-cuda-blackwell/` (auto-fallback when
   `/mnt/cluster/wheels/` is empty — see [FLEET_HOST_READINESS.md](FLEET_HOST_READINESS.md)).
6. `docker compose up -d` for the brain stack and Petals **Blackwell** worker
   (`docker-compose.worker.blackwell.yml`).
7. `docker compose up -d` against `docker-compose.registry.yml`.
8. Prints smoke-test URLs.

### 6. Install Dockge via hub Apps

hub Scale 25.04 → **Apps** → install **Dockge** from the catalog. Bind
port `31014`. This is the only Dockge on `hub` — do **not** run a manual
Dockge stack.

Then on `orchestrator`'s primary Dockge (`http://127.0.0.1:5002/`):
**Settings → Remote agents → Add** → `http://hub` with the
same credentials you set in the `hub` Dockge wizard.

## Daily operations

### Restart the brain stack

**Preferred:** full ordered start with 27B preflight + status checks:

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
sudo bash scripts/start.sh
```

Quick restart (no rebuild; run `brain_verify.sh` after):

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy
sudo docker compose --env-file .env restart
bash ../scripts/brain_verify.sh
```

Before **`up -d --force-recreate alfa-ai-litellm`** alone, ensure the dedicated
`alfa-redis` and `alfa-postgres` (from the protected postgres/redis stacks) are up
(LiteLLM Redis cache + Prisma). Prefer the dedicated stack ups or the full
brain start flow (`scripts/start.sh` or `brain_redeploy_api.sh`) rather than piecemeal.

### Apply a code update

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
git pull --ff-only origin main
bash deploy/cluster-members/hub/deploy.sh   # idempotent
```

### Smoke tests

Standalone probes (services already running). After **recreate/restart**, run the
matching wait helper first — see [WAIT_POLL_OPERATOR.md](WAIT_POLL_OPERATOR.md).

```bash
# Brain API
bash deploy/cluster-members/_common/wait-brain-health.sh 30
curl -fsS http://hub/health

# LiteLLM liveliness (no auth) — host port from deploy/.env (default 8413)
bash deploy/cluster-members/_common/wait-litellm-liveliness.sh 120
curl -fsS http://hub/health/liveliness

# Ollama on hub was removed 2026-07-05 — :11434 should now refuse connections.
# Confirms no stray Ollama App/container survived the teardown.
curl -fsS --max-time 3 http://hub/api/tags && echo "WARN: Ollama still reachable on hub" || echo "OK: no Ollama on hub"

# Chat smoke — inference via LiteLLM (frontier-code / chat aliases)
curl -fsS http://hub/v1/chat/completions \
  -H "Authorization: Bearer $LITELLM_MASTER_KEY" -H 'Content-Type: application/json' \
  -d '{"model":"frontier-code","messages":[{"role":"user","content":"hello"}],"max_tokens":8}'

# Registry mirror
curl -fsS http://hub/v2/
```

### Check disk pressure

```bash
# NVMe hot pool
df -h /mnt/nvme
du -sh /mnt/nvme/*

# HDD canonical tree
df -h /mnt/HDDs
du -sh /mnt/HDDs/Alfa-AI/models/huggingface
```

### ZFS ARC guardrail

ZFS will happily use all of RAM for ARC. On `hub` (~46 GiB) that starves the
brain stack (API + LiteLLM + Postgres/Redis) and the inference coordinator.
`hub` no longer runs a chat LLM, so the cap is to protect those, not Ollama.
Cap ARC at 12–16 GB:

```bash
# On hub — runtime cap (resets at reboot)
echo $((16 * 1024 * 1024 * 1024)) > /sys/module/zfs/parameters/zfs_arc_max

# Persist via /etc/modprobe.d/zfs.conf (hub regenerates; check UI
# System → Advanced → sysctl is the preferred path on Scale).
```

Monitor: `arc_summary | head -30` and `free -g`.

### Watch inference on `hub`

Live chat is the inference coordinator + LiteLLM, not Ollama:

```bash
curl -fsS http://127.0.0.1:31360/health
curl -fsS http://127.0.0.1:8413/health/liveliness
nvidia-smi
sudo docker stats --no-stream
```

June 2026 Ollama CPU-chat on `gaming-c` / `orchestrator` is **retired**.

## Integration with `apps` (apps host)

Websites + bots on `apps` call the brain on `hub`:

```env
# On apps, in each bot's .env:
ALFA_AI_API_URL=http://hub
LITELLM_BASE_URL=http://hub   # host port (container listens on 4000)
LITELLM_API_KEY=<same master key as deploy/.env on hub>
```

Postgres and Redis for the brain (and shared consumers) run as **protected dedicated stacks** using the split compose files (`deploy/docker-compose.postgres.yml` and `deploy/docker-compose.redis.yml`). They are declared in `stackshub.yml` as critical infrastructure and are **never stopped** by normal cluster start/stop cycles (see CLUSTER_START_STOP_OPERATOR.md and the dedicated stacks in stacks manifests). Data volumes are preserved.

The brain and consumers point at the dedicated containers (via Docker DNS on the shared network, or explicit `ALFA_*` URLs in env):

```env
# Example pointing at dedicated stack services (adjust host/port as published)
DATABASE_URL=postgresql://alfaai@alfa-postgres:5432/alfaai
REDIS_URL=redis://alfa-redis:6379/0
```

Point at external hosts only if you intentionally run the DB off-box. Use the dedicated stacks' env for passwords and data paths. Never use `docker compose down -v` on the postgres or redis stacks.

## Dockge remote agent matrix

From the primary Dockge on `orchestrator` (`http://127.0.0.1:5002/`):

| Agent URL | Purpose |
|-----------|---------|
| `http://hub` | Brain + hub (this host) |
| `http://apps` | Apps host (remaining websites/bots) |
| `http://orchestrator` | gaming-worker-b opt-in inference shard |
| `http://orchestrator`  | gaming-worker-c opt-in inference shard |
| `http://orchestrator` | gaming-worker-a opt-in inference shard |

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|--------------|-----|
| `alfa-ai-api` OOM-killed shortly after boot | ZFS ARC ate all of RAM before containers started | Cap `zfs_arc_max` (see above), reboot |
| `chat`/`frontier-code` slow or 500 | inference coordinator or a core shard down | Read-only diagnose (`diagnose-inference-ai.sh` on `inference`); then one full `Start-Stop-AlfaAi.ps1` stop + start. Do not piecemeal-restart shards. |
| LiteLLM returns 500 for `frontier` | Coordinator `:31360` or LiteLLM not up | `wait-litellm-liveliness.sh` then `curl -fsS http://127.0.0.1:31360/health` |
| Brain 502s from bots on `apps` | bot `.env` still points at `http://orchestrator` | Update bot `.env`: `ALFA_AI_API_URL=http://hub` |
| Registry mirror 503 | `docker-compose.registry.yml` stopped | `docker compose -f deploy/cluster-members/hub/docker-compose.registry.yml up -d` |
| `unknown or invalid runtime name: nvidia` when starting **any** container | `/etc/docker/daemon.json` sets `"default-runtime": "nvidia"` but `nvidia-container-toolkit` is missing or misconfigured | Prefer: `docker-compose.registry.yml` pins `runtime: runc` for the mirror. For GPU stacks on `hub`, install toolkit or set `"default-runtime": "runc"` until NVIDIA runtime works. |

## Related

- [history/BRAIN_MIGRATION_105_TO_111.md](history/BRAIN_MIGRATION_105_TO_111.md) — migration runbook
- [hub_111_NVME_POOL.md](hub_111_NVME_POOL.md) — NVMe pool setup
- [DOCKGE_105_OPERATOR.md](DOCKGE_105_OPERATOR.md) — apps host guide
- [DOCKGE_AGENT_111_hub.md](DOCKGE_AGENT_111_hub.md) — Dockge install specifics
- [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) — HDD tree
- [NODE_INVENTORY.md](NODE_INVENTORY.md) — node list
- [FLEET_HOST_READINESS.md](FLEET_HOST_READINESS.md) — per-host sanity / verified status
- [petals/WORKER_ROLLOUT.md](petals/WORKER_ROLLOUT.md) — worker bring-up
- [petals/BLACKWELL_CUDA_BLACKWELL_WHEELS_GOTCHAS.md](petals/BLACKWELL_CUDA_BLACKWELL_WHEELS_GOTCHAS.md) — cuda-blackwell hub seed/sync/build failures
- [DISTRIBUTED_AI.md](DISTRIBUTED_AI.md) — LiteLLM + Petals + Ollama topology
