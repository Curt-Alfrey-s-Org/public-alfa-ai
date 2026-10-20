# Host bootstrap + log capture runbook

Use these scripts when running aria2 bootstrap on each host so errors are always
captured into repo files under `deploy/cluster-members/<host>/logs/`.

## 0) run.ps1 worker deploy — automatic transcript + heartbeat

Every `deploy/cluster-members/<member>/run.ps1` now:

- Opens a UTF-8 PowerShell transcript automatically at
  `deploy\cluster-members\<member>\logs\run-<machineName>-<UTC>.log`
- Prints each phase with a `[HH:mm:ss.fff] [STEP ] PHASE: ...` banner and
  closes it with `PHASE END: ... -> OK in Ns`.
- Emits a `[BEAT ] still running: <op> (elapsed Ns, no hang)` line every 15s
  while `docker load` / `docker build` / `docker compose build` /
  `docker compose up` is blocking the console. That is how you tell slow from hung.
- Finishes with a `RUN SUMMARY` block listing every phase, its result, its
  elapsed time, and a total (`DEPLOY OK (gaming-worker-b, 342s total)` or
  `DEPLOY FAIL (..)`) so you can see at a glance which phase ate the clock.

### Where the log lives

| Host              | Repo root            | Log file                                                                 |
|-------------------|----------------------|--------------------------------------------------------------------------|
| `orchestrator` operator-93   | `C:\alfa-ai`         | `C:\alfa-ai\deploy\cluster-members\orchestrator\logs\run-operator-93-<UTC>.log` |
| `gaming-b` gaming-worker-b      | `C:\alfa-ai-worker`  | `C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-b\logs\run-gaming-worker-b-<UTC>.log` |
| `gaming-c`  gaming-worker-c    | `C:\alfa-ai-worker`  | `C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-c\logs\run-gaming-worker-c-<UTC>.log` |
| `gaming-a` gaming-worker-a  | `C:\alfa-ai-worker`  | `C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-a\logs\run-gaming-worker-a-<UTC>.log` |

### build-start-*.ps1 (remote-building workers — auto SCP to `inference`)

`build-start-gaming-worker-a-219.ps1`, `build-start-gaming-worker-c-59.ps1`, and
`build-start-gaming-worker-b-249.ps1` write:

`deploy\cluster-members\<member>\logs\build-start-<UTC>.log`

Then upload that transcript **and** `alfa-docker-<hostname>-*.log` to:

`operator@orchestrator:/home/operator/alfa-ai/logs/cluster-docker/`

via `_common\send-build-logs-to-148.ps1`. Operators in another building should
**not** paste logs into chat — confirm the script prints
`Analysis dir on inference` and inspect the files on the hub (or via SSH from `orchestrator`).

The final two lines of every run print:

```
[INFO ] Full transcript: <absolute path>
[WARN ] Paste the transcript into chat so we can diagnose.   # only on FAIL
```

### How to paste a log back

Windows (admin PowerShell on the affected worker):

```powershell
# Grab the newest run log and paste its contents into the chat.
Get-ChildItem "$PWD\deploy\cluster-members\<member>\logs" -Filter 'run-*.log' |
    Sort-Object LastWriteTime -Descending |
    Select-Object -First 1 |
    Get-Content
```

### Reading a heartbeat line

- `[BEAT ] still running: docker load <tar> (elapsed 45s, no hang)` every 15s
  = the tarball is being decompressed; expect 60–900s on first load.
- `[BEAT ] still running: docker build <file> (elapsed 180s, no hang)` every 15s
  = image build in progress; `--progress=plain` output is streaming above.
- If you stop seeing BEAT lines AND no regular stdout for more than a minute,
  that is a real hang — capture the log and a `docker info` + `wsl --status`.

### If the run is failing

On `FAIL`, the orchestrator prints:

```
[ERROR] UNHANDLED EXCEPTION in phase: <phase name>
<exception message>
---- Stack trace ----
...
---- /Stack trace ---
```

Then the `RUN SUMMARY` shows exactly which phase failed and how long each
phase took before it died. Paste the full `run-*-<UTC>.log` — that file alone
is enough to diagnose 99 % of worker failures.


## 1) Pull latest on each host

- `hub` hub: repo at `/mnt/HDDs/Alfa-AI/repo/alfa-ai`
- `apps` Ubuntu: repo at `/home/operator/alfa-ai`
- `orchestrator` Win11: repo at `C:/Users/operator\alfa-ai`
- `gaming-b/gaming-c/gaming-a` workers: repo at `C:\alfa-ai-worker`

## 2) Run one logging script per host

### Linux / hub

```bash
# hub
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/run-aria2-bootstrap-with-log.sh

# apps
bash /home/operator/alfa-ai/deploy/cluster-members/apps/run-aria2-bootstrap-with-log.sh
```

### Windows (PowerShell)

```powershell
# orchestrator
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\run-aria2-bootstrap-with-log.ps1

# gaming-b
powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-b\run-aria2-bootstrap-with-log.ps1

# gaming-c
powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-c\run-aria2-bootstrap-with-log.ps1

# gaming-a
powershell -ExecutionPolicy Bypass -File C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-a\run-aria2-bootstrap-with-log.ps1
```

