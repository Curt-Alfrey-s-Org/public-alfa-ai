# Docker host cleanup (staggered cron)

**Goal:** keep every Docker host from bloating after aborted / partial builds
(BuildKit cache, unused images, hub `.tmp` save files) without touching named
volumes or running stack data.

**Official references:**

- [docker system prune](https://docs.docker.com/reference/cli/docker/system/prune/)
- [docker builder prune](https://docs.docker.com/reference/cli/docker/builder/prune/)
- hub SCALE [cronjob.create](https://api.hub.com/v25.10/api_methods_cronjob.create.html)
  (UI: **System Settings → Advanced → Cron Jobs**)

**Related:** [STORAGE_CLEANUP_AND_BUILD_OFFLOAD.md](STORAGE_CLEANUP_AND_BUILD_OFFLOAD.md)
(build offload + one-shot reclaim), [WINDOWS_WSL_DOCKER_ENGINE.md](../WINDOWS_WSL_DOCKER_ENGINE.md),
[HUB_ARTIFACTS.md](../HUB_ARTIFACTS.md).

---

## What gets cleaned

| Action | Default | Safe for production? |
|--------|---------|----------------------|
| `docker builder prune -af --filter until=<BUILDER_UNTIL>` | hub `72h`, others `168h` | Yes — unused build cache only |
| `docker system prune -af --filter until=<SYSTEM_UNTIL>` | `168h` | Yes — unused containers/networks/images; **no** `--volumes` |
| Hub `docker-images/.*.tmp` older than 6h | `hub` only | Yes — partial `docker save` leftovers |

**Never** scheduled: `docker system prune --volumes`, deleting tagged runtime
images still referenced by compose, or compacting WSL `ext4.vhdx` (manual after
large deletes — see [WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md](../WINDOWS_DOCKER_WSL_DISK_AND_CACHE.md)).

---

## Staggered schedule (Sunday, local host time)

Schedules are staggered so prune IO does not hit every host at once.

| Host | When (Sun) | Installer |
|------|------------|-----------|
| `hub` hub | **03:00** | hub **Cron Job** (UI-visible) via `install-docker-cleanup-cron.sh` |
| `inference` | 03:15 | Linux `/etc/cron.d/alfa-docker-cleanup` |
| `pool-opt-in` | 03:30 | same |
| `apps` | 03:45 | same |
| `monitor` | 04:00 | same |
| `probilliards` | 04:15 | same |
| `market` | 04:30 | same |
| `atems` | 04:45 | same |
| `orchestrator` WSL | 05:00 | WSL `/etc/cron.d/alfa-docker-cleanup` (replaces legacy `docker-cleanup`) |
| `gaming-a` WSL | 05:15 | same |
| `gaming-b` WSL | 05:30 | same |
| `gaming-c` WSL | 05:45 | same |
| `secondary` Linux | 06:00 | Linux cron.d |

Shared script: `deploy/cluster-members/_common/docker-host-cleanup.sh`.

---

## Install

### `hub` (operator) — hub Cron Job (UI)

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
git pull --ff-only origin main
bash deploy/cluster-members/hub/install-docker-cleanup-cron.sh
```

Verify in UI: **System Settings → Advanced → Cron Jobs** — description
`alfa docker host cleanup`. Or:

```bash
midclt call cronjob.query | python3 -c "import json,sys; print([r for r in json.load(sys.stdin) if 'alfa docker' in (r.get('description') or '').lower()])"
```

Undo: `bash deploy/cluster-members/hub/install-docker-cleanup-cron.sh --uninstall`

### Linux Docker hosts (`inference`, `pool-opt-in`, `apps`, …)

```bash
cd ~/alfa-ai   # or host clone path
sudo bash deploy/cluster-members/_common/install-docker-cleanup-cron.sh
```

Schedule is auto-picked from hostname / `ALFA_CLEANUP_HOST` (see script). Override:

```bash
sudo ALFA_CLEANUP_MINUTE=15 ALFA_CLEANUP_HOUR=3 ALFA_CLEANUP_DOW=0 \
  bash deploy/cluster-members/_common/install-docker-cleanup-cron.sh
```

### Windows WSL workers (`orchestrator`, `gaming-a`, `gaming-b`, `gaming-c`)

From an elevated / normal PowerShell that can run WSL as root for cron.d:

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\_common\Install-AlfaDockerCleanup.ps1
```

Fresh WSL Docker installs also get this via `install-docker-engine-in-wsl.sh`.

---

## Manual / after Ctrl+C on a hub build

```bash
# Safe reclaim now (same script as cron):
sudo bash deploy/cluster-members/_common/docker-host-cleanup.sh

# Aborted hub build (fresher builder cache + hub .tmp):
ALFA_DOCKER_CLEANUP_MODE=abort sudo bash deploy/cluster-members/_common/docker-host-cleanup.sh
```

Hub build scripts (`scripts/build-llamacpp-rpc-*-on-hub.sh`) call **abort**
cleanup on non-zero exit / INT / TERM so a stopped compile does not leave
BuildKit + `.tmp` sitting until Sunday.

---

## Safety checklist

- [ ] Cron uses the shared script (not ad-hoc one-liners that add `--volumes`)
- [ ] `hub` job visible in hub Cron Jobs UI
- [ ] Running containers and named volumes untouched after a dry run
- [ ] After large WSL reclaim, compact `ext4.vhdx` only when operator chooses
