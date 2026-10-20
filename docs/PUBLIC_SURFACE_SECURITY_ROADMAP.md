# Public Surface Security Roadmap

**Created:** 2026-06-25  
**Authority:** [.cursor/rules/public-surface-security.mdc](../.cursor/rules/public-surface-security.mdc)  
**Audit agent:** [.cursor/agents/public-surface-cyber-audit.md](../.cursor/agents/public-surface-cyber-audit.md)

This roadmap consolidates findings from four cyber-audit passes run against
`alfa-ai` (API, frontend, deploy/nginx) and `contracts-bot` (sibling repo).
Other cluster repos were not cloned on the audit host and need the same pass
on `apps` before production sign-off.

---

## Executive summary

| Area | Critical | High | Medium | Low |
|------|----------|------|--------|-----|
| alfa-ai API / operator routes | 3 | 3 | 6 | 6 |
| alfa-ai frontend / static UI | 1 | 4 | 5 | 3 |
| alfa-ai deploy / nginx / server | 3 | 4 | 6 | 4 |
| contracts-bot | 3 | 7 | 10 | 5 |
| **Total (deduplicated themes)** | **7 themes** | **10 themes** | **12 themes** | **6 themes** |

**Top risks today**

1. Unauthenticated `GET /api/admin/health` and static `GET /admin/health` expose full cluster topology (LAN IPs, ports, roles).
2. Public `/about` page (`modelHosts.tsx`) publishes host octets and stack layout to anonymous visitors.
3. Production defaults leave `ALFA_AI_ADMIN_ALLOWED_CIDRS` empty and operator health unlocked.
4. Edge nginx passthrough (`alfa-ai-edge-api` -> `:8420`) bypasses brain nginx path filters.
5. `contracts-bot` has unauthenticated debug/upload endpoints and hardcoded secrets in compose.

---

## Phase 0 — Production config (same day, no code)

**Status:** Operator action required on `hub` after deploy.

| # | Action | Host | Env / config |
|---|--------|------|--------------|
| 0.1 | Lock operator health JSON | `hub` | `ALFA_AI_LOCK_OPERATOR_HEALTH=true` (now default in code; explicit in `.env` recommended) |
| 0.2 | Restrict admin login/API to tailnet + LAN | `hub`, `apps` | `ALFA_AI_ADMIN_ALLOWED_CIDRS=100.64.0.0/10,orchestrator/24` |
| 0.3 | Verify OpenAPI disabled on internet-facing API | `hub` | `ALFA_AI_DISABLE_OPENAPI=true` |
| 0.4 | Rotate contracts-bot credentials (removed from compose) | `apps` | Set `JWT_SECRET`, `BOT_API_KEY`, admin passwords in `.env` only |
| 0.5 | UFW / firewall: deny public `:8420`, `:8413` except LAN | `hub` | Document in runbook; verify with external curl |
| 0.6 | Set worker heartbeat token on all workers | all Petals hosts | `ALFA_WORKER_HEARTBEAT_TOKEN` in worker `.env` + brain `.env` |

## Phase 1 — Critical leaks (P0) — IMPLEMENTED 2026-06-25

Code changes landed in `alfa-ai` and `contracts-bot`:

- Operator health locked by default (`ALFA_AI_LOCK_OPERATOR_HEALTH` defaults true)
- Worker heartbeat requires bearer token (unless `ALFA_AI_DEV=true`)
- Static `/admin/health` gated behind operator auth
- Public About page sanitized (no host topology table)
- Chat model picker labels neutralized
- Auth messages uniform; `is_admin` replaces public `role` field
- Guest/chat frontend error sanitization
- Edge nginx denies `/admin`, `/api/admin`, `/api/workers`, `/api/petals`
- contracts-bot: admin-gated run-tests, upload, detailed health; secrets removed from compose

---

## Phase 2 — High priority hardening (P1)

### 2.1 Edge / nginx architecture alignment (alfa-ai)

