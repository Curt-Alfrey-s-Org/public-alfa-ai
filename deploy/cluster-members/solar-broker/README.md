# Pi4 Victron (solar-broker) — agent SSH from orchestrator

Scripts and published pubkey for Cursor/agent access to **operator@orchestrator**
(pi4 Victron edge).

## Files

| File | Purpose |
|------|---------|
| `id_ed25519_93_223.pub` | Published agent public key (private key stays on `orchestrator`) |
| `install-agent-ssh-from-93.sh` | Append pubkey to `~/.ssh/authorized_keys` on Pi |
| `install-passwordless-sudo.sh` | Install `/etc/sudoers.d/90-operator` (interactive sudo once) |
| `90-operator.sudoers` | Template fragment (`operator ALL=(ALL) NOPASSWD:ALL`) |

## orchestrator setup

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File `
  ..\operator-93\Copy config/hosts.example.env and add your own SSH keys on the orchestrator (see deploy/cluster-members/README.md).
```

Operator doc: [docs/PI4_VICTRON_OPERATOR.md](../../docs/PI4_VICTRON_OPERATOR.md)
