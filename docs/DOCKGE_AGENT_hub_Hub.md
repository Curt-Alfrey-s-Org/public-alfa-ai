# Dockge on `hub` (hub Scale 25.04)

Dockge on `hub` runs **via hub Scale Apps**, not a manual
`docker compose` stack. This is unchanged after the April 2026 architecture
shift — `hub` has just gained more responsibilities (full ALFa AI brain,
Ollama 32B, NVMe hot pool) around the same Apps-managed Dockge.

For the full brain operator guide, see [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md).
For the Dockge agent matrix across the cluster, see
[DOCKGE_AGENTS_WORKERS.md](DOCKGE_AGENTS_WORKERS.md).

## Canonical URL

| Use | URL |
|-----|-----|
| Browser UI on `hub` | **`http://hub`** |
| **New Agent** on `orchestrator` primary Dockge | **`http://hub`** |

Container name is typically **`ix-dockge-dockge-1`**, publishing
**`0.0.0.0:31014`**.

## Why Apps Dockge only (no manual compose stack)

A **manual** Dockge (historic `docker-compose` / Dockge project `dockge-111`)
competed for ports and attention with **Apps Dockge**. Apps integrates with
hub networking; **31014** is the port that worked reliably for UI login
and agent registration. **Do not** run a second Dockge on the same host for
the same role.

**Removed from this repo:** `deploy/petals/docker-compose.dockgehub.yml`
(and the small `dockge-111.gitignore`). There is **no** compose-based Dockge
for `hub` in **alfa-ai** anymore.

## Install / operate

1. **hub** → **Apps** → install **Dockge** from the catalog.
2. Confirm the published **Node / host port** (here **`31014`**) in the app
   details.
3. Complete the Dockge **first-run** wizard in the browser.
4. On **`orchestrator`** → primary Dockge → **Home** → **New Agent** →
   **`http://hub`** with the **same** credentials as on
   `hub` (per Dockge multi-instance docs).

## What stacks live on `hub`'s Dockge

After the brain migration, Dockge on `hub` manages (or at least shows) the
`alfa-ai` brain stack and its peers:

| Stack | Compose file | Host ports |
|-------|--------------|-----------|
| `alfa-ai` | `deploy/docker-compose.yml` | 8420 (api), 4000 (litellm), 8080/8443 (nginx) |
| `ollama` (if not a hub App) | `deploy/docker-compose.ollama-gpu.yml` | 11434 |
| `alfa-registry` | `deploy/cluster-members/hub/docker-compose.registry.yml` | 5000 |
| `alfa-ai-petals-worker` | `deploy/petals/docker-compose.worker.yml` (+ worker overrides) | 31330 (DHT), 31331 (monitor) |

## If you previously ran a manual stack on `hub`

- **`docker compose down`** any old **`dockge-111`** project so it does not
  hold ports or confuse operators.
- **Do not** bind **`31014`** twice — only **Apps** Dockge should use it.

## `alfa-ai` clone on `hub`

After the April 2026 brain move, `hub` keeps its git clone at
**`/mnt/HDDs/Alfa-AI/repo/alfa-ai`** — the same path every deploy script on
`hub` references (registry compose, brain compose, Petals worker compose if
you ever re-enable one). Keep this path; do **not** migrate the clone to
the NVMe pool unless explicitly planned — the repo is small and benefits
more from snapshot history on the HDD ZFS pool than from NVMe speed.

## Legacy SSH keys for Git

If **`GIT_SSH_COMMAND`** pointed at **`/mnt/HDDs/dockge-111/.ssh/`**, that
path was for the old manual layout; you can **keep** those keys there or
move them to `/mnt/HDDs/Alfa-AI/ssh-keys/` — Git does not require Dockge.

## Related

- [DOCKGE_111_OPERATOR.md](DOCKGE_111_OPERATOR.md) — full brain operator guide
- [DOCKGE_AGENTS_WORKERS.md](DOCKGE_AGENTS_WORKERS.md) — agent matrix
- [history/BRAIN_MIGRATION_105_TO_111.md](history/BRAIN_MIGRATION_105_TO_111.md)
- [hub_111_NVME_POOL.md](hub_111_NVME_POOL.md)
- [NODE_INVENTORY.md](NODE_INVENTORY.md)