**Problem:** Public traffic uses `alfa-ai-edge-api` full passthrough to `:8420`,
not path-filtering brain nginx. Docs say CF -> brain nginx.

**Fix (pick one path)**

- **A (recommended):** Edge nginx allowlist — proxy only `/alfa-ai/api/guest/*`,
  `/alfa-ai/api/auth/*`, `/alfa-ai/api/chat/*`, `/health`; deny `/admin`, `/api/admin`,
  `/api/workers`, `/operator`
- **B:** Route CF to brain `alfa-ai-nginx:8090` with explicit locations; update
  `deploy/cluster-members/apps/stacksapps.yml`

**Docs:** Update `docs/DEPLOYMENT_BASELINE.md` to match live ingress.

### 2.2 Authenticate worker heartbeat (alfa-ai)

**Problem:** `POST /api/workers/heartbeat` is unauthenticated; returns Redis key names.

**Fix:** Require `ALFA_WORKER_HEARTBEAT_TOKEN` bearer; return `{ok: true}` only.

### 2.3 Petals bootstrap error sanitization (alfa-ai)

**Problem:** 503/400 responses mention env var names and `str(exc)` internals.

**Fix:** Generic errors; restrict route to worker network at nginx/edge.

### 2.4 Auth message uniformity (alfa-ai + all bots)

| Current | Required |
|---------|----------|
| `Account deactivated` (403) | `Invalid email, username, or password` (401) |
| `Email already registered` / `Username already taken` | Single generic registration failure |
| `Invalid token type`, `User not found`, `Invalid 2FA code` | `Authentication failed` or login denial string |
| `Admin role required`, `Admin only` | `Access denied.` or `Insufficient permissions` |
| `DATABASE_URL not configured` | `Service temporarily unavailable` |

**Files:** `src/api/routers/auth.py`, `src/api/auth_deps.py`, `src/api/deps.py`;
mirror pattern in each bot `api/routes/auth.py`.

### 2.5 Frontend error sanitization (alfa-ai + contracts-bot)

**Problem:** `GuestChat.tsx`, `Chat.tsx`, `ApiError` render raw API `detail`.

**Fix:** Client helper maps 5xx/upstream to generic copy (see
`websites/.../alfa-ai-chat-widget.js` pattern). contracts-bot: fix `aiErrorFormat.ts`.

### 2.6 contracts-bot — scrub topology from AI errors

**Files:** `api/routes/ai.py`, `ai_narrative.py`, `frontend/src/lib/aiErrorFormat.ts`

**Fix:** `"AI service unavailable"` publicly; log LiteLLM URL server-side.

### 2.7 contracts-bot — remove `VITE_API_KEY`

Client-baked secrets are public. Use HttpOnly session cookies; server-side validation only.

### 2.8 Omit `role` from public user DTO (alfa-ai)

**Problem:** Chat header shows `{user.role}` badge; confirms role model.

**Fix:** Omit `role` from `/me` for non-admin contexts or show `Member` only.

---

## Phase 3 — Medium priority (P2)

| ID | Repo | Item |
|----|------|------|
| 3.1 | alfa-ai | Admin aria2 errors leak `hub` — generic 502 |
| 3.2 | alfa-ai | Static `health.html` copy names `orchestrator/hub/apps` — generic operator text |
| 3.3 | alfa-ai | `build_hash` on public `/health` — optional removal |
| 3.4 | alfa-ai | LiteLLM `:8413` bind `127.0.0.1` or firewall |
| 3.5 | alfa-ai | SPA `/alfa-ai/admin/*` shell loads without server auth — nginx auth subrequest optional |
| 3.6 | contracts-bot | Disable `/docs`, `/redoc`, `/openapi.json` in production |
| 3.7 | contracts-bot | Lock `/metrics` to localhost |
| 3.8 | contracts-bot | DB errors: remove `original_error` from public JSON |
| 3.9 | contracts-bot | Restrict `/api/logs` to admin |
| 3.10 | contracts-bot | Frontend `RequireAdmin` on `/admin/health` |
| 3.11 | all bots | Registration/login enumeration — generic failures |
| 3.12 | all bots | Add `admin_network.py` pattern (CIDR allowlist for admin routes) |

