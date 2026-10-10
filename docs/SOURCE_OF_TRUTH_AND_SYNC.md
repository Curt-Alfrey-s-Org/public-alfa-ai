# Source of Truth and Sync

How code, artifacts, and models flow between cluster members. See
[NODE_INVENTORY.md](NODE_INVENTORY.md) for node details.

> **Current:** **brain + DB on `hub`** (hub: registry, NFS, llama.cpp RPC
> coordinator). **Production RAG** embed `:11435` + rerank `:8360` on **`rag`**.
> **`pool-opt-in` is inference RPC shard only** (`:31354`), not RAG. `inference` is edge + pool
> shards (verify, edge `:8420`, log aggregation). `apps` hosts remaining
> websites/bots. **Petals retired** — history only under [`docs/history/`](history/).
> **Git:** each host commits/pushes from its own clone via GitHub
> ([git-per-host-clone.mdc](../.cursor/rules/git-per-host-clone.mdc)).
> hub = hub `hub` for SMB. **Model routing SoT:**
> [`deploy/litellm_config.yaml`](../deploy/litellm_config.yaml)
> — tiers 0/1/2 = a two-host CPU pool, `qwen3.5:27b` on `gaming-c` (quality) +
> `qwen3.6:35b-a3b` on `orchestrator` (speed), each falling back to the other host then
> `frontier`; the May `gaming-c`-only `qwen3:32b` and April four-host MoE fleet are superseded.

## Distribution channels

| Channel | What it carries | Source | Consumer |
|---------|----------------|--------|----------|
| **GitHub** | Code, configs, scripts, compose files | Owning host pushes (`orchestrator`, `pool-opt-in`, `apps`, …) | Every other clone pulls before deploy |
| **NFS** | Docker image tarballs, HF + Ollama models (cold), NVIDIA drivers, pip wheels, installers, llama.cpp GGUF weights | hub `hub` serves `/mnt/HDDs/Alfa-AI` | **Every Linux LAN member** mounts at **`/mnt/cluster`** via **`scripts/mount_nfs_models.sh`** before hub-backed builds or compose (see [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) §3 policy) |
| **SMB** | Same tree as NFS, Windows side | hub `hub` share `temp` / `alfa-ai` → `/mnt/HDDs/Alfa-AI` | Win members `orchestrator`, `gaming-b`, `gaming-c`, `gaming-a` as `\\hub\temp\` |
| **SSD / NVMe (local to `hub`)** | Fast tier: Docker data-root, BuildKit, hot Ollama, optional GGUF working copies — **reproducible from HDD hub** (Petals retired; see [`docs/history/`](history/)) | `hub` only (not exported) | `hub` brain+DB, builds, Ollama; see [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) hot-pool § |
| **Registry mirror** | Docker Hub pull-through | `http://hub/` | Every Linux/WSL `dockerd` on the LAN |

**hub = hub `hub`.** NFS, SMB, registry mirror, and the brain all
run on the same physical machine.

## Git sync (per-host clone — July 2026)

- **Each host** with a repo checkout may `git commit` and `git push` to GitHub
  when it owns that work ([git-per-host-clone.mdc](../.cursor/rules/git-per-host-clone.mdc)).
