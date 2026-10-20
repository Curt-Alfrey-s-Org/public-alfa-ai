# Storage cleanup + build offload to `hub` (keep workers lean)

**Goal:** stop worker hosts (`orchestrator`, `gaming-c`, `gaming-a`, `gaming-b`, `secondary`) from filling
their C: drives with build artifacts. **`hub` (hub) builds the heavy
per-hardware images once and publishes them**; every other host **`docker load`s
its matching variant** and never builds locally. `hub`'s SSD/NVMe fast tier is
reserved so **alfa-ai gets priority over other repos/projects** sharing that pool.

**Recurring Docker prune (all hosts):** see
[DOCKER_HOST_CLEANUP.md](DOCKER_HOST_CLEANUP.md) — staggered Sunday cron,
hub UI Cron Job on `hub`, builder + system prune, hub `.tmp` reclaim,
abort cleanup when hub builds are stopped.

This runbook complements:

- [DOCKER_HOST_CLEANUP.md](DOCKER_HOST_CLEANUP.md) — scheduled / abort Docker cleanup
- [HUB_ARTIFACTS.md](../HUB_ARTIFACTS.md) — what lives on the hub + delivery per platform
- [CLUSTER_SHARED_STORAGE.md](../CLUSTER_SHARED_STORAGE.md) — canonical HDD tree + capacity budget
- [hub_111_NVME_POOL.md](../hub_111_NVME_POOL.md) — hot pool datasets, Docker data-root on SSD/NVMe
- [WINDOWS_WSL_DOCKER_ENGINE.md](../WINDOWS_WSL_DOCKER_ENGINE.md) — workers run Docker Engine in WSL (no Desktop)

---

## 0. What "too much space on C:" was (June 2026, `orchestrator`)

`orchestrator`'s C: had **~88 MB free**. Root causes and what reclaimed the space:

| Item | Location | Size | Action |
|------|----------|------|--------|
| **Orphaned Docker Desktop disk** | `…\AppData\Local\Docker\wsl\disk\docker_data.vhdx` | **294 GB** | **Deleted.** Leftover from the Desktop→WSL-engine migration. No `docker-desktop*` WSL distro mounts it; not locked; Desktop uninstalled. Removing it also fixed WSL `getpwnam … failed (EIO)` errors, which were caused by the full disk. |
| Dangling images / dead networks / dangling build cache | WSL engine (`Ubuntu` distro) | **15.4 GB** | `docker system prune -f` (safe — does not touch running containers or model-cache volumes). |
| Petals wheel caches | `deploy/petals/build-contexts/wheels-{cpu,cuda,cuda-blackwell}` | **17.4 GB** | Deleted (kept `.gitkeep`). Gitignored, re-syncable on demand: `scripts/sync-petals-wheels-from-smb.ps1 -Variant <cpu|cuda|cuda-blackwell>`. |

Result: **C: free 88 MB → ~315 GB.**

> **Live Docker disk note:** the real WSL engine data is `C:/Users/operator\WSL\Ubuntu\ext4.vhdx`
> (~137 GB; only registered distro). It still holds ~91 GB of in-use images,
> ~52 GB build cache, and ~12 GB unused volumes — the rest of this runbook
> reclaims the build-related part **after** builds move to `hub`.

### Recurring hygiene on a WSL-engine worker

Docker Desktop's auto-GC does **not** run here. Install the staggered weekly
cleanup (`/etc/cron.d/alfa-docker-cleanup`) per
[DOCKER_HOST_CLEANUP.md](DOCKER_HOST_CLEANUP.md)
(`Install-AlfaDockerCleanup.ps1`). To reclaim now without disturbing the running
swarm:

```powershell
wsl -d Ubuntu -- bash /mnt/c/Users/operator/alfa-ai/deploy/cluster-members/_common/docker-host-cleanup.sh
```

The WSL ext4 disk **grows but never auto-shrinks**. After large deletions,
compact it (stops WSL briefly):

```powershell
wsl --shutdown
Optimize-VHD -Path "C:/Users/operator\WSL\Ubuntu\ext4.vhdx" -Mode Full   # Hyper-V present
# or: diskpart → select vdisk file="…\ext4.vhdx" → attach readonly → compact vdisk → detach
```

---

## 1. Per-hardware variant matrix (which image each host loads)

A single image can **not** serve the fleet — CUDA arch differs. `hub` builds
**each variant**; each host loads only the one matching its GPU.

| Host | GPU | Variant | torch / CUDA | Worker tarball on hub |
|------|-----|---------|--------------|------------------------|
| `orchestrator` | 2× RTX 3060 (Ampere) | `cuda` | 2.2.2 / cu121 | `alfa-petals-worker-gpu-12.4.1-cuda-runtime.tar.gz` |
| `secondary` | GTX 1660S | `cuda` | 2.2.2 / cu121 | same as `orchestrator` |
| `gaming-c` / `gaming-a` / `gaming-b` | RTX 50xx (Blackwell sm_120) | `cuda-blackwell` | 2.7.0 / cu128 | `alfa-petals-worker-gpu-12.8.0-cuda-blackwell.tar.gz` |
| gateway-only / CPU box | — | `cpu` | cpu wheels | gateway image (`alfa-ai-petals-gateway-local.tar.gz`) |

