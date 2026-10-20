# Setup Commands (Copy/Paste)

This file is the operator copy/paste guide for aria2/bootstrap rollout across
hosts. Commands are grouped by the terminal they must run in.

---

## 0) Pull latest repo first

### `hub` (hub shell / bash)

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
git pull --ff-only origin main
```

### `apps` (Ubuntu shell / bash)

```bash
cd /home/operator/alfa-ai
git pull --ff-only origin main
```

### `orchestrator` (PowerShell)

```powershell
cd C:/Users/operator\alfa-ai
git pull --ff-only origin main
```

---

## 1) `orchestrator` stage cluster members to SMB (**canonical** — includes `_common\repo`)

Run on `orchestrator` PowerShell after **`git pull`**:

```powershell
cd C:/Users/operator\alfa-ai
.\scripts\stage-cluster-members.ps1
```

Blackwell **`deploy.ps1`** on `gaming-b`/`gaming-c`/`gaming-a` requires **`\\hub\temp\cluster_members\_common\repo\`** ( **`deploy\`** + **`scripts\`** mirrored from `orchestrator` ). This script creates it.

### Supplemental: thin mirror of three member folders only

```powershell
powershell -ExecutionPolicy Bypass -File C:/Users/operator\alfa-ai\deploy\cluster-members\orchestrator\publish-host-folders-to-smb.ps1
```

Updates only **`gaming-worker-b-249`**, **`gaming-worker-c-59`**, **`gaming-worker-a-219`** under **`\\hub\temp\cluster_members\`**. Does **not** refresh **`_common\repo`**. Use **after** a full **`stage-cluster-members.ps1`** when you need a quick member-folder refresh.

---

## 2) `hub` bootstrap with log capture

Run on `hub` bash:

```bash
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/run-aria2-bootstrap-with-log.sh
```

---

## 3) `apps` bootstrap with log capture

Run on `apps` bash:

```bash
bash /home/operator/alfa-ai/deploy/cluster-members/apps/run-aria2-bootstrap-with-log.sh
```

---

## 4) Worker first-run (`gaming-b`, `gaming-c`, `gaming-a`) — SMB-first paths

Petals + Dockge **preferred:** run **`deploy.ps1` from UNC** (Administrator PowerShell)
after **step 1** above — see [FIRST_RUN_WORKERS_FROM_93.md](FIRST_RUN_WORKERS_FROM_93.md).

### A) Optional — aria2 bootstrap (invoke from SMB)

#### `gaming-b`

```powershell
powershell -ExecutionPolicy Bypass -File \\hub\temp\cluster_members\gaming-worker-b-249\run-aria2-bootstrap-with-log.ps1
```

#### `gaming-c`

```powershell
powershell -ExecutionPolicy Bypass -File \\hub\temp\cluster_members\gaming-worker-c-59\run-aria2-bootstrap-with-log.ps1
```

#### `gaming-a`

```powershell
powershell -ExecutionPolicy Bypass -File \\hub\temp\cluster_members\gaming-worker-a-219\run-aria2-bootstrap-with-log.ps1
```

### B) If runner fails — diagnostics (from SMB)

#### `gaming-b`

```powershell
powershell -ExecutionPolicy Bypass -File \\hub\temp\cluster_members\gaming-worker-b-249\run-aria2-runner-diagnostics.ps1
```

#### `gaming-c`

```powershell
powershell -ExecutionPolicy Bypass -File \\hub\temp\cluster_members\gaming-worker-c-59\run-aria2-runner-diagnostics.ps1
```

#### `gaming-a`

```powershell
powershell -ExecutionPolicy Bypass -File \\hub\temp\cluster_members\gaming-worker-a-219\run-aria2-runner-diagnostics.ps1
```

### C) Optional — copy member folder local (UNC blocked / dev checkout)

Only if you cannot execute scripts from **`\\hub\temp\...`**:

```powershell
robocopy \\hub\temp\cluster_members\gaming-worker-b-249 C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-b /E
robocopy \\hub\temp\cluster_members\gaming-worker-c-59 C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-c /E
robocopy \\hub\temp\cluster_members\gaming-worker-a-219 C:\alfa-ai-worker\deploy\cluster-members\gaming-worker-a /E
```

Then run **`git-install-repo.ps1`** / bootstrap / **`deploy.ps1`** from **`C:\alfa-ai-worker\...`** per [FIRST_RUN_WORKERS_FROM_93.md](FIRST_RUN_WORKERS_FROM_93.md).

---

## 5) Analyze all logs centrally on `inference` hub

Run on `inference` bash:

```bash
cd /home/operator/alfa-ai
git pull --ff-only origin main
rg "ERROR|Exception|failed|Traceback|aria2" deploy/cluster-members/*/logs/*.log
rg "ERROR|Exception|failed|Traceback" logs/cluster-docker/*.log
rg "FAIL|WARN|RESULT" logs/cluster-status/*.log
```

## 6) If logs need to be committed from each host

### Linux host (`hub` / `apps`)

```bash
cd <repo-root>
git pull --rebase origin main
git add deploy/cluster-members/<host-folder>/logs/*.log
git commit -m "logs: <host-folder> aria2 bootstrap $(date +%F-%H%M)"
git push origin main
```

### Windows host (`orchestrator` / `gaming-b` / `gaming-c` / `gaming-a`)

```powershell
cd <repo-root>
git pull --rebase origin main
git add deploy/cluster-members/<host-folder>/logs/*.log
git commit -m "logs: <host-folder> aria2 bootstrap $(Get-Date -Format 'yyyy-MM-dd-HHmm')"
git push origin main
```

---

## Notes

- `hub` is the brain/hub.
- `orchestrator` is the Windows control box used to run **`scripts\stage-cluster-members.ps1`** (full SMB tree including **`_common\repo`**).
- PowerShell 5.1 does **not** support `&&`; use one command per line.
