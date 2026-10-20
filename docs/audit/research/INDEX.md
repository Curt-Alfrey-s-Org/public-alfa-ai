# Research index — ALFa AI architecture audit

> Research-agent output for the ALFa AI architecture audit (2026-05-13).
> Read by `audit-agent` as the entry point to per-component upstream guidance under `docs/audit/research/`.

## Component file table

| # | File | Component | Researched | Size | Audit-priority signal |
|---|---|---|---|---|---|
| 1 | [`ollama.md`](./ollama.md) | Ollama | 2026-05-13 | 10.0 KB | **Warning** — pre-release `0.30.0-rc15` shifts runtime to upstream `llama.cpp`; default Windows GPU autoselect; default bind `127.0.0.1:11434` |
| 2 | [`litellm.md`](./litellm.md) | LiteLLM Proxy/Router | 2026-05-13 | 10.5 KB | **Warning** — `usage-based-routing` deprecated (use `simple-shuffle` or `latency-based-routing`); requires Redis ≥ 7.0 for shared state; `master_key` + `LITELLM_SALT_KEY` mandatory in prod |
| 3 | [`petals.md`](./petals.md) | Petals | 2026-05-13 | 11.3 KB | **Warning** — single-replica fragility for private swarms; expired GPG signing keys upstream; CUDA image variants required for Blackwell GPUs |
| 4 | [`llamacpp-rpc.md`](./llamacpp-rpc.md) | llama.cpp RPC | 2026-05-13 | 9.8 KB | **Critical** — upstream still labels RPC backend "proof-of-concept / insecure, never expose to open network"; path moved `examples/rpc → tools/rpc`; org renamed `ggerganov → ggml-org` |
| 5 | [`fastapi.md`](./fastapi.md) | FastAPI | 2026-05-13 | 10.0 KB | **Info** — `0.136.1` requires Python ≥ 3.10; `@app.on_event` deprecated in favor of `lifespan`; `--proxy-headers` required behind nginx |
| 6 | [`react-vite.md`](./react-vite.md) | React + Vite SPA | 2026-05-13 | 9.8 KB | **Warning** — `index.html` MUST be served `Cache-Control: no-cache`; missing `vite:preloadError` handler causes stale-deploy white-screens |
| 7 | [`nginx.md`](./nginx.md) | nginx | 2026-05-13 | 10.7 KB | **Critical** — `1.29.7` security release (2026-03-24) fixed 5 CVEs; latest mainline `1.29.8` (2026-04-07); audit cluster nginx images for current tag |
| 8 | [`postgresql.md`](./postgresql.md) | PostgreSQL | 2026-05-13 | 10.4 KB | **Critical** — PostgreSQL **14.x EOL 2026-11-12** (six months out); `md5` auth deprecated; latest `18.3` |
| 9 | [`redis.md`](./redis.md) | Redis | 2026-05-13 | 10.5 KB | **Critical** — `7.2.14` (2026-05-05) fixes 3 critical RCE CVEs; license change (RSALv2/SSPL) → Valkey fork is upstream successor for OSS; `rename-command` deprecated, use ACLs |
| 10 | [`docker-compose.md`](./docker-compose.md) | Docker Compose v2 | 2026-05-13 | 12.0 KB | **Info** — Compose v1 EOL; drop `version:` key; prefer `compose.yaml`; latest `v2.40.3` |
| 11 | [`twelve-factor.md`](./twelve-factor.md) | 12-Factor App | 2026-05-13 | 9.3 KB | **Info** — methodology baseline; flag named-environment configs, in-process state, slow boot, in-app log writers |
| 12 | [`hub-scale.md`](./hub-scale.md) | hub Scale 25.10 | 2026-05-13 | 11.1 KB | **Warning** — `25.10.3` current (2026-04-14); cluster docs reference `25.04` (verify); legacy REST API removed in hub 26 — must migrate to JSON-RPC 2.0 over WebSocket |
| 13 | [`cloudflare-tunnel.md`](./cloudflare-tunnel.md) | Cloudflare Tunnel (`cloudflared`) | 2026-05-13 | 13.1 KB | **Warning** — `proxy-dns` removed in `2026.2.0`; `2026.3.0` (2026-03-09) is current; CalVer means rapid release cadence |
| 14 | [`windows-task-scheduler.md`](./windows-task-scheduler.md) | Windows Task Scheduler (Win11 `SYSTEM` services) | 2026-05-13 | 14.8 KB | **Warning** — default `ExecutionTimeLimit = 72h` silently kills daemon-style tasks; SYSTEM cannot read network shares; verify per-Win-host process-manager strategy |

