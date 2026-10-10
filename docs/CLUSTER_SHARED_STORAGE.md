# Cluster shared storage: hub as download store + optional SSD/NVMe fast pool

hub (`hub`) is the cluster’s **single download store** for dependencies:
HuggingFace weights, GGUF shards, Ollama blobs, Docker layers (registry mirror +
saved tarballs), PyPI wheels, NVIDIA installers, vendored source tarballs you
place under `models/downloads`, and per-host SMB staging. **Public-internet
fetching happens only when seeding onto `hub`** (or a hub-designated builder);
every other node **reads over the LAN** — see [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md).

> **Two-tier model on `hub`**
>
> - **HDD pool `/mnt/HDDs/Alfa-AI/`** = **canonical** tree (this doc). All new
>   downloads land here first; NFS `/mnt/cluster` and SMB `\\hub\…` expose
>   this tree to members. Registry mirror data lives under `docker/registry/`.
> - **SSD or NVMe pool** (`/mnt/ssd/…`, `/mnt/nvme/…`) = **fast tier** — use for
>   reproducible hot paths: Ollama runtime blobs, Petals/HF working sets, Docker
>   `data-root`, BuildKit cache, LiteLLM/app SQLite, optional **promoted**
>   copies of GGUF or image layers. Anything on SSD/NVMe must be **rebuildable**
>   from the HDD hub (rsync, re-pull, or re-seed). See
>   [hub_111_NVME_POOL.md](hub_111_NVME_POOL.md).
>
> Brain / Dockge on `hub`: [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md).
>
> **Cluster (2026-09-04 update):** `hub` is hub + brain; **Petals retired**
> (historical announce **`.157`** -- do not use). **No Ollama** (App removed
> 2026-07-05; `operator_internal` routes to the RPC pool per
> `deploy/litellm_config.yaml`) -- tiers 0/1/2 are a **two-host CPU pool**:
> dense **`qwen3.5:27b`** on **`gaming-c`** (quality) + **`qwen3.6:35b-a3b`** MoE on
> **`orchestrator`** (speed). Embeddings (`qwen3-embedding:4b`) on `gaming-c` (primary) with
> `gaming-b` cold-standby. **NFS:** bind VIP **`storage/32` on `br1`** (same L2 as
> `hub`). See [hub_111_10G_NIC.md](hub_111_10G_NIC.md).
>
> **Tier-3 runtimes (2026-06-22 primary working set):** the frontier pool uses
> **llama.cpp RPC** (coordinator `orchestrator:31360`) serving **Qwen3.5-122B-A10B** (chat)
> / **Qwen3.6-27B** (code) / agentic alt **Qwen3-Coder-Next-80B-A3B** - all GGUF
> under `llama-cpp/models/` on this hub, read over LAN by every worker (hub-first).
> Petals 70B (HF format under `models/huggingface/`) is the opportunistic boost
> when gaming hosts are online. SSoT:
> [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md).

This document is the **canonical plan** for the **HDD-backed** layout (the
download store). All paths below are **rooted at `/mnt/HDDs/Alfa-AI/` on hub**
— one dataset, one root, category folders underneath. **Do not** treat the SSD
pool alone as the long-term archive: capacity planning and DR assume **HDD**
under `Alfa-AI`.

---

## 1. Canonical tree under `/mnt/HDDs/Alfa-AI/`

```
/mnt/HDDs/Alfa-AI/
├── docker/                         # Everything Docker
│   ├── registry/                   # registry:2.8 pull-through mirror store
│   ├── images/                     # Pre-saved `docker save` tarballs
│   │   ├── alfa-petals-ml-base-cuda.tar.gz
│   │   ├── alfa-petals-ml-base-cpu.tar.gz
│   │   ├── alfa-petals-worker-gpu-cuda.tar.gz
│   │   ├── nvidia-cuda-12.4.1-runtime.tar.gz
│   │   └── …
│   ├── base-images/                # Pinned base image tarballs (`seed-base-images-hub.sh`)
│   ├── buildkit/                   # `docker buildx bake` persistent cache
│   └── compose-data/               # Volumes we want shared (Dockge stacks, etc.)
│
├── models/                         # Every weight file the cluster consumes
│   ├── huggingface/                # HF_HOME for Petals gateway + workers
│   │   └── hub/                    # HF layout: models--<org>--<model>/
│   │       ├── models--meta-llama--Llama-3.3-70B-Instruct/   # tier 3a frontier (primary)
│   │       ├── models--meta-llama--Llama-3.1-70B-Instruct/   # tier 3a fallback
│   │       ├── models--meta-llama--Llama-3.1-8B-Instruct/    # Petals small-model fallback
│   │       └── models--codellama--CodeLlama-7b-Instruct-hf/  # legacy — rollback smoke tests
│   ├── ollama/                     # OLLAMA_MODELS — Ollama's blob store
│   │                                # (qwen3.5:27b on gaming-c + qwen3.6:35b-a3b on orchestrator — tiers 0/1/2 chat;
│   │                                #  qwen3-embedding:4b — embeddings. qwen3:32b / 30B-A3B MoE superseded)
│   └── downloads/                  # aria2 / wget staging before promotion
│
├── llama-cpp/                      # llama.cpp RPC (tier 3b frontier-code)
│   └── models/
│       └── Qwen3-Coder-Next-Q4_K_M/   # 4× GGUF shards (~48 GB total Q4_K_M; tier 3b)
│
├── nvidia/                         # NVIDIA offline installers
│   ├── drivers/                    # Linux .run + Windows .exe per OS/arch
│   ├── cuda-toolkit/               # Offline CUDA toolkit installers
│   ├── cudnn/                      # Optional cuDNN archives
│   └── container-toolkit/          # nvidia-container-toolkit debs/RPMs
│
├── wheels/                         # PyPI offline cache — `pip install --find-links`
│   ├── cpu/                        # torch 2.2.2+cpu + cpu-safe deps
│   ├── cuda/                       # torch 2.2.2+cu121 + petals/hivemind
│   ├── cuda-blackwell/             # torch 2.7 cu128 + Petals stack (RTX 50xx)
│   ├── bots/                       # four bots + atems + auth-service + rv-auto-finder wheels
│   └── victron/                    # victron-ble2mqtt-integration (arm64 + amd64 wheels)
│
├── npm/                            # Verdaccio npm proxy storage (`deploy/npm-proxy/`)
│   └── storage/
├── petals/                         # Private-swarm DHT state (see DISTRIBUTED_AI.md)
│   ├── identity/                   # libp2p keypairs per bootstrap host (0700, owned by operator via NFS maproot)
│   │   └── identity.key            # apps bootstrap — pins peer-id across recreate
│   └── bootstrap/                  # DR cache for joining workers when brain is down
│       └── bootstrap.multiaddr     # /ip4/.../tcp/31330/p2p/<peer-id>
│
├── installers/                     # Non-NVIDIA installers (Ollama, Docker Desktop, aria2 Win)
│   └── docker-cli/                 # Static `docker-*.tgz` for rankings-bot (hub-first builds)
├── backups/                        # Database backups (DR — HDD tier on purpose)
│   └── postgres/                   # Brain pg_dump sidecar output: daily/ weekly/
│                                   #   globals/ metrics/ state/ — see
│                                   #   docs/operations/POSTGRES_BACKUP_RESTORE_111.md
└── smb-scratch/                    # SMB-exposed deployment scratch (\\hub\temp)
    ├── cluster_members/            # Per-member staged deploy bundles
    └── petals-workers/             # Staged petals-worker bundles
```

