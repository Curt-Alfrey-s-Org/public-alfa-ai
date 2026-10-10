# Hot storage on `hub` (hub Scale 25.04) — NVMe **or** SSD mirror

**April 2026 production note:** Many `hub` installs use the motherboard NVMe
**only** for hub `boot-pool`. In that case the **Ollama hot dataset** is a
**ZFS mirror on SATA SSDs** (pool `ssd`, path **`/mnt/ssd/ollama`**) — see
[CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md). Treat **`/mnt/nvme`**
below as an **optional** layout when you have a **separate** NVMe data pool.

The sections below describe a dedicated **600 GB Samsung 990 NVMe** data pool
(`nvme`) for Docker root + Ollama + app state. **For Ollama-only hot storage,**
prefer **`/mnt/ssd/ollama`** and skip creating `nvme/ollama` if you do not
have a separate NVMe data pool.

**Why NVMe as a separate pool (not inside `HDDs`)?**

- Samsung 990 delivers ~7 GB/s sequential / ~1M IOPS random — the HDD pool is
  two orders of magnitude slower. Ollama cold-load of a 19 GB 32B model goes
  from ~60 s (HDD) to ~5 s (NVMe).
- Keeping **Docker data root** (layer graph, volumes, overlays) on NVMe makes
  every `docker compose up -d` and image pull feel native.
- Isolating it from `HDDs` means ZFS ARC tuning on `HDDs` does not impact the
  NVMe cache and vice versa.

## 1. hub Scale — create the pool

**UI path:** **Storage → Create pool**

1. **Name:** `nvme`
2. **Encryption:** off (this is hot cache, full rebuild is cheap).
3. **Layout:** single NVMe drive → **Stripe** (no redundancy — intentional for
   hot cache; if the drive dies you rebuild from HDD-backed artifacts).
4. **ashift:** 12 (4K sectors — default for modern NVMe).
5. **Compression:** `lz4` (CPU-cheap, useful for Docker layers and log text).
6. **Atime:** off.
7. **Deduplication:** off.

After the pool is built, mountpoint is `/mnt/nvme`.

## 2. Datasets under `nvme`

Create these as **separate datasets** in the hub UI
(**Datasets → Add Dataset** with parent `nvme`). Separate datasets let you
snapshot, quota, and tune recordsize per workload.

| Dataset | Purpose | Recordsize | Quota | Notes |
|---------|---------|------------|-------|-------|
| `nvme/docker` | Docker data root (`/var/lib/docker`) | `128K` | 200 GB | `sync=disabled` OK — layers are reproducible from HDD tarballs |
| `nvme/ollama` | `OLLAMA_MODELS` blob store | `1M` | 150 GB | Large sequential reads at inference load time |
| `nvme/app-state` | LiteLLM SQLite, logs, small DBs | `16K` | 20 GB | Small random writes |
| `nvme/buildkit` | BuildKit cache | `128K` | 60 GB | Eject anytime with `rm -rf` |
| `nvme/Alfa-AI/docker-images` (or dir under `nvme/docker-images`) | Hot copy of **`alfa-llamacpp-rpc-cuda128-b8552.tar.gz`** | `1M` | ~10 GB | Promote from HDD; `load-llamacpp-rpc-from-hub.sh` prefers this before NFS HDD |
| `nvme/repo` (optional) | Git clone of alfa-ai if hot clone desired | `128K` | 5 GB | Alternative: keep repo on HDD at `/mnt/HDDs/Alfa-AI/repo/alfa-ai` |

**Total assigned quotas:** 200 + 150 + 20 + 60 + 5 = **435 GB** of 600 GB.
Leaves ~165 GB headroom for ARC and temporary download spill.

## 3. Move Docker data root to NVMe

**This must happen before bringing up any persistent Docker stack on `hub`.**
Moving data-root later requires re-tagging/re-importing every image.

### 3.1. Stop Docker

```bash
# On hub (root shell)
systemctl stop docker
systemctl stop docker.socket
```

### 3.2. Edit `/etc/docker/daemon.json`

```json
{
  "data-root": "/mnt/nvme/docker",
  "registry-mirrors": ["http://hub/"],
  "default-runtime": "nvidia",
  "runtimes": {
    "nvidia": {
      "path": "/usr/bin/nvidia-container-runtime",
      "runtimeArgs": []
    }
  },
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "20m",
    "max-file": "3"
  }
}
```

`registry-mirrors` pointing at the host itself is a no-op internally (hub
runs the mirror on the same dockerd) but keeps the config consistent with
every other node in the cluster.

### 3.3. Migrate existing layers (if any)

```bash
# If /var/lib/docker has existing content, rsync it over once:
rsync -aHAX --info=progress2 /var/lib/docker/ /mnt/nvme/docker/
# Rename the old path so Docker won't accidentally use it.
mv /var/lib/docker /var/lib/docker.OLD.$(date +%F)
```

### 3.4. Start Docker

```bash
systemctl start docker
docker info | grep "Docker Root Dir"
# Expect: Docker Root Dir: /mnt/nvme/docker
```

