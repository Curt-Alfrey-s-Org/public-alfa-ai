# gaming-worker-b (gaming-b) -- agent SSH from `orchestrator`

Give Cursor on **`orchestrator` (`operator`)** the same style of access used for `gaming-a`/`gaming-c`:
dedicated Ed25519 key, OpenSSH Server on Windows, BatchMode SSH.

Official manuals:

- [OpenSSH install (Windows 10)](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse)
- [Key-based auth](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement)
- [Server configuration / DefaultShell](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_server_configuration)

## Why

`gaming-b` is an opportunistic inference RPC shard (`:31358`). Without SSH from `orchestrator`, every
prep step requires the physical console. After this one-time bootstrap, **cluster
start/stop SSH-deploys `gaming-b` from `orchestrator`** when opted in (same as `gaming-a` / `gaming-c`).

## Runbook

### Step 1 -- From `orchestrator` (operator) -- done once per key

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).
```

Commit/push includes `id_ed25519_93_249.pub` (public only). Private key stays in
`C:/Users/operator\.ssh\id_ed25519_93_249` and is **never** committed.

### Step 2 -- From `gaming-b` (Admin PowerShell once)

Repo: `C:\Users\cody\alfa-ai` (pull first, or copy `gaming-worker-b-249\` from SMB stage / `orchestrator`).

**Must be Administrator PowerShell** on account **`cody`** (lowercase).

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\cody\alfa-ai\deploy\cluster-members\gaming-worker-b\enable-agent-ssh-from-93.ps1 -TargetUser cody
```

### Step 3 -- From `orchestrator` (operator) smoke

```powershell
ssh -i $env:USERPROFILE\.ssh\id_ed25519_93_249 -o BatchMode=yes cody@orchestrator hostname
```

First connect may prompt to accept the host key; then BatchMode must succeed.

Override orchestrator target/repo if the account path differs:

```powershell
$env:inference_SSH_249_TARGET = 'YourUser@orchestrator'
$env:inference_REPO_249_WIN = 'C:\Users\YourUser\alfa-ai'
```

## After SSH works

Opt in during full `Start-Stop-AlfaAi.ps1 start` (**Y** for `gaming-b`, or
`-GamingMode Flags -Include249`). Do not piecemeal-restart shards while the
coordinator is up ([cluster-start-stop-only](../../../.cursor/rules/cluster-start-stop-only.mdc)).

## Related

- [README.md](README.md) -- host role, WSL Docker, shard port `:31358`
- [docs/inference_GAMING_HOST_JOIN.md](../../../docs/inference_GAMING_HOST_JOIN.md)
- [docs/CLUSTER_START_STOP_OPERATOR.md](../../../docs/CLUSTER_START_STOP_OPERATOR.md)
