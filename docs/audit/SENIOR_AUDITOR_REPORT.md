# Senior Auditor Report — ALFa AI + integrations

| Field | Value |
|-------|--------|
| **Date** | 2026-07-11 |
| **Auditor role** | Skeptical senior programming auditor (`/senior-auditor`) |
| **Scope** | `alfa-ai` brain + consumers (contracts-bot, rankings-bot, market-pie5-bot) + monitoring-tmp + in-repo public surfaces |
| **Method** | Repo inventory, cross-repo integration map, official vendor doc research |
| **Live hosts** | **Not probed** (except prior session start log: cluster start OK 2026-07-11T012949Z) |
| **Status** | Findings + **repo remediations landed 2026-07-11** (see §8). Live `.env`/UFW still operator. |

---

## 1. Executive risk summary

1. **Auth defaults are LAN-trust, not production-hardened** — orchestrator API auth off by default; LiteLLM published on host port; shared/dev master key pattern across bots. Violates LiteLLM production guidance to protect the proxy with a real master key / virtual keys.
2. **Doc topology is multi-truth** — RAG host (`pool-opt-in` vs `inference`), Petals retirement, operator ports, and REPO_HOST_MAPPING cutover language disagree with compose/inference SSoT and each other. Operators will miswire embeddings or chase dead Petals paths.
3. **Public + dual-path consumers** — rankings `demo-ask` / USPBF static + Ollama fallback can bypass LiteLLM alias policy; market couples trading to brain availability (`BOT_REQUIRE_BRAIN`).
4. **Proxy trust is over-broad** — Uvicorn `--forwarded-allow-ips=*` + Docker-publish CIDR bypass means admin/guest identity can be spoofed if anything but the trusted edge can reach the app. Contradicts Uvicorn deployment guidance.
5. **Async FastAPI + sync DB/LLM** — event-loop blocking under concurrent admin/chat load; no connection pooling. Correctness under light ops load; efficiency risk as Ask ALFa + bots scale.

---

## 2. Integration matrix (compressed)

| Caller | Type | Trust zone | Default brain URL | Key risk |
|--------|------|------------|-------------------|----------|
| **alfa-ai** (provider) | LiteLLM + orchestrator + guest + admin | all zones | compose internal + `:8413`/`:8420` | `REQUIRE_API_AUTH` default false |
| **contracts-bot** (apps) | LiteLLM HTTP + opt-in orchestrator + widget | app / tools | `hub` | orchestrator timeout 120s vs LLM 1200s |
| **rankings-bot** (probilliards) | LiteLLM + **Ollama dual-path** + **public demo** | public + app | **`localhost:8413`** | wrong host default after split; public surface |
| **market-pie5-bot** (market) | LiteLLM + **RAG embed** + orchestrator (implicit) | app / internal | `hub` | `BOT_REQUIRE_BRAIN`; orchestrator 30s |
| **monitoring** (monitor) | Alertmanager webhook + blackbox | ops | `hub:8420` / `:8413` | scrape still points rankings at **apps** |
| **USPBF static** (template in alfa-ai) | UI → rankings demo-ask | public_web | via rankings | theme/security drift vs chat-widget |
| **WP guest plugin** (alfa-ai websites) | same-origin guest chat | public_web | edge → API | rate limit process-local |
| credit-check / atems / auth / rv | **no local clone** | — | — | un-auditable from this workstation |

---

## 3. Discrepancy list (verified in repo)

### D-001 — Severity: **critical** (if LAN-reachable without UFW)
- **Area:** security
- **Finding:** Uvicorn is started with `--proxy-headers --forwarded-allow-ips=*`, so any client can spoof `X-Forwarded-For`. Admin CIDR and guest rate-limit keys that trust the first XFF hop become forgeable when the app port is reachable.
- **Evidence:** `deploy/Dockerfile.api` CMD (`--forwarded-allow-ips=*`); guest/admin network helpers using client IP.
- **Official baseline:** Uvicorn deployment docs: configure `--forwarded-allow-ips` to **only** trust real proxy IPs/networks; *“Only trust clients you can actually trust! Incorrectly trusting other clients can lead to malicious actors spoofing their apparent client address.”* — https://uvicorn.dev/deployment/
- **Discrepancy:** Wildcard `*` trusts everyone, opposite of official guidance.
- **Corrective action:**
  1. Set `--forwarded-allow-ips` to the Docker bridge / nginx container IP(s) only (or edge CIDR), not `*`.
  2. Prefer reading client IP from a single trusted hop at the edge; document hop count.
  3. Keep operator `:8420` firewalled (UFW) so only /LAN admin ranges reach it.
