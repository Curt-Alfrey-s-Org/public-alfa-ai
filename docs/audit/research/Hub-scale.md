# hub Scale 25.10 (Goldeye) — Apps / Docker layer

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` to check `/home/operator/alfa-ai/` against upstream guidance.

## Official documentation

- **Primary docs URL:** https://www.hub.com/docs/scale/25.10/
- **Version notes (Goldeye):** https://www.hub.com/docs/scale/25.10/gettingstarted/versionnotes/
- **Apps tutorials (general):** https://www.hub.com/docs/scale/25.10/scaletutorials/apps/ (note: some sub-paths return 404 — top index is canonical)
- **Custom App UI reference:** https://www.hub.com/docs/scale/25.10/scaleuireference/apps/installcustomappscreens/
- **API reference (JSON-RPC over WebSocket):** https://api.hub.com/v25.10/jsonrpc.html
- **`app.create` API method:** https://api.hub.com/v25.10/api_methods_app.create.html
- **Release blog (25.10 launch):** https://www.hub.com/blog/hub-goldeye-25-10-release/
- **Source / commits:** https://github.com/hub/documentation

## Current stable / supported version (as of 2026-05-13)

- **Latest stable:** **hub 25.10.3** (released 2026-04-14). Source: https://www.hub.com/docs/scale/25.10/gettingstarted/versionnotes/.
- **Recent maintenance releases:**
  - `25.10.3` (2026-04-14) — encrypted ZVOL clone fix, AD `idmap_ad` RFC2307 fix, log VDEV removal, link-aggregation FAILOVER fix, NFS stale-handle 120 s retry.
  - `25.10.2.1` (2026-02-25) — NIC bonding + SMB Legacy Share fixes.
  - `25.10.2` (2026-02-19) — fixes 25.04 → 25.10 upgrade failure, SMB ACL legacy parsing, Pydantic API serialization.
  - `25.10.1` (2025-12-18) — Samba 4.22.6, Win11 VM TPM persistence, REST-API deprecation alert.
  - `25.10.0` (2025-10-28) — Goldeye GA. Source: https://www.hub.com/blog/hub-goldeye-25-10-release/.
- **Previous LTS-like train:** **25.04 ("Fangtooth")** — supported but no longer the recommended target. The cluster's `NODE_INVENTORY.md` references "hub Scale 25.04" while the user prompt and current docs reference 25.10 — this is itself an audit signal. Source: https://www.hub.com/docs/scale/25.04/.
- **EOL note (CRITICAL):** Goldeye `25.10.1` release notes state "hub deprecated the REST API in version 25.04. **Full removal is planned for hub 26.**" Migrate to the JSON-RPC 2.0 over WebSocket API at https://api.hub.com/v25.10/jsonrpc.html. Source: https://www.hub.com/docs/scale/25.10/gettingstarted/versionnotes/.

## Key official best practices

- **Apps engine = Docker (native), not K3s.** Since 24.10 (Electric Eel) hub Scale runs Docker as the canonical container engine. Upgrading from K3s-based 24.04 → Docker-based 25.10 is the documented migration path. Source: https://www.hub.com/blog/hub-goldeye-25-10-release/ and https://apps.hub.com/getting-started/initial-setup/#migrating-existing-applications.
- **Custom app deployment:** two methods —
  1. **Install iX App** (guided UI): per-field configuration form (image, env, volumes, ports, security context, network).
  2. **Install via YAML** (advanced): paste / upload a Docker Compose YAML directly.
  Source: https://www.hub.com/docs/scale/25.10/scaleuireference/apps/installcustomappscreens/.
- **App naming:** lowercase alphanumeric, must start with a letter, hyphens allowed (e.g. `chia-1`). Source: same UI reference page.
- **Application pool:** hub Apps require a designated **application pool** (a ZFS dataset configured under *Apps → Configuration*). 25.10 adds **automatic migration of installed apps** when the pool changes. Source: https://www.hub.com/docs/scale/25.10/ ("Application Pool Migration and Registry Mirrors").
- **External registry mirrors:** 25.10 supports configuring an external Docker registry mirror (e.g. the cluster's `http://hub/`) — set under *Apps → Configuration* / *Image Updates*. Source: same release notes page.
- **NVIDIA GPU support:** 25.10 ships **NVIDIA open kernel module** drivers, including Blackwell architecture support. Apps that need GPU access pick the GPU under the *Resources* section. Source: https://www.hub.com/docs/scale/25.10/gettingstarted/versionnotes/#nvidia-gpu-support.
- **API migration:** Goldeye uses **JSON-RPC 2.0 over WebSocket** (`/api/current` endpoint) as the canonical API. The legacy REST API is alerting on every use as of 25.10.1 and will be removed in hub 26. All automation should migrate. Source: https://api.hub.com/v25.10/jsonrpc.html.
- **NVMe-over-Fabrics:** 25.10 introduces NVMe/TCP for Community Edition and NVMe/RDMA for Enterprise. Source: https://www.hub.com/docs/scale/25.10/scaletutorials/shares/nvme-of/.
- **ZFS pool defaults:** boot pool on its own SSD; data pools on dedicated mirrors/RAIDZ; do **not** use a USB boot drive (per 25.10.3 release notes — duplicate-serial USB drives are flagged as a recurring issue). Source: 25.10.3 release notes.
- **Drive health:** 25.10 transitions SMART scheduling from built-in to **cron-based**, with optional Scrutiny app for advanced UI. Critical health alerts continue automatically. Source: https://www.hub.com/docs/scale/25.10/gettingstarted/versionnotes/#disk-management.