### Tier summary

| Category | Path (hub) | Protocol to clients | Consumers |
|----------|----------------|---------------------|-----------|
| Docker registry mirror | `docker/registry` | HTTP `http://hub/` | Every `dockerd` on the LAN |
| Prebuilt Docker tarballs | `docker/images` | SMB `\\hub\temp\alfa-ai-cluster\docker-images` | Worker `deploy.ps1` fast-path |
| BuildKit cache | `docker/buildkit` | NFS `/mnt/cluster/docker/buildkit` | `docker buildx bake` |
| HuggingFace cache | `models/huggingface` | NFS `/mnt/cluster/models/huggingface` | Petals gateway + all Petals workers |
| llama.cpp GGUF cache | `llama-cpp/models` | NFS `/mnt/cluster/llama-cpp/models` | llama.cpp RPC main on `gaming-b` |
| Ollama blobs | `models/ollama` | NFS `/mnt/cluster/models/ollama` | Ollama on every node |
| Download staging | `models/downloads` | aria2 JSON-RPC `http://hub/jsonrpc` | Operator + brain's Models UI |
| NVIDIA installers | `nvidia/` | SMB (one-shot install) | Bare-metal nvidia-smi / nvidia-container-toolkit setup |
| PyPI wheel cache | `wheels/` (`cpu`, `cuda`, `cuda-blackwell`, `bots`, `victron`) | NFS `/mnt/cluster/wheels` | Offline `pip install --find-links`; bot sync: automatic via `scripts/sync-bot-wheels-preflight.sh` (non-fatal; manual: `scripts/sync-bot-wheels-from-hub.sh`) |
| Petals DHT state | `petals/` | NFS `/mnt/cluster/petals` | libp2p identity (`apps` bootstrap) + DR bootstrap multiaddr cache |
| App installers | `installers/` | SMB | Dockge / Ollama / Docker Desktop setup |
| Postgres backups | `backups/postgres` | local on `hub` (written by `alfa-ai-postgres-backup` sidecar targeting the dedicated postgres stack) | DR restores + `metrics/` freshness file for monitoring (see [operations/POSTGRES_BACKUP_RESTORE_111.md](operations/POSTGRES_BACKUP_RESTORE_111.md)) |
| npm Verdaccio cache | `npm/storage` | HTTP `http://hub` | Frontends `NPM_REGISTRY` (see `deploy/npm-proxy/`) |
| Pinned Docker base tags | `docker/base-images/*.tar.gz` | NFS `/mnt/cluster/docker/base-images` | Optional `docker load` before offline builds |
| Deploy scratch | `smb-scratch/` | SMB `\\hub\temp` | `stage-cluster-members.ps1`, per-member deploy |

### Why this shape

- **One dataset.** Snapshotting, replication, and dataset-level quotas all operate on a single subtree.
- **Category folders** let operators reason about one concern at a time ("I'm out of space on models" vs "registry GC is overdue").
- **`models/downloads`** is an explicit staging zone so aria2 (or manual `wget`s) never lands in a path a running service is also watching.
- **`docker/images`** is the emergency-recovery path — if the registry mirror is wiped, every node can still bring up via SMB image tarballs.

---

## 2. Pre-staging procedures — run once on hub

All commands below run on `hub` as `root` (hub admin). They assume the
dataset `/mnt/HDDs/Alfa-AI` already exists as a ZFS dataset (create it in
the hub UI under **Datasets → Add Dataset → name: `Alfa-AI`**, then SSH
in to populate). NFS/SMB exports are configured separately (see §3).

### 2.1. Create the tree

```bash
# On hub (hub)
ROOT=/mnt/HDDs/Alfa-AI
mkdir -p \
  $ROOT/docker/{registry,images,buildkit,compose-data} \
  $ROOT/models/{huggingface/hub,ollama,downloads} \
  $ROOT/llama-cpp/models \
  $ROOT/nvidia/{drivers,cuda-toolkit,cudnn,container-toolkit} \
  $ROOT/wheels/{cpu,cuda,cuda-blackwell,victron,bots} \
  $ROOT/npm/storage \
  $ROOT/docker/base-images \
  $ROOT/installers/docker-cli \
  $ROOT/installers \
  $ROOT/smb-scratch/{cluster_members,petals-workers}

# Group-writable so the Docker registry mirror + NFS clients + operator
# can all land files here without sudo acrobatics.
chown -R root:alfa-ai $ROOT
chmod -R g+rwXs $ROOT
```

### 2.2. Pre-download HuggingFace models

HuggingFace has gated licenses on Meta's Llama 3.1 repos. Mint a read token
at <https://huggingface.co/settings/tokens> and accept the license on each
model's page **before** running the download. We run the download inside a
throwaway `python:3.12-slim` container so hub's host Python stays clean.