- **Acceptance:** From a non-proxy host, forged `X-Forwarded-For` does not change admin allow/deny or guest rate-limit bucket identity.

### D-002 — Severity: **critical** (prod misconfig)
- **Area:** security / integration
- **Finding:** `ALFA_AI_REQUIRE_API_AUTH` defaults **false**. Tool-bearing `POST /api/runs*` and related orchestrator routes are unauthenticated unless env is set. Market can call orchestrator with empty token.
- **Evidence:** `deploy/docker-compose.yml` / `env.example`; `src/api/auth_deps.py`; market `alfa_orchestrator_client.py`.
- **Official baseline:** FastAPI security model assumes protected dependencies on sensitive routes (OAuth2/JWT/Bearer). LiteLLM production expects the proxy and admin surfaces to require keys. — https://fastapi.tiangolo.com/tutorial/security/oauth2-jwt/ ; https://docs.litellm.ai/docs/proxy/prod
- **Discrepancy:** Homelab default leaves high-power agent API open on any host that can reach `:8420`.
- **Corrective action:**
  1. Production `.env` on `hub`: `ALFA_AI_REQUIRE_API_AUTH=true` + strong `ALFA_AI_API_TOKEN`.
  2. Flip compose default to `true` for non-dev profiles (or document mandatory preflight that fails start if unset on brain).
  3. Consumers: fail-fast if orchestrator enabled and token empty (contracts already closer).
- **Acceptance:** Unauthenticated `POST /api/runs` → 401/403; contracts/market file runs succeed only with Bearer.

### D-003 — Severity: **high**
- **Area:** security / integration
- **Finding:** Shared/dev LiteLLM master key pattern: `change-me` in consumer code defaults and `.env.example` files; LiteLLM host port published for LAN bots.
- **Evidence:** rankings/market `litellm_client.py` defaults; contracts `.env.example`; compose LiteLLM `8413:4000`.
- **Official baseline:** LiteLLM production: set a real `master_key` / `LITELLM_MASTER_KEY`; use **virtual keys** to scope model access and spend per consumer. — https://docs.litellm.ai/docs/proxy/prod ; https://docs.litellm.ai/docs/proxy/virtual_keys
- **Discrepancy:** One well-known key = full proxy for all aliases if port is reachable; no per-bot virtual keys in code.
- **Corrective action:**
  1. Generate unique `LITELLM_MASTER_KEY` (and optional salt) for prod; store only in host secrets.
  2. Issue **virtual keys** per consumer (contracts / rankings-public / rankings-app / market) with model allowlists.
  3. Remove hardcoded dev defaults from runtime code paths (require env; fail closed).
  4. Bind LiteLLM to loopback + reverse-proxy, or firewall 8413 to known bot hosts only.
- **Acceptance:** Old `change-me` rejected; each bot uses distinct key; unauthorized model alias denied.

### D-004 — Severity: **high**
- **Area:** docs-drift / correctness
- **Finding:** **RAG host multi-truth.** Code/`deploy/env.example`/ROADMAP/inference comments: CPU embed+rerank on **`inference`**. `REPO_HOST_MAPPING.md` / parts of PORT_ASSIGNMENTS still describe Track B **`pool-opt-in:11435`/`:8360`**. Recent start log verified RAG phase on **`inference`**.
- **Evidence:** `deploy/env.example` EMBED/RERANK URLs; `docs/REPO_HOST_MAPPING.md` embed/rerank section; start log 20260711-012949 RAG sidecars `inference`.
- **Official baseline:** Internal SSoT policy (program plan KD-9): shards.env + rag-sidecars + litellm + Invoke override stale plans. Single operational truth required for any multi-host system.
- **Discrepancy:** Operators following REPO_HOST_MAPPING will point consumers at dead or wrong embed endpoints.
- **Corrective action:**
  1. Rewrite REPO_HOST_MAPPING dual-NIC / embed rows to **`inference` RAG** + **`pool-opt-in` pool shard only**.
  2. Grep-clean `11435`/`8360` on `pool-opt-in` as “current” in active docs.
  3. Add one line to PORT_ASSIGNMENTS: “RAG SSoT = rag-sidecars.env”.
