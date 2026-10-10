# gaming-worker-a (gaming-a) -- agent SSH from `orchestrator`

Give Cursor on **`orchestrator` (`operator`)** the same style of access used for `market`/`probilliards`/`monitor`:
dedicated Ed25519 key, OpenSSH Server on Windows, BatchMode SSH.

Official manuals:

- [OpenSSH install (Windows 10)](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_install_firstuse)
- [Key-based auth](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_keymanagement)
- [Server configuration / DefaultShell](https://learn.microsoft.com/en-us/windows-server/administration/openssh/openssh_server_configuration)

## Why

`gaming-a` is an opportunistic gaming worker (Dockge `:5003`, optional llama.cpp RPC).
Until SSH works from `orchestrator`, the agent cannot pull, diagnose, or deploy here and must
post operator paste blocks instead.

## Runbook

### Step 1 -- From `orchestrator` (operator)

Generate (or reuse) the key and write the public half into this member folder:

```powershell
cd C:/Users/operator\alfa-ai
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).
```

Commit/push includes `id_ed25519_93_219.pub` (public only). Private key stays in
`C:/Users/operator\.ssh\id_ed25519_93_219` and is **never** committed.

### Step 2 -- From `gaming-a` (Admin PowerShell)

Repo checkout (adjust user path if needed):

```powershell
cd C:\Users\Corey\alfa-ai
git pull --ff-only origin main
```

Enable OpenSSH Server + install the `orchestrator` pubkey:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\gaming-worker-a\enable-agent-ssh-from-93.ps1
```

If the Windows account is **not** `Corey`, pass `-TargetUser YourUser`.
Admin accounts install into `C:\ProgramData\ssh\administrators_authorized_keys`
(Microsoft requirement); standard users use `%USERPROFILE%\.ssh\authorized_keys`.

### Step 3 -- From `orchestrator` (operator) smoke

```powershell
ssh -i $env:USERPROFILE\.ssh\id_ed25519_93_219 -o BatchMode=yes Corey@orchestrator hostname
```

Replace `Corey` with the account used in Step 2. First interactive connect may be
needed once to accept the host key; then BatchMode must succeed.

## After SSH works

Agent may run commands on `gaming-a` via:

```powershell
ssh -i $env:USERPROFILE\.ssh\id_ed25519_93_219 Corey@orchestrator ...
```

Still follow [cluster-start-stop-only](../../../.cursor/rules/cluster-start-stop-only.mdc)
and [no-piecemeal-cluster-scripts](../../../.cursor/rules/no-piecemeal-cluster-scripts.mdc)
for inference -- gaming RPC joins are optional and must not piecemeal-restart shards
while the coordinator is up.

## Related

- [README.md](README.md) -- host role, WSL Docker, Dockge
- [GAMING_DOCKGE_HANDOFF.md](GAMING_DOCKGE_HANDOFF.md) -- stop stacks before games
