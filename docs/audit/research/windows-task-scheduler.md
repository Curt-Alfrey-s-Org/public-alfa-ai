# Windows Task Scheduler — `SYSTEM`-context services on Win11

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` to check `/home/operator/alfa-ai/` against upstream guidance.

## Official documentation

- **Primary docs URL:** https://learn.microsoft.com/en-us/windows/win32/taskschd/tachange-me
- **About:** https://learn.microsoft.com/en-us/windows/win32/taskschd/about-the-task-scheduler
- **Tasks (components / triggers / actions):** https://learn.microsoft.com/en-us/windows/win32/taskschd/tasks
- **Security contexts (how `SYSTEM` / users / Logon-as-Batch work):** https://learn.microsoft.com/en-us/windows/win32/taskschd/security-contexts-for-running-tasks
- **PowerShell `ScheduledTasks` module reference:** https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/
- **Task XML schema reference:** https://learn.microsoft.com/en-us/windows/win32/taskschd/tachange-me
- **`schtasks.exe` CLI reference:** https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks

## Current stable / supported version (as of 2026-05-13)

- **Task Scheduler 2.0** — installed by default on Windows Vista / Server 2008 onward, including all current Win10 / Win11 / Server 2022 / Server 2025 builds. Source: https://learn.microsoft.com/en-us/windows/win32/taskschd/tachange-me.
- **Task Scheduler 1.0** — legacy, `.job` files; only used when interoperating with pre-Vista clients. Should not be used for new deployments. Source: https://learn.microsoft.com/en-us/windows/win32/taskschd/tasks ("Task Scheduler 1.0 Tasks").
- **PowerShell module:** `ScheduledTasks` — built-in on Win10/11 / Server 2016+. Source: https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/.
- **`schtasks.exe`** — built-in CLI shipped on every supported Windows. Source: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks.
- **Versioning / EOL:** the Task Scheduler API has been stable since Windows Vista; documentation pages are last-updated 2019–2020 because the surface area is mature. EOL is tied to the host OS — Win10 22H2 EOL is 2025-10-14 (consumer) / 2026-10-14 (LTSC); Win11 23H2/24H2/25H2 are current.

## Key official best practices

- **Run as `NT AUTHORITY\SYSTEM` for unattended services.** A task registered with the **SYSTEM** account starts at boot, has no interactive desktop, and survives all user logoffs/logins. This is the canonical pattern for "I need to run a Linux-style daemon on Windows". Source: https://learn.microsoft.com/en-us/windows/win32/taskschd/security-contexts-for-running-tasks ("RunLevel ignored for Local System").
- **`Logon as Batch` privilege** is required for tasks registered with `TASK_LOGON_PASSWORD` or `TASK_LOGON_S4U` — i.e. when the task runs as a non-`SYSTEM` user. Administrators and Backup Operators have this by default; other users need `secpol.msc → Local Policies → User Rights Assignment → Log on as a batch job`. Source: same security-contexts page.
- **`RunLevel = HIGHEST` for elevated tasks.** Without it, a task registered for a member of Administrators runs with low privilege under UAC. The flag is ignored for `SYSTEM`/`LocalService` accounts. Source: same.
- **Triggers vs actions:** every task = ≥ 1 trigger (when) + ≥ 1 action (what). Triggers include `AT_LOGON`, `AT_STARTUP`, `ON_EVENT`, `TIME`, `DAILY`, `WEEKLY`, `IDLE`, `REGISTRATION`. Actions: `Exec` (launch program — only one supported on modern OSes), `Email` and `ShowMessage` (deprecated). Source: https://learn.microsoft.com/en-us/windows/win32/taskschd/tasks ("Components of a Task") + https://learn.microsoft.com/en-us/windows/win32/taskschd/task-actions.
- **Default `ExecutionTimeLimit = 72h`** — a task is killed after 72 hours regardless of the action. **Set to `PT0S` (zero seconds) to disable the limit** for true daemon-style tasks. Source: https://learn.microsoft.com/en-us/windows/win32/taskschd/tasks ("Note about ExecutionTimeLimit").
- **Auto-restart on failure:** under *Settings → If the task fails, restart every: …* (XML: `RestartOnFailure → Interval / Count`). Pair with `RestartCount` for daemon-like persistence.
- **`StartWhenAvailable=true`** ensures the task runs ASAP when the computer boots even if the trigger time was missed.
- **Hide / no-window:** for service-style tasks, set Action `Hidden=true` (XML attribute) — otherwise a console window flashes briefly on each launch.
- **Definition format:** the canonical artifact is **XML** (Task Scheduler 2.0 schema). Export with `schtasks /Query /TN "<name>" /XML > task.xml`; import with `schtasks /Create /XML task.xml /TN "<name>"`. Source: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks-create.
- **PowerShell idiomatic registration:**
  ```powershell
  $Action  = New-ScheduledTaskAction  -Execute 'C:\bin\my-svc.exe' -Argument '--config C:\bin\my-svc.yaml'
  $Trigger = New-ScheduledTaskTrigger -AtStartup
  $Principal = New-ScheduledTaskPrincipal -UserId 'NT AUTHORITY\SYSTEM' -RunLevel Highest -LogonType ServiceAccount
  $Settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Days 0) -StartWhenAvailable -RestartCount 99 -RestartInterval (New-TimeSpan -Minutes 1)
  Register-ScheduledTask -TaskName 'my-svc' -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings
  ```
  Source: https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/register-scheduledtask.
- **Logging:** Task history goes to *Event Viewer → Applications and Services Logs → Microsoft → Windows → TaskScheduler → Operational*. Enable "History" via the Task Scheduler MMC if disabled. Source: https://learn.microsoft.com/en-us/windows/win32/taskschd/using-the-task-scheduler.
- **NSSM (third-party) is the OTHER common pattern** for daemonizing CLI tools on Windows — wraps an `.exe` as a real Windows Service. Documented external to Microsoft (https://nssm.cc) but is the typical alternative when an app needs proper service-lifecycle (`sc query`, `services.msc`).

## Canonical configuration examples

**SYSTEM-context, always-on task in PowerShell** (verbatim shape from the cmdlet docs above):

```powershell
$Action    = New-ScheduledTaskAction -Execute 'C:\Program Files\Ollama\ollama.exe' -Argument 'serve'
$Trigger   = New-ScheduledTaskTrigger -AtStartup
$Principal = New-ScheduledTaskPrincipal `
                -UserId 'NT AUTHORITY\SYSTEM' `
                -LogonType ServiceAccount `
                -RunLevel Highest
$Settings  = New-ScheduledTaskSettingsSet `
                -StartWhenAvailable `
                -DontStopOnIdleEnd `
                -ExecutionTimeLimit (New-TimeSpan -Seconds 0) `
                -RestartCount 99 `
                -RestartInterval (New-TimeSpan -Minutes 1) `
                -MultipleInstances IgnoreNew

Register-ScheduledTask `
    -TaskName 'Ollama-AlfaAI' `
    -Action $Action -Trigger $Trigger -Principal $Principal -Settings $Settings
```