- **Acceptance:** Zero active-doc claims that production RAG lives on `pool-opt-in`; `curl` health only documented for `inference`.

### D-005 — Severity: **high**
- **Area:** docs-drift
- **Finding:** Root `README.md` still describes **Petals** workers and wrong operator port (**8020** vs **8420**). Petals retired 2026-07-09 in ROADMAP/plans; `deploy/petals/` removed.
- **Evidence:** `README.md` L5, L85+; ROADMAP Petals retired banner.
- **Official baseline:** Project’s own ROADMAP/DISTRIBUTED_AI as post-retirement SSoT; dead docs violate “single source of truth” ops practice.
- **Discrepancy:** First file newcomers read is actively wrong.
- **Corrective action:** Rewrite README stack section: RPC-only inference, brain `hub`, edge `inference:8420`, link ROADMAP; delete Petals setup steps.
- **Acceptance:** `README.md` grep for Petals/8020 returns none in active setup sections.

### D-006 — Severity: **high**
- **Area:** integration / ops
- **Finding:** rankings-bot default LiteLLM base is **`http://localhost:8413`** while host map places rankings on **`probilliards`** and brain on **`hub`**. Unless `.env` overrides, AI silently falls back to Ollama dual-path or fails.
- **Evidence:** `rankings-bot/api/services/litellm_client.py`; `REPO_HOST_MAPPING.md` rankings row.
- **Official baseline:** LiteLLM clients must target the proxy base URL where the proxy actually listens (OpenAI-compatible `api_base`). Mis-pointed clients are configuration defects, not “graceful dual path.”
- **Discrepancy:** contracts/market default LAN IP; rankings defaults localhost (pre-split era).
- **Corrective action:**
  1. Change default to `http://hub` (or env-only, no localhost).
  2. Fix `.env.example` comments (`8013` / docker DNS only when on shared network).
  3. Log clearly when falling back to Ollama so dual-path is auditable.
- **Acceptance:** On `probilliards` with only LAN env, LiteLLM path used; metrics show alias hits.

### D-007 — Severity: **high**
- **Area:** integration / ops
- **Finding:** Monitoring Prometheus still scrapes **rankings on `apps`** while REPO_HOST_MAPPING says rankings live on **`probilliards`**. Blackbox still references topology notes involving Petals / `orchestrator:8413` patterns.
- **Evidence:** `monitoring-tmp/prometheus/prometheus.yml`; host map rankings row.
- **Official baseline:** Prometheus scrape configs must match actual service discovery / host inventory or alerts are false.
- **Discrepancy:** Ops “truth” disagrees with host map → blind spots or false downs.
- **Corrective action:**
  1. Retarget rankings (and any moved bots) scrapes to current hosts/ports.
  2. Remove or relabel Petals probes.
  3. Add CI/doc check: host map ↔ prometheus job host list.
- **Acceptance:** `up` metrics green for live rankings on `probilliards`; no scrape to decommissioned `apps` rankings API.

### D-008 — Severity: **medium**
- **Area:** security
- **Finding:** JWT access (~300 min) + refresh (~70 days) stored in **localStorage** (`AuthContext.tsx`). Any XSS steals full session.
- **Evidence:** `frontend/src/contexts/AuthContext.tsx`.
- **Official baseline:** Industry/OWASP-aligned guidance: avoid localStorage for tokens when possible; prefer **httpOnly Secure cookies** so JS cannot read tokens. — OWASP HTML5 / JWT storage discussions (XSS amplifies localStorage theft).
- **Discrepancy:** SPA convenience over defense-in-depth.
- **Corrective action:**
  1. Short-term: strict CSP, dependency audit, sanitize admin HTML paths.
  2. Medium: migrate access token to httpOnly cookie + CSRF strategy for cookie auth, or BFF pattern.
  3. Reduce refresh TTL; rotate on privilege change.
- **Acceptance:** XSS PoC cannot `localStorage.getItem` a live access token (cookie httpOnly).