```bash
# On hub
export HF_TOKEN=hf_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx

docker run --rm \
  -v /mnt/HDDs/Alfa-AI/models/huggingface:/hf \
  -e HF_HOME=/hf \
  -e HUGGINGFACE_HUB_CACHE=/hf/hub \
  -e HF_TOKEN="$HF_TOKEN" \
  python:3.12-slim bash -c '
    set -e
    pip install --quiet "huggingface_hub>=0.25" hf_xet
    # huggingface_hub >= 1.0 deprecated `huggingface-cli` in favor of `hf`.

    # ── Tier 3a frontier chat (Petals target) ─────────────────────────────
    # Gated — accept Meta license on
    # https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct first.
    # ~140 GB bf16; NF4 ≈ 42 GB at worker load time (fits 46 GB swarm).
    hf download meta-llama/Llama-3.3-70B-Instruct

    # ── Fallback frontier chat ─────────────────────────────────────────────
    # Keep Llama 3.1 70B as the fallback if 3.3 license accept is pending.
    # hf download meta-llama/Llama-3.1-70B-Instruct

    # ── Legacy ─────────────────────────────────────────────────────────────
    # Keep around for rollback smoke tests.
    hf download meta-llama/Llama-3.1-8B-Instruct
  '
```

Notes:
- The download resumes on re-run (HF client checks ETags).
- Expect Llama-3.3-70B ≈ 140 GB bf16, Llama-3.1-70B ≈ 140 GB,
  Llama-3.1-8B ≈ 16 GB.
- If you want to background this, wrap the whole thing in
  `tmux new-session -d -s hf-download '…'` and tail with `docker logs`.
- **Progress tip:** `hf download` buffers output without a TTY. Watch progress
  with `du -sh /mnt/HDDs/Alfa-AI/models/huggingface/hub/models--meta-llama--Llama-3.3-70B-Instruct/`
  (disk usage growing) and `docker stats` (network I/O).

### 2.2b Pre-download llama.cpp GGUF weights (tier 3b)

For the `frontier-code` tier, the llama.cpp RPC stack loads a single GGUF
off shared storage (NFS path on `gaming-b` coordinator). Use the helper in
`deploy/llamacpp-rpc/scripts/`:

```bash
# On hub (hub) or any machine with huggingface-cli + LAN SMB/NFS access.
sudo bash /home/operator/alfa-ai/deploy/llamacpp-rpc/scripts/fetch-qwen3-coder.sh \
  /mnt/HDDs/Alfa-AI/llama-cpp/models
# → Qwen3-Coder-Next-Q4_K_M/*.gguf  (4 shards; ~48 GB Q4_K_M total)
```

The `llama-server` on `gaming-b` mounts
`/mnt/HDDs/Alfa-AI/llama-cpp/models` → `/models` via NFS and loads the GGUF
by file name. See
[LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md) for the full flow.

### 2.3. Pre-download Ollama models

Ollama stores models in its own format at `OLLAMA_MODELS`. On `hub`, the
authoritative **hot** location is typically **`/mnt/ssd/ollama`** (ZFS dataset
`ssd/ollama`; bind-mounted into `alfa-ai-ollama` — see
`deploy/docker-compose.ollama-gpu.yml`). We keep a
cold copy on HDD for disaster recovery and NFS availability.

**DO NOT** seed Ollama tags by curling `/api/pull` from another host (e.g.
`apps` → `hub:11434`). Use **`hub_hub_models.sh` on `hub`** so
`ollama pull` runs locally with native resume into the hub path.

```bash
# On hub — hub cold mirror (canonical, June 2026 CPU plan).
# Requires Ollama 0.30.x (Gated-DeltaNet) on the serving hosts — verify each tag loads first.
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
sudo bash scripts/hub_hub_models.sh pull quality --stores cold   # qwen3.5:27b (~19 GB)
sudo bash scripts/hub_hub_models.sh pull embed --stores cold     # qwen3-embedding:4b (~2.5 GB)

# On gaming-c gaming-worker-c — after hub has tags; sync from SMB/NFS then local pull if needed:
bash deploy/cluster-members/_common/pull-models.sh quality

# On gaming-b gaming-worker-b — embed cold-standby only:
bash deploy/cluster-members/_common/pull-models.sh reranker
```

Equivalent one-shot Docker pull (same as what `hub_hub_models.sh` runs
internally when host `ollama` is not on PATH):

```bash
# On hub only — do not run from inference over the network.
sudo docker run --rm \
  -v /mnt/HDDs/Alfa-AI/models/ollama:/root/.ollama \
  --entrypoint /bin/sh \
  ollama/ollama:0.35.1 -c '
    ollama serve >/dev/null 2>&1 &
    for i in $(seq 1 120); do ollama list >/dev/null 2>&1 && break; sleep 1; done
    ollama pull qwen3.5:27b
  '
```

The canonical `pull-models.sh` / `pull-models.ps1` scripts live in
`deploy/cluster-members/_common/`. They encode the role → model mapping
(quality / embed / reranker) so the list stays in one place. See
[deploy/litellm_config.yaml](../deploy/litellm_config.yaml) for the LiteLLM
tier routing. Download policy: [HTTP_DOWNLOADS.md](HTTP_DOWNLOADS.md).

### 2.4. Pre-download PyPI wheels (torch + Petals-from-git stack)

`alfa-petals-ml-base` installs **Petals from GitHub** (`PETALS_GIT_REF`, default
**pinned SHA `22afba6`** in `deploy/petals/Dockerfile.ml-base`) with **transformers
4.43.1**. **`Dockerfile.petals-worker.gpu-blackwell`** uses **Petals from `main`**
(default build-arg) plus **torch 2.7 cu128** so hivemind matches torch≥2.3. A **hivemind**
revision is archived on the hub (`HIVE_REV` in the seed script). Caching **torch** and
every **PyPI** dependency on hub keeps builder `docker build` traffic on the LAN.
Post-install pins match **Llama-3.3** tokenizer requirements (`tokenizers>=0.20`, see Dockerfiles).

**Python tag:** both CPU and CUDA base images use **3.12**; the seed script uses
`--python-version 312` and manylinux platform tags so files match **`cp312`**.

**Authoritative hub seed (run on `hub` as root):**

Seeds are verbose; capture a reviewable transcript with **`tee`** via the wrapper
(it writes under `deploy/cluster-members/hub/logs/`, which is gitignored):

```bash
cd /path/to/alfa-ai   # e.g. /mnt/HDDs/Alfa-AI/repo/alfa-ai on hub
bash deploy/cluster-members/hub/run-seed-wheels-with-log.sh cuda-blackwell
# omit argument to default to cuda-blackwell; or pass cuda | cpu | all
```

