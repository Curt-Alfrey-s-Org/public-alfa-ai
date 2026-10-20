# gaming-worker-c (gaming-c) -- agent SSH from `orchestrator`

Give Cursor on **`orchestrator` (`operator`)** the same style of access used for `gaming-a`/`market`:
dedicated Ed25519 key, OpenSSH Server on Windows, BatchMode SSH.

Official manuals:

- [OpenSSH install (Windows 10)](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse)
- [Key-based auth](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement)
- [Server configuration / DefaultShell](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_server_configuration)

## Why

`gaming-c` is an opportunistic inference RPC shard (`:31351`). Without SSH from `orchestrator`, every
prep step requires the physical console. After this one-time bootstrap, **all work
runs from `orchestrator` or Cursor** (RDP only if you prefer a GUI).

## Runbook

### Step 1 -- From `orchestrator` (operator) -- done once per key

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).
```

Commit/push includes `id_ed25519_93_59.pub` (public only). Private key stays in
`C:/Users/operator\.ssh\id_ed25519_93_59` and is **never** committed.

### Step 2 -- From `gaming-c` (Admin PowerShell once; RDP is fine)

Copy the public key and enable script to `gaming-c` if the repo is not current:

- Repo: `C:\Users\Colin\alfa-ai`
- Or SMB stage: `\\hub\temp\cluster_members\gaming-worker-c-59\` (after `git pull` on `orchestrator` + stage)

**Must be Administrator PowerShell** (not cmd). OpenSSH install fails from plain cmd.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\Users\Colin\alfa-ai\deploy\cluster-members\gaming-worker-c\enable-agent-ssh-from-93.ps1 -TargetUser Colin
```

If `id_ed25519_93_59.pub` is missing on `gaming-c`, copy it from `orchestrator` repo path or SMB stage
before running the script.

### Step 3 -- From `orchestrator` (operator) smoke

```powershell
ssh -i $env:USERPROFILE\.ssh\id_ed25519_93_59 -o BatchMode=yes Colin@orchestrator hostname
```

First connect may prompt to accept the host key; then BatchMode must return `QuantumExampleX`
(or the current hostname).

## After SSH works

Agent may run inference prep remotely. After OpenSSH + WSL Docker + image are ready,
**cluster start/stop SSH-deploys `gaming-c` from `orchestrator`** when you answer **Y** (or
`-GamingMode Last` / `-Include59`) -- same pattern as `gaming-a`:

```powershell
# Manual smoke only (coordinator must be down). Routine join = full start opt-in.
ssh -i $env:USERPROFILE\.ssh\id_ed25519_93_59 Colin@orchestrator "cd C:\Users\Colin\alfa-ai; powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-c\deploy-grev27-pool-shard.ps1"
```

Still follow [cluster-start-stop-only](../../../.cursor/rules/cluster-start-stop-only.mdc) for
bringing `gaming-c` into the live pool -- opt in during full `Start-Stop-AlfaAi.ps1 start`, do not
piecemeal-restart shards while the coordinator is up.

Join checklist / image HTTP fallback when SMB is denied:
[inference_GAMING_HOST_JOIN.md](../../../docs/inference_GAMING_HOST_JOIN.md) (section
"gaming-worker-c `gaming-c` join (2026-08-04)").

## Related

- [README.md](README.md) -- host role, WSL Docker, shard port `:31351`
- [docs/inference_GAMING_HOST_JOIN.md](../../../docs/inference_GAMING_HOST_JOIN.md)
- [docs/CLUSTER_START_STOP_OPERATOR.md](../../../docs/CLUSTER_START_STOP_OPERATOR.md)