### D-009 — Severity: **medium**
- **Area:** security / correctness
- **Finding:** API service default `LLAMACPP_CODE27_URL=http://127.0.0.1:31360/v1` inside Docker bridge is wrong; LiteLLM uses `host.docker.internal`. If API ever talks direct to coordinator with default, it fails closed or hits wrong stack.
- **Evidence:** `deploy/docker-compose.yml` API env default vs LiteLLM service default; `deploy/env.example`.
- **Official baseline:** Container localhost is the container itself, not the host (Docker networking).
- **Discrepancy:** Two different defaults for the same logical upstream.
- **Corrective action:** Align API default with LiteLLM (`host.docker.internal` or host gateway); document host-probe-only use of `127.0.0.1` on hub shell.
- **Acceptance:** Unset override still reaches coordinator from API container.

### D-010 — Severity: **medium**
- **Area:** performance / correctness
- **Finding:** FastAPI routes are `async` but stores use **sync** `psycopg.connect` per call; agent LLM uses **sync** OpenAI client. Under concurrent Ask ALFa + admin, event loop blocks.
- **Evidence:** store patterns under `src/api/`; `src/llm/client.py`.
- **Official baseline:** FastAPI docs: blocking I/O in async endpoints should run in threadpool or use async drivers (`asyncpg` / httpx AsyncClient).
- **Discrepancy:** Architecture looks concurrent; runtime is largely single-threaded blocking.
- **Corrective action:**
  1. Short-term: `asyncio.to_thread` for hot sync paths; connection pool (`psycopg_pool`).
  2. Medium: asyncpg or psycopg async; async httpx for LLM.
- **Acceptance:** 10 concurrent admin health + chat requests do not serialize on one blocked worker for multi-second DB waits.

### D-011 — Severity: **medium**
- **Area:** security
- **Finding:** Guest chat is unauthenticated LLM spend with **process-local** rate limits; multi-worker multiplies quota; XFF spoof (D-001) resets identity.
- **Evidence:** `src/api/routers/guest.py`.
- **Official baseline:** Public LLM endpoints need durable rate limiting (Redis) and trusted client identity.
- **Discrepancy:** In-memory map is not a shared limiter.
- **Corrective action:** Redis rate limit keyed by stable client id; lower guest model budget; optional CAPTCHA/turnstile on WP; never tools on guest (already tested — keep).
- **Acceptance:** Two API workers share one counter; guest cannot invoke tools (existing contract tests remain green).

### D-012 — Severity: **medium**
- **Area:** integration
- **Finding:** Timeout matrix is inconsistent: contracts LiteLLM 1200s / feature 300–600s / orchestrator **120s**; market orchestrator default **30s**. Long agent jobs fail while chat succeeds.
- **Evidence:** consumer clients (see integration explore).
- **Official baseline:** Client timeout ≥ server/proxy timeout ≥ model p99 latency; document ladder.
- **Discrepancy:** No shared timeout policy across repos.
- **Corrective action:** Publish timeout ladder in AI_GOVERNANCE consumer stub; set orchestrator ≥ expected agent wall; disable retries on 429 that stampede pool (contracts research already notes careful retry).
- **Acceptance:** Documented matrix; no silent 30s kill on market agent jobs.

### D-013 — Severity: **medium**
- **Area:** integration / security
- **Finding:** Rankings dual-path (LiteLLM → Ollama) and residual contracts Ollama-direct flag create **two policy planes**. Public demo may not honor LiteLLM alias controls when LiteLLM is “enabled” but unreachable.
- **Evidence:** rankings `ai_narrative_llm.py`; contracts residual flags.
- **Official baseline:** Single choke-point proxy for model access (LiteLLM virtual keys / model list) is the production pattern. — LiteLLM proxy docs.
- **Discrepancy:** App-level backup undoes central governance.
- **Corrective action:** Production: `LITELLM_ENABLED=true` and **fail closed** (no Ollama) except explicit `*_ALLOW_OLLAMA_DIRECT=1` for break-glass; log metric on fallback.
- **Acceptance:** With LiteLLM down, public demo returns 503 not Ollama answer (prod mode).