The gateway (`orchestrator`, `:8413`) loads `alfa-ai-petals-gateway-local.tar.gz` (built
`FROM alfa-petals-ml-base:cpu`). Variant auto-selection on Windows workers comes
from `nvidia-preflight`'s `ALFA_NODE_GPU_CLASS` (`blackwell`→`cuda-blackwell`,
`ampere-or-newer`→`cuda`, else `cpu`).

---

## 2. Build + publish on `hub` (run on the hub)

Builds happen **only** here (or `apps`), pulling wheels from the LAN hub with
`PIP_OFFLINE=1`. SSH in as `operator` and run from the hub repo checkout.

```bash
ssh operator@hub
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai

# 2a. Ensure wheels are seeded for each variant you build (idempotent):
sudo bash scripts/seed-ml-base-wheels-hub.sh cuda
sudo bash scripts/seed-ml-base-wheels-hub.sh cuda-blackwell
sudo bash scripts/seed-ml-base-wheels-hub.sh cpu

# 2b. Build each per-variant image ON THE HUB and docker-save to
#     /mnt/HDDs/Alfa-AI/docker-images/ (updates images.json):
sudo bash scripts/build-worker-image-on-hub.sh cuda            # ml-base:cuda
sudo bash scripts/build-worker-image-on-hub.sh cuda-runtime    # worker-gpu:12.4.1-cuda-runtime (Ampere)
sudo bash scripts/build-worker-image-on-hub.sh cuda-blackwell  # worker-gpu:12.8.0-cuda-blackwell (RTX 50xx)
```

**Gateway image (`alfa-ai-petals-gateway:local`).** There is no
`build-worker-image-on-hub.sh` variant for the gateway yet, so build it once on
a host that has it (e.g. `apps` or `orchestrator`) and publish:

```bash
# Linux (apps), /mnt/cluster mounted:
bash scripts/publish-built-image-to-hub.sh alfa-ai-petals-gateway:local \
  alfa-ai-petals-gateway-local.tar.gz
```
```powershell
# or Windows (orchestrator), if orchestrator currently holds the freshly built gateway image:
.\scripts\Publish-BuiltImage-ToHub.ps1 -ImageTag 'alfa-ai-petals-gateway:local' `
  -Tarball 'alfa-ai-petals-gateway-local.tar.gz'
```

**Verify the hub has every tarball a worker will need:**

```bash
ls -lh /mnt/HDDs/Alfa-AI/docker-images/*.tar.gz
cat   /mnt/HDDs/Alfa-AI/docker-images/images.json | python3 -m json.tool
```
```powershell
# From a Windows worker:
Get-ChildItem '\\hub\docker-images\*.tar.gz' | Select Name,@{N='GB';E={[math]::Round($_.Length/1GB,2)}}
```

---

## 3. Switch workers to load-not-build (run on each worker)

> Do this **only after** §2 confirms the matching tarball exists on the hub —
> otherwise the no-build deploy has nothing to load.

`orchestrator` today runs `build-start-alfa-ai-93.ps1 → deploy.ps1`, whose worker/gateway
steps call `docker compose build` (forcing the local `ml-base` + wheel path).
The hub-first, **no-build** entry points already exist:

```powershell
cd C:/Users/operator\alfa-ai

# Gateway (NEVER builds; docker loads the tarball, --no-build --pull never):
.\deploy\cluster-members\orchestrator\deploy-petals-gateway.ps1

# GPU worker via the shared LAN/no-build helper (auto-picks variant from nvidia-preflight,
# docker loads the worker tarball from \\hub\docker-images, skips build):
. .\deploy\cluster-members\_common\deploy-worker-lan.ps1
```

For Blackwell workers (`gaming-c`/`gaming-a`/`gaming-b`) use that host's
`build-start-*.ps1` after the `cuda-blackwell` tarball is on the hub; the shared
`deploy-worker-lan.ps1` selects `cuda-blackwell` automatically.

### Reclaim the build artifacts (after a successful no-build deploy)

Once a worker is healthy purely from loaded tarballs, the local build inputs are
dead weight and safe to drop (re-syncable / rebuildable from the hub):

```powershell
# 1) Build-base images only needed to BUILD (worker now loads the final image):
wsl -d Ubuntu -- docker image rm alfa-petals-ml-base:cuda alfa-petals-ml-base:cpu

# 2) Local BuildKit cache (workers no longer build):
wsl -d Ubuntu -- docker builder prune -af

# 3) Wheel caches (already cleared on orchestrator; for other hosts):
#    just delete deploy/petals/build-contexts/wheels-*/*.whl (keep .gitkeep)
```

Expected reclaim on `orchestrator`: ~53 GB (`ml-base` ×2) + ~52 GB (build cache).
**Do not** remove `alfa-petals-worker-gpu:*`, `alfa-ai-petals-gateway:local`,
`louislam/dockge`, or `python:3.12-slim` — those are the running runtime images.

---

## 4. Give alfa-ai priority on `hub`'s SSD (over other repos)

`hub`'s fast pool (`ssd`, or `nvme` if you have a dedicated NVMe data pool) is
shared by alfa-ai and other projects. ZFS has no per-dataset IO scheduler, so
"priority" = **guarantee alfa-ai's space with reservations** and **cap the
competing repos with quotas**, while keeping alfa-ai's hottest paths (Docker
data-root, BuildKit cache, Petals/HF working set, Ollama blobs) physically on
the SSD.

> Replace `ssd` with `nvme` if that is your fast pool's name. Inspect current
> layout first: `zfs list -o name,used,avail,refer,reservation,quota,mountpoint`.

### 4a. Reserve guaranteed space for alfa-ai hot datasets

`refreservation` guarantees the dataset can always grow to that size regardless
of what other repos do — this is the actual "priority":

```bash
# On hub (root). Create datasets if absent (UI: Datasets → Add Dataset, parent ssd).
sudo zfs create -o recordsize=128K ssd/alfa-ai            2>/dev/null || true
sudo zfs create -o recordsize=128K ssd/alfa-ai/docker     2>/dev/null || true  # Docker data-root
sudo zfs create -o recordsize=128K ssd/alfa-ai/buildkit   2>/dev/null || true  # build cache (the heavy builds)
sudo zfs create -o recordsize=1M   ssd/alfa-ai/ollama     2>/dev/null || true  # hot Ollama blobs
sudo zfs create -o recordsize=1M   ssd/alfa-ai/petals     2>/dev/null || true  # Petals/HF hot working set

