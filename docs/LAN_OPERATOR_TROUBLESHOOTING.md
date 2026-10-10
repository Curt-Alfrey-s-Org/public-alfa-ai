# ALFa AI LAN Operator Troubleshooting

This runbook covers failure modes from the hub `hub` brain + Ubuntu `apps` apps + Win11 `orchestrator` Dockge rollout. **Petals inference retired 2026-07-09** — sections below that mention Petals are **historical** unless labeled otherwise.

Use this file when a Docker restart fails on a LAN deployment.

**IP map, dual-NIC policy routing, iperf baselines:** [CLUSTER_LAN_AUDIT.md](CLUSTER_LAN_AUDIT.md).

**hub `br1` island with no AXE300 gateway (2026-09):** cluster git, Cloudflare **530**, and `github.com` DNS failures with LAN hub still up — [LAN_ISLAND_GATEWAY_OUTAGE.md](LAN_ISLAND_GATEWAY_OUTAGE.md).

**WOLF1 X540 bridge / `orchestrator` on wrong `Ethernet N` after Windows network reset:** production = **`orchestrator` on 10G Network Bridge**; **Large Send Offload V2 Disabled** on both X540s; Realtek **not required** — [WOLF1_92_X540_BRIDGE.md](WOLF1_92_X540_BRIDGE.md). Check: `Verify-Wolf1NetworkLayout.ps1` under `deploy/cluster-members/orchestrator/`.

**Run the port discovery script on the target machine before first `docker compose up` or after any port conflict.** This replaces manual port guessing.

### Windows PowerShell (`orchestrator`)

```powershell
cd C:/Users/operator\alfa-ai\deploy
.\scripts\assign-ports.ps1
```

### Linux / Ubuntu / hub

```bash
cd /home/operator/alfa-ai
./scripts/preflight_ports.sh --assign
```

The script checks each ALFa AI port against listening processes, reassigns from the approved `8400-8499` range if needed, and writes results to `deploy/.env`. See [PORT_ASSIGNMENTS.md](PORT_ASSIGNMENTS.md) for the full range policy.

## 2. Manual Port Ownership Check

If you need to inspect ports without running the assignment script:

### Windows PowerShell (`orchestrator`)

```powershell
Get-NetTCPConnection -State Listen -LocalPort 8412,8413,8420,8090 -ErrorAction SilentlyContinue |
  Select-Object LocalAddress, LocalPort, OwningProcess
```

### Linux / Ubuntu / hub

```bash
ss -ltnp | grep -E ':(8412|8413|8420|8090|31330)\b'
```

Meaning:

- `8412` = ALFa AI API
- `8413` = LiteLLM
- `8420` = operator console
- `8090` = nginx/UI
- `31330` = Petals worker / DHT (**retired** — audit firewall history only)

If a port is already owned by some other process, stop there and resolve that owner first.

## 3. Common Failure: LiteLLM Port 8413 Already In Use

### Symptom

Compose reports:

```text
ports are not available: exposing port TCP 127.0.0.1:8413 ...
```

### Cause

Some other process or an old container already owns `127.0.0.1:8413`.

### Fix

Find the owner first, then decide whether it is the expected `alfa-ai-litellm` container or a stale process:

```powershell
Get-NetTCPConnection -State Listen -LocalPort 8413 -ErrorAction SilentlyContinue |
  Select-Object LocalAddress, LocalPort, OwningProcess
```

If needed, map the PID to a process:

```powershell
Get-Process -Id <PID>
```

Do **not** guess. Remove or stop the actual owner, then rerun the verification script.

## 4. Common Failure: `orchestrator` Cannot Reach `apps:31330` — **RETIRED (Petals 2026-07-09)**

### Symptom

```powershell
Test-NetConnection apps -Port 31330
```

shows:

```text
TcpTestSucceeded : False
```

### Cause

The CPU worker may be healthy locally, but the host firewall or routing blocks LAN access.

### Fix on `apps` (historical — Petals retired 2026-07-09)

If auditing legacy Petals worker firewall rules:

```bash
sudo ufw allow from orchestrator to any port 31330 proto tcp
# .157 Petals plane — retired; remove rule if still present
sudo ufw reload
```

Then rerun `Test-NetConnection` from `orchestrator`.

### hub `hub` and `br1` (historical Petals source-IP note)

> **Petals retired.** Current LAN: **`br1`** with **`hub/24` + `storage/32` NFS VIP** (same L2). See [hub_111_10G_NIC.md](hub_111_10G_NIC.md).

