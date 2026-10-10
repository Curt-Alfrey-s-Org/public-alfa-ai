# RAG migration: `inference` CPU sidecars to `rag`

**Status:** Phase C cutover (2026-07-18) — production RAG on **`rag`**. `inference` RAG retired.

**Goal:** Move embed (`:11435`) + rerank (`:8360`) off `inference` so both GPUs stay inference-only. `rag`
is a dedicated RAG VM (same CPU sidecar stack as `inference` today).

| Phase | What | Production impact |
|-------|------|-------------------|
| **A** | SSH from `orchestrator`, git clone, hub/NFS | None |
| **B** | Deploy RAG on `rag`, verify in parallel | None (`hub` still points at `inference`) |
| **C** | Cutover `rag-sidecars.env`, orchestrator, `hub deploy/.env` | **Done 2026-07-18** — full stop + start required on each host pull |

Operator entry: [DOCKGE_110_OPERATOR.md](DOCKGE_110_OPERATOR.md)

---

## Why `rag` matches `inference` RAG (not legacy `pool-opt-in` GPU RAG)

| | Legacy `pool-opt-in` (retired) | `inference` today | `rag` target |
|--|-------------------------|--------------|---------------|
| Embed | GPU Ollama on 1660S | CPU Ollama `:11435` | CPU Ollama `:11435` |
| Rerank | GPU llama-server | CPU llama-server `:8360` (`alfa-llamacpp-rpc:cuda128`) | CPU llama-server `:8360` (`ghcr.io/ggml-org/llama.cpp:server`) |
| inference | Shard `:31354` | Shards `:31356`/`:31357` | **No shard** |

Scripts: `deploy/cluster-members/rag-host/` (mirror `ai-148/deploy-rag-cpu.sh`).

---

## Phase A — SSH and clone (like VM100 bootstrap)

**Prerequisites on Proxmox / guest:**

1. Static LAN **`orchestrator`**, user **`operator`**, Ubuntu + Docker Engine.
2. **CPU type `host`** in Proxmox (AVX2 required for rerank — same as VM100 rerank gate).
3. **NVIDIA driver + nvidia-container-toolkit** — rerank uses `alfa-llamacpp-rpc:cuda128` with
   `CUDA_VISIBLE_DEVICES=-1` but still needs host `libcuda.so.1` (see
   [ai-148/docker-compose.reranker-cpu.yml](../deploy/cluster-members/inference-coordinator/docker-compose.reranker-cpu.yml)).
4. Optional NFS: `hub_IP=orchestrator bash scripts/mount_nfs_models.sh`

**From `orchestrator` (operator) — generate agent key (once):**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).
```

**On `rag` (operator) — after `git pull` on `orchestrator` pushed the pubkey, or paste pubkey manually:**

```bash
mkdir -p ~/.ssh && chmod 700 ~/.ssh
bash ~/alfa-ai/deploy/cluster-members/rag-host/install-agent-ssh-from-93.sh
```

**From `orchestrator` — accept host key + smoke:**

```powershell
ssh -i $env:USERPROFILE\.ssh\id_ed25519_93_110 -o StrictHostKeyChecking=accept-new operator@orchestrator "echo SSH_OK"
```

(Do not rely on `ssh-keyscan` from Windows — KEX mismatch with Ubuntu OpenSSH 10.x.)

**On `rag` — hostname (if still `101` from clone):**

```bash
sudo hostnamectl set-hostname 110
sudo sed -i 's/\t101$/\t110/' /etc/hosts
```

---

## Phase B — Load artifacts and start RAG on `rag`

**Hub seeds (once on `hub` if missing):**

- Rerank GGUF: `sudo bash scripts/seed-qwen3-reranker-gguf-hub.sh`
- Embed: Ollama blob under `/mnt/HDDs/Alfa-AI/models/ollama/embed-qwen3-4b`
- Docker image: `alfa-llamacpp-rpc:cuda128` tarball on hub (same as inference workers)

**On `rag`:**

```bash
cd ~/alfa-ai && git pull --ff-only origin main
bash deploy/cluster-members/rag-host/bootstrap-vm110.sh
```

Or stepwise:

```bash
bash deploy/cluster-members/rag-host/operator-cluster-110.sh start-rag
```

**Verify from `inference` hub (staging — does not change production URLs):**

```bash
cd ~/alfa-ai
RAG_SIDECARS_ENV=deploy/cluster-members/_common/rag-sidecarsrag-staging.env \
  RAG_REQUIRE_RERANK=1 bash deploy/cluster-members/_common/verify-rag-sidecars.sh
```

Local on `rag`:

```bash
curl -fsS http://127.0.0.1:11435/api/tags
curl -fsS http://127.0.0.1:8360/health
```

---

## Phase C — Cutover (last step — operator only)

Do **not** run until Phase B is green for **24h** or after deliberate soak test.

1. **Repo:** change canonical hosts in `deploy/cluster-members/_common/rag-sidecars.env`:
   - `EMBED_HOST` / `RERANK_HOST` → `orchestrator`
2. **Orchestrator:** `Invoke-AlfaAiCluster.ps1` — `Invoke-AlfaStartRagSidecars` / stop / verify
   target `rag` instead of `inference` (see commit that lands Phase C).
3. **`hub` brain env:** update `deploy/.env` on `hub` (preserve live file):
   - `EMBED_BASE_URL=http://orchestrator`
   - `RERANK_BASE_URL=http://orchestrator`
4. **`switch-pool-27b.sh`:** `WANT_EMBED_URL` / `WANT_RERANK_URL` → `rag`
5. **Docs:** [NODE_INVENTORY.md](NODE_INVENTORY.md), [REPO_HOST_MAPPING.md](REPO_HOST_MAPPING.md)
6. **Full cycle from `orchestrator`:**

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 stop
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 start
```

7. **Verify:** post-start checks hit `rag:11435` and `rag:8360`; `inference` RAG containers stopped.

**Rollback:** revert `rag-sidecars.env` to `inference`, restore `hub deploy/.env`, full stop + start.

---

## Related

- [DOCKGE_110_OPERATOR.md](DOCKGE_110_OPERATOR.md)
- [.cursor/plans/RAG_248_VM100_SHARD.md](../.cursor/plans/RAG_248_VM100_SHARD.md) — prior RAG move to `inference`
- [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) — RAG start order after coordinator