**Equivalent XML (Task Scheduler 2.0 schema)** — source: https://learn.microsoft.com/en-us/windows/win32/taskschd/tachange-me:

```xml
<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.4" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <Triggers>
    <BootTrigger><Enabled>true</Enabled></BootTrigger>
  </Triggers>
  <Principals>
    <Principal id="Author">
      <UserId>S-1-5-18</UserId>
      <RunLevel>HighestAvailable</RunLevel>
      <LogonType>ServiceAccount</LogonType>
    </Principal>
  </Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <AllowHardTerminate>true</AllowHardTerminate>
    <StartWhenAvailable>true</StartWhenAvailable>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <RestartOnFailure>
      <Interval>PT1M</Interval>
      <Count>99</Count>
    </RestartOnFailure>
    <Hidden>true</Hidden>
  </Settings>
  <Actions Context="Author">
    <Exec>
      <Command>"C:\Program Files\Ollama\ollama.exe"</Command>
      <Arguments>serve</Arguments>
    </Exec>
  </Actions>
</Task>
```

**Import via `schtasks.exe`:**

```powershell
schtasks /Create /XML task.xml /TN "Ollama-AlfaAI" /F
schtasks /Query  /TN "Ollama-AlfaAI" /V /FO LIST
```

Source: https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks-create.

## Common pitfalls / gotchas

- **Default `ExecutionTimeLimit = 72h`** kills daemon-style tasks every three days. Set to `PT0S` to disable. Source: https://learn.microsoft.com/en-us/windows/win32/taskschd/tasks.
- **Tasks registered for a normal user account require the user to be logged in** unless `LogonType = Password` is used (which means caching the password). `SYSTEM` avoids this entirely. Source: https://learn.microsoft.com/en-us/windows/win32/taskschd/security-contexts-for-running-tasks.
- **`Run only when user is logged on`** is the *default* in the Task Scheduler GUI — flip to *Run whether user is logged on or not* for service-style tasks. This is `LogonType=Password` or `LogonType=ServiceAccount` (`SYSTEM`).
- **`SYSTEM` cannot read network shares** by default — `\\server\share\file` paths fail under SYSTEM unless the resource is anonymous-read. Use a local path or run as a domain account. Source: same security-contexts page.
- **No real PID-1.** Task Scheduler launches a process and tracks it, but if the launched process spawns children that the parent loses, those children may orphan. Wrap in a process supervisor (e.g. `nssm`, or a PowerShell wrapper that `Wait-Process`).
- **History off by default in some builds** — enable in Task Scheduler MMC's *Action* pane.
- **`RunLevel=Highest` is silently ignored under SYSTEM** (already privileged). Source: same.
- **Group as principal** requires `LogonType = InteractiveToken` only — incompatible with `Password`/`S4U`. Source: same.
- **Console window flashes** unless `<Hidden>true</Hidden>`.
- **PowerShell as the action** — prefer `pwsh.exe -NoProfile -ExecutionPolicy Bypass -File C:\path\script.ps1`; `-NoProfile` shaves seconds off cold start.
- **Working directory** must be set explicitly via `<WorkingDirectory>` in the action — defaults to `C:\Windows\System32`, which causes "file not found" errors if the program uses relative paths. Source: https://learn.microsoft.com/en-us/windows/win32/taskschd/task-actions.

