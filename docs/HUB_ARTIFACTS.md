# Hub artifacts policy (hub = download store for all cluster deps, ≥ 100 MB)

**Canonical store:** hub `hub`, **HDD dataset** `/mnt/HDDs/Alfa-AI/`. This
is the cluster’s **authoritative download and archive**: every dependency the
swarm needs — wheels, model weights, Docker layers/tarballs, Ollama blobs,
installers, staging for `git`/source tarballs you choose to vendor, and the
registry mirror’s backing store — is **seeded here first** (public internet
**only** during that seed on `hub` or a hub-designated builder), then **every
other host reads over the LAN** (NFS `/mnt/cluster`, SMB `\\hub\…`,
registry mirror `http://hub`).

**Fast tier (optional):** An **SSD or NVMe ZFS pool** on `hub` (e.g.
`/mnt/ssd/…` or `/mnt/nvme/…`) holds **reproducible hot copies** — Ollama
blobs, Docker data-root, BuildKit cache, **`alfa-llamacpp-rpc` tarball** — for
latency. It is **not** a second source of truth: promote from or sync with the
HDD tree; see [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) and
[hub_111_NVME_POOL.md](hub_111_NVME_POOL.md).

## Active vs retired models (2026-07-16)

| Status | Artifact | Notes |
|--------|----------|-------|
| **Active** | **Qwen3.8-27B** GGUF (`Qwen3.8-27B-Q8_0.gguf`, ~29 GB) | Production `frontier-code` / default inference; next bump: [inference_MODEL_UPGRADE.md](inference_MODEL_UPGRADE.md) |
| **Rollback (3.6 Q8)** | **Qwen3.6-27B** GGUF (`Qwen3.6-27B-Q8_0.gguf`, ~28.6 GB) | Env rollback only; keep on hub |
| **Exclusive chat** | **Qwen2.5-72B-Instruct** Q4_K_M (12 shards; lead `qwen2.5-72b-instruct-q4_k_m-00001-of-00012.gguf`) | `frontier` via `-InferenceMode Pool72` — [GREV72_72B_OPERATOR.md](GREV72_72B_OPERATOR.md) |
| **Deferred coding** | Qwen3-Coder-Next **80B** GGUF (4 shards) | Later; `pull gguf` |
| **Rollback** | `Qwen3.6-27B-UD-Q4_K_XL.gguf` (~17.6 GB) | Keep on hub for multi-slot Q4 rollback |
| **Active (train)** | **Qwen2.5-Coder-7B-Instruct** HF cache | Canonical HDD; **hot SSD** `promote-hf-7b-to-ssd.sh` (`models--Qwen--Qwen2.5-Coder-7B-Instruct`); trainers read `/mnt/cluster-ssd`, not spinning `/mnt/cluster`. |
| **Archived (later)** | **Qwen2.5-Coder-14B-Instruct** HF cache | **HDD keep:** `models--Qwen--Qwen2.5-Coder-14B-Instruct`. Do not Start 14B. Drop SSD copies with `archive-hf-14b-keep-hdd.sh`. Do not `promote-hf-14b-to-ssd.sh` unless un-archiving ([TRAIN_7B_QLORA_GUI.md](operations/TRAIN_7B_QLORA_GUI.md)) |
| **Active** | **`alfa-llamacpp-rpc:cuda128`** tarball (~2.2 GB) | RPC shards + coordinator (Turing+ hosts) |
| **Active** | **`alfa-llamacpp-rpc:cuda128-pascal`** tarball (~2.2 GB) | gpu-248 `secondary` GTX 1070 shard only (sm_61) |
| **Retired** | Qwen3-Coder-**30B** GGUF | Do not seed or mount; safe to delete from hub |
| **Retired** | Qwen3.6-**35B**-A3B MoE (`switch-pool-35b.sh` only if operator revives) | Not production; LiteLLM aliases remap to 27B |
| **Retired** | **Llama-3.3-70B** (Petals HF) | Petals retired; purge with Petals hub script |
| **Retired** | **Qwen3:8b** / small operator Ollama chat | Not a inference/chat tier; do not re-seed for inference |

Historical Petals / MoE narrative may remain under `docs/history/` — **do not** treat those as live runbooks.

## Local-first start (permanent fast path)

**Policy:** every host that runs inference / RAG keeps large artifacts on **local
disk**. Hub HDD/NFS/SMB is the **seed**, not the warm-start read path. A warm
`Start-Stop-AlfaAi.ps1 start` should not re-copy multi-GB blobs over the LAN.

