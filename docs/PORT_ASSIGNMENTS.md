# ALFa AI port assignments

This file defines ALFa AI host port defaults after reviewing rankings-bot canonical assignments.

**Cursor rule:** [.cursor/rules/cluster-port-assignments.mdc](../.cursor/rules/cluster-port-assignments.mdc) — preflight and fleet matrix before cluster deploys (distinct from `apps` bot ports in `port-assignment-rules.mdc`).

## Upstream Reserved API Ports (Do Not Reuse)

From `rankings-bot/.github/PORT_ASSIGNMENTS.md`:

- `127.0.0.1:5000` (ATEMS API)
- `127.0.0.1:8002` (Contracts API)
- `127.0.0.1:8003` (Rankings API)
- `127.0.0.1:8004` (Market API)
- `127.0.0.1:8005` (Credit Check API)
- `127.0.0.1:8011` (RV Auto Finder API)

## ALFa AI defaults

Live defaults from `deploy/env.example` (the source of truth; this doc tracks
those values per audit CROSS-DOC-001). When the env keys are unset, compose
falls back to the values below.

| Service              | Host port | Container port | Env key                              |
|----------------------|-----------|----------------|--------------------------------------|
| ALFa AI API          | 8412      | 8000           | `ALFA_AI_API_HOST_PORT`              |
| ALFa AI LiteLLM      | 8413      | 4000           | `ALFA_AI_LITELLM_HOST_PORT`          |
| ALFa AI operator     | 8420      | 8000           | `ALFA_AI_OPERATOR_CONSOLE_HOST_PORT` |
| Pool switch daemon   | 8421      | 8421           | `ALFA_POOL_SWITCHD_HOST_PORT` (host loopback only; see [POOL_SWITCH_OPERATOR.md](POOL_SWITCH_OPERATOR.md)) |
| Contracts-bot edge (`inference`) | 8422 | 8000        | `CONTRACTS_BOT_EDGE_HOST_PORT` — /LAN proxy to `apps:8003` ([CONTRACTS_BOT__EDGE.md](CONTRACTS_BOT__EDGE.md)) |
| ALFa AI Postgres     | 5540      | 5432           | `ALFA_AI_POSTGRES_HOST_PORT` (compose: `docker-compose.postgres.yml`) |
| ALFa AI Redis        | 6390      | 6379           | `ALFA_AI_REDIS_HOST_PORT` (compose: `docker-compose.redis.yml`) |

**Exporter coupling (hub):** `hub-postgres-exporter-brain` and
`hub-redis-exporter-brain` (host network) scrape loopback **5540** / **6390**.
Base compose always publishes **`127.0.0.1:5540`** / **`127.0.0.1:6390`**. When remote
agent workers need LAN access, merge **`docker-compose.postgres.lan-bind.yml`** /
**`docker-compose.redis.lan-bind.yml`** (sets `ALFA_AI_*_LAN_BIND=hub` in
`deploy/.env`) so both loopback and LAN binds are active. Single LAN-only publish breaks
exporters (`connection refused` on `127.0.0.1`) and flaps `AlfaBrainPostgresDown` /
`AlfaBrainRedisDown` while containers stay healthy. Apply with
`bash scripts/open_lan_db_for_workers.sh` on `hub`.
| ALFa AI nginx/UI     | 8090      | 80             | `ALFA_AI_NGINX_HOST_PORT`            |
| SearXNG (agent search) | 8888    | 8080           | LAN loopback on `hub`; see [deploy/searxng/README.md](../deploy/searxng/README.md) |

All API and data services bind `127.0.0.1` on the host per `.cursorrules` Rule
3. The operator console is the same uvicorn process as the API, mapped a second
time on a different host port for the LAN console URL (`http://<host>:8420/operator/`).
See [OPERATOR_CONSOLE.md](OPERATOR_CONSOLE.md).

History: prior versions of this doc (Mar 2026 and earlier) used `8012/8013/8020`;
the live defaults moved to `8412/8413/8420` in April 2026 to avoid collisions
with rankings-bot's `8010-8019` block. Updated 2026-05-13 per audit
CROSS-DOC-001.