To copy the finished transcript to `apps` for inspection (SSH from `hub`; lands under
`logs/hub-seed/`, gitignored):

```bash
SCP_TO_BUILD_HOST=1 bash deploy/cluster-members/hub/run-seed-wheels-with-log.sh cuda-blackwell
```

**Blackwell-specific failures** (missing NVIDIA bundle, cu126 torch masquerading, purge
bugs): [petals/BLACKWELL_CUDA_BLACKWELL_WHEELS_GOTCHAS.md](petals/BLACKWELL_CUDA_BLACKWELL_WHEELS_GOTCHAS.md).

Direct invocation (no log file):

```bash
cd /path/to/alfa-ai   # or copy the script onto hub
sudo bash scripts/seed-ml-base-wheels-hub.sh
```

Defaults: `HUB_ROOT=/mnt/HDDs/Alfa-AI/wheels`, `HIVE_REV` matching Petals
`setup.cfg` (GitHub archive of hivemind for a small on-hub copy). Override
`HUB_ROOT` if your dataset path differs.

The script runs `python:3.12-slim-bookworm` twice (CUDA + CPU wheel dirs) and
downloads:

- **Phase A:** `torch==2.2.2` + `torchvision` + `torchaudio` with
  `--only-binary=:all:` from `download.pytorch.org` (cu121 or cpu index).
