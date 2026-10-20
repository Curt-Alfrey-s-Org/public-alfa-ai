# Fleet host readiness (official manuals checklist)

Per-host operator prerequisites before deploy or host actions. Technical behavior follows
**official vendor docs** (RULE #1); cluster layout follows alfa-ai `docs/`.

## All hosts

- [ ] `git pull --ff-only origin main` on the owning clone before deploy
- [ ] Docker: [docs.docker.com](https://docs.docker.com/) — `docker info` succeeds
- [ ] Compose: [Compose specification](https://compose-spec.io/)
- [ ] OS/app updates: [FLEET_OS_AND_APP_UPDATES.md](FLEET_OS_AND_APP_UPDATES.md) (Ubuntu overlay installed; no auto-reboot; no Watchtower)

## Ubuntu Server / Debian (not Proxmox, not Mint)

- [ ] `/etc/apt/apt.conf.d/51alfa-unattended` present (`Automatic-Reboot` false)
- [ ] `/etc/needrestart/conf.d/50-alfa-list-only.conf` present (`$nrconf{restart} = 'l'`)
- [ ] `solar-broker`: `unattended-upgrades` package installed (Debian enable script)

## `orchestrator` Windows (operator / operator)

- [ ] PowerShell 5.1 for operator paste blocks ([learn.microsoft.com/powershell](https://learn.microsoft.com/en-us/powershell/scripting/overview))
- [ ] WSL Ubuntu + Docker Engine ([learn.microsoft.com/wsl](https://learn.microsoft.com/en-us/windows/wsl/))
- [ ] HTTP smoke: `curl.exe` only (not `Invoke-WebRequest` alias)
- [ ] Cluster start/stop: `Start-Stop-AlfaAi.ps1` only (operator)

## `hub` hub (operator)

- [ ] Hub path `/mnt/HDDs/Alfa-AI/` mounted; repo at `/mnt/HDDs/Alfa-AI/repo/alfa-ai`
- [ ] Operator runs `git pull`; agent does not SSH-commit
- [ ] NFS export for Linux workers per `docs/CLUSTER_SHARED_STORAGE.md`

## `apps` / `pool-opt-in` / `inference` Linux (ansible / operator)

- [ ] NFS `/mnt/cluster` mounted when compose reads hub artifacts
- [ ] systemd owns production APIs where documented

## `probilliards` USPBF (operator)

- [ ] nginx: official [nginx.org/docs](https://nginx.org/en/docs/)
- [ ] Maintenance default unless operator requests production cutover

## Host actions SSH (Phase 1)

- [ ] Dedicated Ed25519 key in brain `secrets/host-actions/`
- [ ] `known_hosts` file present (`ALFA_AI_HOST_ACTIONS_KNOWN_HOSTS`)
- [ ] asyncssh connect uses known_hosts ([asyncssh.readthedocs.io](https://asyncssh.readthedocs.io/))

## Monitoring `monitor`

- [ ] Prometheus scrape config includes alfa-ai admin metrics endpoint (JWT via file_sd or manual)
- [ ] Alertmanager webhook token matches brain `ALFA_AI_ALERT_WEBHOOK_TOKEN`

## Consumer VMs (`market` market, `atems` atems, etc.)

- [ ] Copy `.cursor/templates/alfa-ai-consumer-only.mdc` from alfa-ai into this repo's `.cursor/rules/`
- [ ] Link `docs/AI_GOVERNANCE_CONSUMER_STUB.md` (or equivalent) in README
- [ ] **Git push from owning VM:** `operator@example.com` remote + `~/.ssh/id_ed25519` deploy key on the repo (not HTTPS). Pattern matches `pool-opt-in`/`market`/`probilliards`.

### `atems` ATEMS git SSH (one-time)

| Item | Value |
|------|-------|
| Clone | `/home/operator/atems` |
| Remote | `operator@example.com:example/atems.git` |
| Key | `~/.ssh/id_ed25519` on `atems` (deploy key on GitHub **atems** repo) |

After adding the deploy key in GitHub → Settings → Deploy keys, verify:

```bash
ssh -T operator@example.com
cd /home/operator/atems && git push origin main
```

## Related

- [REPO_HOST_MAPPING.md](REPO_HOST_MAPPING.md)
- [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md)
- [ADMIN_AI_HOST_ACTIONS.md](ADMIN_AI_HOST_ACTIONS.md)
