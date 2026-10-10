# gpu-248 (`secondary`) -- inference GTX 1070 shard operator

**Host:** `orchestrator` (`Nickey-Nakita` / `gpu-248`). **2026-09-14:** Wi-Fi static `secondary` (USB Ethernet unplugged).  
**Account:** `operator`  
**Repo:** `~/alfa-ai`  
**Shard:** llama.cpp `rpc-server` on **`:31355`** (GTX 1070 8 GB, Pascal sm_61)  
**Membership:** **opt-in** at `Start-Stop-AlfaAi.ps1 start` (Y/N like `gaming-c`/`gaming-a`/`gaming-b`)  
**Image:** `alfa-llamacpp-rpc:cuda128-pascal` (hub tarball only; not `cuda128`)

See also [.cursor/plans/RAG_248_VM100_SHARD.md](../.cursor/plans/RAG_248_VM100_SHARD.md),
[docs/GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md), [docs/HUB_ARTIFACTS.md](HUB_ARTIFACTS.md),
[docs/FLEET_OS_AND_APP_UPDATES.md](FLEET_OS_AND_APP_UPDATES.md) (Mint Update Manager, not Ubuntu `unattended-upgrades`).

---

## Prerequisites (one-time gate)

1. **BIOS / display:** Monitor on **iGPU (HD 530)**; GTX 1070 headless for compute.
2. **NVIDIA driver:** Linux Mint Driver Manager (proprietary). Verify:

   ```bash
   nvidia-smi
   ```

   Expect **GeForce GTX 1070**, ~0 MiB used, no Xorg on GPU 0.

3. **Docker Engine + NVIDIA Container Toolkit** (official Docker / NVIDIA docs).
4. **Hub access:** NFS `/mnt/cluster` (seed only). **Warm path:** tarball copied once to **`~/alfa-ai-cache/docker-images/`** on local SSD, then `docker load` from there (same as VM100 `pool-opt-in`).
5. **SSH from `orchestrator`:** `ssh operator@orchestrator` BatchMode OK (Wi-Fi static).
6. **inference error recorder:** one-time passwordless sudo for orchestrator log capture:

   ```bash
   sudo bash ~/alfa-ai/deploy/cluster-members/pool-shard-secondary/setup-inference-logging-prereqs.sh
   sudo -n true && echo sudo_ok
   ```

   Without this, `Start-Stop-AlfaAi.ps1` stop/start warns `missing inference-248-errors.log`.

Do **not** add `secondary` to the live pool until driver + Docker GPU smoke pass.

## Dockge agent

Visibility only -- does **not** start or restart `llamacpp-rpc`. Image from hub
tarball `louislam-dockge-1.tar.gz` in `~/alfa-ai-cache/docker-images/` (NFS
autofs on this host may not list `/mnt/cluster`). Stacks dir defaults to
`/home/operator/stacks` because passwordless sudo for `/opt/stacks` is not assumed.

```bash
cd ~/alfa-ai && git pull --ff-only origin main
bash deploy/cluster-members/pool-shard-secondary/deploy-dockge.sh
```

On `orchestrator` primary: Settings -> Remote agents -> `http://orchestrator`

---

## Hub image (`hub` only -- once per llama.cpp bump)

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
sudo bash scripts/pack-llamacpp-vendor-tarball-on-hub.sh b8552
sudo bash scripts/build-llamacpp-rpc-cuda128-pascal-on-hub.sh
```

Workers load (on `secondary` — promotes hub -> local SSD, then `docker load`):

```bash
mkdir -p ~/alfa-ai-cache/docker-images
bash deploy/cluster-members/_common/load-llamacpp-rpc-pascal-from-hub.sh
```

First run copies `alfa-llamacpp-rpc-cuda128-pascal-b8552.tar.gz` from `/mnt/cluster/docker-images/` into `~/alfa-ai-cache/docker-images/` on the **local SSD** (~2.2 GB one-time). Subsequent loads skip NFS if the image is already in Docker.

---

## Deploy shard (coordinator must be **down**)

```bash
cd ~/alfa-ai
git pull --ff-only origin main
bash deploy/cluster-members/pool-shard-secondary/deploy-grev27-pool-shard.sh
```

Or via operator wrapper:

```bash
bash deploy/cluster-members/pool-shard-secondary/operator-cluster-248.sh start-shard
```

Verify (only while coordinator is stopped):

```bash
nc -zv 127.0.0.1 31355
nc -zv orchestrator 31355
docker logs llamacpp-rpc-248-gpu1070 2>&1 | tail -20
```

---

## Stop shard

```bash
bash deploy/cluster-members/pool-shard-secondary/operator-cluster-248.sh stop-shard
```

Or full cluster stop from `orchestrator` (`Start-Stop-AlfaAi.ps1 stop`) -- orchestrator calls
`operator-cluster-248.sh stop-shard` when `secondary` is in the active shard list.

---

## Join live pool (orchestrator only)

1. Ensure `orchestrator 31355 6 85` is in `deploy/llamacpp-rpc/inference-shards.core.env`.
2. **Full** `Start-Stop-AlfaAi.ps1 stop` then `start` from `orchestrator` (no piecemeal coordinator).
3. Accept: coordinator self-test decode OK; admin health shows 6/6 core shards.

---

## Network

**Intended cluster address:** `orchestrator/24` via `orchestrator` (keep out of the
AXE300 DHCP pool). Orchestrator, inference shard lists, and Prometheus `static_configs`
use that address.

**2026-09-14 live:** USB Ethernet unplugged. Onboard `enp2s0` DOWN. Wi-Fi
`wlx58044f258f9f` profile `Auto StarWarz2` is **manual** **`orchestrator/24`**
(gateway/DNS `orchestrator`). Prometheus scrapes `secondary`.

Keep `secondary` out of the AXE300 DHCP pool (one MAC reservation for the Wi-Fi NIC
`58:04:4f:25:8f:9f`). Re-apply if the profile resets:

```bash
sudo nmcli connection modify "Auto StarWarz2" ipv4.method manual ipv4.addresses orchestrator/24 ipv4.gateway orchestrator ipv4.dns orchestrator
sudo nmcli device reapply wlx58044f258f9f
```

Do **not** answer Y for gpu-248 at cluster start on Wi-Fi: RTT from `orchestrator` is
~70-100 ms, a poor path for llama.cpp RPC. Prefer USB Ethernet (AXE300 1G) before
opt-in.

---

## Troubleshooting

| Symptom | Check |
|---------|--------|
| `failed to initialize CUDA` in rpc-server logs | Driver / `nvidia-container-toolkit`; iGPU must drive desktop |
| Wrong image tag | Must be `cuda128-pascal`, not `cuda128` (sm_61) |
| `:31355` closed after start | Coordinator not up yet, or shard crashed -- `docker logs llamacpp-rpc-248-gpu1070` |
| Pool wedge after join | Full stop + start from `orchestrator`; no manual shard restart while coordinator holds session |
