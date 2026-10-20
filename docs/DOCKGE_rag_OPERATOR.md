# Operator guide — VM110 (ALFA-AI RAG host)

**Host:** `orchestrator`  
**SSH user:** `operator`  
**Repo path:** `/home/operator/alfa-ai` (`~/alfa-ai`)  
**Role (target):** **CPU embed + rerank** — `qwen3-embedding:4b` on **`:11435`**, Qwen3 reranker on **`:8360`**.  
**Production today:** RAG on **`rag`** ([RAG_148_TO_110_MIGRATION.md](RAG_148_TO_110_MIGRATION.md) Phase C complete 2026-07-18).  
**Brain + inference:** **`hub`** coordinator + `inference`/`orchestrator`/`pool-opt-in`/`secondary` shards (unchanged by `rag` prep).

## What runs here

| Stack | Compose | Port |
|-------|---------|------|
| Embed | `vm110-alfa-ai/docker-compose.embed-cpu.yml` | **`:11435`** |
| Rerank | `vm110-alfa-ai/docker-compose.reranker-cpu.yml` | **`:8360`** (`ghcr.io/ggml-org/llama.cpp:server`, CPU) |
| `dockge-agent` | `vm110-alfa-ai/deploy-dockge.sh` | **`:5001`** (register on `orchestrator` primary) |

**Not on `rag`:** brain api/litellm, inference shards, postgres, redis.

## Guest prerequisites

| Item | Requirement |
|------|-------------|
| RAM | **>= 16 GB** recommended (embed ~2.5 GB + rerank ~0.6 GB + OS headroom) |
| CPU | **AVX2** — Proxmox **CPU type: host** |
| Docker | Engine + compose plugin |
| NVIDIA | **Not used** — `rag` is CPU-only; rerank runs `ghcr.io/ggml-org/llama.cpp:server` |
| Hub | NFS `/mnt/cluster` for first model seed; steady-state `~/alfa-ai-cache/rag` |

**Smoke:**

```bash
grep -q avx2 /proc/cpuinfo && echo AVX2_OK
docker info
```

Do **not** install NVIDIA drivers or `nvidia-container-toolkit` on `rag` unless you later add GPU passthrough. Production `inference` RAG is unchanged (`alfa-llamacpp-rpc:cuda128` + host driver).

## SSH from `orchestrator` (agent + orchestrator)

1. **From `orchestrator` (operator):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).
```

2. **On `rag` (operator)** — clone repo first if needed, then:

```bash
git clone operator@example.com:example/alfa-ai.git ~/alfa-ai
cd ~/alfa-ai && git pull --ff-only origin main
bash deploy/cluster-members/rag-host/install-agent-ssh-from-93.sh
```

**GitHub access:** use **SSH** `origin` (`operator@example.com:...`), same as `inference`/`pool-opt-in`. HTTPS
`git pull` fails without interactive credentials. One-time: add a read/write or
deploy key for `operator` on GitHub, then
`git remote set-url origin operator@example.com:example/alfa-ai.git`.

3. **From `orchestrator`:**

```powershell
ssh -i $env:USERPROFILE\.ssh\id_ed25519_93_110 -o StrictHostKeyChecking=accept-new operator@orchestrator "echo SSH_OK"
```

Use **`StrictHostKeyChecking=accept-new`** instead of `ssh-keyscan` on Windows OpenSSH
9.x — Ubuntu 24.04+ servers advertise KEX (`operator@example.com`) that
`ssh-keyscan` on Win11 cannot negotiate (`choose_kex: unsupported KEX method`).

**Set hostname (guest was cloned as `101`):**

```bash
sudo hostnamectl set-hostname 110
sudo sed -i 's/\t101$/\t110/' /etc/hosts
hostname
```

Key path: `%USERPROFILE%\.ssh\id_ed25519_93_110`  
Published pubkey in repo: `deploy/cluster-members/rag-host/id_ed25519_93_110.pub`

## First-time RAG deploy

```bash
cd ~/alfa-ai && git pull --ff-only origin main
bash deploy/cluster-members/rag-host/bootstrap-vm110.sh
```

**Verify:**

```bash
curl -fsS http://127.0.0.1:11435/api/tags
curl -fsS http://127.0.0.1:8360/health
bash deploy/cluster-members/rag-host/operator-cluster-110.sh status
```

**Staging verify from `inference` hub** (production URLs unchanged):

```bash
RAG_SIDECARS_ENV=deploy/cluster-members/_common/rag-sidecarsrag-staging.env \
  RAG_REQUIRE_RERANK=1 bash deploy/cluster-members/_common/verify-rag-sidecars.sh
```

## Routine operator commands

```bash
bash deploy/cluster-members/rag-host/operator-cluster-110.sh start-rag
bash deploy/cluster-members/rag-host/operator-cluster-110.sh stop-rag
bash deploy/cluster-members/rag-host/operator-cluster-110.sh status
```

## Dockge agent

Image `louislam/dockge:1` from hub tarball `louislam-dockge-1.tar.gz` (copy into
`~/alfa-ai-cache/docker-images/` if NFS autofs does not show `/mnt/cluster`).
Do not `docker pull` from Docker Hub.

```bash
cd ~/alfa-ai && git pull --ff-only origin main
bash deploy/cluster-members/rag-host/deploy-dockge.sh
```

On `orchestrator` primary: Settings -> Remote agents -> `http://orchestrator`

## Cutover

See [RAG_148_TO_110_MIGRATION.md](RAG_148_TO_110_MIGRATION.md) Phase C — do not point `hub`
`deploy/.env` at `rag` until staging verify passes.

## Related

- [deploy/cluster-members/rag-host/README.md](../deploy/cluster-members/rag-host/README.md)
- [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md) — RAG local cache policy