### D-014 — Severity: **medium**
- **Area:** security
- **Finding:** Postgres compose default password `alfaai` if env not overridden.
- **Evidence:** `deploy/docker-compose.postgres.yml`.
- **Official baseline:** PostgreSQL/Docker: always set strong `POSTGRES_PASSWORD`; never leave default/weak passwords in production; limit network exposure. — PostgreSQL auth best practices; docker-library postgres requires password env.
- **Discrepancy:** Convenience default invites copy-paste prod.
- **Corrective action:** Remove weak default; require env; document rotation; bind only internal Docker network (already largely true).
- **Acceptance:** Stack refuses to start without strong password set.

### D-015 — Severity: **low**
- **Area:** docs-drift / product
- **Finding:** `AI_GOVERNANCE_CONSUMER_STUB.md` exists only in alfa-ai; contracts/rankings/market do not ship a local governance stub (NIST-W4 incomplete).
- **Evidence:** alfa-ai `docs/AI_GOVERNANCE_CONSUMER_STUB.md`; consumer docs trees lack copy.
- **Official baseline:** Program COMPOSER NIST plan Wave 4 requires consumer stubs.
- **Discrepancy:** Policy not distributed where engineers work.
- **Corrective action:** PR-11 style: copy stub + consumer-only cursor rule to each bot; link REPO_HOST_MAPPING.
- **Acceptance:** Each consumer repo has `docs/AI_GOVERNANCE.md` stub with L1/L2/L3 table.

### D-016 — Severity: **low**
- **Area:** performance / docs
- **Finding:** Ask ALFa concurrent soft cap (3) is **frontend-only** (`MAX_CONCURRENT_BUSY`). Direct API clients ignore it. Docs describe soft cap as a control without server enforcement.
- **Evidence:** `frontend/.../AskAlfaWidget.tsx`; no matching Semaphore in `src/`.
- **Official baseline:** Capacity controls that matter must be server-side when the API is multi-client.
- **Discrepancy:** UX guard ≠ enforcement.
- **Corrective action:** Optional Redis counter / LiteLLM rate limit per virtual key for admin agent model; keep UI soft cap as UX only, document as such.
- **Acceptance:** Docs say “UI soft cap”; server limits documented separately.

### D-017 — Severity: **low**
- **Area:** security
- **Finding:** Host-actions private key **on disk** under `deploy/secrets/host-actions/` but **gitignored** (only `.gitkeep` tracked). Code correctly refuses `known_hosts=None` (asyncssh MITM baseline). Good pattern if keys never commit.
- **Evidence:** `git ls-files` → `.gitkeep` only; `.gitignore` ignores `id_ed25519`; `ssh_executor.py` requires known_hosts.
- **Official baseline:** AsyncSSH/OpenSSH: verify host keys; never `known_hosts=None` in production. — asyncssh docs / SSH host key verification practice.
- **Discrepancy:** None for code path if defaults stay disabled; residual risk is workstation secret sprawl (`alfa-ai-deploy.env.backup` etc. outside repo).
- **Corrective action:** Keep host actions disabled until training (KD-23); ensure backup env files not in cloud sync; rotate if key ever left gitignored-but-copied insecurely.
- **Acceptance:** `git ls-files` never lists private key; host actions default off.

### D-018 — Severity: **nit**
- **Area:** ops
- **Finding:** pyproject.toml dependency set incomplete vs `requirements.txt` (missing JWT stack if someone installs via pyproject only).
- **Evidence:** `pyproject.toml` vs `requirements.txt`.
- **Official baseline:** Single install path for the service that actually runs (Docker uses requirements.txt — OK).
- **Corrective action:** Generate lockfile or make pyproject the SSoT exported to requirements.
- **Acceptance:** One documented install path for API image and local dev.

---

## 4. Improvement backlog (not pure defects)