- **No host** `scp`s code to another — GitHub is the bus.
- After any push, **every other clone** runs `git pull --ff-only` before deploy.
- `hub` (hub) **pulls** for its hub clone; operator runs git there.
- `orchestrator` may push when editing locally; also **stages** per-member folders to
  `\\hub\temp\cluster_members\` via SMB.
- Win members (`gaming-b`, `gaming-c`, `gaming-a`) copy deploy folders from SMB and run
  their `deploy.ps1`.

## Repo and hub paths

| Host | Git repo path | Artifacts | Deploy | Member folder |
|------|--------------|-----------|--------|---------------|
| `pool-opt-in` (ALFA-AI VM, **inference shard only**) | `/home/operator/alfa-ai` | Local fast disk + NFS `/mnt/cluster` | `deploy/cluster-members/pool-shard-opt-in/operator-cluster-100.sh` | `vm100-alfa-ai/` |
| `apps` (Ubuntu, **remaining apps**) | `/home/operator/<repo>` | NFS `/mnt/cluster` (from `hub`) | `deploy/cluster-members/apps/deploy.sh` | `apps-105/` |
| `rag` (VM110, **RAG production**) | `/home/operator/alfa-ai` | Local + NFS `/mnt/cluster` | [DOCKGE_110_OPERATOR.md](DOCKGE_110_OPERATOR.md) | RAG embed `:11435` + rerank `:8360` |
| `hub` (hub, **hub + brain + DB**) | `/mnt/HDDs/Alfa-AI/repo/alfa-ai` | NFS + SMB + registry mirror | `deploy/cluster-members/hub/deploy.sh` | `hub-111/` |
| `orchestrator` (Win11, Dockge UI + worker) | `C:/Users/operator\alfa-ai` | SMB `\\hub\temp\` | `deploy/cluster-members/orchestrator/deploy.ps1` | `operator-93/` |
| `gaming-b` (gaming-worker-b) | N/A (gets files from SMB) | `\\hub\temp\cluster_members\gaming-worker-b-249\` | `deploy.ps1` | `gaming-worker-b-249/` |
| `gaming-c` (gaming-worker-c) | N/A (gets files from SMB) | `\\hub\temp\cluster_members\gaming-worker-c-59\` | `deploy.ps1` | `gaming-worker-c-59/` |
| `gaming-a` (gaming-worker-a) | N/A (gets files from SMB) | `\\hub\temp\cluster_members\gaming-worker-a-219\` | `deploy.ps1` | `gaming-worker-a-219/` |

All member folders live under `deploy/cluster-members/` in the repo. Each
contains a deploy script and environment file specific to that node.

## hub hub folder layout

Canonical layout (see **[CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md)** for the full tree, capacity budgets, and cleanup procedures):

```
/mnt/HDDs/Alfa-AI/                    single canonical root
  docker/
    registry/                         pull-through registry mirror (:5000)
    images/                           prebuilt ALFa image tarballs (docker save)
    buildkit-cache/                   docker buildx bake cache
  nvidia/
    drivers/{rtx-30xx,rtx-50xx-blackwell}/
    cuda-toolkit/
    cudnn/
  ollama/
    models/                           OLLAMA_MODELS blob+manifest store
    installers/
  hf/
    hub/                              HF_HOME cache (models--org--name/snapshots/...)
    tokens/                           per-node .env with HF_TOKEN (0600)
  llama-cpp/                          tier 3b (frontier-code) GGUF weights
    models/Qwen3-Coder-Next-Q4_K_M/Qwen3-Coder-Next-Q4_K_M-0000[1-4]-of-00004.gguf
  wheels/{cu124,cu128,cpu}/
  installers/{docker-desktop,wsl2-kernel,python}/
  aria2/{config,session,downloads-tmp}/
  repo/
    alfa-ai/                          git clone (hub's own copy)
  smb-scratch/                        \\hub\alfa-ai\smb-scratch\ target
                                      (deploy staging, prune freely)
```

## Env file conventions

| Role | Live env file | Template (committed) | Location |
|------|---------------|----------------------|----------|
| **Brain (`hub`)** | `deploy/.env` | [deploy/env.example](../deploy/env.example) | Git repo |
| `hub` Petals worker *(retired — [`history/`](history/) only)* | was `deploy/cluster-members/hub/.env.worker` | [hub-111/env.worker.example](../deploy/cluster-members/hub/env.worker.example) | Git repo (audit) |
| **Apps host (`apps`)** | `deploy/.env.apps` | [apps-105/env.apps.example](../deploy/cluster-members/apps/env.apps.example) | Git repo |
| `apps` Petals bootstrap worker *(retired — [`history/`](history/) only)* | was `deploy/petals/.env.worker` | [apps-105/env.worker.example](../deploy/cluster-members/apps/env.worker.example) | Git repo (audit) |
| **`orchestrator` primary gateway** | `deploy/.env.gateway` | [operator-93/env.gateway.example](../deploy/cluster-members/orchestrator/env.gateway.example) | Git repo |
| `orchestrator` Petals worker(s) *(retired — [`history/`](history/) only)* | was `deploy/petals/.env.worker` | [operator-93/env.worker.example](../deploy/cluster-members/orchestrator/env.worker.example) | Git repo (audit) |
| Other Petals workers (`inference`, `gaming-b`, `gaming-c`, `gaming-a`) *(retired — [`history/`](history/) only)* | was host-side `.env.worker` | `deploy/cluster-members/<host>/env.worker.example` | Git repo (audit) |
| Petals worker (generic field reference) *(retired — [`history/`](history/) only)* | n/a | [deploy/petals/env.worker.example](../deploy/petals/env.worker.example) | Git repo (audit) |
| llama.cpp RPC main + rpc-server | `deploy/llamacpp-rpc/.env.rpc` | `deploy/llamacpp-rpc/.env.rpc.example` | Git repo |
| Dockge (hub Apps on `hub`) | configured in hub UI | n/a | hub Apps |

Per-host workflow + industry rationale: [docs/petals/PER_HOST_ENV_TEMPLATES.md](petals/PER_HOST_ENV_TEMPLATES.md).

**Container env:** `alfa-ai-litellm` uses `OLLAMA_BASE_URL`,
`OLLAMA_AGENT_URL`, `EMBED_BASE_URL` / `RERANK_BASE_URL` (RAG on **`rag`**),
and `LLAMACPP_RPC_URL` from `deploy/.env` (`PETALS_GATEWAY_URL` is retired —
[`history/`](history/) only). Inside the same compose network, use service names
(`http://alfa-ai-litellm:4000`). For cross-host calls (brain+DB on `hub`
→ RAG on `rag` → llama.cpp RPC coordinator on `hub`), use LAN IPs.