### RPC Docker image (`alfa-llamacpp-rpc:cuda128` and `:cuda128-pascal`)

| Tag | SMs | Hosts |
|-----|-----|-------|
| `cuda128` | 75;80;86;120 | `orchestrator`, `pool-opt-in`, `inference`, `hub`, gaming workers |
| `cuda128-pascal` | 61;75;80;86;120 | **`secondary` GTX 1070 only** |

Build pascal on `hub`: `sudo bash scripts/build-llamacpp-rpc-cuda128-pascal-on-hub.sh`.
`hub` runs with **boost off, no MHz cap** (Post Init); builds use
`BUILD_JOBS=6` by default. See [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md).
Workers load: `load-llamacpp-rpc-pascal-from-hub.sh` (sets `ALFA_RPC_TARBALL` for
`ensure-rpc-image-local-cache.sh`).

### RPC Docker image warm path (`alfa-llamacpp-rpc:cuda128`)

| Step | What runs | Behavior |
|------|-----------|----------|
| Warm start (Linux) | `load-llamacpp-rpc-from-hub.sh` | Skip if image present (no NFS) |
| Warm start (Windows) | `deploy-llamacpp-rpc.ps1` | Skip if image present (no SMB / vendor sync) |
| Cold load | `ensure-rpc-image-local-cache.sh` / Windows promote | Copy hub → local **once**, then `docker load` from local |
| `hub` start-pool | `promote-rpc-image-to-nvme.sh` | Ensures hot tarball on `/mnt/ssd` (or nvme) |