## Highest-priority components (read these first)

Based on what the research turned up, the **five components** the Audit Agent should inspect first — in this order — are:

1. **`postgresql.md` — Critical, time-bound.** PostgreSQL 14.x reaches EOL on **2026-11-12** (six months from research date). If any `apps`/`hub`/Dockge Postgres instance is on 14.x, plan the major-version upgrade now. Also flag `md5` auth (deprecated; switch to `scram-sha-256`).
2. **`redis.md` — Critical, security.** OSS Redis `7.2.14` (released 2026-05-05) patches three critical RCE CVEs. Verify both the `apps` and `hub` Redis containers are pinned to a tag ≥ `7.2.14` (or migrated to Valkey, which is upstream's successor for the OSS line after the 2024 license change).
3. **`nginx.md` — Critical, security.** `1.29.7` (2026-03-24) fixed 5 CVEs; `1.29.8` is current. Confirm both `alfa-ai-nginx` instances (`apps`, `hub`) are on a tag at or after `1.29.7`.
4. **`llamacpp-rpc.md` — Critical, security posture.** Upstream still ships the RPC backend with an explicit "proof-of-concept / insecure / never expose to open network" warning. Confirm `orchestrator` and `gaming-b` `rpc-server` listeners bind to `127.0.0.1` or to the private cluster network only, never to a public interface, and live behind a tunnel/SG. Path moved to `tools/rpc`; build flags must be current.
5. **`litellm.md` — Warning, breaking config.** `usage-based-routing` is deprecated; the cluster's gateway should be on `simple-shuffle` or `latency-based-routing`. Production install requires `master_key`, `LITELLM_SALT_KEY`, Redis ≥ 7.0 with `redis_host`/`redis_port`/`redis_password` (NOT `redis_url`), and `cosign`-verified images.

A close 6th is **`hub-scale.md`** — the legacy REST API is removed in hub 26; if any cluster automation talks to hub via REST, plan the JSON-RPC 2.0 / WebSocket migration. And **`windows-task-scheduler.md`** is a Warning class because the 72-hour default kill silently destroys daemon-style Petals/Ollama tasks every three days unless `ExecutionTimeLimit = PT0S` is explicitly set.

## Note for the Audit Agent

- **Read order:** start with the five files above, then `hub-scale.md`, `windows-task-scheduler.md`, `cloudflare-tunnel.md`, `petals.md`, `ollama.md`, then the remaining four (FastAPI / React-Vite / Docker Compose / 12-Factor) which are mostly hygiene checks.
- **Each file ends with an "AUDIT CHECKLIST" section** containing falsifiable, repo-path-anchored questions. Apply them against:
  - `deploy/docker-compose.yml`, `deploy/litellm_config.yaml`, `deploy/nginx/`, `deploy/cluster-members/<host>/`
  - `docs/NODE_INVENTORY.md`, `docs/ROADMAP.md`, `docs/QWEN3_MIGRATION.md`, `docs/MODEL_FIT_AUDIT.md`
  - `src/api/`, `env.example`, per-host runbooks
- **Cross-cutting findings to surface in the audit report:**
  - Version drift between `apps` and `hub` for the duplicated stack (api, litellm, nginx, postgres, redis).
  - Any service started by both a process manager and a script (violates `deployment-process-ownership.mdc`).
  - Any port binding deviating from `port-assignment-rules.mdc` (8002/8003/8004/8005, `127.0.0.1:` host bind).
  - Any documentation referencing hub 25.04 when the operator system is on 25.10.
- **Versioning sources are explicit** in each file's "Current stable / supported version" section — when in doubt, cite the upstream release-notes URL listed there rather than re-deriving.
- **Each component file is ~150–250 lines.** Do not summarize them away in the audit report; quote the relevant URL + checklist item directly so reviewers can verify.
