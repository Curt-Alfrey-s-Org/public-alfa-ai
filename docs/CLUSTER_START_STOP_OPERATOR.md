# ALFa AI inference — full cluster start/stop (single operator path)

**Do not** run piecemeal deploy scripts (`deploy-grev27-pool-shard`, `switch-pool-27b.sh`,
`deploy-grev27-pool-coordinator.sh`, etc.) during routine bring-up or tear-down. Those are
for **first-time setup or repair** only. Routine ops use **one start** and **one stop** from
`orchestrator` only (`hub` steps are fully automated via **direct SSH** from `orchestrator` using `id_ed25519_93_111`).

Partial deploys leave the pool in inconsistent state (coordinator `/health` 200 while GPU
shards are down, contracts-bot **degraded**, LiteLLM connection errors).

**Exception (narrow):** admin **inference <-> pool35 swap** from the chat picker when shards are
already healthy is documented in [POOL_SWITCH_OPERATOR.md](POOL_SWITCH_OPERATOR.md). That path
does **not** replace this full start/stop orchestrator. Exclusive **Qwen2.5-72B** chat uses the
same orchestrator with **`-InferenceMode Pool72`** (full mesh opt-in; uses
`pool72-shards.*.env` dense budgets + default CTX 131072) —
[GREV72_72B_OPERATOR.md](GREV72_72B_OPERATOR.md).

**Agents:** do not run piecemeal deploy or keep-warm to fix cluster errors. Diagnose from
logs, fix code on `apps`, then one full stop + start. See `.cursor/rules/cluster-start-stop-only.mdc`.

---

## Git sync before start (all hosts, all repos)

Every host must be on `origin/main` **before** `Start-Stop-AlfaAi.ps1 start`. The orchestrator
syncs autonomous hosts in preflight; `hub` syncs inside `operator-cluster-111.sh start-pool`.

| Host | Account | Repo path | When |
|------|---------|-----------|------|
| `orchestrator` | `operator` | `C:/Users/operator\alfa-ai` | Orchestrator preflight (or manual `git fetch` + `reset --hard origin/main`) |
| `inference` | `operator` | `~/alfa-ai` | Orchestrator preflight (**cluster hub** — verify, edge) |
| `pool-opt-in` | `operator` | `~/alfa-ai` | Orchestrator preflight (inference shard `:31354`) |
| `secondary` | `operator` | `~/alfa-ai` | Orchestrator preflight + shard deploy/stop (`:31355`; GTX 1070) |
| `rag` | `operator` | `~/alfa-ai` | Orchestrator git sync + RAG start/stop (production CPU embed/rerank since 2026-07-18) |
| `hub` | `operator` | `/mnt/HDDs/Alfa-AI/repo/alfa-ai` | Direct SSH from `orchestrator`; `git fetch` + `reset --hard origin/main` inside `operator-cluster-111.sh` unless `--SkipPull` |

After a push from `apps`, consumers must sync before start ([cluster-sync-order.mdc](../.cursor/rules/cluster-sync-order.mdc)).

**LAN island / no GitHub DNS:** When **`orchestrator`** is unreachable from `hub`/`inference`/`pool-opt-in` but NFS hub works, use hub **`file://`** remotes and `deploy/cluster-members/_common/sync-git-origin-hub-lan.sh`. Full runbook: [LAN_ISLAND_GATEWAY_OUTAGE.md](LAN_ISLAND_GATEWAY_OUTAGE.md). The orchestrator invokes that script on `inference`/`pool-opt-in`/`secondary`; **stop** treats remaining git failures as **non-fatal**.

**Prerequisite (one-time on `hub`):** grant `operator` the extended `sudo_commands_nopasswd`
allowlist in [POOL_SWITCH_OPERATOR.md](POOL_SWITCH_OPERATOR.md) (operator action **A11**). Without
it, automated `hub` steps fail with `sudo: a password is required`.

### Git sync is self-healing and never blocks a stop

`operator-cluster-111.sh` git-syncs before pool/brain steps. Two safeguards keep it
from wedging the cluster:

- **aria2 config ownership** — the `p3terx/aria2-pro` container runs as root and
  rewrites its bind-mounted `deploy/aria2/config/` tree. Before `git reset --hard`,
  the script restores that path to `operator` so the reset never fails with
  `unable to unlink ...: Permission denied`. The config tree is git-ignored runtime
  (template in `deploy/aria2/config.example/`); see [aria2/README.md](../deploy/aria2/README.md).
- **stop is resilient** — a git-sync failure during `stop` is downgraded to a
  warning; teardown always proceeds. `start` still hard-fails on sync errors so the
  pool never comes up on stale code. Remote sync uses
  [`sync-git-origin-hub-lan.sh`](../deploy/cluster-members/_common/sync-git-origin-hub-lan.sh)
  (GitHub first, then hub `file://` on LAN). See [LAN_ISLAND_GATEWAY_OUTAGE.md](LAN_ISLAND_GATEWAY_OUTAGE.md).

If a stop/start ever fails at the `hub` git sync with `Permission denied`, run the
one-time recovery from the repo root on `hub`:

```bash
sudo chown -R "$(id -un)":"$(id -gn)" deploy/aria2/config
git fetch origin main && git reset --hard origin/main
```

---

## Startup order (orchestrator — probes only after each step)

