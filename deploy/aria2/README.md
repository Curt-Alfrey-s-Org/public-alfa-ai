# aria2 in Dockge (all cluster hosts)

This directory holds the **canonical** `docker-compose.yml` for **`p3terx/aria2-pro`**
(JSON-RPC **`http://<host>:6800/jsonrpc`**). Deploy a **separate Dockge stack**
per machine so `http_fetch.sh` / `hub_hub_models.sh` / operator tooling can
use **local** RPC (`127.0.0.1`) or a **chosen hub** (usually hub `hub`).

## One-time per host

1. **Disk path** — pick a directory with enough free space (GGUFs are tens of GB).
   Create it: `mkdir -p "<path>"`. If an older compose used **`container_name:
   aria2`**, **`docker compose down`** that stack before deploying this one so
   only a single aria2 instance owns **:6800**.
2. **Env** — create `.env` beside this compose file (key reference:
   `env.dockge.example.bak`) **or** paste the same keys into Dockge’s stack
   **Environment** UI. **`ARIA2_RPC_KEY` is required and has no default**:
   compose refuses to start without it. Generate one long random value
   (`openssl rand -hex 24`) and use the **same** value on the aria2 hub, on every
   client (`export ARIA2_RPC_KEY=…` / `$env:ARIA2_RPC_KEY = '…'`) and in the
   brain's `deploy/.env` (Admin → Models downloads). Never commit it. Set
   **`ARIA2_DOWNLOADS_HOST_PATH`** if the default is wrong for that OS.
3. **Dockge** — **Stacks → + → Web editor** (or **Compose**), name e.g. `alfa-aria2`,
   paste `docker-compose.yml`, set env, **Deploy**.
4. **Firewall** — allow **TCP `6800`** from `orchestrator/24` (or your LAN CIDR) on
   every host that should accept remote RPC. hub: **Network → Global Settings**
   / **Firewall** as appropriate.
5. **Smoke test** — use the **fixed-path** script for that host (below), or:

```bash
curl -sS -X POST "http://127.0.0.1:6800/jsonrpc" \
  -H 'Content-Type: application/json' \
  -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"aria2.getVersion\",\"params\":[\"token:${ARIA2_RPC_KEY:?set ARIA2_RPC_KEY}\"]}"
```

## Per-host env scripts

The scripts carry fixed paths but **no secret**: export `ARIA2_RPC_KEY` in the
shell (or as a Windows user env var) before sourcing/running them. The env scripts
warn and the smoke/bootstrap scripts stop with an error when it is unset.

Each folder under `deploy/cluster-members/<name>/` ships **`aria2-env`** +
**`aria2-smoke`** with canonical paths for that machine. Non-`hub` env scripts
now default to **hub `hub` RPC** with `ARIA2_MODE=rpc` so model HTTP fetches
route through the hub instead of direct internet fallback. After `git pull`,
use the paths in the table (same paths are inside the scripts).

| Node | Folder | Env (source / dot-source) | Smoke |
|------|--------|---------------------------|--------|
| hub `hub` | `deploy/cluster-members/hub/` | `source /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/aria2-env.sh` | `bash …/hub-111/aria2-smoke.sh` |
| Win11 `orchestrator` | `deploy/cluster-members/orchestrator/` | `. C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\aria2-env.ps1` | `powershell -File …\operator-93\aria2-smoke.ps1` (tests `hub:6800`) |
| Ubuntu `apps` | `deploy/cluster-members/apps/` | `source /home/operator/alfa-ai/deploy/cluster-members/apps/aria2-env.sh` | `bash …/apps-105/aria2-smoke.sh` (tests `hub:6800`) |
| gaming-worker-b `gaming-b` | `deploy/cluster-members/gaming-worker-b/` | `. C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-b\aria2-env.ps1` | `powershell -File …\gaming-worker-b-249\aria2-smoke.ps1` (tests `hub:6800`) |
| gaming-worker-c `gaming-c` | `deploy/cluster-members/gaming-worker-c/` | `. C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-c\aria2-env.ps1` | `powershell -File …\gaming-worker-c-59\aria2-smoke.ps1` (tests `hub:6800`) |
| gaming-worker-a `gaming-a` | `deploy/cluster-members/gaming-worker-a/` | `. C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-a\aria2-env.ps1` | `powershell -File …\gaming-worker-a-219\aria2-smoke.ps1` (tests `hub:6800`) |

## One-command bootstrap per host

After `git pull`, export `ARIA2_RPC_KEY`, then run a single host-local
bootstrap script. It writes `deploy/aria2/.env` with that host's fixed paths and
the secret from your environment, starts/restarts the aria2 compose stack, and
runs smoke checks. It refuses to run when `ARIA2_RPC_KEY` is unset.

| Node | Bootstrap command |
|------|-------------------|
| hub `hub` | `bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/aria2-bootstrap.sh` |
| Ubuntu `apps` | `bash /home/operator/alfa-ai/deploy/cluster-members/apps/aria2-bootstrap.sh` |
| Win11 `orchestrator` | `powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\aria2-bootstrap.ps1` |
| gaming-worker-b `gaming-b` | `powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-b\aria2-bootstrap.ps1` |
| gaming-worker-c `gaming-c` | `powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-c\aria2-bootstrap.ps1` |
| gaming-worker-a `gaming-a` | `powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-a\aria2-bootstrap.ps1` |