# Guarantee space for alfa-ai (tune to your SSD capacity):
sudo zfs set refreservation=120G ssd/alfa-ai/docker
sudo zfs set refreservation=60G  ssd/alfa-ai/buildkit
sudo zfs set refreservation=150G ssd/alfa-ai/ollama
sudo zfs set refreservation=80G  ssd/alfa-ai/petals
```

### 4b. Cap the other repos so they cannot crowd alfa-ai out

```bash
# List every dataset on the fast pool, then quota the NON-alfa ones:
zfs list -r ssd -o name,used,avail,quota

# Example — cap a competing project's dataset:
sudo zfs set quota=50G ssd/<other-repo>
# Repeat per non-alfa dataset. Sum of (other quotas) should leave the
# alfa-ai refreservations comfortably satisfiable on the pool.
```

### 4c. Put alfa-ai's heavy build/runtime IO on the SSD

- **Docker data-root → SSD** (so every build/layer/volume is fast): set
  `"data-root": "/mnt/ssd/alfa-ai/docker"` in `hub`'s `/etc/docker/daemon.json`
  and migrate per [hub_111_NVME_POOL.md](../hub_111_NVME_POOL.md) §3
  (stop docker, rsync `/var/lib/docker/` over, restart, verify
  `docker info | grep "Docker Root Dir"`).
- **BuildKit cache → SSD:** point `deploy/cluster/docker-bake.hcl` cache at
  `/mnt/ssd/alfa-ai/buildkit` (hub_111_NVME_POOL.md §6). This is where the
  "large builds" land, so it must be on the fast tier.
- **Ollama / Petals hot reads:** bind `OLLAMA_MODELS` → `/mnt/ssd/alfa-ai/ollama`
  and Petals HF working set → `/mnt/ssd/alfa-ai/petals`. Both remain
  **reproducible** from the HDD canonical tree (`/mnt/HDDs/Alfa-AI/...`).

### 4d. ARC guardrail

The fast pool and `HDDs` share global ZFS ARC. Cap it so builds + Ollama coexist
(hub_111_NVME_POOL.md §7): `vfs.zfs.arc_max` via **System → Advanced →
Sysctl** (e.g. 16 GB).

---

## 5. Verify

```bash
# On hub
ls -lh /mnt/HDDs/Alfa-AI/docker-images/*.tar.gz        # per-variant tarballs present
docker info | grep "Docker Root Dir"                    # → /mnt/ssd/alfa-ai/docker
zfs list -o name,used,avail,reservation,quota | grep -E 'ssd/alfa-ai|ssd/'
```
```powershell
# On orchestrator after the no-build deploy
wsl -d Ubuntu -- docker ps                              # gateway + workers healthy
wsl -d Ubuntu -- docker images                          # no ml-base; worker+gateway present
wsl -d Ubuntu -- docker system df                       # build cache ~0
curl http://orchestrator/health                    # gateway reachable_peers > 0
```

---

## 6. Steady-state policy

- **Workers never build.** If a worker rebuilds an alfa image from source or
  pulls wheels from pypi.org / pytorch.org, that's a hub gap — build+publish on
  `hub` instead (see [HUB_ARTIFACTS.md](../HUB_ARTIFACTS.md) audit section).
- **`hub` SSD is alfa-ai-first** via refreservations; other repos live within
  quotas and/or on the HDD pool.
- **C: stays lean:** runtime images + the WSL ext4 disk only; no Desktop VHDs,
  no wheel caches, no build cache.