```
tails open
  -> opt-in prompts (gaming-a/gaming-c/gaming-b/secondary/pool-opt-in for inference)  [first; writes active shard list]
  -> required-host TCP :22 (inference/hub/rag; opted-in shards)  [fail-fast]
  -> cluster-must-be-stopped (core)  [brain/LiteLLM/:31360/RAG; fail-fast before leftover]
  -> leftover stop gaming-a/gaming-c/gaming-b   [inference only; coordinator already down; non-fatal if offline]
  -> cluster-must-be-stopped (shards)  [active-list RPC closed, incl. gaming-a WSL probe]
  -> local Docker/WSL + Hyper-V firewall (orchestrator :31350)  [fail-fast before STEP 0]
  -> STEP 0 error capture
  -> preflight + git sync (orchestrator, inference hub; pool-opt-in/secondary/rag only if needed)
  -> Ask ALFa host-actions key on hub (scp from orchestrator seed if missing)
  -> RPC image/tarball deps (all opted-in shards + hub; fail-fast)
  -> orchestrator shard :31350          [wait TCP in deploy script]
  -> stagger 30s               [inference_SHARD_STAGGER_SEC — RPC wedge mitigation]
  -> inference shard :31356 (3060)  [then stagger 20s, then :31357 5060]
  -> secondary shard :31355 (1070)   [opt-in; cuda128-pascal; SSH from orchestrator]
  -> pool-opt-in shard :31354         [opt-in; 1660 Super]
  -> verify remote shards      [from inference hub; --remote-only skips hub]
  -> hub start-pool (automated) [switch-pool-27b + 3050 shard :31353 + CPU coordinator :31360]
  -> verify hub coordinator :31360 [wait /health up to 900s]
  -> real-decode self-test gate [before LiteLLM; fail -> ordered recovery incl. gaming hosts]
  -> RAG rag CPU embed :11435 + rerank :8360 [both mandatory; local cache under ~/alfa-ai-cache/rag]
  -> verify RAG (embed + rerank)  [from inference hub]
  -> hub start-brain (automated) [LiteLLM only after pool proven]
  -> Ask ALFa host-actions key on hub again (after start-pool git clean)
  -> verify shards again       [from inference; fail start if any shard down]
  -> inference edge :8420           [wait /health]   (protected; not part of cluster stop)
  -> post-start HTTP verify (coordinator, embed, rerank, brain, LiteLLM, alfa-ai website login)
  -> monitor incident-metrics bearer refresh (same script as 2h cron; no Prometheus restart)
  -> verify shards + keep-warm
```

**Local-first artifacts (warm start):** RPC image skip-if-loaded on every host;
`hub` GGUF + RPC tarball on `/mnt/ssd`; RAG trees on `rag` local disk (not NFS).
Hub is seed-only — see [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md) § Local-first start.

**Naming (do not confuse repos):**

- **alfa-ai website** = the `/alfa-ai` console/login SPA in **this repo** (`alfa-ai-api` + `alfa-ai-nginx`), reached via `inference:8420/alfa-ai/login` or `www.example.com/alfa-ai/...`. Started by `start-brain` + edge proxy; hard-gated in post-start verify.
- **alfaqd-website** = separate repo for the **main domain** WordPress/nginx edge. Cluster start/stop **never** deploys or stops it.

**RAG mandatory:** embed + rerank on **`rag` CPU** are hard requirements (same tier as inference shards). `inference` RAG retired 2026-07-18. `pool-opt-in` is shard-only (`:31354`).

**Protected stacks:** postgres/redis on `apps`/`hub` (apps host — not cluster-managed); `alfa-ai-edge-api` on **`inference`** (hub). Orchestrator never stops them. Bring edge up via `start-edge-api.sh` on `inference` if needed before start.

**503 from LiteLLM during start:** LiteLLM on `hub` must not probe `frontier-code` while the
coordinator is loading (llama-server returns **503** until `/health` is 200 — official
[tools/server/README.md](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)).
`scripts/start.sh` waits up to **900s** on coordinator `/health` **before** bringing up LiteLLM.
`litellm_config.inference.yaml` sets `background_health_checks: false` (LiteLLM official default).

**No mid-start restarts:** the orchestrator does **not** redeploy `hub` coordinator or restart
`hub` shard after brain start. If verify fails, fix code and run **full stop + start**.

**`not reachable` during start:** the previous step has not finished listening yet, or a host
firewall blocks LAN TCP (`orchestrator` WSL Hyper-V rules for `:31350`). If the **full** cycle ends with
FAIL, run **stop** then **start** — do not redeploy one host alone.

**`Client connection closed` in rpc-server logs:** coordinator connecting to shards during model
load; normal while cold-starting. Not a signal to probe earlier.

**No GPU CPU fallback:** inference GPU shards (rpc-server on `orchestrator`/`hub`/`inference`) **must** show CUDA
in container logs. Deploy scripts call `assert-rpc-server-cuda.sh` and **fail** if llama.cpp would
run CPU-only. The `hub` CPU **coordinator** (`:31360`) is intentional orchestration, not a shard
fallback. LiteLLM model routing fallbacks for inference are disabled in `litellm_config.inference.yaml`
(only explicit 27B/35B model policy applies outside inference mode).

---

## Host reachability and local fail-fast (before STEP 0)

After gaming-host opt-in writes `inference-shards.active.env`, **start** runs these
**before** STEP 0 error capture:

1. **Required hosts TCP `:22`** — always `inference`, `hub`, **`rag` (RAG)**; plus
   opted-in `pool-opt-in` / `secondary` / `gaming-a` / `gaming-c` / `gaming-b` (inference); not required for core green.
   All failures listed in one throw.