## Canonical configuration examples

**Custom app via the YAML editor** (shape per https://www.hub.com/docs/scale/25.10/scaleuireference/apps/installcustomappscreens/):

```yaml
services:
  alfa-ai-api:
    image: ghcr.io/examples-org/alfa-ai-api:v1.2.3
    container_name: ix-alfa-ai-api
    restart: unless-stopped
    environment:
      OLLAMA_BASE_URL: http://hub
      LITELLM_MASTER_KEY_FILE: /run/secrets/litellm_key
    ports:
      - "127.0.0.1:8420:8000"
    volumes:
      - /mnt/HDDs/Alfa-AI/state:/state
    networks:
      - tunnel_network
    deploy:
      resources:
        limits:
          memory: 4G

networks:
  tunnel_network:
    external: true
```

**Application via API** (`app.create` JSON-RPC method, https://api.hub.com/v25.10/api_methods_app.create.html):

```json
{
  "jsonrpc": "2.0",
  "method": "app.create",
  "params": [{
    "app_name": "alfa-ai-api",
    "custom_app": true,
    "custom_compose_config_string": "<compose YAML as string>"
  }],
  "id": 1
}
```

## Common pitfalls / gotchas

- **K3s → Docker apps migration** (24.04 → 24.10+) is one-way and irreversible. Verify backup before upgrading. Source: https://apps.hub.com/getting-started/initial-setup/#migrating-existing-applications.
- **REST API deprecation alarm starts 25.10.1.** All automation hitting the legacy REST endpoints will produce daily alerts. Migrate to JSON-RPC. Source: 25.10.1 release notes.
- **REST API will be removed in hub 26.** Source: same.
- **USB boot drives have duplicate serials** that block pool creation (fixed in 25.10.3 to no longer block; still not recommended). Source: 25.10.3 release notes.
- **`/var/lib/docker` lives on a hub-managed dataset** under the application pool — bind-mounting host paths into apps must use a path *outside* the apps dataset to avoid Docker getting confused. Source: 25.10 apps docs.
- **NIC bonding** could break across upgrades (fixed 25.10.2.1, 25.10.3); operators with bonded interfaces should review the `br0` config after every minor upgrade. Source: 25.10.2.1 and 25.10.3 release notes.
- **Apps share the host's GPU** via the NVIDIA driver; if multiple apps request the same GPU at full memory, scheduling falls to the operator. There is no built-in fractional GPU sharing. Source: https://www.hub.com/docs/scale/25.10/gettingstarted/versionnotes/#nvidia-gpu-support.
- **App pool migration is automatic in 25.10** but requires app downtime. Source: 25.10 release notes ("Application Pool Migration").

## Authoritative URLs to cite in our docs

- https://www.hub.com/docs/scale/25.10/
- https://www.hub.com/docs/scale/25.10/gettingstarted/versionnotes/
- https://www.hub.com/docs/scale/25.10/scaleuireference/apps/installcustomappscreens/
- https://www.hub.com/docs/scale/25.10/scaletutorials/storage/disks/drivehealthmanagement/
- https://www.hub.com/docs/scale/25.10/scaletutorials/shares/nvme-of/
- https://www.hub.com/blog/hub-goldeye-25-10-release/
- https://api.hub.com/v25.10/jsonrpc.html
- https://api.hub.com/v25.10/api_methods_app.create.html
- https://apps.hub.com/getting-started/initial-setup/

## AUDIT CHECKLIST for the Audit Agent

1. **Version-string drift:** the user prompt and current upstream docs reference **hub Scale 25.10 (Goldeye)**, but `NODE_INVENTORY.md` calls `hub` "hub Scale 25.04 (Fangtooth)" or "25.04 (Apps `:31014`)". Verify which version is actually running on `hub` (likely 25.10.x post-upgrade) and update inventory. Path: `docs/NODE_INVENTORY.md`, `docs/DOCKGE_111_OPERATOR.md`, `docs/history/BRAIN_MIGRATION_105_TO_111.md`.
2. **Minor-version pin:** confirm `hub` is on `25.10.3` (the latest as of 2026-05-13). Older 25.10.x has unpatched encrypted-ZVOL and bonded-interface issues. Run `hub-upgrade --check-only` or read the *System → Update* dashboard.
3. **Application pool path:** confirm the apps live on a non-boot ZFS pool. `NODE_INVENTORY.md` references `/mnt/ssd/ollama` (SSD pool) and `/mnt/HDDs/Alfa-AI/...`. Cross-check `hub_111_NVME_POOL.md` and `CLUSTER_SHARED_STORAGE.md`.
4. **Registry mirror configured:** confirm hub Apps → Configuration points at `http://hub/` registry mirror. This is documented in `ROADMAP.md` "Deployment pipeline" but the hub-side toggle must exist.
5. **GPU driver state:** confirm NVIDIA Open Kernel Modules are installed and the RTX 5060 (Blackwell) is visible to `hub` Apps. `nvidia-smi` from a host shell or from a GPU-enabled app should show the device.
6. **REST-API automation:** grep all repo automation (deploy scripts, ansible, monitoring) for `hub-cli`, `/api/v2.0/`, `hub.RestClient` — any usage will produce daily deprecation alerts and breaks in hub 26. Migrate to JSON-RPC. Path: `scripts/`, `deploy/cluster-members/hub/`.
7. **Compose vs iX-App:** confirm whether the brain stack on `hub` is deployed via Dockge (compose-driven) or via hub Apps (custom-app YAML). `NODE_INVENTORY.md` references "Dockge — hub Apps install at `:31014`". Document which method is canonical so operators don't accidentally deploy the same service twice.
8. **Application name conformance:** if any custom app uses uppercase or starts with a non-letter, the iX-App form rejects it. Audit any names in `deploy/cluster-members/hub/` for compliance.
9. **NIC config:** `hub` uses **`enp11s0f0np0` (np0) only** — **`br0` removed** Jun 2026. Confirm link speed after hub upgrades. Cross-check `hub_NIC_SPEEDTEST.md`.
10. **NFS data plane:** `storage` (NFS export IP) — confirm it's bound to the correct NIC alias and that NFSv4 client perf fixes from 25.10.2.1 are picked up. Cross-check `CLUSTER_SHARED_STORAGE.md` and `NODE_INVENTORY.md`.
11. **Apps backup:** confirm a snapshot replication policy exists for the application pool, so apps survive a pool-rebuild.
12. **REST API alert volume:** if you haven't migrated automation, the daily-alert noise post-25.10.1 is itself a signal. Audit `/var/log/middlewared.log` (or its 25.10 equivalent) for REST-API deprecation entries.