## Deployment workflow

### First time (new member)

Use the per-host deploy script under `deploy/cluster-members/<host>/`:

```bash
git clone operator@example.com:example/alfa-ai.git ~/alfa-ai
cd ~/alfa-ai && git pull --ff-only origin main
# hub brain:
sudo bash deploy/cluster-members/hub/deploy.sh
# apps apps:
bash deploy/cluster-members/apps/deploy.sh
# Windows workers: see deploy/cluster-members/<host>/README.md
```

### Routine update (all members)

```bash
git pull --ff-only origin main
# Then run the host deploy script (same paths as above).
```

### After development (any owning host)

```bash
# 1. On the host where you edited (e.g. orchestrator, pool-opt-in, apps):
git add -A && git commit -m "description" && git push origin main

# 2. On every other clone before deploy:
git pull --ff-only origin main

# 3. Deploy on each touched host:
# bash deploy/cluster-members/<host>/deploy.sh
```

### Windows members (via SMB staging)

`orchestrator` stages per-member deploy folders to `\\hub\temp\cluster_members\`. Each member has a **self-contained** `deploy.ps1` with all deploy logic inline. Shared artifacts (worker-files, Docker images, Ollama) live in `_common\` on the SMB share and are read directly by each member's script.

```powershell
# On orchestrator: pull latest and stage to SMB
cd C:/Users/operator\alfa-ai
.\scripts\stage-cluster-members.ps1

# On each Win worker (e.g. gaming-worker-b): copy 1 folder, run 1 script
Copy-Item -Recurse '\\hub\temp\cluster_members\gaming-worker-b-249' 'C:\alfa-ai-worker'
cd C:\alfa-ai-worker
.\deploy.ps1
```

Each `deploy.ps1` is fully self-contained: SMB file sync, Docker image loading, GPU detection (Blackwell vs standard), compose up, and Ollama setup. To fix a bug: edit on `apps` -> push -> pull on `orchestrator` -> `stage-cluster-members.ps1`.

### Brain (`hub`), apps host (`apps`), and Dockge UI (`orchestrator`)

These nodes run their deploy scripts directly from the git repo (no SMB copy
needed):

```bash
# Brain (hub, hub): full ALFa AI brain stack + Ollama + registry mirror
# operator is the canonical ops user on hub (root SSH is disabled).
ssh operator@hub
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
sudo bash deploy/cluster-members/hub/deploy.sh
```

```bash
# Apps host (apps): remaining websites/bots + shared Postgres/Redis (no Petals)
ssh operator@apps
cd /home/operator/alfa-ai
bash deploy/cluster-members/apps/deploy.sh
```

```powershell
# Dockge UI (orchestrator): primary Dockge + inference shard (no Petals)
cd C:/Users/operator\alfa-ai
.\deploy\cluster-members\orchestrator\deploy.ps1
```

## SSH key setup

All cluster members use SSH key auth (no passwords) for `scp` and `git` over SSH.

```bash
# On apps: generate keys and print install instructions (includes ~/.ssh/config for hub)
bash scripts/setup_ssh_keys.sh

