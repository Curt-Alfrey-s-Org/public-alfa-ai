# gaming-worker-a (gaming-a) — gaming + Dockge handoff

Saved from Cursor session (2026-06-10). Use this when you need to free RAM/GPU for games on `gaming-a`.

### Deferred: Petals/Hivemind cleanup (offline as of 2026-07-09)

Before using Dockge for games or RPC: `git pull`, then
`wsl -d Ubuntu bash -lc '.../scripts/purge-petals-runtime-on-host.sh --apply'`,
remove Dockge **`petals-worker`** stacks. Full checklist:
[README.md](README.md) § Deferred. **Petals is retired** — only Dockge + optional RPC.

## Problem

- Process starting with **`vmm`** (usually **`vmmem`** / **`vmmemWSL`**) eats RAM — that is the **WSL2 VM** hosting Docker, not a random Windows app.
- Leftover **Petals worker** containers (if any) keep WSL memory large — purge them first.
- **Ollama** can be stopped separately; cluster Docker stacks need **Dockge** so you can stop/start them from a UI.

## Dockge URLs (cluster)

| Host | URL | Role |
|------|-----|------|
| **`orchestrator`** | `http://orchestrator/` | Primary UI (manage all agents) |
| **`gaming-a`** | `http://127.0.0.1:5003/` or `http://orchestrator/` | Agent on gaming-worker-a |

Register `gaming-a` on `orchestrator` primary: **Settings → Remote agents** → `http://orchestrator/`

Full matrix: [docs/DOCKGE_AGENTS_WORKERS.md](../../../docs/DOCKGE_AGENTS_WORKERS.md)

## One-time: Dockge-managed stacks

Legacy stacks started outside Dockge may not appear in the UI. Reconcile once (after `git pull` + Petals purge):

```powershell
cd C:\Users\Corey\alfa-ai
git pull --ff-only origin main
. .\deploy\cluster-members\_common\initialize-windows-deploy.ps1
Initialize-AlfaDockerCli
powershell -NoProfile -ExecutionPolicy Bypass -File `
    .\deploy\cluster-members\gaming-worker-a\reconcile-dockge-stacks.ps1
```

**Repo commit:** `8047616` — `feat(dockge): add worker stack reconcile for gaming-a gaming control`

Scripts added:

- `deploy/cluster-members/gaming-worker-a/reconcile-dockge-stacks.ps1`
- `deploy/cluster-members/_common/reconcile-dockge-stacks-worker.ps1`
- `Sync-AlfaWorkerDockgeStacks` in `_common/sync-dockge-stacks-windows.ps1`

After reconcile, Dockge **Current** should show stacks you still run (e.g.
**`llamacpp-rpc`** if opted in). **Do not** bring **`petals-worker`** back — Petals
is retired; remove that stack if it appears.

## Desktop shortcut (recommended)

One-time install:

```powershell
cd C:\Users\Corey\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-a\install-gaming-desktop-shortcut.ps1
```

Creates **ALFa Gaming Mode** on the Desktop:

- **Start Gaming** -- stop shard + `wsl --shutdown`
- **Done Gaming** -- start WSL only (does **not** redeploy the inference shard)

## Before gaming (correct leave)

llama.cpp RPC cannot drop a backend while the coordinator is green. **Leave path:**

1. From **`orchestrator`:** `Start-Stop-AlfaAi.ps1 stop`
2. From **`orchestrator`:** `Start-Stop-AlfaAi.ps1 start` and answer **N** for `gaming-a`
3. On **`gaming-a`:** optional local free (GPU/WSL):

```powershell
cd C:\Users\Corey\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-a\gaming-stop-for-session.ps1 -ShutdownWsl
```

| What it does | Detail |
|--------------|--------|
| Stops **local** `rpc-server` shard | Safe after cluster stop / when `gaming-a` not in active list |
| `-ShutdownWsl` | Drops **vmmem** (~3+ GB); Dockge offline until resume |
| Pool impact | Coordinator on `hub` may error until shard is back or `orchestrator` runs full **stop+start** |

**Alternative:** Dockge UI (`http://127.0.0.1:5003/`) -> **Stop** stack `llamacpp-rpc` (same pool impact).

Also stop **Ollama** if running (startup link removed by `apply-gaming-worker-a-efficiency.ps1`).

## After gaming (start WSL only)

```powershell
cd C:\Users\Corey\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-a\gaming-resume-pool-shard.ps1
```

Starts Ubuntu ([WSL run a specific distro](https://learn.microsoft.com/en-us/windows/wsl/basic-commands#run-a-specific-linux-distribution-from-powershell-or-cmd)).
Does **not** deploy `llamacpp-rpc-server`. Put `gaming-a` back in inference from `orchestrator`:
`Start-Stop-AlfaAi.ps1 start` and answer **Y** for `gaming-a`
([CLUSTER_START_STOP_OPERATOR.md](../../../docs/CLUSTER_START_STOP_OPERATOR.md)).

## Before gaming (manual checklist)

1. Open Dockge (`http://127.0.0.1:5003/`) or `orchestrator` primary -> select gaming-worker-a agent.
2. **Stop** any leftover `petals-worker` and **`llamacpp-rpc`** if present (RPC is
   single-client -- stopping a shard while coordinator is up can crash inference;
   prefer full orchestrator stop/start from `orchestrator` if the shard was joined).
3. Stop **Ollama** (Windows service / your launcher).
4. Optional -- reclaim WSL RAM: `wsl --shutdown` (Docker/Dockge down until WSL restarts).

## After gaming (bring cluster back)

```powershell
wsl -d Ubuntu sudo service docker start
```

Then in Dockge: **Start** `petals-worker`. Or re-run reconcile if stacks drifted.

## Diagnostic (RAM / Docker / Dockge)

```powershell
Get-Process vmm* -ErrorAction SilentlyContinue | Format-Table Name, @{N='MB';E={[math]::Round($_.WorkingSet64/1MB)}}, Id -AutoSize
. C:\Users\Corey\alfa-ai\deploy\cluster-members\_common\initialize-windows-deploy.ps1
Initialize-AlfaDockerCli
docker ps --format "table {{.Names}}\t{{.Status}}"
curl.exe -sS -o NUL -w "Dockge HTTP %{http_code}\n" http://127.0.0.1:5003/
```

## Related docs

- [README.md](README.md) — full gaming-worker-a deploy
- [docs/DOCKGE_AGENTS_WORKERS.md](../../../docs/DOCKGE_AGENTS_WORKERS.md)
- [docs/WINDOWS_WSL_ROLLOUT_CHECKLIST.md](../../../docs/WINDOWS_WSL_ROLLOUT_CHECKLIST.md) Phase G