| ID | Theme | Proposal | Benefit | Effort | Depends |
|----|-------|----------|---------|--------|---------|
| I-01 | Features | Ship Ask ALFa cancel (AbortController + disconnect) | Free pool slots; better UX | M | brain rebuild |
| I-02 | Features | WorkflowRunner implement→review→fix (mutate off default) | Cursor-class loops on 27B | L | OP-GATE-1 for live E2E |
| I-03 | Features | LiteLLM virtual keys per bot | Blast-radius limit | M | D-003 |
| I-04 | Efficiency | psycopg pool + to_thread/async | Lower latency under concurrency | M | D-010 |
| I-05 | Efficiency | Shared httpx.AsyncClient for chat/guest | Fewer TLS handshakes | S | — |
| I-06 | Performance | Keep PARALLEL=10 only if Ask-AI go criteria met; record tok/s | Evidence-based ctx vs concurrency | S ops | OP-GATE-1 metrics |
| I-07 | Hardware | `secondary` 1070 only after Pascal image + nvidia-smi | More VRAM for PARALLEL or dense frontier | L | physical GPU |
| I-08 | Hardware | Opportunistic gaming shards after primary stable | Burst capacity | M | D-004/005 docs clean |
| I-09 | Docs | Master SSoT pass (README + REPO_HOST + PORT + CLUSTER_*) | Stop dual-truth ops | M | D-004/005 |
| I-10 | Code | Server-side agent concurrency + circuit multi-replica (Redis) | Correct under multi-worker | M | — |
| I-11 | Security | httpOnly JWT cookies or shorter refresh | XSS impact reduction | L | D-008 |
| I-12 | Integration | Fail-closed dual-path on rankings public | Governance choke point | M | D-013 |
| I-13 | Ops | Prometheus job generator from REPO_HOST_MAPPING | Scrape drift dies | M | D-007 |
| I-14 | Product | Unified chat-widget only for public demos (drop static fork drift) | One theme pipeline | M | USPBF |

---

## 5. Hardware / performance notes (skeptical)

| Topic | Current (repo) | Auditor note |
|-------|----------------|--------------|
| Pool | Qwen3.6-27B RPC, PARALLEL=10, CTX 163840 (16384/slot) | Matches llama.cpp model: **total ctx ÷ parallel = per-slot** — document operators must not expect 163k **per** concurrent request. Official llama.cpp server semantics divide ctx among slots. |
| Shards | `inference×2`, `orchestrator`, `pool-opt-in`, `hub` tail | 5-shard live after successful start 2026-07-11; `secondary` paused correctly. |
| RAG | CPU on `inference` (start path) | Do not co-locate heavy RAG on scarce GPU shards. |
| Circuit | In-process agent circuit (3/60s) | Not cluster-wide; OK for single brain replica. |
| Warm | keep-inference-warm post-start | Good against cold RPC load 503s. |

---

## 6. Sources

### Official / primary (research pass)

- Uvicorn deployment / `forwarded-allow-ips`: https://uvicorn.dev/deployment/
- FastAPI OAuth2 JWT: https://fastapi.tiangolo.com/tutorial/security/oauth2-jwt/
- LiteLLM production: https://docs.litellm.ai/docs/proxy/prod
- LiteLLM virtual keys: https://docs.litellm.ai/docs/proxy/virtual_keys
- AsyncSSH API: https://asyncssh.readthedocs.io/
- llama.cpp parallel/ctx division: ggml-org/llama.cpp server behavior (ctx shared across `--parallel` slots; see project issues/docs on `--ctx-size` / `--parallel`)
- PostgreSQL password practices: PostgreSQL auth best practices; docker-library postgres password requirement
- JWT/localStorage XSS: OWASP HTML5 storage guidance / industry consensus on httpOnly preference

### Repo paths (primary evidence)

- `deploy/Dockerfile.api`, `deploy/docker-compose.yml`, `deploy/env.example`
- `deploy/llamacpp-rpc/inference-shards.env`, `deploy/litellm_config.yaml`
- `src/api/auth_deps.py`, `src/agent/tools.py`, `src/llm/client.py`, `src/ops/ssh_executor.py`
- `frontend/src/contexts/AuthContext.tsx`, `frontend/src/components/admin/AskAlfaWidget.tsx`
- `docs/REPO_HOST_MAPPING.md`, `docs/ROADMAP.md`, `README.md`
- `contracts-bot/api/services/litellm_client.py`, `.../alfa_orchestrator_client.py`
- `rankings-bot/api/services/litellm_client.py`, `.../ai_narrative_llm.py`
- `Desktop/repos/market-bot/api/services/litellm_client.py`, `.../market_rag.py`
- `monitoring-tmp/prometheus/prometheus.yml`, `alertmanager/alertmanager.yml`

### Prior in-repo audit research (secondary)

- `docs/audit/research/*.md` (fastapi, litellm, llamacpp-rpc, redis, postgresql, …)

---

## 7. Out of scope / unverified