## Petals Swarm Ports (RETIRED — historical audit)

> **Retired 2026-07-09.** Petals workers/gateways removed from deploy. Port list kept for firewall audit history.

- **Historical (April 2026 rebalance):** Petals DHT / worker (primary port): `31330` (TCP). hub then pinned SSH/UI/mgmt on **`hub`** and announced Petals on **`orchestrator`** (`PETALS_ANNOUNCE_IP`). **Superseded 2026-09-04:** **`br1` is the LAN** — mgmt **`hub/24`** + NFS VIP **`storage/32`** on the same L2 ([hub_111_10G_NIC.md](hub_111_10G_NIC.md)); **`.157` / `.173` retired** (Petals inference removed 2026-07-09). With -only nodes, prefer the  interface; see [DISTRIBUTED_AI.md](DISTRIBUTED_AI.md).
- Petals worker monitor (heartbeat): `31331` was the Petals sidecar port. **Live again (2026-10-02)** as the GPU **worker-monitor** HTTP sidecar (`/health`, `/stats`) on gaming workers. Petals is not started. Brain Admin Health polls `http://<worker>:31331/stats` on the LAN. Compose: `deploy/cluster-members/_common/worker-monitor/`.
- **`orchestrator` dual-GPU second worker** (April 2026 hardware refresh, `petals-worker-b` pinned to the second RTX 3060 via [deploy/petals/docker-compose.worker.dual-gpu.yml](../deploy/petals/docker-compose.worker.dual-gpu.yml)):
  - Petals DHT / worker-b: **`31340/tcp`** (must be reachable from every other peer on the LAN — add to Windows firewall allowlist alongside `31330`).
  - Petals worker-b monitor: **`31341/tcp`** (loopback only on `orchestrator`).
  - `orchestrator` (worker-a, GPU 0) and `orchestrator` (worker-b, GPU 1) both announce via `PETALS_ANNOUNCE_IP=orchestrator` with distinct identity paths; Petals treats them as two independent peers.
- **`inference` ai-148** (RTX 5060 8 GB + RTX 3060 LHR 12 GB) — inference shards `:31356`/`:31357`; port `31330/tcp` on **`orchestrator`** (`bond0`). Standard CUDA 12.4 image.

## Dual-NIC data plane (RAG sidecars — not RPC pool)

**Production RAG SSoT (2026-07-18):** CPU embed+rerank on **`rag:11435` / `:8360`**. `inference` RAG retired; `pool-opt-in` is inference shard only.

Optional second NIC per host for high-volume embed/rerank traffic (hub: **`hub` mgmt + `storage` NFS VIP both on `br1`**, same L2 — not a separate wire).

| Data-plane IP | Mgmt IP | Host | Service | Port | Client env |
|---------------|---------|------|---------|------|------------|
| **`orchestrator`** | `rag` | VM110 | **CPU RAG** embed + rerank (SSoT 2026-07-18) | **11435** / **8360** | `EMBED_BASE_URL` + `RERANK_BASE_URL` on brain `hub` |
| **`orchestrator`** | `inference` | ai-148 | inference shards only (RAG retired) | — | legacy embed/rerank stopped on cluster start |
| **`orchestrator`** | `apps` | apps-105 | Legacy embed data NIC (Track A, retired) | — | **Do not use** — second virtio/`enp6s19` not present in 2026-07 live guest dump; mgmt is `bond0` `apps` only |
| ~~`pool-opt-in` Track-B RAG~~ | `pool-opt-in` | VM100 | ~~embed/rerank~~ | ~~11435/8360~~ | **Retired as RAG** — inference shard `:31354` only |
| (mgmt `inference`) | `inference` | ai-148 | inference shards + edge | **31356**/ **31357** | RAG retired to `rag` |

**inference RPC** (`31356`/`31357`/`31350`, coordinator `31360`) always uses **mgmt IPs** (`inference`/`orchestrator`), never `.104`/`.147`.

### Same-subnet requirement: source policy routing (mandatory)