| Host | Local cache path | Wired into |
|------|------------------|------------|
| **`secondary`** | **`~/alfa-ai-cache/docker-images/`** on local **SSD** (`/` ext4) | `load-llamacpp-rpc-pascal-from-hub.sh` promotes from NFS hub **once**, then `docker load` from SSD |
| **`pool-opt-in`** | `~/alfa-ai-cache/docker-images/` | `ensure-rpc-image-local-cache.sh` |
| **`inference`** | `~/alfa-ai-cache/docker-images/` | same (shard + RAG rerank image) |
| **`hub`** | `/mnt/ssd/Alfa-AI/docker-images/` (else nvme) | `promote-rpc-image-to-nvme.sh` on `start-pool` |
| **`orchestrator` / `gaming-a` / …** | `Get-AlfaWindowsCacheRoot` (`D:\alfa-ai-cache\docker-images\` on `gaming-a`; skip `C:` when another NTFS drive is under 80% used) | `deploy-llamacpp-rpc.ps1` |

### 27B GGUF (coordinator on `hub` only)

| Step | What runs | Behavior |
|------|-----------|----------|
| `start-pool` | `promote-gguf-to-ssd.sh` | HDD → SSD/NVMe once; then POSIX other-read |
| env | `write-grev27-pool-env.sh` | `MODELS_DIR` prefers SSD/NVMe over `HDDs`; fail-fast if GGUF is not other-readable |

Shards do **not** mount the 27B GGUF (RPC backends only).

### 7B QLoRA HuggingFace cache (train island)

Production train is **Qwen2.5-Coder-7B-Instruct**
([HF card](https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct)). 14B HF promote remains
on hub for the **parked** 14B yaml; operators do not Start 14B.

| Step | What runs | Behavior |
|------|-----------|----------|
| `hub` once (if HDD cache missing) | `sudo bash scripts/hub_hub_models.sh pull hf Qwen/Qwen2.5-Coder-7B-Instruct` | Seed canonical HDD HF cache on **`hub` only** ([huggingface_hub snapshot](https://huggingface.co/docs/huggingface_hub/en/guides/download#snapshot-download)). Needs `HF_TOKEN` in hub `deploy/.env`. Do **not** download on trainers. |
| `hub` once | `promote-hf-7b-to-ssd.sh` | HDD `models/huggingface/hub/models--Qwen--Qwen2.5-Coder-7B-Instruct` -> `/mnt/ssd/Alfa-AI/models/huggingface/hub/` ([rsync](https://man7.org/linux/man-pages/man1/rsync.1.html)); `chmod a+rX` on the tree, then **`chmod a+rwx` on `hub/` and `hub/.locks`** so trainers can create HF lock files ([cache locks](https://huggingface.co/docs/huggingface_hub/en/guides/manage-cache)) |
| `hub` archive 14B | `archive-hf-14b-keep-hdd.sh` | Verify HDD 14B HF cache, then `CONFIRM=1` removes SSD/NVMe copies only. Do not Start 14B. |
| `hub` un-archive 14B only | `promote-hf-14b-to-ssd.sh` | HDD -> SSD hot copy. Do **not** run while 14B is archived. |
| hub once | Unix NFS share path `/mnt/ssd/Alfa-AI` | Do **not** export pool root `/mnt/ssd` ([Adding NFS shares](https://www.hub.com/docs/scale/shares/nfs/addingnfsshares/)). LAN `orchestrator/24`, Maproot `operator` (same as HDD Alfa-AI share). |
| Train Start | `Start-AlfaTrain7bQlora.ps1` (7B QLoRA) | Remounts `/mnt/cluster-ssd` from `hub:/mnt/ssd/Alfa-AI`; Docker `HF_HOME` is that tree. Corpus/logs stay on HDD `/mnt/cluster`. |

Do **not** point 7B `from_pretrained` at spinning `/mnt/cluster/models/huggingface`. Weight load is shard/tensor I/O ([Transformers big models](https://huggingface.co/docs/transformers/main/en/big_models)); HDD NFS was the 5070 "slow load" stall.

### sudo promote / seed must leave POSIX other-read

**Root cause (2026-08-14):** `sudo cp` / `sudo docker save` on hub follows
root **umask** (often `027` → files `0640` `root:root`). Docker bind-mounts
keep those host mode bits
([bind mounts](https://docs.docker.com/engine/storage/bind-mounts/)).
`llama-server` then cannot open the GGUF and exits in about a minute without
binding `:31360`. Same class as SMB `Access denied` on hub tarballs.

**Policy:** every script that writes a hub or SSD/NVMe artifact consumed by
Docker, NFS, or SMB must finish with GNU **`chmod a+r`** (files) /
**`chmod a+rX`** (directories)
([chmod(1)](https://man7.org/linux/man-pages/man1/chmod.1.html)).
`X` adds execute/search only on directories. Do **not** skip chmod on
"already present" -- that is how 0640 survived the first Pool80 promote.

| Writer | Helper |
|--------|--------|
| `promote-gguf-to-ssd.sh` | `ensure-posix-other-read.sh` after each copy **and** skip |
| `promote-hf-7b-to-ssd.sh` | `chmod -R a+rX` on dest hub dir, then `ensure-posix-other-read.sh`, then `chmod a+rwx` on `hub/` + `hub/.locks` (HF lock files) |
| `archive-hf-14b-keep-hdd.sh` | Verify HDD 14B cache; `CONFIRM=1` removes SSD/NVMe copies only |
| `promote-hf-14b-to-ssd.sh` | Un-archive only; same POSIX steps as 7B promote |
| `promote-rpc-image-to-nvme.sh` | same |
| `write-grev27/72/80-pool-env.sh` | `ensure-gguf-posix-other-read.sh` (self-heal + fail-fast) |
| `build-llamacpp-rpc-cuda128-on-hub.sh` | `chmod a+r` + `setfacl` after `docker save` |

Do not treat HTTP or NFS copy as a substitute for POSIX/ACL on the hub file.

### LoRA adapter GGUF (coordinator overlay)

| Artifact | Hub path | Notes |
|----------|----------|-------|
| LoRA GGUF | `/mnt/HDDs/Alfa-AI/llama-cpp/lora/<base>/<adapter>.gguf` | Convert on `hub` only; see [LORA_ADAPTER_OPERATOR.md](operations/LORA_ADAPTER_OPERATOR.md) |
| Registry manifest | `/mnt/HDDs/Alfa-AI/llama-cpp/lora/lora-adapters.json` | Mirror in brain `{ALFA_AI_DATA}/lora/` via `publish-lora-adapter-to-hub.sh` |

Coordinator reads `LORA_GGUF` from gitignored `.env.rpc`; requires **full cluster stop + start**
(not piecemeal coordinator restart). NFS clients: `/mnt/cluster/llama-cpp/lora/`.

### RAG models (CPU on `inference`)

| Step | What runs | Behavior |
|------|-----------|----------|
| Warm / cold | `ensure-rag-models-local-cache.sh` | Prefer `~/alfa-ai-cache/rag/`; promote from NFS **once** |
| Deploy | `deploy-rag-cpu.sh` | Sets `RERANK_MODELS_DIR` + `OLLAMA_EMBED_MODELS_DIR` to local; skips `ollama pull` if tag present |

Overrides: `ALFA_RAG_CACHE`, `ALFA_RPC_IMAGE_CACHE`. Force image reload:
`FORCE_HUB_RPC_LOAD=1`. Force vendor re-copy: `FORCE_VENDOR_SYNC=1`.

**Operator first promote on `hub` (SSD is the live hot pool when `/mnt/nvme` is absent):**

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && git pull --ff-only origin main
sudo bash scripts/hub_hub_models.sh pull hf Qwen/Qwen2.5-Coder-7B-Instruct
sudo bash deploy/cluster-members/hub/promote-rpc-image-to-nvme.sh
sudo bash deploy/cluster-members/hub/promote-gguf-to-ssd.sh
sudo bash deploy/cluster-members/hub/promote-hf-7b-to-ssd.sh
```

Seed `pull hf` only when `models--Qwen--Qwen2.5-Coder-7B-Instruct` is missing on HDD. Promote fails until that tree exists. Do not `huggingface-cli download` on `gaming-c` / `gaming-b`.

**Operator first promote on `inference` (RAG local cache):**

```bash
cd ~/alfa-ai && git pull --ff-only origin main
eval "$(bash deploy/cluster-members/_common/ensure-rag-models-local-cache.sh)"
```

`hub` promotes also run automatically at the start of `operator-cluster-111.sh start-pool`.
`write-grev27-pool-env.sh` sets `MODELS_DIR` to the SSD/NVMe hot GGUF path when present.

### What belongs on spinning HDD vs SSD (`hub`)

**Target:** SSD = high-cadence ALFa I/O; HDD = hub seed + Immich/Jellyfin
media (leave those apps as-is). Procedure:
[hub_111_ARCHIVE_VS_SSD.md](hub_111_ARCHIVE_VS_SSD.md).

| On HDD / The_Biz (archive / seed) | On SSD (runtime) |
|-----------------------------------|------------------|
| Canonical hub tree (`HDDs/Alfa-AI`) | Postgres + Redis (`ssd/alfa-ai/...`) |
| Registry tarballs, Verdaccio, wheels, retired models | RPC tarball (`/mnt/ssd/Alfa-AI/docker-images/`) |
| Master GGUF copy (keep) | **Hot GGUF** (`/mnt/ssd/Alfa-AI/llama-cpp/models/`) |
| Master HF 7B cache (`models/huggingface/hub/models--Qwen--Qwen2.5-Coder-7B-Instruct`); **archived 14B** HF cache stays on HDD | **Hot 7B HF** (`/mnt/ssd/Alfa-AI/models/huggingface/`) -- train `HF_HOME`; NFS `/mnt/cluster-ssd`. 14B must **not** occupy SSD while archived (`archive-hf-14b-keep-hdd.sh`) |
| NFS/SMB export for workers (cold) | hub **Apps pool** -- deferred (Immich ixVolumes would copy onto SSD) |
| Immich library / Jellyfin media (stay) | Coordinator slot-cache (Phase B; heartbeat went to tmpfs/RAM) |
| **`HDDs/ix-apps`** Docker overlay (stays) | Do **not** migrate while media ixVolumes are in that tree |

**No `/mnt/nvme` data pool on this host today** — use `/mnt/ssd` as the fast tier.

### Docker on `hub` (hub Apps — do not hand-edit `daemon.json`)

Live check (2026-07-16):

| Fact | Value |
|------|--------|
| `Docker Root Dir` | `/mnt/.ix-apps/docker` |
| ZFS dataset | **`HDDs/ix-apps/docker`** (~230G) — **spinners** |
| Full Apps tree | **`HDDs/ix-apps`** (~633G used) |
| Largest ixVolume | Immich under `app_mounts/immich` (~401G library+video+…) |
| Pool `ssd` size | **444G** total (~423G free) |

`daemon.json` points at `/mnt/.ix-apps/docker` by hub design
([App Storage](https://apps.hub.com/getting-started/app-storage/)). Do **not**
hand-edit `data-root`.

**Migrate Apps pool to `ssd` is blocked by capacity today:** official
**Apps → Configuration → Choose Pool → Migrate** moves the **whole** hidden
`ix-apps` dataset (~633G), including Immich ixVolumes. Pool `ssd` is only 444G.
You cannot put "Docker only" on SSD while leaving Immich on HDD via that UI —
they share one Apps dataset ([App Storage](https://apps.hub.com/getting-started/app-storage/)).

**Operator priority (updated 2026-09-03):** Immich/Jellyfin **stay on HDD**.
Do not Choose Pool migrate (would copy those ixVolumes onto `ssd` and does
not fit). Cut high-cadence ALFa writers (named-volume DBs, 30 s backup
`touch`, slot-cache) per
[hub_111_ARCHIVE_VS_SSD.md](hub_111_ARCHIVE_VS_SSD.md) Phase B.
July 2026 "leave Apps on HDDs" remains the Apps-pool reality until capacity
and media policy change.

**What matters for ALFA programs (already on SSD host binds):**

- Postgres / Redis under `/mnt/ssd/alfa-ai/`
- Hot GGUF + RPC image tarball under `/mnt/ssd/Alfa-AI/`
- Compose/host mounts outside `.ix-apps` (migrate would not move these anyway)

Docker image/overlay I/O for all Apps stays on `HDDs/ix-apps/docker` while
Immich/Jellyfin remain ixVolumes in that tree. That overlay is the remaining
steady writer after Phase B timers move off HDD.

**Other cluster hosts** (`orchestrator`, `pool-opt-in`, `inference`, gaming) have **no spinning
hub pool** — local Docker is already on SSD/NVMe. Their only spinner risk is
reading uncached hub files over NFS/SMB from `hub` HDDs (mitigated by local
RPC image cache).

**≥ 100 MB rule:** Any blob above that size **must** live on the hub before
workers use it. (Tightened from the previous ≥ 200 MB threshold; see
`.cursor/rules/hub-hub-first.mdc`.) Smaller deps should still prefer the
hub (wheels, mirror, SMB `cluster_members` staging) so builds stay auditable
and offline-friendly.

Workers re-pulling artifacts from pypi.org, huggingface.co, docker.io,
ollama.com, or GitHub **releases** for large binaries indicates a hub gap —
file it and fix.

---

## Download policy — DO NOT use bare curl for files

Large artifacts must be seeded on **`hub`** using the tool that matches the
format. **Do not** stream multi-GB downloads with manual `curl` from another
host (especially `curl …/api/pull` to Ollama on `hub` — connection drops
are common and waste hours).

| Artifact type | Correct method (on `hub` unless noted) | Wrong |
|---------------|-------------------------------------------|-------|
| **Ollama tags** (legacy quality/embed only if still used) | `sudo bash scripts/hub_hub_models.sh pull … --stores cold` | `curl …/api/pull` from workers |
| **Single HTTPS files** (GGUF, installers) | `aria2c` / aria2 JSON-RPC `:6800` via `scripts/lib/http_fetch.sh` (**no curl fallback**) | bare `curl -L -o` or any curl-as-download for GB-scale files |
| **HF model trees** | `sudo bash scripts/hub_hub_models.sh pull hf REPO_ID` (**not** Llama-3.3-70B — retired) | ad-hoc curl per shard |
| **Fleet sync** (`gaming-c`, `gaming-b`, …) | `pull-models.sh quality` / `pull-models.ps1 -Role Quality` (hub merge first) | `ollama pull` from public internet when hub has the tag |

Full aria2-only download rules (no curl fallback): [HTTP_DOWNLOADS.md](HTTP_DOWNLOADS.md).
Operator runbook for `hub` Ollama hub pulls:
[DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md) §4.

---

## Artifact inventory

| Artifact | Approx. size | On-hub path | Notes |
|---|---|---|---|
| PyPI wheels (bots / apps) | ~2–6 GB | `/mnt/HDDs/Alfa-AI/wheels/bots/` | SMB `\\hub\petals-wheels\bots\` (share name legacy) |
| PyPI wheels (victron-ble2mqtt) | ~15 MB | `/mnt/HDDs/Alfa-AI/wheels/victron/` | SMB `\\hub\petals-wheels\victron\` |
| PyTorch **2.14 cu130** wheels (from-scratch trainer) | several GB | `/mnt/HDDs/Alfa-AI/wheels/torch-cu130/` | SMB `\\hub\petals-wheels\torch-cu130\`. cp314 `win_amd64` and `manylinux_2_28_x86_64` from [cu130](https://download.pytorch.org/whl/cu130). Seed on `hub` only. Check: `train/from-scratch/check_wheel.py`. |
| From-scratch **checkpoints** | grows (about 1 GB weights, AdamW state on top) | `/mnt/HDDs/Alfa-AI/training/alfa-train/checkpoints/from-scratch/` | Same `training` SMB share as the corpus shards. HDD, not the SSD HF cache. Trainer: `train/from-scratch/train.py`. |
| Prebuilt **`alfa-llamacpp-rpc:cuda128`** tarball | **~2.2 GB** (image ~7.3 GB) | HDD: `/mnt/HDDs/Alfa-AI/docker-images/`; hot: `/mnt/nvme/Alfa-AI/docker-images/` | Canonical seed on HDD (`alfa-llamacpp-rpc-cuda128-b10355.tar.gz`); promote to NVMe on `hub`; local copy on `pool-opt-in` |
| llama.cpp GGUF **Qwen3.8-27B Q8_0** (`frontier-code` / default) | ~29 GB | `/mnt/HDDs/Alfa-AI/llama-cpp/models/` | `inference_GGUF_PROFILE=q8 hub_hub_models.sh pull gguf27` |
| llama.cpp GGUF **Qwen3.6-27B Q8_0** (rollback) | ~28.6 GB | same | Keep on hub; `inference_MODEL_FILE` env rollback |
| llama.cpp GGUF **Qwen2.5-72B-Instruct Q4_K_M** (exclusive `frontier`) | ~41–48 GB (12 shards) | same | `hub_hub_models.sh pull gguf72` ([official GGUF](https://huggingface.co/Qwen/Qwen2.5-72B-Instruct-GGUF); lead `...-00001-of-00012.gguf`) |
| npm Verdaccio storage | grows | `/mnt/HDDs/Alfa-AI/npm/storage/` | `:4873` |
| Dockge / Watchtower / HA tarballs | varies | `/mnt/HDDs/Alfa-AI/docker-images/` (`louislam-dockge-1.tar.gz` for `louislam/dockge:1`) | member `docker load` |
| **`theengs/gateway:v1.7.5.1`** | ~267 MB gzip (~1.1 GB image) | `/mnt/HDDs/Alfa-AI/docker-images/theengs-gateway-v1.7.5.1.tar.gz` | Pi4/Pi5 Theengs BLE; seed from a host that already has the image (`docker save`). Do not `docker pull` on the Pis. |
| **`searxng/searxng:2026.10.2-19ffbcd30`** (compose pin; tarball name unchanged) | image ~258 MB; gzip tarball smaller | `/mnt/HDDs/Alfa-AI/docker-images/searxng-searxng-latest.tar.gz` | LAN admin `web_search` on `hub`. Existing tarball matches this digest; after `docker load`, `docker tag searxng/searxng:latest docker.io/searxng/searxng:2026.10.2-19ffbcd30` ([official tag](https://docs.docker.com/reference/cli/docker/image/tag/)). Seed tarball with `docker save` of the pinned tag ([official save](https://docs.docker.com/reference/cli/docker/image/save/)). Do not `docker pull` on workers. |

**Retired on hub (safe to delete when reclaiming space):**

| Path / artifact | Why |
|-----------------|-----|
| Petals wheels/tarballs/DHT (`wheels/cpu`, `cuda*`, `alfa-petals-*`, `petals/`) | Petals retired 2026-07-09 — purge script below |
| HF **Llama-3.3-70B** | Petals tier-3a retired |
| `llama-cpp/models/Qwen3-Coder-30B*` | 30B coder retired |
| `llama-cpp/models/*35B*` / Ollama `qwen3.6:35b-a3b` | 35B MoE retired (2026-07-10) |
| Ollama **`qwen3:8b`** operator blobs | 8B chat path retired |
| Stale Win cache `alfa-petals-worker-*.tar.gz` on workers | Not used by inference |

Full legacy table (pre-2026-07-09 Petals rows) archived in git history; active path is llama.cpp RPC only ([`.cursor/rules/llama-cpp-rpc-only.mdc`](../.cursor/rules/llama-cpp-rpc-only.mdc)).

**Fleet sync (hub-first, audit HUB-001):** run `deploy/cluster-members/_common/pull-models.sh` (Linux) or `pull-models.ps1` (Windows). They merge hub `manifests/` + `blobs/` into local `~/.ollama\models` when the hub layout is visible (`ALFA_OLLAMA_HUB_MODELS`, NFS `/mnt/cluster/ollama/models`, or SMB `\\hub\ollama` / mapped `W:`) and call `ollama pull` only for tags absent on the hub.

---

## Delivery mechanism per platform

### Linux (`apps` apps, `hub` brain)

- Mount `/mnt/cluster/*` from hub NFS on boot (`scripts/mount_nfs_models.sh`).
- **Bot/app wheels:** `scripts/sync-bot-wheels-from-hub.sh` (or automatic preflight in bot Docker builds).
- **Victron BLE / Pi edge:** `scripts/sync-victron-wheels-from-hub.sh` after `scripts/seed-victron-wheels-hub.sh`.
- **llama.cpp RPC:** prebuilt image tarballs under `docker-images/`; GGUF under `llama-cpp/models/`.

### Windows Docker Desktop (`orchestrator`, `gaming-b`, `gaming-c`, `gaming-a`)

- Map SMB shares (legacy share name `petals-wheels` = PyPI wheel hub root; only **`bots/`** and **`victron/`** subtrees are used now):
  ```powershell
  net use Y: \\hub\petals-wheels /PERSISTENT:YES
  net use Z: \\hub\huggingface   /PERSISTENT:YES
  ```
- **RPC shards:** `docker load` from `\\hub\docker-images\` (`alfa-llamacpp-rpc*` tarballs).
  Share ACL FULL is not enough -- filesystem ACL + POSIX other-read on the tarballs
  ([CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) Windows SMB). Do not HTTP-serve from `orchestrator`.
- Runtime HF cache (if needed): `\\hub\huggingface\` → `Z:\`.

---

## Seeding the hub

Run on hub (`hub`), not on a worker. **Write targets** are under
**`/mnt/HDDs/Alfa-AI/`** (HDD canonical store). After seeding, you may **promote**
hot subsets to the SSD/NVMe pool for faster local reads on `hub` only — see
[CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md).

```bash
# Python wheels (CUDA cu121 + CUDA Blackwell cu128 + CPU) for Dockerfile.ml-base
# and Dockerfile.petals-worker.gpu-blackwell.
ssh operator@hub
sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/seed-ml-base-wheels-hub.sh
# Or one variant at a time:
#   sudo bash scripts/seed-ml-base-wheels-hub.sh cuda-blackwell

# Victron BLE → MQTT (Raspberry Pi edge): pip wheels for victron-ble2mqtt-integration.
# Writes linux/arm64 + linux/amd64 wheels under .../wheels/victron/
sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/seed-victron-wheels-hub.sh

# Bot / app pip wheels (rankings, market-pie5, contracts, credit-check, atems, auth-service, rv-auto-finder).
# Requires sibling repos under the same parent as alfa-ai (WORKSPACE_ROOT). Writes wheels/bots/.
sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/seed-bot-wheels-hub.sh

# Verdaccio npm LAN proxy (first npm ci warms cache).
sudo mkdir -p /mnt/HDDs/Alfa-AI/npm/storage && sudo chown -R 10001:65533 /mnt/HDDs/Alfa-AI/npm/storage
chmod a+r /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/npm-proxy/config.yaml
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/npm-proxy && docker compose -f docker-compose.verdaccio.yml up -d

# Docker CLI tarball + pinned base images (optional offline docker load).
sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/seed-docker-cli-hub.sh
sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/seed-base-images-hub.sh
# Home Assistant container (GHCR — not proxied by the Docker Hub registry mirror on :5000).
# Pin matches victron docker-compose.homeassistant.yml. Seed linux/amd64 for apps
# (an arm64 Pi tarball will not run on the apps VM).
docker pull --platform linux/amd64 ghcr.io/home-assistant/home-assistant:2026.7.3
sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/publish-built-image-to-hub.sh \
  ghcr.io/home-assistant/home-assistant:2026.7.3 \
  home-assistant-2026.7.3.tar.gz

# HuggingFace model weights — canonical hub seed.
# Status after seeding (total size + which models are present):
sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/hub_hub_models.sh status

# llama.cpp git source tarball for deploy/llamacpp-rpc/vendor (LAN-first builds)
sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/pack-llamacpp-vendor-tarball-on-hub.sh

# Prebuilt llama.cpp RPC image (replaces retired Petals worker tarballs):
sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/build-llamacpp-rpc-cuda128-on-hub.sh
sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/publish-built-image-to-hub.sh alfa-llamacpp-rpc:cuda128
```

Workers `docker load` from `\\hub\docker-images\` — zero public registry pulls.

## Purge Petals hub artifacts (`hub`)

After Petals retirement, remove stale blobs that the RPC-only path no longer uses.
**Keeps:** `wheels/bots`, `wheels/victron`, llama.cpp GGUF, Ollama blobs, `alfa-llamacpp-rpc*` tarballs, Dockge/HA images.

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai && git pull --ff-only origin main
sudo bash scripts/purge-petals-hub-artifacts-on-111.sh              # dry-run
sudo bash scripts/purge-petals-hub-artifacts-on-111.sh --apply      # delete
```

Deletes (when present):

| Path | What |
|------|------|
| `docker-images/alfa-petals-*`, `alfa-ai-petals-gateway*`, `petals-worker*` | Petals image tarballs |
| `wheels/cpu`, `wheels/cuda`, `wheels/cuda-blackwell` | Petals ml-base PyPI wheels (~8 GB) |
| `petals/` | DHT identity / bootstrap cache |
| `models/huggingface/.../Llama-3.3-70B*` | Petals tier-3a weights (~140 GB) |
| Local `docker rmi` | Petals-tagged images on `hub` engine |

Optional log + SCP to `inference`: `SCP_TO_BUILD_HOST=1 sudo bash deploy/cluster-members/hub/run-purge-petals-hub-artifacts.sh --apply`

**Per-host runtime** (containers/images/local `.env.gateway` — any clone):

```bash
bash scripts/purge-petals-runtime-on-host.sh          # dry-run
bash scripts/purge-petals-runtime-on-host.sh --apply
```

Windows WSL: `wsl -d Ubuntu bash -lc 'cd /mnt/c/Users/<user>/alfa-ai && bash scripts/purge-petals-runtime-on-host.sh --apply'`.

Gaming hosts **`gaming-c` / `gaming-a` / `gaming-b`**: deferred until next online — member README § Deferred.

## Verifying the hub

```bash
# Linux — models + sizes (the Petals ml-base wheel check verify-wheels-hub.sh was
# removed 2026-09-25: those wheels are purged above and its helper scripts no longer exist)
sudo bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/scripts/hub_hub_models.sh status
ls /mnt/HDDs/Alfa-AI/wheels/bots /mnt/HDDs/Alfa-AI/wheels/victron | head
```

```powershell
# Windows — quick reachability (the SMB share keeps its historical name "petals-wheels")
Test-Path '\\hub\petals-wheels\victron\'
Test-Path '\\hub\petals-wheels\bots\'
Test-Path '\\hub\huggingface\hub\'
```

---

## hub SMB share setup (one-time, operator action)

In the hub web UI (or `midclt`), add SMB shares:

| Share name | Path | Purpose | ACL |
|---|---|---|---|
| `petals-wheels` | `/mnt/HDDs/Alfa-AI/wheels` | PyPI wheel hub for Windows ml-base builds | read-only to SMB users `operator`, `ansible`, plus **per-host users** (e.g. `Corey`, `gaming-worker-c`, `gaming-worker-b`) on switch-B workers |
| `huggingface` | `/mnt/HDDs/Alfa-AI/models/huggingface` | HF model weights cache (shared by all swarm workers) | read-write to `operator`, `ansible` (worker needs to write the first time it caches; subsequent workers read) |
| `docker-images` | `/mnt/HDDs/Alfa-AI/docker-images` | Prebuilt worker image tarballs (`alfa-petals-ml-base:cuda`, `alfa-petals-worker-gpu:12.8.0-cuda-blackwell`) so Windows workers can `docker load` instead of `docker build` | read-only to `operator`, `ansible` |
| `ollama` (optional) | `/mnt/HDDs/Alfa-AI/ollama` | Ollama model blobs | read-only |

Using `midclt` on hub:

```bash
sudo midclt call sharing.smb.create '{"name": "petals-wheels", "path": "/mnt/HDDs/Alfa-AI/wheels", "purpose": "DEFAULT_SHARE", "ro": true, "browsable": true, "comment": "PyPI wheel hub for ml-base builds"}'
sudo midclt call sharing.smb.create '{"name": "huggingface", "path": "/mnt/HDDs/Alfa-AI/models/huggingface", "purpose": "DEFAULT_SHARE", "browsable": true, "comment": "HF model weights cache shared across workers"}'
sudo midclt call sharing.smb.create '{"name": "docker-images", "path": "/mnt/HDDs/Alfa-AI/docker-images", "purpose": "DEFAULT_SHARE", "ro": true, "browsable": true, "comment": "Prebuilt worker image tarballs for docker load"}'
sudo midclt call service.restart '"cifs"'
```

After adding shares, on each Windows worker:

```powershell
# Admin PowerShell
net use Y: \\hub\petals-wheels /PERSISTENT:YES
net use Z: \\hub\huggingface   /PERSISTENT:YES
Test-Path Y:\cuda
Test-Path Z:\hub
```

---

## Audit: finding artifacts currently bypassing the hub

If a worker's build or runtime step is pulling from the public internet and the
artifact is >100 MB, the hub is incomplete. To audit what's coming in from
outside the LAN:

```bash
# On any Linux worker — capture DNS lookups to external ML/CDN hosts during a build
sudo timeout 1200 tcpdump -l -n 'udp port 53' 2>/dev/null \
  | grep -iE 'pypi|huggingface|docker\.io|ollama|pytorch' | awk '{print $NF}' | sort -u
```

Any hostname that appears repeatedly during `docker build` or `petals-worker`
startup is a candidate for the hub. File as a "hub gap" and seed.