Legacy note: when Petals used **`network_mode: host`**, outbound TCP from hub could use **`src orchestrator`** — confirm with `ip route get apps`. **Do not add new `.157` UFW rules.**

## 5. Common Failure: Wrong Petals Model on a Worker — **RETIRED (Petals 2026-07-09)**

> Historical audit only. Do not run Petals workers.

### Symptom

Worker logs show `deepseek-ai/...`, `trust_remote_code`, or:

```text
EOFError: EOF when reading a line
```

### Cause

The worker stack `.env` or a stale template still points `PETALS_MODEL` at `deepseek-ai/DeepSeek-Coder-V2-Lite-Instruct`, which requires interactive `trust_remote_code`.

### Correct model for this rollout

```text
meta-llama/Llama-3.3-70B-Instruct
```

### Source-of-truth files on `apps`

- `deploy/petals/dockge.petals-worker.env`
- `deploy/petals/.env.dockge`
- `deploy/petals/env.worker.example`
- `deploy/petals/.env.worker.example`

Sync those from `apps`; do not hand-edit shared defaults on target machines.

## 6. Common Failure: New Peer ID After Worker Restart — **RETIRED (Petals 2026-07-09)**

### Symptom

Petals gateway or joining workers cannot find the bootstrap peer even though the old IP is still correct.

### Cause

The worker restarted and got a **new P2P peer ID**. The `/p2p/...` suffix in `PETALS_INITIAL_PEERS` is stale.

### Fix

On the bootstrap worker (historical **`.157`** announce), get the multiaddress from logs:

```bash
sudo docker logs petals-worker 2>&1 | grep -E 'Running a server on|Full list of visible multiaddresses'
```

Then update `PETALS_INITIAL_PEERS` on `apps` / `orchestrator` to the **full current multiaddr**, not just the IP.

## 7. Common Failure: LiteLLM `/v1/models` missing expected aliases

### Symptom

Chat fails with **invalid model** / model not in router.

### Cause

Stale LiteLLM container, wrong `deploy/litellm_config.yaml` mount, or `.env` pointing at the wrong compose project.

### Check

```powershell
Invoke-RestMethod http://127.0.0.1:8413/v1/models `
  -Headers @{ Authorization = "Bearer <LITELLM_MASTER_KEY>" }
```

You should see **`chat`**, **`qwen3.6:35b-a3b`** (`orchestrator` + `inference` MoE), **`fast`**, **`frontier`** (122B coordinator), **`frontier-code`**, **`embed`**, and **`operator_internal`** (routes to the RPC pool — `hub` runs no Ollama), etc. You should **not** see **`qwen3.5:27b`**, **`qwen3:32b`**, **`qwen3-coder:30b-a3b-q4_K_M`**, or **`qwen3:4b`** as routable chat aliases — if they appear, recreate **`alfa-ai-litellm`** from current **`deploy/`** and `git pull`.

## 8. Docker Desktop / Windows networking rule — **RETIRED Petals stack**

> Historical. Current `orchestrator` stack uses llama.cpp RPC + LiteLLM; no `alfa-ai-petals-gateway`.

For the legacy ALFa Petals stack on Win11 Docker Desktop:

- `alfa-ai-litellm` reaches `alfa-ai-petals-gateway` by service name
- `PETALS_GATEWAY_URL=http://alfa-ai-petals-gateway:8000/v1`
- do **not** use `host.docker.internal` for the gateway in this stack

Host ports on the Windows machine are only for operator access from Windows itself:

- `8412` = API
- `8413` = LiteLLM
- `8420` = operator console

## 9. Recommended verification flow

From a Linux host with the repo (e.g. `apps`):

```bash
cd ~/alfa-ai
./scripts/smoke-litellm-tiers.sh deploy/.env
```

That exercises tiers 0–3b + embeddings against `deploy/litellm_config.yaml`.

From Windows, smoke the brain LiteLLM port (Petals gateway checks **retired**):

```powershell
curl.exe -fsS --max-time 5 http://hub/health/liveliness
```

**Historical:** `http://apps/health` was the last-resort Petals gateway.

## 10. Source-of-Truth Workflow

Shared fixes belong in the repo on `apps`, then sync outward:

- `apps` = authoritative checkout
- `orchestrator` = sync `deploy/` and `src/` from `apps`
- `hub` = sync `deploy/` from GitHub (Petals **`deploy/petals/` retired**)

Only machine-specific values should be changed on the target host:

- `deploy/.env`
- worker `.env` / Dockge `.env`
- secrets
- peer multiaddrs
- host IPs
- approved port overrides
