# VM100 migration — July 2026

**Updated:** 2026-07-02  
**Track:** **B** — VM100 = GPU embed (`:11435`); brain + DB stay on `hub`.

## Intent

Move **alfa-ai GPU embed** from VM105 to VM100 on the same Proxmox host (`pve-i5` / `hypervisor`). **1660 Super** passthrough moves with it. **Do not** move brain/LiteLLM/Postgres off `hub`.

## Topology

```
pve-i5 (hypervisor)
├── VM105 — apps, edge, bot DB (no GPU after move)
└── VM100 — alfa-ai-embed-ollama :11435 (operator@orchestrator, ~/alfa-ai)

hub hub — brain + canonical postgres/redis + hub
```

## Progress

| Step | Status |
|------|--------|
| Track B repo commit (`608b017`) | Done |
| GPU passthrough VM105 → VM100 | Done |
| NVIDIA 595 + nvidia-container-toolkit | Done |
| Root LV extended 15 → 30 GB | Done |
| Track A brain/postgres/redis torn down on VM100 | Done |
| `.env.embed` on VM100 | Done |
| `operator-cluster-100.sh start-embed` | **Done** |
| `hub` `EMBED_BASE_URL` → `pool-opt-in:11435` | **Done** |
| `apps` stop old embed compose | **Done** |

## Cutover complete (2026-07-02)

All operator steps finished. Embed lives on `pool-opt-in:11435`; LiteLLM on `hub` retargeted; old `apps` embed container removed.

See [DOCKGE_100_OPERATOR.md](../DOCKGE_100_OPERATOR.md) and [.cursor/plans/VM100_ALFA_AI_MIGRATION.md](../.cursor/plans/VM100_ALFA_AI_MIGRATION.md).