---

## Phase 4 — Sibling repo audit backlog (not yet scanned)

Run `.cursor/agents/public-surface-cyber-audit.md` on `apps` for each clone:

| Repo | Path on `apps` | Priority |
|------|----------------|----------|
| rankings-bot | sibling of alfa-ai | P1 (public website) |
| market-pie5-bot | sibling | P1 |
| credit-check-bot | sibling | P1 |
| atems | sibling | P2 |
| auth-service | sibling | P0 (auth surface) |
| rv-auto-finder | sibling | P2 |

**Command on `apps`:** Launch cyber audit agent per repo; append findings to this doc.

---

## Phase 5 — Continuous compliance

### 5.1 CI grep gate (alfa-ai)

Add to pre-commit or CI:

```bash
# Fail if public-route files introduce LAN IPs in HTTPException detail strings
rg -n "detail=.*192\.168" src/api/routers/auth.py src/api/routers/guest.py frontend/src/pages/GuestChat.tsx
```

Expand allowlist carefully; admin-only files excluded.

### 5.2 PR checklist

Extend `.github/PULL_REQUEST_TEMPLATE.md`:

- [ ] Public route errors use `PUBLIC_*_DETAIL` or `public_errors.py`
- [ ] No new host octets/ports in `frontend/src/content/` or guest surfaces
- [ ] Admin routes tested with `ALFA_AI_ADMIN_ALLOWED_CIDRS` set

### 5.3 Quarterly re-audit

Re-run cyber audit agent after:

- nginx / Cloudflare tunnel changes
- New public API routes
- New bot deployments to `apps`

---

## Positive controls already in place

- `src/api/admin_network.py` — correct public denial strings for network blocks
- `src/api/public_errors.py` — upstream chat/guest failures sanitized
- Global 500 handler — generic `UNEXPECTED_ERROR`
- Login wrong-password path — uniform `Invalid email, username, or password`
- Login lockout enforced (5 failures / 15 min -> 15 min lock; a correct password does not bypass it) plus a per-client-IP failed-login limit (`ALFA_AI_LOGIN_IP_MAX_FAILURES` / `ALFA_AI_LOGIN_IP_WINDOW_SEC`, Uvicorn trusted-proxy IP). See [AUTH_ACCOUNT_LIFECYCLE.md](AUTH_ACCOUNT_LIFECYCLE.md#failed-login-lockout-and-per-ip-limit)
- `/alfa-ai/api/admin/*` — requires admin JWT
- OpenAPI disabled by default in production compose
- WordPress guest widget — generic errors (good reference)
- contracts-bot — global exception handler avoids tracebacks on unexpected 500s
- contracts-bot API bound to `127.0.0.1:8002` on host (nginx proxied)

---

## Implementation ownership

| Phase | Owner | Est. effort |
|-------|-------|-------------|
| 0 — prod config | Operator (`hub`/`apps`) | 1 hour |
| 1 — critical code | Dev on `apps` | 3-5 days |
| 2 — high hardening | Dev on `apps` + bot repos | 1-2 weeks |
| 3 — medium | Dev + bot maintainers | 2 weeks |
| 4 — sibling audits | Dev on `apps` | 1 day per repo |
| 5 — CI / process | Dev on `apps` | 1 day |

---

## Related docs

- [public-surface-security.mdc](../.cursor/rules/public-surface-security.mdc) — rule source
- [admin_network.py](../src/api/admin_network.py) — reference implementation
- [public_errors.py](../src/api/public_errors.py) — upstream error pattern
- [DEPLOYMENT_BASELINE.md](DEPLOYMENT_BASELINE.md) — ingress (needs alignment with Phase 2.1)