# On each member: install the public key
bash scripts/install_ssh_key.sh "ssh-ed25519 AAAA..."

# Verify: test connectivity
bash scripts/setup_ssh_keys.sh --test
```

**hub (hub) from inference:** Run `ssh-copy-id -i ~/.ssh/id_ed25519_cluster.pub operator@hub` once. If the account’s **home directory is not writable** (often `/var/empty`), hub rejects keys in both UI and `midclt` until you assign a **home on the HDDS pool** — e.g. create dataset **`HDDs/homes`** if needed, then **Credentials → Users →** user **→ Edit** → **Home directory** → **`/mnt/HDDs/homes/operator`** (match the username). Then add the key. `setup_ssh_keys.sh` prints a `Host hub` block for `~/.ssh/config`. **Root SSH is not used on hub** (disabled on this deployment); all operator access is as `operator`.

### hub SSH + HDDS home (reference procedure)

Use a **root** shell on hub (e.g. **System → Shell**). On **zsh**, do not assign to `UID` (read-only); use e.g. `TN_USER_ID=$(midclt call user.query '[["username","=","operator"]]' | jq -r '.[0].id')`.

1. **Dataset** on pool **HDDs** (no `create_parents` — not all API versions support it):
   ```bash
   midclt call pool.dataset.create '{"name": "HDDs/homes"}'
   ```
   Mountpoint is typically `/mnt/HDDs/homes`.

2. **Directory for the user’s home** (must exist before `user.update` accepts `home`):
   ```bash
   mkdir -p /mnt/HDDs/homes/operator
   chown operator:operator /mnt/HDDs/homes/operator
   ```
   Or: `zfs create HDDs/homes/operator` then `chown` as appropriate.

3. **Set home**, then **set SSH public key** (`sshpubkey` must be a **string**, not an array):
   ```bash
   TN_USER_ID=$(midclt call user.query '[["username","=","operator"]]' | jq -r '.[0].id')
   midclt call user.update "$TN_USER_ID" '{"home": "/mnt/HDDs/homes/operator"}'
   PUBKEY='ssh-ed25519 AAAA... alfa-ai-cluster@web-sites'
   midclt call user.update "$TN_USER_ID" "$(jq -n --arg k "$PUBKEY" '{sshpubkey: $k}')"
   ```

4. **On `apps`**, append **`Host hub`** to **`~/.ssh/config`** with a **heredoc** or editor — do not paste `Host` / `HostName` lines as shell commands. Then: `ssh -o BatchMode=yes hub 'echo ok'` (expect `ok`).

5. **Export Docker images** to the hub: mount NFS at `/mnt/cluster` when the export exists, or set `CLUSTER_IMAGES_DIR` to a writable path; see `scripts/export_docker_images.sh`.

## Related docs

- [NODE_INVENTORY.md](NODE_INVENTORY.md) — node list, IPs, roles, GPUs
- [DISTRIBUTED_AI.md](DISTRIBUTED_AI.md) — llama.cpp RPC + LiteLLM architecture (Petals in [`history/`](history/) only)
- [QWEN3_MIGRATION.md](QWEN3_MIGRATION.md) — April 2026 model + runtime split
- [MODEL_FIT_AUDIT.md](MODEL_FIT_AUDIT.md) — Meta + Qwen benchmark tables vs repo tiers (auditor-style)
- [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md) — tier 3b runbook
- [ROADMAP.md](ROADMAP.md) — near-term cluster work
- [MILESTONE_BACKLOG.md](MILESTONE_BACKLOG.md) — Milestone 6 definition of done