`.104` (`apps`) and `.147` (`inference`) sit on the **same `orchestrator/24` L2 segment** as their mgmt
IPs. Two interfaces on one subnet must use **source-based policy routing**, or the kernel adds a
second on-link `/24` route and the host suffers **ARP flux + asymmetric returns** — intermittently
breaking **all** LAN egress from that host (this took down inference verify from `inference` and bumps the
co-located bots offline). Per the official netplan source-routing example
(https://netplan.readthedocs.io/en/stable/examples/ → "source routing", canonical/netplan
`examples/source_routing.yaml`) and the Linux ARP sysctls
(https://www.kernel.org/doc/Documentation/networking/ip-sysctl.txt):

1. **Data-plane IP is `/32`** (not `/24`) so it does **not** create a competing main-table `/24`
   route. Unbound egress always uses the mgmt default route (`bond0`).
2. **`routing-policy: from <data-ip> table 101`** + a `table 101` on-link `orchestrator/24` route so
   replies sourced from the data IP leave the data NIC (symmetric). **No** default route in
   table 101 (data plane is server-only, no gateway).
3. **ARP flux sysctls** (`/etc/sysctl.d/60-alfa-dual-nic.conf`, applied by the setup script):
   `net.ipv4.conf.all.arp_ignore=1`, `net.ipv4.conf.all.arp_announce=2` so each NIC only answers
   ARP for its own IP. (`rp_filter` is already `2`/loose.)

Verify after apply: `ip route get hub` must show `dev bond0 src apps` (mgmt),
and `ip rule` must list `from orchestrator lookup 101`.

Setup: `deploy/cluster-members/apps/setup-dual-ip-data-plane.sh`, `deploy/cluster-members/inference-coordinator/setup-dual-ip-data-plane.sh`.

## llama.cpp RPC ports (frontier pool — chat 122B / code 27B / coder-80B)

SSoT: [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md) Â§6.0.
See also [QWEN3_MIGRATION.md](QWEN3_MIGRATION.md) and [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md).
**One TCP port per `rpc-server` process** (one GPU each) plus the coordinator.

**Primary working set (G-rev Phase H — 27B RPC pool, 2026-06-28):**

- **27B RPC pool coordinator** (CPU on `hub`): **`31360`** (`LLAMACPP_CODE27_URL`; LiteLLM `frontier-code` / `qwen3.6-27b`)
- **27B RPC shards** (`rpc-server`, one GPU each):
  - `inference` RTX 3060 → **`31356`** (tensor-split 12)
  - `inference` RTX 5060 → **`31357`** (tensor-split 8; 8151 MiB physical)
  - `orchestrator` RTX 3060 → **`31350`** (tensor-split 10; 2048 MiB WDDM reserve)
  - `pool-opt-in` GTX 1660S → **`31354`** (tensor-split 5; opt-in)
  - `secondary` GTX 1070 → **`31355`** (tensor-split 7; opt-in)
  - `hub` RTX 3050 → **`31353`** (tensor-split 5; nvidia-smi 6144 MiB / 6 GB)
- **35B MoE coordinator** (CPU on `hub`, when 27B pool stopped): **`31360`**
  (LiteLLM `LLAMACPP_35B_URL`; speed aliases including `qwen3.6:35b-a3b`)

**Mutual exclusion:** only one coordinator profile on **`hub:31360`** (27B or 35B) at a time.

**Legacy / retired:** `inference` `:31358` local dual-GPU 27B (non-RPC); `apps` `:31354` 35B shard optional.

**`RPC_BACKENDS`** for 27B pool (`hub` coordinator): see `deploy/llamacpp-rpc/inference-shards.env`.

**LiteLLM routing (Phase H):** `LLAMACPP_CODE27_URL=http://host.docker.internal:31360/v1` in brain `deploy/.env`
(host-network coordinator on `hub:31360`; host probes use `127.0.0.1:31360`);
`LLAMACPP_35B_URL=http://hub/v1` (35B pool only).

**Standalone 7B llama-server (not RPC):** `gaming-c` WSL **`8470`** (`LLAMACPP_7B_URL` only after eval gate + operator promote). Mutex with 7B QLoRA train and inference opt-in `gaming-c:31351` on the same GPU. Do **not** use `31350–31360` for this server. See [ALFA_7B_SERVE_ALONGSIDE_27B.md](operations/ALFA_7B_SERVE_ALONGSIDE_27B.md). LAN-only; do not expose `:8470` to the public internet.

**Firewall (mandatory):** upstream **`rpc-server` is explicitly insecure / PoC** — see [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md) Â§ **Security and networking**. Open TCP **`31350`–`31357`** only **between the coordinator host (`hub`) and each backend**, and **`31360`** **only from trusted LAN sources** (e.g. LiteLLM on `hub`, operators). **Do not** expose **`31350`–`31360`** to the public internet. On **hub** use **Network → Firewall** (no default `ufw`); on **Windows** use **Defender Firewall** with LAN-scoped inbound rules for published RPC ports on `orchestrator` and `inference`.

hub `hub` uses mgmt **`hub`** on **`br1`** for brain traffic; NFS VIP **`storage/32`** on the same bridge (prefer for nfsd bind; **`hub` fallback** same L2). **`.157` Petals plane — retired.** See [hub_111_10G_NIC.md](hub_111_10G_NIC.md).

**Avoid collisions:** historical Petals worker-b used **`31340`** (DHT). Do not
reuse **`31340`** for a new service on `orchestrator` without checking this matrix. Live
RPC on `orchestrator` is **`31350`**.

## aria2 JSON-RPC (Dockge — every node that runs `deploy/aria2/`)

- **Host `6800/tcp`** → container `6800` (`http://<host>:6800/jsonrpc`).
- **Optional BT:** `6888/tcp` + `6888/udp` (same compose file).
- **Standard on each machine:** deploy the stack once per host; clients on that
  host use `http://127.0.0.1:6800/jsonrpc` or the hostâ€™s LAN IP from peers.
- **Rollout:** [deploy/aria2/README.md](../deploy/aria2/README.md).

## systemd vs Docker (API port 8412)

If the API runs under **`deploy/systemd/alfa-ai-api.service`**, it owns
**127.0.0.1:8412** on the host — do not also publish **alfa-ai-api** from
Compose on the same port. Use Compose for **LiteLLM** only, or stop systemd
and use full Compose. See
[DEPLOYMENT_BASELINE.md](DEPLOYMENT_BASELINE.md).

**Preflight:** Before **`docker compose ... up`** when the stack defines **`alfa-ai-api`**, run **`scripts/preflight_api_ownership.sh compose-will-manage-api`** (cluster **`deploy/cluster-members/hub/deploy.sh`** and **`deploy/cluster-members/apps/deploy.sh`** invoke this). Before enabling systemd after Compose had the API: **`scripts/preflight_api_ownership.sh systemd-will-manage-api`**.

## LAN-bind exceptions (audit CROSS-RULE-001/002, LITELLM-005)

The `.cursorrules` Rule 3 default is `127.0.0.1:HOSTPORT:CONTAINERPORT` for
every API. Two ALFa AI services intentionally deviate:

| Service                       | Host bind         | Why                                                            |
|-------------------------------|-------------------|----------------------------------------------------------------|
| LiteLLM (`alfa-ai-litellm`)   | `0.0.0.0:8413`    | `apps` apps and `orchestrator` bot frontends call `http://<brain>:8413` directly. Reverse-proxying through `alfa-ai-nginx` was rejected because it adds a hop + breaks the existing `LITELLM_BASE_URL` discipline. |
| Operator console (`alfa-ai-api` second mapping) | `0.0.0.0:8420` | Browser-served operator UI for the LAN. Same justification — no internal proxy hop. |

Operators **must** restrict these LAN-bound ports with the host firewall.

**`hub` brain** — LAN only (no  on `:8420`/`:8413`; admin browsers use
`inference` edge proxy instead):

```bash
sudo ufw allow from orchestrator/24 to any port 8413 proto tcp comment 'LiteLLM LAN (audit CROSS-RULE-001)'
sudo ufw allow from orchestrator/24 to any port 8420 proto tcp comment 'ALFa AI operator console LAN (audit CROSS-RULE-002)'
sudo ufw deny  to any port 8413 proto tcp
sudo ufw deny  to any port 8420 proto tcp
sudo ufw reload
```

**`inference` edge** (`docker-compose.edge-api.yml`) — LAN **and**  tailnet
(`100.64.0.0/10`) on host `:8420` for admin login
(`http://<inference--ip>:8420/alfa-ai/login`; run ` ip -4` on `inference`):

```bash
sudo ufw allow from orchestrator/24 to any port 8420 proto tcp comment 'ALFa edge LAN'
sudo ufw allow from 100.64.0.0/10 to any port 8420 proto tcp comment 'ALFa edge tailnet'
sudo ufw deny  to any port 8420 proto tcp
sudo ufw reload
sudo ufw status numbered | grep 8420
```

**`inference` contracts-bot edge** (`docker-compose.contracts-edge.yml`) — same host,
port **`:8422`** → LAN upstream `apps`
([CONTRACTS_BOT__EDGE.md](CONTRACTS_BOT__EDGE.md)):

```bash
sudo ufw allow from orchestrator/24 to any port 8422 proto tcp comment 'contracts-bot edge LAN'
sudo ufw allow from 100.64.0.0/10 to any port 8422 proto tcp comment 'contracts-bot edge tailnet'
sudo ufw deny  to any port 8422 proto tcp
sudo ufw reload
```

Do **not** use `hub`  for browser login — that IP is the hub host,
not the edge proxy. Edge runs on **`inference`** ([ai-148/README.md](../deploy/cluster-members/inference-coordinator/README.md)).

Audit `~/.cursor/rules/port-assignment-rules.mdc` Rule 2 should be amended to
list ports 8413 and 8420 as **LAN-only exceptions** with the UFW recipe above
as the gate. **Cluster AI ports** are covered by [.cursor/rules/cluster-port-assignments.mdc](../.cursor/rules/cluster-port-assignments.mdc) and this doc's fleet matrix.

## Fleet port matrix by host

**Before deploying any service**, check the target host does not already bind the
port (`sudo lsof -i :PORT` on Linux; `Get-NetTCPConnection -LocalPort PORT
-State Listen` on Windows). This matrix is the authoritative **per-host** map;
the tables above define **service defaults** when a port is not host-specific. **Petals DHT/gateway columns are audit-only (retired 2026-07-09).**

| Host | IP | Dockge agent | Petals DHT (retired) | worker-monitor | Petals gateway (retired) | llama.cpp RPC | aria2 RPC | Other |
|------|-----|--------------|----------------------|--------------------------|--------------------------|---------------|-----------|-------|
| **`hub`** brain | `hub` | **31014** (hub Apps) | — (was **31330** on **`.157`**) | — | — | **31353** shard (3050) + **31360** coord (CPU) | 6800 | 8420 API, 8413 LiteLLM, 5000 registry, 2049 NFS (VIP **`storage`** on `br1`), 445 SMB |
| **`apps`** apps | `apps` | **5001** | — | — | — | **31354** backend (optional) | 6800 | 5432 Postgres, 6379 Redis, bot APIs 8002–8005 (loopback); **MQTT 1883** (systemd Mosquitto); **HA 8123** (Container, host net); **Refoss UDP 9989** (LAN EM16, [Refoss](https://www.home-assistant.io/integrations/refoss/)) |
| **Pi4** Victron radio | `orchestrator` | **5006** (when up) | — | — | — | — | — | BLE/USB collectors only after cutover; do not keep HA/Mosquitto here |
| **Pi5** house edge | `orchestrator` | — | — | — | — | — | — | AdGuard **53**/8080; Theengs → `apps:1883`; exporters 9100/9617 |
| **`orchestrator`** orchestrator | `orchestrator` | **5002** primary UI | — | — | — | **31350** shard (3060) | 6800 | **6006** TensorBoard loopback (7B train metrics). **Not** LiteLLM — `:8413` is **`hub` only**. |
| **`inference`** ai-148 | `orchestrator` | **5001** | -- | -- | -- | **31356** (3060) + **31357** (5060) | 6800 | **8420** alfa-ai edge, **8422** contracts-bot edge; **12853** LACT TCP (GTK remote, LAN only); **not** a 7B train rank |
| **`gaming-a`** gaming-worker-a | `orchestrator` | **5003** not 5001 | -- | **31331** worker-monitor | -- | **31352** | 6800 | **5001 = GT3 mobile service (OS)**; **optional** train worker (rdzv client; `-Include219`) |
| **`gaming-c`** gaming-worker-c | `orchestrator` | **5001** | — | **31331** worker-monitor | — | **31351** inference opt-in / Pool72/80 (not concurrent 27B+72B on same GPU) | 6800 | **29500** train c10d rdzv head (7B QLoRA); **8470** standalone 7B llama-server (mutex vs train + `:31351`) |
| **`gaming-b`** gaming-worker-b | `orchestrator` | **5001** | — | **31331** worker-monitor | — | **31358** inference opt-in / Pool72/80 (not concurrent 27B+72B on same GPU) | 6800 | train worker (rdzv client) |
| **`secondary`** gpu-248 | `orchestrator` (Wi-Fi static; USB Ethernet unplugged 2026-09-14) | `operator@orchestrator` | — | — | — | **31355** shard (GTX 1070; `cuda128-pascal`; do not opt-in on Wi-Fi) | — | **9100** / **9400** (`monitor` Prometheus) |

### 7B QLoRA train island (mutex with inference on train GPUs only)

Core 27B (`inference` / `orchestrator` / `hub`) **stays up**. Train uses **`gaming-c` + `gaming-b`** by default
(`nnodes=2`, 2-node DDP QLoRA). Optional **3-node** (`nnodes=3`) adds `gaming-a` when
`-Include219` or the Train GUI checkbox is checked. `inference` is **not** a train worker.
Start **fails** if those hosts still run `llamacpp-rpc` (opted-in shards). Authoritative
operator path: [operations/TRAIN_7B_QLORA_GUI.md](operations/TRAIN_7B_QLORA_GUI.md).
14B QLoRA is **archived** on hub HDD (do not Start 14B).

| Port | Role | Who listens | When |
|------|------|-------------|------|
| **29500** / TCP | torchrun c10d rendezvous (`--rdzv_id alfa-train-pool7b-n2`, `alfa-train-pool7b-n3`, or `alfa-train-pool7b-n1`, `--rdzv_endpoint orchestrator`) | **Only `gaming-c`** (rank 0; `--rdzv_conf is_host=1`) | During train start/run |
| (clients) | Workers connect to `gaming-c:29500` | **Required:** `gaming-b` (rank 1). **Optional:** `gaming-a` (rank 2 when 3-node) -- they do **not** listen on 29500 | During train |

**Ready to train with 27B still running:** SSH `:22` UP on train hosts; **29500 DN**;
inference RPC on **train** hosts only (`31351` / `31358` / `31352` when included) idle
(no rpc-server container). Core `inference` `:31356`/`:31357` and coordinator `:31360` may stay UP.
**Do not** TCP-probe train-host shard ports after the coordinator is up.
**Do not** reuse **29500** for other services on `gaming-c`. Mirrored WSL needs Hyper-V inbound
allow for **29500** on `gaming-c` ([WSL networking](https://learn.microsoft.com/en-us/windows/wsl/networking)).

### TensorBoard (7B train metrics on `orchestrator`)

| Port | Role | Who listens | When |
|------|------|-------------|------|
| **6006** / TCP | TensorBoard UI (SSH tunnel target on `orchestrator` loopback) | **`orchestrator`** `127.0.0.1:6006` via `Start-AlfaTrainTensorBoard.ps1` | Anytime sidecar + tunnel healthy (idle, training, after Stop) |
| (server) | TensorBoard reads hub `checkpoints/` recursively via `gaming-c` WSL Docker `alfa-train-tb` | **`gaming-c`** loopback `:6006` (tunneled to `orchestrator`) | While `gaming-c` Docker + hub NFS mount up (`--restart unless-stopped`) |

Official default TensorBoard port: [TensorBoard get started](https://www.tensorflow.org/tensorboard/get_started).
Bind on `orchestrator` is **loopback only** (`127.0.0.1:6006`); do not expose `:6006` to WAN.
Sidecar uses `--load_fast=false`, `--reload_interval=5`, `--detect_file_replacement=true`,
`--reload_multifile=true` (NFS + SSH tunnel; see [TRAIN_7B_QLORA_GUI.md](operations/TRAIN_7B_QLORA_GUI.md)).
Operator enables **Reload data** in the TensorBoard gear menu for UI refresh
([README](https://github.com/tensorflow/tensorboard/blob/master/README.md)).

### LACT GPU control (TCP, not HTTP)

[LACT](https://github.com/ilya-zlobintsev/LACT) headless daemon optional remote listener.
**Not a web UI** — remote operators use **`lact gui --tcp-address HOST:12853`** (GTK).
TCP has **no authentication or encryption** ([LACT README Remote management](https://github.com/ilya-zlobintsev/LACT#remote-management)).
Bind **`tcp_listen_address`** to the host LAN IP, not `0.0.0.0`. Firewall: **`orchestrator/24` only**.

| Port | Role | Who listens | When |
|------|------|-------------|------|
| **12853** / TCP | LACT daemon remote (GTK client) | **`inference`**, **`pool-opt-in`** only | When `lactd` enabled and `tcp_listen_address` set in `/etc/lact/config.yaml` |

**Not installed:** **`apps`** (CPU-only), **`hub`** (hub SCALE; use `nvidia-smi` only),
**`orchestrator`** (Windows Afterburner). Operator doc: [GPU_OC_LACT_OPERATOR.md](GPU_OC_LACT_OPERATOR.md).

### Dockge ports (detail)

| Port | Host(s) | Role |
|------|---------|------|
| **5002** | `orchestrator` only | **Primary Dockge UI** — registers all remote agents |
| **5001** | `pool-opt-in`, `market`, `atems`, `apps`, `probilliards`, `monitor`, `gaming-c`, `gaming-b`, `inference` | Dockge **agent** (Linux / Win workers without OS conflict) |
| **5003** | **`gaming-a` only** | Dockge agent — **required**; Win10 **GT3 mobile service** owns **5001** |
| **31014** | `hub` only | Dockge via hub Apps (not `alfa-dockge` compose on 5002) |

### Dedicated VM Dockge agents (apps / monitoring)

These hosts are outside the AI-cluster RPC matrix above but register on the
same primary UI at **`orchestrator:5002`**.

| Host | IP | Dockge agent | Primary app clone path | `/opt/stacks` symlinks |
|------|-----|--------------|------------------------|------------------------|
| **`pool-opt-in`** ALFA-AI | `orchestrator` | **5001** | `/home/operator/alfa-ai` | inference shard `:31354` (not RAG); **12853** LACT TCP (LAN only) |
| **`market`** MARKET | `market` | **5001** | `/home/operator/market-pie5-bot` | `market-pie5-bot` |
| **`atems`** ATEMS | `atems` | **5001** | `/home/operator/atems` | `atems` |
| **`probilliards`** ProBilliards | `orchestrator` | **5001** | `/home/operator/rankings-bot`, `/home/operator/USPBF` | `rankings-bot`, `uspbf` |
| **`monitor`** Grafana | `monitor` | **5001** | `/home/operator/monitoring` | `monitoring` |

Set on workers: `ALFA_DOCKGE_HOST_PORT` in the member `.env.worker` (or Dockge
stack env). Primary UI on `orchestrator` lists agents at `http://<host-ip>:<port>/` —
see [DOCKGE_AGENTS_WORKERS.md](DOCKGE_AGENTS_WORKERS.md).

**Windows preflight** (before `docker compose â€¦ dockge`):

```powershell
Get-NetTCPConnection -LocalPort <PORT> -State Listen -ErrorAction SilentlyContinue
```

If occupied by a non-Docker process, pick the host-specific port from this table
(do not reuse another cluster host's Dockge port on the same machine).

### Petals gateway ports (RETIRED — do not deploy)

> **Retired 2026-07-09.** Do not start `alfa-ai-petals-gateway` or set
> `PETALS_GATEWAY_*`. Live OpenAI-compatible chat is **LiteLLM on `hub:8413`**
> (container `:4000`) routing to the inference coordinator **`hub:31360`**.

Historical ports (firewall audit only):

| Host | IP | Port | Was |
|------|-----|------|-----|
| **`orchestrator`** | `orchestrator` | **8413** | Primary Petals gateway (`PETALS_GATEWAY_URL`) |
| **`hub`** | `hub` | **8013** | In-stack Petals fallback |
| **`apps`** | `apps` | **8013** | Last-resort Petals hedge |

**Live URLs today:**

| URL | Service |
|-----|---------|
| `http://hub` | LiteLLM proxy (brain) |
| `http://hub/v1` | llama.cpp RPC coordinator (host / `host.docker.internal` from LiteLLM) |

`orchestrator:8413` is **free**. Do not publish a second LiteLLM or a Petals gateway there.
Rankings-bot **`8010–8019`** on `apps` are bot APIs — keep them distinct from
retired Petals **`8013`**.

### Windows `orchestrator` — port ownership and preflight

WSL Docker with **mirrored networking** publishes container ports on the
**Windows** host stack. Live services on `orchestrator`:

| Port | Owner on `orchestrator` | Bind surface | Firewall |
|------|----------------|--------------|----------|
| **5002** | `alfa-dockge` (primary Dockge UI) | `0.0.0.0:5002` | LAN optional (UI) |
| **31350** | llama.cpp `rpc-server` RTX 3060 (27B pool shard) | LAN when RPC enabled | LAN scoped to coordinator `hub` |
| **6800** | aria2 JSON-RPC (optional) | per `deploy/aria2/` | LAN |
| **6006** | TensorBoard (7B train metrics) | `127.0.0.1:6006` | loopback only |

**Retired on `orchestrator` (do not start):** Petals gateway **`:8413`**, DHT **`:31330`** /
**`:31340`**, monitors **`:31331`** / **`:31341`**. **`:8013`** is not a cluster
service on `orchestrator` (IDE tunnels may still bind loopback; leave them alone).

**Mandatory preflight** (before `deploy.ps1` on `orchestrator`):

```powershell
cd C:/Users/operator\alfa-ai
. .\deploy\cluster-members\_common\Test-AlfaWindowsDeployPortPreflight.ps1
Test-AlfaWindowsDeployPortPreflight -Profile operator-93
```

`deploy.ps1` runs this automatically before tarball load. Manual listener dump
for live ports:

```powershell
5002, 31350, 6800, 6006 | ForEach-Object {
  $p = $_
  Get-NetTCPConnection -LocalPort $p -State Listen -ErrorAction SilentlyContinue |
    ForEach-Object { [pscustomobject]@{ Port = $p; PID = $_.OwningProcess; Process = (Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue).ProcessName } }
}
```

**Windows Firewall (live):** LAN-scope inbound for Dockge **5002** and RPC
**31350** (coordinator on `hub` only). Do not re-open Petals DHT ports.
See [WINDOWS_WSL_DOCKER_ENGINE.md](WINDOWS_WSL_DOCKER_ENGINE.md) and
[deploy/cluster-members/orchestrator/README.md](../deploy/cluster-members/orchestrator/README.md).

## Rules

- API and data services must bind to `127.0.0.1` on host (with the LAN-bind
  exceptions tabled above).
- Containers communicate using Docker DNS and internal ports.
- Do not use existing fixed ports from rankings-bot port standards **on the same
  host** without checking this matrix.
- Do not expose llama.cpp RPC ports (**31350–31360**) to the public internet.
  Historical Petals DHT (**31330**, **31340**) stays closed.