Verify images + containers survived: `docker images`, `docker ps -a`.

## 4. Ollama on NVMe (retired — kept for reference only)

**Ollama App removed from `hub` entirely on 2026-07-05** — `hub` runs no
Ollama-backed model (`operator_internal` now routes to the RPC pool per
`deploy/litellm_config.yaml`). The install steps below are kept only in case a
future Lane-A workload needs Ollama on `hub` again; do not run them as part
of routine deploy.

hub 25.04 has Ollama in the App catalog **and** can run it via
`deploy/docker-compose.ollama-gpu.yml`. Either way, point `OLLAMA_MODELS` at
`/mnt/nvme/ollama`.

### Option A: hub Apps (recommended)

In **Apps → Discover → Ollama → Install** (or edit installed app):

- **Host Path Volumes → Add:**
  - Host: `/mnt/ssd/ollama` (or `/mnt/nvme/ollama` if using NVMe data pool) → Mount: `/root/.ollama`
- **GPU passthrough:** enable RTX 3060 12 GB (post-swap; hub Apps GPU section).
- **Port:** `11434` on host.

### Option B: compose from the repo

Edit `deploy/docker-compose.ollama-gpu.yml` (or override) so the bind-mount
uses your hot path, e.g. **`/mnt/ssd/ollama:/root/.ollama`** (default in repo)
or `/mnt/nvme/ollama` if you created that dataset. Then:

```bash
docker compose --env-file deploy/.env -f deploy/docker-compose.ollama-gpu.yml up -d
```

### Seed models on `hub` (hub) — `hub` runs no Ollama at all

**July 2026 update:** `hub` is the artifact **hub** and runs **no Ollama App**
(removed 2026-07-05; `operator_internal` routes to the RPC pool per
`deploy/litellm_config.yaml`, no sub-frontier chat). Tiers 0/1/2 are a
**two-host CPU pool** — dense **`qwen3.5:27b`** on **`gaming-c`** (quality) +
**`qwen3.6:35b-a3b`** MoE on **`orchestrator`** (speed); the May `gaming-c`-only `qwen3:32b`
and April `qwen3-coder:30b-a3b-q4_K_M` MoE fleet are **superseded**.
Embeddings: `qwen3-embedding:4b` on `gaming-c` (primary), `gaming-b` (cold-standby).
**Requires Ollama `0.30.x`** (Gated-DeltaNet) on the hosts that do run it
(`gaming-c`/`orchestrator`) — verify each tag loads first. On `hub`, seed the hub blobs
only (no local Ollama App needed to do that) — see
[HUB_ARTIFACTS.md](HUB_ARTIFACTS.md) / [HTTP_DOWNLOADS.md](HTTP_DOWNLOADS.md):

```bash
# Seed the hub so gaming-c/orchestrator can sync qwen3.5:27b / qwen3.6:35b-a3b + qwen3-embedding:4b (hub-first):
sudo bash scripts/hub_hub_models.sh pull quality --stores cold,hot
sudo bash scripts/hub_hub_models.sh pull embed  --stores cold
```

Then on `gaming-c`: `bash deploy/cluster-members/_common/pull-models.sh quality`.
**Status:** `gaming-c` rollout pending — until it is up, chat aliases fall back to
`frontier` (Petals 70B).

## 5. LiteLLM state on NVMe

LiteLLM keeps a small SQLite for spend tracking + virtual keys. Mount the
`nvme/app-state` dataset into the LiteLLM container. In
`deploy/docker-compose.yml` (LiteLLM service), the volume becomes:

```yaml
services:
  alfa-ai-litellm:
    volumes:
      - /mnt/nvme/alfa-ai/app-state/litellm:/var/lib/litellm
```

Create the host dir once:

```bash
mkdir -p /mnt/nvme/alfa-ai/app-state/litellm
chown 1000:1000 /mnt/nvme/alfa-ai/app-state/litellm   # LiteLLM image UID
```

## 6. BuildKit cache on NVMe

If the brain builds Docker images on `hub` (rare — normally built on `apps`
and imported), point BuildKit at the NVMe dataset:

```bash
# Persistent builder with NVMe-backed cache
docker buildx create --name alfa-nvme-builder \
  --driver-opt image=moby/buildkit:latest \
  --driver-opt env.BUILDKIT_STEP_LOG_MAX_SIZE=10000000 \
  --bootstrap
```

Then set cache dir in `deploy/cluster/docker-bake.hcl` → `/mnt/nvme/buildkit`.

## 7. ZFS ARC guardrail

`nvme` and `HDDs` are separate pools, but ARC is global. Cap ARC so Ollama's
13–18 GB of RAM (32B CPU spill) can coexist with the brain stack on **~46 GiB**
system RAM on `hub` (Apr 2026 `free`; plan for **48 GB** if DIMMs are 48 GB).

### Via hub UI

**System → Advanced → Sysctl → Add**