**hub hub only** — same directory also has **`aria2-pull-gguf.sh`** and
**`aria2-hub-status.sh`** (they `source` `aria2-env.sh` then call
`scripts/hub_hub_models.sh`). Example:

```bash
export HF_TOKEN='hf_…'   # if needed
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/aria2-pull-gguf.sh
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/aria2-hub-status.sh
```

Dockge stack compose path on **`hub`**:  
`/mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/aria2/docker-compose.yml`  
On **`orchestrator`**:  
`C:/Users/operator\alfa-ai\deploy\aria2\docker-compose.yml`

## `ARIA2_DOWNLOADS_HOST_PATH` by node (Apr 2026 layout)

| Host | Mgmt IP | Suggested bind |
|------|---------|----------------|
| hub `hub` (brain hub) | `hub` | `/mnt/HDDs/Alfa-AI/models/downloads` (default) or legacy symlink **`/mnt/models`** if that is what you still use |
| Ubuntu apps | `apps` | **`/home/operator/alfa-ai/data/aria2-downloads`** (see `apps-105/aria2-env.sh`) |
| Win11 Dockge primary | `orchestrator` | **`C:/Users/operator\AppData\Local\alfa-ai\aria2-downloads`** (see `operator-93/aria2-env.ps1`) |
| gaming-worker-b / gaming-worker-c / gaming-worker-a | `gaming-b` / `gaming-c` / `gaming-a` | **`C:\alfa-ai-worker\data\aria2-downloads`** (see each member’s `aria2-env.ps1`) |

**Critical:** Any machine that runs `aria2_jsonrpc_fetch.py` must set
**`ARIA2_HOST_STAGING`** to the **same host path** as `ARIA2_DOWNLOADS_HOST_PATH`
on the **aria2 server** it talks to (the Python helper `move`s from staging into
the final destination). Example for hub hub:

```bash
export ARIA2_RPC_URL='http://hub/jsonrpc'
export ARIA2_RPC_KEY='<same secret as the hub stack>'
export ARIA2_RPC_DIR='/downloads'
export ARIA2_HOST_STAGING='/mnt/HDDs/Alfa-AI/models/downloads'
```

For RPC to **localhost** on the same box as the container:

```bash
export ARIA2_RPC_URL='http://127.0.0.1:6800/jsonrpc'
export ARIA2_HOST_STAGING='/mnt/HDDs/Alfa-AI/models/downloads'   # match this host’s bind
```

## Rotating the RPC secret

The old default secret was committed in earlier revisions and must be
treated as public. To rotate: generate a new value, put it in `deploy/aria2/.env`
(or the Dockge stack env) on every aria2 host and `docker compose up -d` there, set
the same value in the brain's `deploy/.env` and recreate `alfa-ai-api`, and update
any client shells / Windows user env vars that export `ARIA2_RPC_KEY`.

## Dockge entrypoints

| Node | Dockge URL (typical) |
|------|----------------------|
| `hub` hub | `http://hub/` (hub Apps) |
| `orchestrator` Win11 | `http://127.0.0.1:5002/` on that PC |
| Other LAN agents | `http://<host>:5001/` per [NODE_INVENTORY.md](../../docs/NODE_INVENTORY.md) |

Use **the same git path** on each host (e.g. clone `alfa-ai` and point Dockge at
`deploy/aria2/docker-compose.yml`), or paste the compose from this repo.

## Config is host-local runtime (NOT tracked); template is `config.example/`

The `p3terx/aria2-pro` container runs as **root** (`PUID=0` default) and rewrites
its bind-mounted `/config` tree in place (chowning `LICENSE`, `aria2.conf`,
`script.conf`, `script/*` to root). If those files were **tracked** in git, a
`git reset --hard origin/main` on a host that syncs as a non-root user (e.g.
`operator` on hub `hub`) fails with `unable to unlink ...: Permission denied`
and **aborts the cluster stop/start** (the orchestrator git-syncs `hub` first).

To prevent this, `deploy/aria2/config/` is **git-ignored runtime** — the container
seeds defaults on first start. The canonical defaults are tracked as a template in
**`deploy/aria2/config.example/`**.

- **Fresh host:** `docker compose up` creates `config/`; the image populates
  defaults. To pin the repo's copy instead, seed it first:
  `cp -rn deploy/aria2/config.example/. deploy/aria2/config/`.
- **Customize:** edit files in `config/` on that host (host-local; never committed).
  To change the cluster-wide default, edit `config.example/` and commit.
- **Recover a wedged sync** (root-owned `config/` blocks `git reset --hard`):

```bash
sudo chown -R "$(id -un)":"$(id -gn)" deploy/aria2/config
git fetch origin main && git reset --hard origin/main
```

The `hub` operator script (`operator-cluster-111.sh`) does this chown
automatically before every git sync, so the standard `Start-Stop-AlfaAi.ps1`
cycle self-heals. Runtime files (`aria2.session`, `dht.dat`, `dht6.dat`) were
already ignored and are recreated by the container.

## Docs

- [HTTP_DOWNLOADS.md](../../docs/HTTP_DOWNLOADS.md) — `http_fetch` env table.
- [CLUSTER_SHARED_STORAGE.md](../../docs/CLUSTER_SHARED_STORAGE.md) — hub layout,
  `models/downloads/`, migration notes.