2. **Cluster must be stopped (core first)** — refuse start if coordinator `:31360` /
   brain / LiteLLM / RAG still listening. Then leftover-stop `gaming-a`/`gaming-c`/`gaming-b`
   (keyed SSH; skip `gaming-a` when `INCLUDE_219=1`; skip `gaming-c`/`gaming-b` while
   `alfa-train.lock` exists). Then refuse start if any **active
   shard** RPC is still up. Never leftover-stop a shard while `:31360` is up.
3. **Local `orchestrator`** — WSL VM probe + auto `wsl --shutdown` recovery
   (`Invoke-AlfaWslBash.ps1`), then `preflight-docker-engine.sh` + Hyper-V
   firewall rule for `:31350`. See [WINDOWS_WSL_DOCKER_ENGINE.md](WINDOWS_WSL_DOCKER_ENGINE.md)
   (Orchestrator WSL recovery).

After git sync (preflight start-only), **Ask ALFa host-actions SSH key** is
checked on `hub`. If `deploy/secrets/host-actions/id_ed25519` or `known_hosts`
is missing or empty there, the orchestrator copies the gitignored seed from
`orchestrator` (`C:/Users/operator\alfa-ai\deploy\secrets\host-actions\`) via `scp`
([OpenSSH scp](https://man.openbsd.org/scp.1)) and `chmod 600` on the private
key ([POSIX chmod](https://pubs.opengroup.org/onlinepubs/9699919799/utilities/chmod.html)).
If the seed is also missing on `orchestrator`, start continues with a WARN (inference
still comes up; Ask ALFa inspect stays blocked). The same check runs again
after `hub start-brain` so `git clean -fd` in `start-pool` cannot leave the
API mount empty. See [ADMIN_AI_HOST_ACTIONS.md](ADMIN_AI_HOST_ACTIONS.md).

After post-start HTTP verify (brain `:8420/health` green), the orchestrator
SSHs from `orchestrator` to `monitor` (`id_ed25519_93_107`,
[OpenSSH BatchMode](https://man.openbsd.org/ssh_config.5)) and runs
`bash /home/operator/monitoring/scripts/refresh-alfa-ai-prometheus-bearer.sh`.
That closes the gap when the cluster was stopped longer than the **5h** admin
access-token TTL while the 2h cron on `monitor` skipped (brain down). Missing
key, `monitor` down, or refresh failure is a **WARN** -- pool start still
succeeds. **Do not restart Prometheus** after a bearer write:
`authorization.credentials_file` is read on each scrape
([Prometheus `<http_config>`](https://prometheus.io/docs/prometheus/latest/configuration/configuration/#http_config)).
Dead refresh token: Path A/B in [ALFA_AI_OPERATIONAL_ALERTS.md](ALFA_AI_OPERATIONAL_ALERTS.md).

After git sync (preflight start-only), **RPC image dependencies** run on every
opted-in shard host **before** any shard deploy:

4. **RPC image / hub tarball** — each active shard must have `alfa-llamacpp-rpc:cuda128`
   already loaded **or** hub tarball `alfa-llamacpp-rpc-cuda128-b10355.tar.gz` on a
   documented path (`<Get-AlfaWindowsCacheRoot>\docker-images` on Windows via
   `Get-AlfaWindowsCacheRoot.ps1`, `\\hub\docker-images`,
   Linux `/mnt/cluster/docker-images`, etc.). Always includes **`orchestrator` / `inference` / `hub`**
   plus opted-in shards. **Pool80** sets `FORCE_HUB_RPC_LOAD=1`
   (tarball required even when an old image exists). **`secondary`** uses the pascal twin
   `alfa-llamacpp-rpc-cuda128-pascal-b10355.tar.gz`. All missing hosts are listed in
   one throw (no partial shard deploy). Gaming fix:
   `Prep-GamingHostinferenceReady.ps1 -LoadImage` on that PC, or copy from hub SMB.

Power on / fix SSH for down hosts, or re-run start and answer **N** / omit `-Include*`
for that host. If ports are still busy, run **stop** first. If firewall is missing,
run the printed `operator` Admin one-liner once.

Stop still treats unreachable `secondary` / `pool-opt-in` as optional WARN when not required.

## STEP 0 — Error capture

Every `Start-Stop-AlfaAi.ps1` cycle runs **STEP 0: inference error capture** after
gaming opt-in (and, on **start**, after the fail-fast checks above):

1. **`orchestrator`** — starts WSL background recorder automatically  
2. **`inference` / `pool-opt-in`** — starts background recorders via SSH (git pull or scp scripts from `orchestrator`)  
3. **`secondary`** — same SSH recorder **only when** `orchestrator` is in `inference-shards.active.env` (opted in). Skip when the box is not in this start.  
4. **`hub`** — orchestrator runs `operator-cluster-111.sh start-error-logs` via direct `orchestrator` SSH (same session id as `orchestrator`)

**Timeouts (do not hang the GUI):** OpenSSH `ConnectTimeout` covers TCP connect and
KEX only ([ssh_config.5](https://man.openbsd.org/ssh_config.5)), not a live
`test -f` / `git fetch` stuck on remote disk. Recorders are **best-effort**:
`Invoke-inferenceLogSsh` uses a **local** `Process.WaitForExit` deadline then
`Process.Kill` ([WaitForExit(Int32)](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.waitforexit);
[Process.Kill](https://learn.microsoft.com/en-us/dotnet/api/system.diagnostics.process.kill)).
`Wait-Process -Timeout` does **not** kill
([Wait-Process](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.management/wait-process)).
Default command cap is **20s** (`test -f`); git sync uses **90s**. A WARN on
`secondary` must not block stop. If Models GUI stays on `Running stop...` after
`OK pool-opt-in error recorder started`, the next host is `secondary` script existence check.

Recorders collect **errors only** until **CLUSTER … COMPLETE**, then `orchestrator` gathers files into:

`C:/Users/operator\alfa-ai\logs\inference-sessions\<session>-start|stop\inference-<host>-errors.log`

**Analysis on `orchestrator`:**

```powershell
cd C:/Users/operator\alfa-ai\logs\inference-sessions\<session>
Get-Content inference-*-errors.log
```

---

## Desktop shortcuts on `orchestrator` (optional)

Two Desktop icons open **separate WinForms panels** on `orchestrator`:

| Shortcut | Script | Title bar |
|----------|--------|-----------|
| **ALFa Models** | `models-desktop-menu.ps1` | `ALFa Models r4` |
| **ALFa Trainer 7B** | `train-desktop-menu.ps1` | `ALFa Trainer 7B r5` |

**ALFa Models** wraps the same orchestrator (`Start-Stop-AlfaAi.ps1`) for inference
only. **ALFa Trainer 7B r5** runs 7B QLoRA DDP on the train island only
([TRAIN_7B_QLORA_GUI.md](operations/TRAIN_7B_QLORA_GUI.md)). Both windows may stay
open. **Start/Stop is serialized:** `deploy/llamacpp-rpc/alfa-desktop-job.lock`
([FileMode.CreateNew](https://learn.microsoft.com/en-us/dotnet/api/system.io.filemode))
so Models Start/Stop cluster cannot run at the same time as Trainer Start/Stop
(CLI of those scripts uses the same lock). Each GUI greys its Start/Stop while
that file is live (the child launcher PID owns it, not the WinForms process).
Failed Trainer Start runs nested Stop with `ALFA_DESKTOP_JOB_NEST=1` so cleanup
does not deadlock on the parent lock. After a trainer Start script exits,
containers keep running under `alfa-train.lock` only; inference core Start is still
allowed, but leftover gaming-stop **skips** `gaming-c`/`gaming-b` while that lock exists.

Each script is loaded once by `powershell -File` at launch
([about_PowerShell.exe](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_powershell_exe)).
After editing either menu script, fully close that window and reopen the shortcut
(title bar must show `r4` on Models and `r8` on Trainer). The host-status `GroupBox` does not set `AutoScroll`
-- WinForms GroupBox cannot scroll
([GroupBox](https://learn.microsoft.com/en-us/dotnet/api/system.windows.forms.groupbox)).

### ALFa Models (`models-desktop-menu.ps1`)

| UI | Behavior |
|----|----------|
| **Model** | Radio: inference (3.8 production), Pool72 (exclusive 72B Q5), or Pool80 (exclusive 80B Q5) |
| **Opt-in hosts** | **inference:** checkboxes `gaming-a` / `gaming-c` / `gaming-b` / `secondary` / `pool-opt-in` (never required for core green). **Pool72/Pool80:** same mesh hosts; core `inference`/`orchestrator`/`hub`/`rag` always on |
| **Run settings** | **Context** and **Parallel** before Start. inference defaults are **`262144`** and **`5`**: Qwen3.8 native context ([model card](https://huggingface.co/Qwen/Qwen3.8-27B)), split across 5 slots (2 user + 3 automated, 52428 tokens each). Do not raise context without YaRN. llama-server's unset parallel becomes 4 ([server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)); 5 is the fitted slot count for this mesh, not a single-GPU `--parallel 1`. Pool72 and Pool80 defaults stay **`86016`** and **`1`**. Switching the model radio resets the boxes. Start passes them as `CTX_SIZE` and `PARALLEL`. |
| **Status lights** | Inference ports only (SSH + RPC/LiteLLM/brain/RAG). **DN after Stop cluster is expected.** While coordinator `:31360` is UP, shard RPC badges use the active shard list (no TCP probe -- rpc-server is single-client). When coord is down, TCP probes shard ports. Job I/O pulses while log streams. |
| **Stop / Start cluster** | Orchestrator with `-GamingMode Flags` and `-Include*` for checked hosts (one cluster job at a time). **Greyed while** Trainer Start/Stop holds `alfa-desktop-job.lock`. **Start cluster** is **not** greyed out by `alfa-train.lock` alone (job already launched). **Start** first runs `Get-AlfaGuiServicesStillUp` (HTTP/TCP on brain, LiteLLM, coord, RAG, shard ports). It must list **service names** when anything is still up, or a **Confirm start** dialog when the list is empty. Do not treat a dialog that says `System.Object[]` as a real leftover -- that was a PS 5.1 unary-comma wrap (`return ,@($up.ToArray())`) plus `-f` on an array ([about_Operators comma / `-f`](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_operators?view=powershell-5.1); [.NET composite formatting](https://learn.microsoft.com/en-us/dotnet/standard/base-types/composite-formatting)). `gaming-a :31352` is not LAN-probed here (Win10 portproxy stays listening; orchestrator WSL-probes). |
| **Train lock (Models GUI)** | While `deploy/llamacpp-rpc/alfa-train.lock` exists: Pool72 and Pool80 radios and `gaming-c`/`gaming-b` checkboxes are disabled; `gaming-a` is disabled only when the lock has `INCLUDE_219=1`. Footer status line (full width below the footer buttons) auto-sizes and wraps long train-lock hints so text is never clipped, e.g. `Train lock on: 7B running on gaming-c/gaming-b -- inference core start allowed; Pool72/Pool80 blocked` ([Label.AutoSize](https://learn.microsoft.com/en-us/dotnet/desktop/winforms/controls/autosize-property-overview)). **inference core** Start proceeds after the trainer launcher has exited. Orchestrator `Test-AlfaTrainLockBlocksStart` throws only when Start would place a shard on a train GPU: `-InferenceMode Pool72` or `Pool80`, resolved opt-in `gaming-c` or `gaming-b`, or resolved opt-in `gaming-a` while `INCLUDE_219=1`. inference leftover gaming-stop on `gaming-c`/`gaming-b` is **skipped** while `alfa-train.lock` exists (same GPU Docker as Axolotl). `gaming-a` leftover stop still skipped when `INCLUDE_219=1`. |
| **Show terminal** | Collapsed by default; expand to stream orchestrator stdout/stderr in-panel. Closing the GUI while a cluster job runs: **Yes** kills it, **No** leaves it running, **Cancel** stays open. If the window is frozen, Task Manager end `models-desktop-menu` / that `powershell.exe` -- inference and trainer containers stay up. |
| **Refresh** | Inference light sweep (does not SSH to train hosts). |
| **inference metrics** | Opens Grafana inference inference on `monitor` (same URL as `ALFa inference metrics.url`). |


### Verify RAG / embed (same checks as the lights)

Canonical RAG lives on **`rag`** (CPU). Production start verifies both:

| Service | URL (from LAN / `orchestrator`) |
|---------|-------------------------|
| **Embed** | `http://orchestrator/api/tags` |
| **Rerank** | `http://orchestrator/health` |

Desktop **ALFa Models** **Hosts / SSH / network I/O** matrix also shows:

| Host | SSH | Network I/O |
|------|-----|------------|
| `orchestrator` | local | `:31350` |
| `rag` | `:22` | embed + rerank HTTP |
| `hub` | `:22` | coord `:31360`, shard `:31353`, LiteLLM `:8413`, brain `:8420` |
| `inference` | `:22` | `:31356` + `:31357` |
| `pool-opt-in` / `gaming-a` / `gaming-c` / `gaming-b` / `secondary` | `:22` | shard RPC ports |
| Job I/O | -- | green while log stream is active |

When **coord is UP**, shard RPC cells show **UP** if that host:port is in
`inference-shards.active.env` (mesh membership) -- they are **not** TCP-probed
(rpc-server is single-client; a probe is a false **DN** and can disrupt the
pool). When coord is **DN**, the GUI TCP-probes shard ports again.

Orchestrator path: `verify-rag-sidecars.sh` after RAG start (see post-start verify in
`Invoke-AlfaAiCluster.ps1`). Manual from `orchestrator`:

```powershell
curl.exe -fsS --max-time 15 http://orchestrator/api/tags
curl.exe -fsS --max-time 15 http://orchestrator/health
```

Also green in a healthy start: coordinator `http://hub/health`,
LiteLLM `:8413/health/liveliness`, brain `:8420/health`. Chat picker labels come
from the brain API image (`GET /api/health` `build_hash`). `start-brain` must
`compose up` the same `BUILD_HASH` tag it built -- a `local` stamp means the SPA
is stale even when inference loaded Qwen3.8. Fix without touching shards:
`bash scripts/brain_redeploy_api.sh` on `hub` ([MODEL_CONFIG_DRIFT_PREVENTION.md](MODEL_CONFIG_DRIFT_PREVENTION.md)).
That script does **not** need a full cluster start first. It requires Docker plus dedicated
postgres/redis (protected; left up by cluster stop). It starts/recreates brain API/LiteLLM/nginx.

Start builds: `start -InferenceMode inference|Pool72|Pool80 -GamingMode Flags [-Include59 …]`.
Normal **inference** loads **Qwen3.8-27B Q8_0** (`ALFA_inference_FAMILY=qwen38` default).
Rollback to 3.6: set `inference_MODEL_FILE=Qwen3.6-27B-Q8_0.gguf` and
`ALFA_inference_FAMILY=qwen36` in brain `deploy/.env` before start (hub rollback only;
**`inference_38` test mode retired**).
Stop runs `stop` (membership comes from last active shard list).

**One-time install (as `operator` on `orchestrator`):**

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\install-cluster-desktop-shortcut.ps1
```

Creates **`ALFa Models.lnk`** -> `models-desktop-menu.ps1` and
**`ALFa Trainer 7B.lnk`** -> `train-desktop-menu.ps1` on the Desktop
(title **ALFa Trainer 7B r5**)
(WScript.Shell [CreateShortcut](https://learn.microsoft.com/en-us/previous-versions/xsy6k3ys(v=vs.85));
both use `powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File ...`).
Removes legacy **`ALFa Cluster Start-Stop.lnk`** and **`ALFa Trainer 14B.lnk`**
if present. Also creates
**`ALFa inference metrics.url`** (Internet Shortcut to Grafana **inference inference**
on `monitor`; [inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md)). This is **not**
the gaming-only **ALFa Gaming Mode** icon (`install-gaming-desktop-shortcut.ps1` in
`operator-93`, `gaming-worker-a-219`, `gaming-worker-c-59`, `gaming-worker-b-249`;
[inference_GAMING_HOST_JOIN.md](inference_GAMING_HOST_JOIN.md) Desktop shortcut).

Re-run the install script once after `git pull` to refresh shortcuts / remove the legacy `.lnk`.

---

## Stop (full cycle)

**From `orchestrator` (PowerShell as `operator`):**

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 stop
```

The orchestrator runs STEP 0 (error recorders on all hosts) and `hub stop` automatically.
No manual `hub` paste blocks or Enter gates.

**Protected infrastructure (never downed by cluster stop):**
- Dedicated Postgres/Redis stacks (`postgres` / `redis` projects on `hub` and `apps`).
- `inference` `alfa-ai-edge-api` (edge proxy for  admin and `/alfa-ai/*`).

**Stopped by cluster stop (inference + RAG + brain app):**
- inference shards/coordinator on **every host in `inference-shards.active.env`** (core + opted-in gaming, including `gaming-a`)
- Brain app on `hub` (LiteLLM, API, nginx — not postgres/redis)
- **RAG sidecars:** embed + rerank on `rag` CPU (`:11435` + `:8360`; **both mandatory**); legacy `inference`/`pool-opt-in`/`hub`/`.147` RAG stopped if present

Canonical placement: `deploy/cluster-members/_common/rag-sidecars.env`

**Stop must leave a clean slate:** post-stop verify uses the **active** shard list (not core-only). Start preflight refuses if any active shard port, coordinator, brain, or RAG is still listening. A failed start does not auto-clean; **run stop** (it is the cleanup). Do not treat "half-up" as normal — that means stop/verify did not finish or was skipped.

**Stop SSH reachability (`gaming-a` / `gaming-c` / `gaming-b`):** Stop preflight must use the
same dedicated keys as Start deploy: `id_ed25519_93_219`, `id_ed25519_93_59`,
`id_ed25519_93_249` with `ssh -i` and `-o BatchMode=yes`
([ssh.1](https://man.openbsd.org/ssh.1),
[ssh_config IdentityFile](https://man.openbsd.org/ssh_config)). Bare
`ssh user@host` without `-i` is **not** a valid reachability test on those Windows
gaming hosts (that miss used to skip gaming-worker-a while Start could still see a leftover
container). If TCP `:22` is down **or** keyed BatchMode fails, Stop WARNs and skips
that host (optional opt-in). Fix key auth (`Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).` +
`enable-agent-ssh-from-93.ps1`) when `:22` is up but `-i` BatchMode fails.

**Stop when a inference opt-in host (`gaming-a` / `secondary` / `pool-opt-in`) or Pool72/80 host
(`gaming-c` / `gaming-b` when in active list) is offline:** Stop preflight treats unreachable
TCP `:22` on those hosts as a WARN (not a hard fail). The orchestrator skips git sync
and that host's shard stop when offline or when the host is not in
`inference-shards.active.env` (except inference leftover `gaming-a`/`gaming-c`/`gaming-b` -- see below).
Always-on stop continues for `hub`/`inference`/`orchestrator`/`rag`. Power the box on (or leave
it unchecked at the next start) if you need that shard again.

**Stop when gpu-248 (`secondary`) or VM100 (`pool-opt-in`) is offline or not opted in:** same rule
as other opt-in hosts above.

**inference Stop leftover (`gaming-a` / `gaming-c` / `gaming-b`):** Attempt keyed
`gaming-stop-for-session.ps1` on each reachable gaming host, even when that host is
**not** in the last `inference-shards.active.env` (leftover `llamacpp-rpc*` from a prior
session), except: skip leftover `gaming-a` when `alfa-train.lock` contains `INCLUDE_219=1`;
skip leftover `gaming-c` and `gaming-b` while `alfa-train.lock` exists (do not `docker` on
train GPUs). Never run leftover shard stop while coordinator `:31360` is still up
(rpc-server is single-client). Start preflight runs the same leftover cleanup after
core (brain/LiteLLM/coordinator/RAG) is confirmed down and **before** the
active-shard-port closed assertion -- checking `gaming-a` in ALFa Models at start is
enough; Exited `llamacpp-rpc-server` containers must not require a manual `docker rm`.

**gaming-a / WSL shard stop (Win10 NAT):** Deploy uses Compose project name `llamacpp-rpc` (directory default; [Compose project name](https://docs.docker.com/compose/how-tos/project-name/)). Stop downs that project **and** `alfa-grev27-shard`, sweeps leftover `alfa-llamacpp-rpc` containers, and asserts **WSL** `127.0.0.1:31352` closed (not LAN TCP). Win10 [`netsh` portproxy](https://learn.microsoft.com/en-us/windows/wsl/networking) keeps `orchestrator` listening after the container is gone -- LAN `Test-NetConnection` / hub `nc` would false-fail stop. Hub `verify-inference-stopped.sh` skips `gaming-a`; orchestrator re-checks via keyed SSH + WSL.

**gaming-c / WSL shard stop (Win11 mirrored):** Same SSH path as `gaming-a`: orchestrator runs `gaming-stop-for-session.ps1` on gaming-worker-c via `id_ed25519_93_59`, then asserts WSL `127.0.0.1:31351` closed. Hub `verify-inference-stopped.sh` probes LAN `:31351` (mirrored networking; no portproxy skip).

**gaming-b / WSL shard stop:** Same SSH path via `id_ed25519_93_249` + `gaming-worker-b-249\gaming-stop-for-session.ps1`; asserts WSL `127.0.0.1:31358` closed.

Expected end: `CLUSTER Stop COMPLETE`, **all active** pool ports closed, RAG ports closed. DB + edge remain up.

---

## Start (full cycle)

**From `orchestrator` (PowerShell as `operator`):**

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Start-Stop-AlfaAi.ps1 start
```

The orchestrator runs STEP 0, `hub start-pool`, and `hub start-brain` automatically (live-streamed
output on `orchestrator`; blocks until each subcommand exits). A per-run step ledger is written to
`logs\inference-sessions\<session>\step-ledger.json`.

### inference opt-in shards (`gaming-a` / `gaming-c` / `gaming-b` / `secondary` / `pool-opt-in`)

**inference opt-in:** `gaming-a` / `gaming-c` / `gaming-b` / `secondary` / `pool-opt-in` — never required for core
green (always-on `inference` / `orchestrator` / `hub`). **`gaming-c` / `gaming-b` blocked** while
`deploy/llamacpp-rpc/alfa-train.lock` exists (7B QLoRA train island).

**Pre-flight for gaming hosts:** [inference_GAMING_HOST_JOIN.md](inference_GAMING_HOST_JOIN.md)
documents failures from joining `gaming-a`, `gaming-c`, and `gaming-b` (VRAM / `MAX_MIB`, hub SMB
over OpenSSH, LAN probe host IP, HTTP image load when SMB denied, commit before start
so `git reset --hard` does not wipe fixes). All opt-in hosts deploy via SSH from `orchestrator`
when checked at start.

**gpu-248 (`secondary`) / VM100 (`pool-opt-in`):** same Y/N prompt as gaming hosts. Answer **N** when
the box is powered off, you do not want that shard, **or** gpu-248 is on Wi-Fi
(USB Ethernet unplugged 2026-09-14 -- RTT is a poor RPC path). Prefer USB Ethernet
before answering **Y**. Start does **not** require that host's SSH unless you opted
in. See [DOCKGE_248_OPERATOR.md](DOCKGE_248_OPERATOR.md) and VM100 deploy under
`deploy/cluster-members/pool-shard-opt-in/`.

**Pre-flight `hub` TCP to hub:** if ping to `inference` works but shard verify on
hub fails with `No route to host`, check `ip route get orchestrator` --
`src` must be **`hub`**, not `storage`. Fix: [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md)
(`br1` aliases `hub/24` + `storage/32`).

At the **very beginning** of each start (before error capture / preflight), the
orchestrator asks whether to include each **inference** opt-in host for **this run only**.
Defaults = last answers. Answers write:

| File (gitignored) | Role |
|-------------------|------|
| `deploy/llamacpp-rpc/inference-gaming-selection.env` | Last Y/N answers |
| `deploy/llamacpp-rpc/inference-shards.active.env` | Core shards + opted-in gaming lines |

Catalog: `inference-shards.core.env` (always-on: `inference` / `orchestrator` / `hub`) +
`inference-shards.gaming.env` (inference catalog: `gaming-a` / `gaming-c` / `gaming-b` / `secondary` / `pool-opt-in`).
Committed `inference-shards.env` = core-only fallback.

**Official constraint:** llama.cpp RPC backends are fixed when the coordinator starts
([tools/rpc/README.md](https://github.com/ggml-org/llama.cpp/blob/master/tools/rpc/README.md)).
There is **no** hot-join or hot-leave while the pool is green.

| Goal | Action |
|------|--------|
| Include a inference opt-in host | Answer **Y** at start (auto-deploy via SSH from `orchestrator`) |
| Include `gaming-c`/`gaming-b` while train lock on | **Blocked** — stop trainer first, or omit those hosts |
| Leave host out | `Start-Stop-AlfaAi.ps1 stop`, then `start` and answer **N** for that host |
| Non-interactive | **inference:** `-GamingMode None` (core), `-GamingMode Last`, or `-GamingMode Flags -Include219 -Include59 -Include249 -Include248 -Include100`. **Pool72/80:** same `-Include*` flags with `-InferenceMode Pool72` or `Pool80` |

Local **ALFa Gaming Mode** on `orchestrator` / `gaming-a` / `gaming-c` / `gaming-b` frees GPU/WSL after
the host is **out** of the active pool (or after cluster stop). **Start Gaming**
stops the local shard and `wsl --shutdown`. **Done Gaming** starts WSL Ubuntu only
([run a specific distro](https://learn.microsoft.com/en-us/windows/wsl/basic-commands#run-a-specific-linux-distribution-from-powershell-or-cmd));
it does **not** redeploy `llamacpp-rpc-server`. Rejoin the pool from `orchestrator` cluster
Start (answer **Y** for that host). Stopping a shard that is still in the live
`RPC_BACKENDS` list crashes the coordinator. Install the `.lnk` on each PC (not
from `orchestrator` onto another Desktop).

Expected end: `CLUSTER Start COMPLETE`, HTTP verify green, keep-warm on `hub` (cron + post-start ping).

---

## gpu-248 (`secondary`) opt-in shard `:31355`

**Prerequisites:** GTX 1070 driver + Docker + NVIDIA Container Toolkit on `secondary`;
hub tarball `alfa-llamacpp-rpc-cuda128-pascal-b10355.tar.gz` on `hub`.

1. Commit/push this repo; `git pull --ff-only origin main` on `orchestrator`, `inference`, `pool-opt-in`, `secondary` (when on), `hub`.
2. **From `hub` (operator):** `sudo bash scripts/build-llamacpp-rpc-cuda128-pascal-on-hub.sh` (once per llama.cpp bump).
3. **From `secondary` (operator):** follow [DOCKGE_248_OPERATOR.md](DOCKGE_248_OPERATOR.md) — load pascal image, smoke `deploy-grev27-pool-shard.sh` while coordinator is **down**.
4. **From `orchestrator` (operator):** full `Start-Stop-AlfaAi.ps1 stop` then `start` and answer **Y** for `secondary`.

Accept: coordinator self-test decode OK; `secondary` listed in active shard verify when opted in.

**One-time after first start on `hub`:** `bash deploy/cluster-members/hub/operator-cluster-111.sh install-keep-warm`  
**Retire `apps` cron:** `bash scripts/install-inference-keep-warm-cron.sh --uninstall-only` on `apps`.

**Cold start:** first `frontier-code` completion after idle may take **~3-4 minutes**
([inference_BENCHMARKS.md](inference_BENCHMARKS.md)). The start cycle waits for coordinator health;
warm traffic is handled by `scripts/keep-inference-warm.sh` (cron every 15 min on **`hub`**, localhost LiteLLM). Shard verify during start runs from **`inference`** hub (production LAN path).  bound on `inference` 2026-07-05 (node `ai-148`, `100.112.43.57`) — baked into `Invoke-AlfaAiCluster.ps1`'s default; only set `ALFA_EDGE__LOGIN_URL` on `orchestrator` if `inference` is re-bound to a new  IP.

---

## When piecemeal scripts are allowed

| Situation | Allowed |
|-----------|---------|
| First-time inference setup on a host | `deploy-grev27-pool-shard` on that host only |
| Hub tarball / image missing | `load-llamacpp-rpc-from-hub` then **full start** |
| Routine daily ops | **Start-Stop-AlfaAi.ps1 only** |
| After any manual shard/coordinator fix | Run **stop** then **start** full cycle |

---

## Known issues (fix in repo — no restart workarounds)

| Priority | Issue | Fix (in repo) |
|----------|-------|----------------|
| **Critical** | All inference shards `not reachable` from `inference` hub after `start-brain` — `inference` second data NIC (`.147`) on the **same `/24`** as `apps` (`.104`) can cause ARP flux | Source policy routing: data IP `/32` + `routing-policy from <ip> table 101` in `netplan-dual-ip-data-plane.yaml`; ARP sysctls `60-alfa-dual-nic.conf` on `inference`. See [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) |
| **Critical** | LiteLLM `background_health_checks` chat-probes during coordinator load → 503 storm, contracts-bot cooldown | `litellm_config.inference.yaml`: `background_health_checks: false`, per-model `disable_background_health_check` |
| **Critical** | `start-brain` one-shot curl on coordinator before load complete | `scripts/start.sh`: `wait-llamacpp-coordinator-health.sh` 900s before brain compose up |
| **Critical** | Mid-start `inference` coordinator redeploy (`Invoke-AlfaEnsureCoordinator148AfterBrain`) | **Removed** from `Invoke-AlfaAiCluster.ps1` |
| **Critical** | Mid-start `hub` shard restart in `operator-cluster-111.sh start-brain` | **Removed**; `start-brain` runs `scripts/start.sh` + shard verify only |
| **High** | `start-brain`: `failed to set up container networking: network <id> not found` | Stale brain containers after network prune/recreate. `scripts/_alfa_compose_env.sh` `alfa_compose_brain_up` retries with `--force-recreate` ([Compose force recreate](https://docs.docker.com/reference/cli/docker/compose/up/)). Full stop + start after a failed start cycle. |
| **High** | `orchestrator:31350` unreachable from LAN (WSL mirrored Hyper-V firewall) | One-time `install-wsl-lan-firewall.ps1 -Profile operator-93` as `operator` (Admin); orchestrator preflight checks before shard deploy |
| **High** | `inference:31356` rpc-server accept-queue wedge under concurrent RPC load | **Mitigated** — `GGML_CUDA_DISABLE_GRAPHS=1` on all shard compose files ([#20315](https://github.com/ggml-org/llama.cpp/issues/20315)) + **staggered startup** (`inference_SHARD_STAGGER_SEC`) |
| **High** | Coordinator `/health` OK but inference dead (split-brain) | Coordinator must deploy **after** all shards; **no** mid-start redeploy; full stop+start. See [inference_RPC_RELIABILITY.md](inference_RPC_RELIABILITY.md) |
| **High** | Silent TCP wedge (container Up, remote `nc` fails) | Force-recreate via **full cluster cycle**; do not lone `docker restart` |
| **Minor** | `contract_ai_ready: false` after transient 503 at start | Clears after `keep-inference-warm.sh` success or TTL; stale error_logs in detailed health |

---

## Diagnostics (read-only)

**From `inference` hub:**

```bash
cd ~/alfa-ai
bash scripts/diagnose-inference-ai.sh
```

**contracts-bot** (still on `apps` apps host): `curl -fsS http://127.0.0.1:8002/api/health/connectivity`

If degraded: run **full stop**, then **full start** with tails open — do not chain individual redeploys.

---

## Related

- [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) — pool topology and troubleshooting
- [START_STOP_AND_OPERATIONS.md](START_STOP_AND_OPERATIONS.md) — brain `scripts/start.sh` / `stop.sh` (used inside `hub` operator script)
- [inference_BENCHMARKS.md](inference_BENCHMARKS.md) — cold/warm timing, keep-warm cron
- [inference_RPC_RELIABILITY.md](inference_RPC_RELIABILITY.md) — wedge root causes, stagger order