- `Variable:` `vfs.zfs.arc_max`
- `Value:` `17179869184` (16 GB in bytes)

### Via CLI (volatile — use UI for persistence on Scale)

```bash
echo $((16 * 1024 * 1024 * 1024)) > /sys/module/zfs/parameters/zfs_arc_max
arc_summary | head -30
```

Monitor under load: `free -g` and `cat /proc/spl/kstat/zfs/arcstats | grep -E '^size|^c_max'`.

## 8. Smoke tests

```bash
# Pool mounted
zpool list | grep -E '^NAME|^nvme'
df -h /mnt/nvme

# Datasets with quotas
zfs list | grep nvme

# Docker root on NVMe
docker info | grep "Docker Root Dir"

# Ollama models on NVMe
du -sh /mnt/nvme/ollama

# Sequential read benchmark (should be > 3 GB/s)
dd if=/mnt/nvme/docker/.test bs=1M count=4096 of=/dev/null 2>&1 | tail -1 || \
  (fio --name=seqread --ioengine=libaio --iodepth=8 --rw=read --bs=1M \
       --size=4G --filename=/mnt/nvme/.fio-test --runtime=30 --time_based 2>&1 | tail -10 ; \
   rm /mnt/nvme/.fio-test)

# Chat cold-load smoke runs on gaming-c (qwen3.5:27b) / orchestrator (qwen3.6:35b-a3b), NOT hub (hub serves only the operator model).
# Requires Ollama 0.30.x (Gated-DeltaNet). While a host rollout is pending, smoke via LiteLLM (falls back to frontier):
#   curl -s http://orchestrator/api/generate \
#     -d '{"model":"qwen3.5:27b","prompt":"hi","stream":false,"options":{"num_predict":4}}'
```

## 9. Backup + replacement

The NVMe pool is **hot cache** — by design, no redundancy. Every file it
holds is reproducible:

- **Docker layers** → rebuild from `/mnt/HDDs/Alfa-AI/docker/images/*.tar.gz`
  or repull from registry mirror (also on `hub`, but on HDD).
- **Ollama models** → re-`ollama pull`.
- **LiteLLM SQLite** → snapshot to `/mnt/HDDs/Alfa-AI/backups/litellm/` nightly
  (ZFS `zfs snapshot nvme/app-state@daily-$(date +%Y%m%d)` then
  `zfs send … | zstd > /mnt/HDDs/…/backup.zst`).

When the NVMe dies or is upgraded:

1. Stop Docker (`systemctl stop docker`).
2. Rebuild the pool in the hub UI on the new drive.
3. Recreate the datasets from § 2.
4. `systemctl start docker` — the data-root is empty, but `docker compose up -d`
   re-pulls from the LAN mirror within minutes.
5. `ollama pull` the model list.
6. Restore the LiteLLM SQLite from HDD backup.

## 10. Rollback

If NVMe usage reveals a problem and you need to revert Docker to HDD:

```bash
systemctl stop docker
# Move current NVMe root back to a HDD-backed location:
rsync -aHAX /mnt/nvme/docker/ /mnt/HDDs/Alfa-AI/docker-root/
# Update /etc/docker/daemon.json → "data-root": "/mnt/HDDs/Alfa-AI/docker-root"
systemctl start docker
```

Accept that cold-starts will be 5–10x slower.

<!-- iofix-2026-06-19-hub -->
## 11. Idle-I/O hygiene (system dataset, DB placement, bridge)

Beyond the hot-pool layout above, `hub` had three idle-write sources fixed
2026-06-19 (full standards: [HOST_STORAGE_AND_NETWORK_STANDARDS.md](HOST_STORAGE_AND_NETWORK_STANDARDS.md)):

- **System dataset on SSD** — `.system` was on `HDDs`; moved to `ssd`
  (System Settings -> Advanced -> System Dataset Pool). Keeps the array idle at rest.
- **App DB on SSD** — `alfa-ai` Postgres/Redis moved off HDD named volumes to
  `/mnt/ssd/alfa-ai/{postgres,redis}` via `ALFA_AI_PG_DATA_PATH` /
  `ALFA_AI_REDIS_DATA_PATH` in `deploy/.env` (compose default stays a named volume).
- **`enp11s0f0np0` direct (no `br0`)** — bridge removed Jun 2026; LAN IPs on
  np0 only. Historical: `br0` was reduced to the 10 GbE `enp11s0f0np0` on
  2026-06-19, killing an L2 loop that spammed the kernel log every ~30 s.

Verify: `zfs list -o name | grep '/\.system'`, `docker inspect alfa-ai-postgres`,
`journalctl -k -b | grep -c "own address as source"` (expect `ssd/.system`,
`/mnt/ssd/...`, and `0`).

## Related

- [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md)
- [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) — HDD tree on `/mnt/HDDs/Alfa-AI`
- [history/BRAIN_MIGRATION_105_TO_111.md](history/BRAIN_MIGRATION_105_TO_111.md)
- [NODE_INVENTORY.md](NODE_INVENTORY.md)