- **Phase B:** Petals **install_requires** from PyPI (same pins as
  [bigscience-workshop/petals](https://github.com/bigscience-workshop/petals)
  `setup.cfg` **except** hivemind): `transformers==4.43.1`, `bitsandbytes==0.41.1`,
  `peft==0.8.2`, `tensor_parallel==1.0.23`, `grpcio` / `grpcio-tools`, etc., plus
  the gateway stack (`fastapi`, `uvicorn`, `pydantic`, `hf_xet`, …).

**Still from the public internet during `docker build` unless you vendor:**

- `git+https://github.com/bigscience-workshop/petals.git@…` (Petals source).
- Hivemind is fetched as a **git checkout** while installing Petals (the hub
  `.tar.gz` is optional archival; the Dockerfile does not install from it yet).

`Dockerfile.ml-base` passes **`--no-build-isolation`** for the Petals install so
hivemind’s `setup.py` sees **`pkg_resources`** (pip’s isolated build env does
not, which breaks the wheel build).

Consumers: [deploy/petals/Dockerfile.ml-base](../deploy/petals/Dockerfile.ml-base)
copies `deploy/petals/build-contexts/wheels-{cpu,cuda}/` into `/tmp/wheels` and
uses explicit **`--find-links=/tmp/wheels`** on pip invocations so **local wheels
are preferred**; pip still hits indexes for anything missing (e.g. git deps).

On a builder with NFS, sync from the hub into the repo paths (safe: `*.whl`
is gitignored):

```bash
# From repo root (alfa-ai)
bash scripts/sync-petals-wheels-from-hub.sh
```

Override hub paths if needed: `CLUSTER_WHEELS_CPU`, `CLUSTER_WHEELS_CUDA`
(default `/mnt/cluster/wheels/{cpu,cuda}`). On hub itself, point those at
`/mnt/HDDs/Alfa-AI/wheels/...`.

> **Pin drift:** when Petals `main` changes `setup.cfg` (new `hivemind` commit,
> `transformers` pin, etc.), update **`HIVE_REV`** in
> `scripts/seed-ml-base-wheels-hub.sh` if you use the archive, re-run the
> seed script on `hub`, then `sync-petals-wheels-from-hub.sh` on builders. The
> seed script’s package list should track `setup.cfg`; the Dockerfile remains
> authoritative for torch / install ordering.

### 2.5. Pre-save Docker images to SMB tarballs

The SMB fast-path is what makes a fresh worker come up in 2 min instead of
25. Save once from `apps` (which holds the build history) onto hub, then
every other Win worker's `deploy.ps1` will load from SMB before falling back
to `docker build`.

> `apps` is the **build host** for cluster images regardless of the brain
> move to `hub`. It has the most historical build cache and the CPU is good
> enough for Docker builds.

```bash
# On apps (build host), save images directly onto hub SMB export.
# If hub isn't CIFS-mounted on apps, use NFS instead: save into
# /mnt/cluster/docker/images/.

DEST=/mnt/cluster/docker/images    # or /mnt/hub-smb/docker/images
mkdir -p "$DEST"

for img in \
  alfa-petals-ml-base:cuda \
  alfa-petals-ml-base:cpu \
  alfa-petals-worker-gpu:12.4.1-cuda-runtime \
  nvidia/cuda:12.4.1-runtime-ubuntu22.04 \
  ollama/ollama:0.35.1 \
  registry:2.8 \
  python:3.12-slim \
  ghcr.io/berriai/litellm:v1.103.2 ; do
    safe=$(echo "$img" | tr '/:' '__')
    echo "saving $img → $safe.tar.gz"
    docker save "$img" | gzip -1 > "$DEST/$safe.tar.gz"
done
```

The worker `deploy.ps1` discovery path is
`\\hub\temp\cluster_members\_common\docker-images\*.tar.gz`; expose
`docker/images/` there via an SMB alias, or copy the tarballs once per
release into the SMB scratch.

### 2.6. Stage NVIDIA installers

NVIDIA drivers and the CUDA toolkit are downloaded manually from nvidia.com
(license click-through) and dropped into hub so cluster hosts install
from LAN. Suggested URLs to feed aria2:

```bash
# On hub — aria2 JSON-RPC is already exposed at :6800 by deploy/aria2/.
# Browse to https://www.nvidia.com/Download/index.aspx , copy the direct
# download link, then:

ARIA=http://127.0.0.1:6800/jsonrpc
SECRET="${ARIA2_RPC_KEY:?export ARIA2_RPC_KEY first}"   # no default; see deploy/aria2/README.md

curl -sS -X POST "$ARIA" -H 'Content-Type: application/json' -d "{
  \"jsonrpc\":\"2.0\",\"id\":\"drv\",\"method\":\"aria2.addUri\",
  \"params\":[\"token:$SECRET\",
    [\"https://us.download.nvidia.com/tesla/…/NVIDIA-Linux-x86_64-550.90.07.run\"],
    {\"dir\":\"/downloads/../nvidia/drivers\"}
  ]
}"
```

(Replace the URL with the exact driver build that matches your GPU /
kernel. Windows drivers go into `nvidia/drivers/windows/` using the same
pattern.)

For `nvidia-container-toolkit` Linux debs:

```bash
# On any Ubuntu node
distribution=$(. /etc/os-release; echo $ID$VERSION_ID)
curl -fsSL https://nvidia.github.io/libnvidia-container/$distribution/libnvidia-container.list \
  | sudo tee /etc/apt/sources.list.d/libnvidia-container.list
sudo apt-get update
sudo apt-get download \
  nvidia-container-toolkit nvidia-container-toolkit-base \
  libnvidia-container1 libnvidia-container-tools
# Then SCP the resulting .debs up to hub:
scp *.deb operator@hub:/mnt/HDDs/Alfa-AI/nvidia/container-toolkit/
```

### 2.7. Stage app installers

```bash
# Example — latest Ollama Windows installer
curl -L --output /mnt/HDDs/Alfa-AI/installers/OllamaSetup.exe \
  https://ollama.com/download/OllamaSetup.exe

# Docker Desktop (cache to speed up future installs, not strictly required)
curl -L --output /mnt/HDDs/Alfa-AI/installers/DockerDesktopInstaller.exe \
  https://desktop.docker.com/win/main/amd64/Docker%20Desktop%20Installer.exe
```

---

## 3. Export to clients

### Linux / WSL nodes (NFS)

hub UI → **Shares → UNIX Shares (NFS) → Add** → path `/mnt/HDDs/Alfa-AI`,
**Maproot user `operator`** (root SSH is disabled on `hub`; client root writes
are translated to `operator` server-side so the files own to a named account
rather than uid 0), allow `orchestrator/24`.

**NFS bind (2026-09-04 SSoT):** Prefer binding nfsd to **`storage`** on **`br1`**
(`/32` VIP alongside **`hub/24`** on the same bridge). This is **not** a separate
physical NIC plane -- cabinet NICs are `br1` members (one L2). Clients may mount
**`orchestrator:/mnt/HDDs/Alfa-AI`** or **`hub:/mnt/HDDs/Alfa-AI`**
(same wire; `scripts/mount_nfs_models.sh` falls back to `hub`).

Per [hub bridge setup](https://www.hub.com/docs/scale/network/interfaces/settingupbridge/)
and [configuring interfaces](https://www.hub.com/docs/scale/network/interfaces/configuringinterfaces/),
IPv4 belongs on the bridge, not on enslaved members.

hub UI -> **System Settings -> Services -> NFS -> Configure -> Bind IP
addresses -> `orchestrator`** (and/or `hub`). Then on each Linux client:

```bash
sudo apt-get install -y nfs-common
sudo mkdir -p /mnt/cluster
sudo mount -t nfs -o vers=4.1 orchestrator:/mnt/HDDs/Alfa-AI /mnt/cluster

# Persist in /etc/fstab (prefer storage when nfsd binds it; hub is same L2 fallback):
echo 'orchestrator:/mnt/HDDs/Alfa-AI /mnt/cluster nfs vers=4.1,_netdev,x-systemd.automount 0 0' \
  | sudo tee -a /etc/fstab
# Alternate (same L2): hub:/mnt/HDDs/Alfa-AI
```

**Cluster policy — Linux on the LAN:** Every host that participates in ALFa
image builds, Petals/HF shared caches, or hub-backed compose overlays **must**
keep **`/mnt/cluster`** mounted from hub. Use the idempotent helper
**`scripts/mount_nfs_models.sh`** from the `alfa-ai` repo (same NFS settings as
above; sets `fstab`). Without this mount, heavy steps fall back to the public
internet and bypass the hub. **Cursor:** preflight in [.cursor/rules/runtime-prerequisites-preflight.mdc](../.cursor/rules/runtime-prerequisites-preflight.mdc); hub IPs in [.cursor/rules/hub-network-aliases.mdc](../.cursor/rules/hub-network-aliases.mdc). **Windows** members use SMB to the same dataset
(see below), not `/mnt/cluster`. For wheel sync only, off-LAN machines may set
**`CLUSTER_HUB_REQUIRED=0`** when running `scripts/sync-petals-wheels-from-hub.sh`
(documented in that script).

**Troubleshooting:** `showmount -e orchestrator` is often **empty** on hub
Scale even when NFS works. Use **`scripts/mount_nfs_models.sh`** (it probes
export paths) and **`scripts/verify_hub_hub.sh`** for ping, export list,
`/mnt/cluster` status, and registry `:5000` reachability.

**WSL gaming hosts (`gaming-c` / `gaming-b` / `gaming-a`):** mirrored networking needs hub NFS
service **`allow_nonroot: true`**
([`nfs.update`](https://api.hub.com/v25.04.2/api_methods_nfs.update.html);
UI: Allow non-root mount). Mount with `vers=4.1,noresvport` to **`hub`** when
**`storage`** is down. Full verified paste blocks:
[TRAIN_7B_QLORA_GUI.md](operations/TRAIN_7B_QLORA_GUI.md) (section *Verified bring-up*).

**7B QLoRA weights (SSD, not HDD):** a **second** Unix NFS share exports
`/mnt/ssd/Alfa-AI` (directory/dataset under the SSD pool -- **not** pool root
`/mnt/ssd`, per [Adding NFS shares](https://www.hub.com/docs/scale/shares/nfs/addingnfsshares/)).
Clients mount `hub:/mnt/ssd/Alfa-AI` at **`/mnt/cluster-ssd`**. If HDD
lacks `models--Qwen--Qwen2.5-Coder-7B-Instruct`, seed on `hub` only:
`sudo bash scripts/hub_hub_models.sh pull hf Qwen/Qwen2.5-Coder-7B-Instruct`
([HUB_ARTIFACTS.md](HUB_ARTIFACTS.md)). Then promote with `promote-hf-7b-to-ssd.sh`.
Parked 14B still has `promote-hf-14b-to-ssd.sh`. Train Start remounts this path
and bind-mounts `models/huggingface` as `HF_HOME`. **`hub/.locks` must be
other-writable** (`chmod a+rwx` on `hub/` and `hub/.locks`):
[huggingface_hub cache locks](https://huggingface.co/docs/huggingface_hub/en/guides/manage-cache)
create files there even when the 7B snapshot is already local. `chmod a+rX` alone
causes `PermissionError: /data/hf/hub/.locks` and torchrun `ChildFailedError`.
Corpus JSONL stays on HDD `/mnt/cluster`.

**Stale mount after LAN changes:** `x-systemd.automount` can leave a
mountpoint that answers `mountpoint -q` but returns `ENODEV` on `ls` (bond
reconfig, `storage` alias edits). **`scripts/mount_nfs_models.sh`** and
**`deploy/cluster-members/_common/preflight-nfs-hub.sh`** detect that and
remount. For hands-off recovery on Linux workers:

```bash
cd ~/alfa-ai && bash scripts/install-nfs-hub-systemd.sh
```

Installs **`alfa-nfs-hub-mount.service`** (boot + before Docker) and
**`alfa-nfs-hub-watch.timer`** (every 5 min stale check). Run once per host:
**`pool-opt-in`**, **`apps`**, **`inference`**. Sibling repos that bind-mount
`/mnt/cluster` (e.g. **contracts-bot** on `apps`) depend on this mount — not
a separate NFS config in each consumer repo.

Deploy entrypoints that call **`preflight-nfs-hub.sh`** before hub reads:
`load-llamacpp-rpc-from-hub.sh`, `ai-148/deploy*.sh`, `apps-105/deploy.sh`,
`vm100-alfa-ai/deploy.sh`, `deploy-llamacpp-rpc-shard.sh`.

If `showmount` lists **only** paths like **`/mnt/HDDs/media`**, the ALFa hub is
**not** exported yet: add a **separate** UNIX (NFS) share for **`/mnt/HDDs/Alfa-AI`**
(the dataset that holds `models/`, `wheels/`, `repo/`). One NFS share for media
does not expose the hub tree; cluster members need both shares or only the
Alfa-AI share for `/mnt/cluster`.

Client-side structure is identical — `/mnt/cluster/models/huggingface`,
`/mnt/cluster/docker/images`, etc. Compose overlays bind named volumes
onto these paths; see
[deploy/cluster/docker-compose.nfs-mounts.override.yml](../deploy/cluster/docker-compose.nfs-mounts.override.yml).

### Windows nodes (SMB)

**Local worker cache (not the hub):** Windows members stage Docker tarballs, GGUF
promotes, and train packs under `<drive>:\alfa-ai-cache\` on a **local fixed NTFS
drive**, not on hub SMB. Pick the drive with
`deploy/cluster-members/_common/Get-AlfaWindowsCacheRoot.ps1` (skip `C:` when another
eligible drive exists; prefer `G:` on `gaming-c`). Override with env
`ALFA_WINDOWS_CACHE_ROOT`. Linux workers use NFS `/mnt/cluster` for hub seed and
`~/alfa-ai-cache` for warm local cache — see [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md).

hub UI → **Shares → Windows (SMB) → Add** (or edit existing **`temp`** share):

| SMB share name | **Required** server path | Windows UNC |
|----------------|--------------------------|-------------|
| **`temp`** | **`/mnt/HDDs/Alfa-AI/smb-scratch`** | `\\hub\temp\` |
| `docker-images` | `/mnt/HDDs/Alfa-AI/docker-images` | `\\hub\docker-images\` |
| `petals-wheels` | `/mnt/HDDs/Alfa-AI/wheels` | `\\hub\petals-wheels\` |

Scripts stage to `\\hub\temp\cluster_members\` (same tree as
`/mnt/HDDs/Alfa-AI/smb-scratch/cluster_members/` on the hub). Linux staging uses
`scripts/stage-cluster-members.sh` with destination `$HUB_ROOT/smb-scratch/cluster_members`.

**Do not point `temp` at `/mnt/HDDs/media/temp`.** That path is on the **`media`**
dataset (movies/TV, etc.), not the ALFa hub. If `midclt call sharing.smb.query`
shows `temp /mnt/HDDs/media/temp`, cluster staging and gaming-worker deploy will
fail ACL checks against **Alfa-AI** even when Cody/Colin/Corey ACEs on
`/mnt/HDDs/Alfa-AI` are correct. Repoint **`temp`** to **`smb-scratch`** (operator
on `hub`); cleaning up legacy files under `media/temp` is optional and separate.

Verify share path on `hub`:

```bash
sudo midclt call sharing.smb.query | python3 -c "import sys,json; [print(s['name'], s['path']) for s in json.load(sys.stdin) if s['name']=='temp']"
```

Expected: `temp /mnt/HDDs/Alfa-AI/smb-scratch`

Optional legacy alias: second share `alfa-ai-cluster` → same `smb-scratch` path.

PowerShell mount:

```powershell
# Persistent on orchestrator etc.
New-SmbMapping -LocalPath 'T:' -RemotePath '\\hub\temp' `
  -UserName 'hub\operator' -Password 'xxx' -Persistent $true
```

**SMB Access denied on `docker-images` (`gaming-a` Corey, `gaming-c` Colin, `gaming-b` Cody, `orchestrator` operator):**
Share ACL FULL is **not** sufficient. Official hub: share ACL cannot exceed
filesystem ACL
([Windows SMB shares](https://www.hub.com/docs/scale/25.10/scaletutorials/shares/smb/)).
Do **not** HTTP-serve tarballs from `orchestrator` or skip SMB.

1. Credentials: each worker Windows account must exist as a hub local user
   with **SMB Access** enabled ([Creating User Accounts](https://www.hub.com/docs/scale/25.10/scaletutorials/shares/smb/)).
2. **Edit Filesystem ACL** on share `docker-images` (kebab menu -- not Share ACL):
   ACE for each user (or one group) with **Read** + inherit flags; check
   **Apply permissions recursively**; Save Access Control List
   ([Edit ACL](https://www.hub.com/docs/scale/datasets/permissions/editaclscreens/)).
   If `docker-images` is nested under dataset `Alfa-AI`, that parent needs
   **Traverse** for the same users.
3. Root-owned `docker save` tarballs need POSIX other-read. On `hub`:
   `bash scripts/fix-hub-docker-images-smb-read.sh --apply-posix`
   (hub publish scripts now `chown operator:operator` + `setfacl` after save).
   The same umask trap applies to **SSD GGUF promotes**
   (`promote-gguf-to-ssd.sh`): `sudo cp` left `0640` and the Pool80
   coordinator could not open the weights. Promote and
   `write-grev*-pool-env.sh` now `chmod a+r` / `a+rX` and fail-fast
   ([HUB_ARTIFACTS.md](HUB_ARTIFACTS.md) sudo promote).
4. Verify from the worker **console** (not a guest session):
   `Get-Item \\hub\docker-images\alfa-llamacpp-rpc-cuda128-b10355.tar.gz`

### Registry mirror

The registry mirror is exposed by hub's Docker stack, not by NFS. Every
Linux/WSL client writes `{ "registry-mirrors": ["http://hub/"] }`
to `/etc/docker/daemon.json`; Windows uses `configure-docker-mirror.ps1`.

### aria2 JSON-RPC

`deploy/aria2/docker-compose.yml` — import into **Dockge on every host** that
should offer JSON-RPC (see [`deploy/aria2/README.md`](../deploy/aria2/README.md)).
Default bind is **`ARIA2_DOWNLOADS_HOST_PATH`** → `/downloads` (falls back to
`/mnt/HDDs/Alfa-AI/models/downloads` on the hub). The brain’s Models UI and
`http_fetch.sh` talk to **`http://hub/jsonrpc`** by default so
operators can queue downloads into **`models/downloads/`** without SSHing into
hub. Legacy **`/mnt/models:/downloads`** still works if that symlink points
at the same dataset (migrate per §5).

**Scripts:** Bash helpers that prefer **aria2c** or this JSON-RPC endpoint,
then fall back to **curl** (scripts only — not for manual GB-scale downloads),
live in `alfa-ai/scripts/lib/http_fetch.sh`. Policy, environment variables,
and exclusions (Ollama tags, HF trees) are documented in
[HTTP_DOWNLOADS.md](HTTP_DOWNLOADS.md) — **DO NOT use bare curl for files**.

---

## 4. Capacity budget

| Subtree | Floor | Recommended | Eviction / GC pressure above |
|---------|-------|-------------|------------------------------|
| `docker/registry` | 60 GB | 120 GB | 150 GB (trigger registry GC) |
| `docker/images` | 40 GB | 60 GB | 80 GB (prune old tags) |
| `docker/buildkit` | 20 GB | 40 GB | 60 GB (`rm -rf *`) |
| `models/huggingface` | 30 GB (7B only) | 300 GB (Llama-3.3-70B + Llama-3.1-70B fallback) | none — models are the point |
| `llama-cpp/models` | ~50 GB (Q4 80B primary) | 80 GB (multi-quant + experiments) | evict retired GGUFs after tier-3b changes |
| `models/ollama` | 30 GB | 120 GB | delete unused tags |
| `models/downloads` | — | 20 GB scratch | auto-purge on promotion |
| `nvidia/` | 10 GB | 20 GB | none — installers are small |
| `wheels/` | 5 GB | 15 GB | delete older cu / torch combos |
| `installers/` | 2 GB | 5 GB | keep current + previous |
| `backups/postgres` | 1 GB | 5 GB | rotation is automatic (7 daily / 4 weekly per DB) |
| `smb-scratch/` | — | 40 GB rolling | 14-day prune (see §6) |

Minimum provision for the whole `/mnt/HDDs/Alfa-AI` dataset at the
Llama-3.3-70B + **Qwen3-Coder-Next-80B-A3B** (GGUF) target: **≈ 600 GB**. With
buildkit, image tarballs, two generations of CUDA / torch wheels, and a
Llama-3.1-70B fallback sitting side-by-side during upgrades: **900 GB** is
the "don't think about it" budget. **1.2 TB** if you retain **multiple** GGUF quants
or long **HF** snapshot histories alongside Petals caches.

### Hot pool on `hub` (SSD mirror or dedicated NVMe — fast tier for promoted deps)

Use this pool for **I/O-heavy, reproducible** data — not as a separate download
origin. **Seed to HDD first**; then bind-mount, symlink, or `zfs send | recv`
hot subsets here.

Typical **Apr 2026** install: **ZFS pool `ssd`** (mirrored SATA SSDs) with
**`ssd/ollama` → `/mnt/ssd/ollama`** for Ollama; hub **boot NVMe** may stay on
`boot-pool` only (no separate `/mnt/nvme` data pool until you create one).
Alternative: dedicated data NVMe pool `/mnt/nvme` as in
[hub_111_NVME_POOL.md](hub_111_NVME_POOL.md).

**hub shell:** `zfs` may be missing from a non-root user’s `PATH`; use
`sudo zfs list -o name,used,avail,mountpoint` or `df -h` (datasets appear as
mounts). **`zsh`:** avoid globs like `/mnt/nvme/*` when the directory is empty —
use `du -sh /mnt/nvme 2>/dev/null` instead.

| Dataset (example) | Quota | Purpose |
|-------------------|-------|---------|
| `ssd/ollama` | sized per site | Hot Ollama blobs (`qwen3.5:27b` on `gaming-c` + `qwen3.6:35b-a3b` on `orchestrator`, tiers 0/1/2 chat; embed hosts also hold `qwen3-embedding:4b`; `qwen3:32b` / 30B-A3B MoE superseded); **cold mirror** on HDD under `models/ollama` |
| `ssd/petals` | ≥ 200 GB | Petals worker hot paths (HF shard reads, identity) — `hub` rejoined the swarm Apr 2026; authoritative libp2p keys still backed on HDD/NFS per policy |
| `ssd/buildkit` or `nvme/buildkit` | 40–60 GB | Fast BuildKit cache (eject anytime); HDD `docker/buildkit` remains the shared long-lived option |
| `nvme/docker` | 200 GB | *(Optional)* Docker data root on `hub` for fast layer I/O |
| `nvme/app-state` | 20 GB | LiteLLM SQLite, logs |
| *(optional)* `ssd/llama-cpp-hot` | per GGUF set | If the coordinator benefits from NVMe read latency, **copy** GGUF from `HDDs/Alfa-AI/llama-cpp/models` — do not seed downloads only here |
| *(optional)* `nvme/Alfa-AI/docker-images` | ~10 GB | Hot copy of **`alfa-llamacpp-rpc` tarball** for fast `docker load` on `hub` ([HUB_ARTIFACTS.md](HUB_ARTIFACTS.md)) |

---

## 5. Migration from `/mnt/HDDs/alfa-ai-cluster` (old layout)

Before this doc landed, three divergent path conventions were in play on
hub: `/mnt/HDDs/alfa-ai-cluster/*` (registry + models), `/mnt/cluster/*`
(NFS mount on clients), `/mnt/models/*` (aria2 scratch). Convert in one
pass on a maintenance window:

```bash
# On hub (hub) — as root, with the registry + aria2 stacks stopped.

# 1. Create the new dataset if not already present.
zfs create -p HDDs/Alfa-AI 2>/dev/null || true
mkdir -p /mnt/HDDs/Alfa-AI

# 2. rsync existing content into the new tree.
rsync -aHAX --info=progress2 \
  /mnt/HDDs/alfa-ai-cluster/registry/    /mnt/HDDs/Alfa-AI/docker/registry/
rsync -aHAX --info=progress2 \
  /mnt/HDDs/alfa-ai-cluster/docker-images/  /mnt/HDDs/Alfa-AI/docker/images/
rsync -aHAX --info=progress2 \
  /mnt/HDDs/alfa-ai-cluster/caches/buildkit/ /mnt/HDDs/Alfa-AI/docker/buildkit/
rsync -aHAX --info=progress2 \
  /mnt/HDDs/alfa-ai-cluster/models/       /mnt/HDDs/Alfa-AI/models/
rsync -aHAX --info=progress2 \
  /mnt/HDDs/alfa-ai-cluster/installers/   /mnt/HDDs/Alfa-AI/installers/

# 3. Symlink the legacy path so in-flight compose files don't break while
#    we finish migrating code. Safe to leave in place for weeks.
mv /mnt/HDDs/alfa-ai-cluster /mnt/HDDs/alfa-ai-cluster.OLD.$(date +%F)
ln -s /mnt/HDDs/Alfa-AI /mnt/HDDs/alfa-ai-cluster

# 4. If the operator migrated /mnt/models (aria2 landing zone) too:
mv /mnt/models /mnt/models.OLD.$(date +%F)
ln -s /mnt/HDDs/Alfa-AI/models/downloads /mnt/models

# 5. Update NFS export path in hub UI: Shares → NFS → edit the old
#    export → point at /mnt/HDDs/Alfa-AI . Re-mount on every client:
#      sudo umount /mnt/cluster && sudo mount /mnt/cluster
#    (the /etc/fstab entry from §3 continues to work.)

# 6. Bring the registry + aria2 back up. Verify:
docker compose -f .../docker-compose.registry.yml up -d
docker compose -f deploy/aria2/docker-compose.yml up -d
curl -fsS http://127.0.0.1:5000/v2/                  # {}
curl -fsS http://127.0.0.1:6800/jsonrpc -X POST ...  # aria2 health
```

After migration, the following repo files need their hard-coded paths
flipped to `/mnt/HDDs/Alfa-AI/…` (tracked for a follow-up commit):

- `deploy/aria2/docker-compose.yml` (`/mnt/models` → `/mnt/HDDs/Alfa-AI/models/downloads`)
- `deploy/cluster-members/hub/docker-compose.registry.yml`
  (`/mnt/HDDs/alfa-ai-cluster/registry` → `/mnt/HDDs/Alfa-AI/docker/registry`)
- `deploy/cluster/docker-compose.nfs-mounts.override.yml`
  (`/mnt/cluster/models/…` still works — NFS mount name unchanged — but
  update the comments.)
- `deploy/cluster/docker-bake.hcl` (buildkit cache path)
- `scripts/mount_nfs_models.sh`, `scripts/setup_hub_hub.sh`
- `deploy/cluster-members/hub/deploy.sh`
- The `docs/ROADMAP.md` sections that quote the old root.

Until those flips land, the §5.3 symlink keeps everything working.

---

## 6. Routine cleanup

### Registry GC (quarterly, on `hub`)

  ```bash
docker compose -f deploy/cluster-members/hub/docker-compose.registry.yml stop
# Delete unwanted tags first (example — old CUDA minors):
#   curl -sS -X DELETE http://127.0.0.1:5000/v2/<name>/manifests/<digest>
docker compose -f deploy/cluster-members/hub/docker-compose.registry.yml run --rm registry \
  bin/registry garbage-collect --delete-untagged /etc/docker/registry/config.yml
docker compose -f deploy/cluster-members/hub/docker-compose.registry.yml up -d
```

<https://distribution.github.io/distribution/about/garbage-collection/>

### SMB scratch prune

```powershell
# Run on orchestrator with SMB admin rights — dry run first, drop -WhatIf to delete.
Get-ChildItem \\hub\temp\ -Recurse -Directory |
  Where-Object { $_.LastWriteTime -lt (Get-Date).AddDays(-14) -and
                 $_.FullName -notmatch 'cluster_members$|petals-workers$' } |
  Remove-Item -Recurse -Force -WhatIf
```

### HuggingFace cache trim

```bash
# After flipping PETALS_MODEL, the prior model's snapshots stay on disk.
# Either use the brain's Admin → Models → Delete, or manually:
rm -rf /mnt/HDDs/Alfa-AI/models/huggingface/hub/models--<org>--<old-model>
```

### BuildKit cache truncate

  ```bash
sudo rm -rf /mnt/HDDs/Alfa-AI/docker/buildkit/*
# Next `docker buildx bake` rehydrates what the active graph needs.
```

---

## 7. Sanity checks (run any time)

```bash
# Registry mirror reachable
curl -fsS http://hub/v2/

# aria2 JSON-RPC reachable
curl -sS -X POST http://hub/jsonrpc \
  -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"aria2.getVersion\",\"params\":[\"token:${ARIA2_RPC_KEY:?set ARIA2_RPC_KEY}\"]}"

# NFS mount live + expected layout
mountpoint /mnt/cluster && ls /mnt/cluster/models/huggingface/hub | head

# Buildkit cache has bytes after a bake
ls -lh /mnt/cluster/docker/buildkit/ | head

# Model presence (quick eyeball)
ls -1 /mnt/cluster/models/huggingface/hub | grep -E 'Llama-3\.[13]'
ls -lh /mnt/cluster/llama-cpp/models/*.gguf
```