## Authoritative URLs to cite in our docs

- https://learn.microsoft.com/en-us/windows/win32/taskschd/tachange-me
- https://learn.microsoft.com/en-us/windows/win32/taskschd/about-the-task-scheduler
- https://learn.microsoft.com/en-us/windows/win32/taskschd/tasks
- https://learn.microsoft.com/en-us/windows/win32/taskschd/security-contexts-for-running-tasks
- https://learn.microsoft.com/en-us/windows/win32/taskschd/task-triggers
- https://learn.microsoft.com/en-us/windows/win32/taskschd/task-actions
- https://learn.microsoft.com/en-us/windows/win32/taskschd/tachange-me
- https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/
- https://learn.microsoft.com/en-us/powershell/module/scheduledtasks/register-scheduledtask
- https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks
- https://learn.microsoft.com/en-us/windows-server/administration/windows-commands/schtasks-create

## AUDIT CHECKLIST for the Audit Agent

The cluster runs Windows hosts (`orchestrator`, `gaming-c`, `gaming-b`, `gaming-a`, `secondary`) where Petals workers, llama.cpp `rpc-server`, and Ollama CPU MoE need to be **always-on, surviving logout and reboot**. Per the workspace's `pre-install-research.mdc` rule, these "must survive logout/reboot". Per `deployment-process-ownership.mdc`, "production = process manager; scripts delegate".

1. **Process-manager method documented:** confirm each Win11 host has a documented process-manager strategy — Task Scheduler under `SYSTEM`, `nssm`-wrapped Windows service, or Docker Desktop's auto-start. Path: `deploy/cluster-members/<host>/README.md` and `DOCKGE_*_OPERATOR.md`. Per `pre-install-research.mdc`, this should be captured in the relevant `*_INSTALL_GOTCHAS.md`.
2. **Per-host audit (each Win host: `orchestrator`, `gaming-c`, `gaming-b`, `gaming-a`, `secondary`):** for every long-running process (Ollama, Petals worker, `cloudflared`, `rpc-server`, Docker Desktop / WSL2 daemons), verify ONE of:
   - Task Scheduler task exists with `Principal = NT AUTHORITY\SYSTEM`, `LogonType = ServiceAccount`, `Trigger = AtStartup`, `ExecutionTimeLimit = PT0S`, `Hidden = true`, `RestartOnFailure` set.
   - Registered Windows service via `nssm install <name>` (visible in `services.msc` and `sc query <name>`).
   - Wrapped by Docker Desktop's "start on login" + `restart: unless-stopped` (only acceptable when the user *is* an auto-login admin account).
3. **`ExecutionTimeLimit = PT0S`:** for Task Scheduler tasks, confirm the 72-hour default is overridden. Otherwise the worker dies every 3 days. Run `schtasks /Query /TN "<name>" /XML` and grep for `ExecutionTimeLimit`.
4. **Hidden window:** confirm `<Hidden>true</Hidden>` (XML) or `New-ScheduledTaskSettingsSet -Hidden` (PowerShell). A console flash is benign but not best-practice for "service-style" tasks.
5. **Working directory pinned:** confirm `<WorkingDirectory>` is set on tasks that use relative paths (Ollama models cache, Petals weight directory). Otherwise SYSTEM defaults to `C:\Windows\System32` and breaks.
6. **Auto-restart on failure:** confirm `RestartOnFailure` (`Count >= 3`, `Interval = PT1M` or similar) so a transient crash doesn't take the worker out of the swarm.
7. **`SYSTEM` vs domain user:** confirm operator's choice. `SYSTEM` is recommended for stateless services that don't need user-level network shares; a domain user is needed only when the task accesses `\\hub\temp\...` SMB shares (per `NODE_INVENTORY.md` "Deployment pipeline").
8. **CPU-only enforcement under SYSTEM:** if Ollama CPU MoE is registered as a SYSTEM Task Scheduler action, the action env must include `CUDA_VISIBLE_DEVICES=` (empty) and `OLLAMA_NUM_GPU=0` per `ollama.md` audit. Verify in the action `<Arguments>` / wrapper script.
9. **Logging path:** Task Scheduler doesn't capture stdout — wrap actions in a script that redirects to a file (`> C:\logs\ollama.log 2>&1`) so post-mortem is possible.
10. **Single-source ownership** (per `deployment-process-ownership.mdc`): confirm there is exactly ONE start mechanism per service — flag any host where both a Task Scheduler entry AND a Docker Desktop "start on login" both attempt to start Ollama.
11. **Documentation:** verify each Windows-host runbook (`deploy/cluster-members/<host>/README.md` or `operator-93/deploy.ps1`) names the canonical process-management method and shows the exact `Register-ScheduledTask` / `nssm install` commands.
12. **Audit log:** confirm Task Scheduler "History" is enabled on each host so failures appear in *Event Viewer → Microsoft → Windows → TaskScheduler → Operational*.