- Live `hub` `deploy/.env` values (auth, master key, EMBED URLs).
- UFW rules on hub / Windows firewall on `orchestrator`.
- credit-check, atems, auth-service, live USPBF (no clones here).
- Whether `change-me` is still the **live** master key.
- Runtime guest abuse tests against production.
- Full dependency CVE scan (recommend scheduled `pip-audit` / `npm audit` in CI).

---

## 8. Remediation status (2026-07-11 autonomous pass)

| ID | Status | What landed in git |
|----|--------|-------------------|
| D-001 | **Fixed (repo)** | `Dockerfile.api` + compose: `FORWARDED_ALLOW_IPS` default private ranges, not `*` |
| D-002 | **Fixed (repo default)** | compose/`env.example` `ALFA_AI_REQUIRE_API_AUTH` default **true** — **verify live `.env` on `hub` still overrides correctly** |
| D-003 | **Partial** | Removed shared `change-me` code defaults (alfa-ai client, rankings, market); env.examples cleared. **Virtual keys still operator (LiteLLM admin)** |
| D-004 | **Fixed (docs)** | REPO_HOST_MAPPING + PORT_ASSIGNMENTS RAG → **`inference`**; `pool-opt-in` shard-only |
| D-005 | **Fixed (docs)** | README Petals retired; operator port **8420** |
| D-006 | **Fixed (code)** | rankings default base `http://hub` |
| D-007 | **Fixed (local snapshot)** | `monitoring-tmp/prometheus.yml` rankings target → `probilliards`; legacy `orchestrator:8413` probe commented. **Push to live monitoring on `monitor`** |
| D-009 | **Fixed** | API `LLAMACPP_CODE27_URL` → `host.docker.internal` |
| D-013 | **Fixed (rankings)** | Ollama fallback off when LiteLLM enabled unless `LITELLM_ALLOW_OLLAMA_FALLBACK` |
| D-014 | **Fixed (compose)** | Postgres requires `ALFA_POSTGRES_PASSWORD` (no `alfaai` default) |
| D-015 | **Fixed** | `docs/AI_GOVERNANCE.md` stubs in contracts/rankings/market |
| D-016 | **Fixed (docs)** | AI_ACTIONS soft cap labeled UI-only |
| D-010 | **Partial (2026-07-11)** | `db_pool.py` + AiSettingStore; `psycopg_pool` in requirements |
| D-011 | **Fixed (2026-07-11)** | Redis sliding-window guest rate limit + memory fallback |
| D-008 | **Open** | httpOnly JWT cookies |
| Live P0 | **Operator** | Confirm `hub` env: auth token, JWT secret, master key, UFW; recreate brain image for Dockerfile change |

### Remaining operator actions (not automated)

1. On `hub`: ensure `deploy/.env` has strong secrets; `ALFA_AI_REQUIRE_API_AUTH=true`; unique `LITELLM_MASTER_KEY`.
2. Rebuild/recreate **alfa-ai-api** so `FORWARDED_ALLOW_IPS` Dockerfile change is live (full start or targeted recreate — operator).
3. Deploy monitoring prometheus.yml to `monitor` (monitoring-tmp is a workstation snapshot).
4. Push/commit rankings-bot, contracts-bot, market-bot from their repos if separate remotes.
5. Issue LiteLLM virtual keys per bot (I-03 / D-003 complete).

## 8b. Earlier suggested fix order (superseded where fixed above)

| Priority | Actions |
|----------|---------|
| **P0 remaining** | Live `.env` + brain image recreate + monitoring push |
| **P2 remaining** | D-010 pooling; D-011 Redis guest limit; D-008 cookies |
| **P3** | I-01 cancel; I-02 WorkflowRunner; I-07/I-08 hardware gates |

---

## 9. Agent installation

| Location | Path |
|----------|------|
| Grok user skill | `~/.grok/skills/senior-auditor/SKILL.md` → `/senior-auditor` |
| Checklist | `~/.grok/skills/senior-auditor/references/checklist.md` |
| alfa-ai agent skill | `alfa-ai/skills/senior-auditor/SKILL.md` |

Re-run: `/senior-auditor` or “senior audit alfa-ai integrations”.

---

*End of report. Skeptical posture: any claim not backed by path or official URL is labeled unverified.*