Each script prints `LOG FILE: ...` at the end.

## 3) Commit + push logs from each host (if errors)

```bash
# Linux hosts
cd <repo-root>
git pull --rebase origin main
git add deploy/cluster-members/<host-folder>/logs/*.log
git commit -m "logs: <host> aria2 bootstrap <YYYY-MM-DD HH:MM>"
git push origin main
```

```powershell
# Windows hosts
cd <repo-root>
git pull --rebase origin main
git add deploy/cluster-members/<host-folder>/logs/*.log
git commit -m "logs: <host> aria2 bootstrap $(Get-Date -Format 'yyyy-MM-dd HH:mm')"
git push origin main
```

## 4) Docker container logs → `inference` hub (alfa-ai / Petals stack)

Script: **`scripts/collect-alfa-docker-logs-to-148.sh`** (Linux, hub, Git Bash on Windows).

If `git pull` says up to date but the script is missing, restore it (local delete does not come back from pull):

```bash
git restore scripts/collect-alfa-docker-logs-to-148.sh
```

### Linux / hub (bash)

```bash
cd /path/to/alfa-ai    # hub: /mnt/HDDs/Alfa-AI/repo/alfa-ai  |  apps: /home/operator/alfa-ai
git pull --ff-only origin main
git restore scripts/collect-alfa-docker-logs-to-148.sh   # only if "No such file"
SCP_TO_BUILD_HOST=1 bash scripts/collect-alfa-docker-logs-to-148.sh
```

Local-only (no SCP): `bash scripts/collect-alfa-docker-logs-to-148.sh`

### Windows (PowerShell on `orchestrator` / workers)

Use **PowerShell paths** (`C:/Users/operator\alfa-ai`), not `/c/Users/...` (that is Git Bash syntax).

```powershell
cd C:/Users/operator\alfa-ai
git pull --ff-only origin main
git restore scripts/collect-alfa-docker-logs-to-148.sh
.\scripts\collect-alfa-docker-logs-to-148.ps1
```

`-NoScp` keeps the log under `logs\cluster-docker\` on that PC only.

Destination on `inference`: `/home/operator/alfa-ai/logs/cluster-docker/alfa-docker-<hostname>-<timestamp>.log`

Requires SSH from the source host to `operator@orchestrator` when using SCP.

---

## 5) Post-startup status (containers + GPU + Petals + anti-bloat)

After bringing a host online (or after WSL Docker migration), run the **profile**
script — it writes a timestamped log and optionally **SCP**s to `inference`.

Destination on `inference`: `/home/operator/alfa-ai/logs/cluster-status/`

### Linux / hub

```bash
# hub
SCP_TO_BUILD_HOST=1 bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/run-post-startup-status-with-log.sh

# apps
bash /home/operator/alfa-ai/deploy/cluster-members/apps/run-post-startup-status-with-log.sh
```

### Windows (WSL Docker Engine)

Use **`-WarmUpSec 180`** after cold start so the throughput benchmark can finish
inside one WSL session (do not use PowerShell `Start-Sleep` then a separate `wsl` call).

```powershell
# Unified wrapper (all Windows profiles)
powershell -ExecutionPolicy Bypass -File `
  C:\Users\YOURUSER\alfa-ai\deploy\cluster-members\_common\run-post-startup-status-with-log.ps1 `
  -HostProfile operator-93 -WarmUpSec 180

# Other profiles: gaming-worker-a-219 | gaming-worker-b-249 | gaming-worker-c-59 | ai-148
```

`-NoScp` keeps the log local only.

Core checker: `scripts/cluster-post-startup-status.sh` (`HOST_PROFILE=…`).

Checklists: [WINDOWS_WSL_ROLLOUT_CHECKLIST.md](../../docs/WINDOWS_WSL_ROLLOUT_CHECKLIST.md),
[WINDOWS_WSL_DOCKER_ENGINE.md](../../docs/WINDOWS_WSL_DOCKER_ENGINE.md).

---

## 6) inference start/stop error capture → `orchestrator` (automatic)

Built into **Start-Stop-AlfaAi.ps1** / **Invoke-AlfaAiCluster.ps1** — no extra step
required. Background recorders on `orchestrator`/`inference`/`apps`/`hub` capture **errors only**
(filtered docker logs, die/oom events, TCP probe failures). Files land on `orchestrator` at:

`C:/Users/operator\alfa-ai\logs\inference-sessions\<session>-start|stop\inference-<host>-errors.log`

```powershell
cd C:/Users/operator\alfa-ai\logs\inference-sessions\<session>
Get-Content inference-*-errors.log
```

Backup pull if a host file is missing:

```powershell
wsl.exe -d Ubuntu bash -lc "cd /mnt/c/Users/operator/alfa-ai && bash deploy/cluster-members/_common/fetch-inference-session-to-93.sh <session>"
```

---

## 7) Analyze centrally on `inference` hub (aria2 / docker dumps)

```bash
cd /home/operator/alfa-ai
git pull --ff-only origin main
rg "ERROR|Exception|failed|Traceback|aria2" deploy/cluster-members/*/logs/*.log
rg "ERROR|Exception|failed|Traceback" logs/cluster-docker/*.log
rg "FAIL|WARN|RESULT" logs/cluster-status/*.log
```
