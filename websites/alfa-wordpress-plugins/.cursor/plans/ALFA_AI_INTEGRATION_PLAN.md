# ALFa AI Integration Plan — alfa-wordpress-plugins

> Doc-first, single best path. WordPress plugin archetype — **not** a Docker service. Plugins are PHP files copied into the WordPress instance behind www.example.com.
>
> **Architecture decision (Wave 3 sign-off):** WordPress chat uses the **proxy-via-alfa-ai pattern** (Option A). The browser calls **same-origin `/alfa-ai/api/guest/chat`** (or `/alfa-ai/api/chat` for admin); nginx (`alfa-nginx`) forwards to `alfa-ai-api:8000` on `tunnel_network`; `alfa-ai` calls LiteLLM at `http://hub`. **WordPress PHP never holds a LiteLLM URL, API key, or talks to `:8413` directly.** This matches the USPBF (Wave 3b) thin-client pattern and keeps inference, trust zones, rate limits, anti-hallucination, and telemetry in `alfa-ai` where they already exist.
>
> See [/home/operator/.cursor/plans/ALFA_AI_INTEGRATION_PLAN_HOST_105.md](/home/operator/.cursor/plans/ALFA_AI_INTEGRATION_PLAN_HOST_105.md) §1 (host service contract) and [/home/operator/alfaqd-website/.cursor/plans/ALFA_AI_INTEGRATION_PLAN.md](/home/operator/alfaqd-website/.cursor/plans/ALFA_AI_INTEGRATION_PLAN.md) (edge/proxy owner — sibling plan).

---

## 0. Authoritative References

### ALFa AI canonical (read-only, `/home/operator/alfa-ai`)

1. `alfa-ai/docs/CURRENT_CAPABILITIES_AND_USE_CASES.md`
2. `alfa-ai/docs/PORT_ASSIGNMENTS.md`
3. `alfa-ai/docs/ADMIN_HEALTH_WEB_WORKFLOW.md` — confirms alfaqd-website is **edge-only**; inference stays in `alfa-ai`
4. `alfa-ai/docs/COLLABORATION_RUNTIME.md`
5. `alfa-ai/src/api/routers/guest.py` — anonymous `POST /alfa-ai/api/guest/chat`; per-IP rate limit; uses `llm_tuple(role="guest")`
6. `alfa-ai/deploy/litellm_config.yaml` — model alias SSoT (`public-chat`, `app-chat`, `agent`)
7. `/home/operator/.cursor/plans/ALFA_AI_INTEGRATION_PLAN_HOST_105.md` — host service contract
8. `/home/operator/docs/ALFA_AI_HOST_105_USAGE.md` — trust zones (`public_web` → `public-chat`)

### Sibling plans (mandatory cross-references)

9. `alfaqd-website/.cursor/plans/ALFA_AI_INTEGRATION_PLAN.md` — owns nginx `/alfa-ai` proxy + rate limits + edge hardening
10. `alfaqd-website/docs/ALFA_AI_HOW_TO_USE.md` — operator stack
11. `USPBF/.cursor/plans/ALFA_AI_INTEGRATION_PLAN.md` — Wave 3b thin-client precedent (static site delegates to rankings-bot)
12. `market-pie5-bot/.cursor/plans/ALFA_AI_INTEGRATION_PLAN.md` §2.1 — **NOT FINANCIAL ADVICE** disclaimer text
13. `credit-check-bot/.cursor/plans/ALFA_AI_INTEGRATION_PLAN.md` — informational-only (not legal/tax) disclaimer pattern

### WordPress target stack

14. `/home/operator/alfaqd-website/docker-compose.yml` — `alfa_wordpress_1`, volume `alfa1_wp_data`
15. `/home/operator/alfaqd-website/nginx-config/alfa-nginx.conf` L28–41 — `/alfa-ai` upstream
16. `/home/operator/ALFA_WORDPRESS_SETUP.md` — volume paths, theme, mu-plugin convention

### This repo (source of truth for plugin PHP)

17. `alfa-wordpress-plugins/README.md`
18. `alfa-wordpress-plugins/chatbot-product-intelligence.php` — current rule-based wpbot integration (security issues to fix)
19. `alfa-wordpress-plugins/market-bot-responsive-grid.php` — UI-only homepage grid (disclaimer pending)
20. `alfa-wordpress-plugins/install-credit-check-bot-button.sh` — operator deploy script for the grid mu-plugin

### WordPress standards (mandatory citations)

- [Plugin Security](https://developer.wordpress.org/plugins/security/) — escaping, sanitization, capabilities
- [Nonces](https://developer.wordpress.org/plugins/security/nonces/) — every AJAX/REST handler
- [Sanitizing & Escaping](https://developer.wordpress.org/plugins/security/securing-input/)
- [Capabilities & Roles](https://developer.wordpress.org/plugins/security/checking-user-capabilities/)
- [Plugin headers](https://developer.wordpress.org/plugins/plugin-basics/header-requirements/)
- [WordPress HTTP API](https://developer.wordpress.org/reference/functions/wp_remote_post/) — referenced only for admin assist Stage 4 (server-side proxy when needed)
- [WP REST API](https://developer.wordpress.org/rest-api/) — `register_rest_route` for admin assist
- [OWASP ASVS V4/V11](https://owasp.org/www-project-application-security-verification-standard/) — access control + business logic rate limiting

### Workspace rules

21. `/home/operator/.cursorrules`
22. `/home/operator/.cursor/rules/port-assignment-rules.mdc` — LAN exception for `:8413` (not relevant here — WP never calls it)
23. `/home/operator/.cursor/rules/git-push-from-105.mdc`

---

## 1. Discovered State + Service Contract

### 1.1 WordPress host (confirmed)

| Item | Value |
|------|-------|
| Site URL | `https://www.example.com/` |
| Compose project | `/home/operator/alfaqd-website` |
| WordPress container | `alfa_wordpress_1` (`wordpress:latest`) |
| DB container | `alfa_db_1` (MySQL 8) |
| WP files volume | `alfa1_wp_data` → host `/var/lib/docker/volumes/alfa1_wp_data/_data` |
| In-container path | `/var/www/html/wp-content/` |
| Ingress | Cloudflare → `cf-alfa` → `alfa-nginx:80` → `alfa_wordpress_1` |
| Other WP on `apps` | `uspbf_wordpress_1` — **out of scope** (USPBF has no plugins from this repo) |

### 1.2 Plugin inventory (this repo)

| Plugin file | Header | Version | Current LLM | What it does | Install path |
|---|---|---|---|---|---|
| `chatbot-product-intelligence.php` | Chatbot Product Intelligence | 1.0 | **None directly** — rule-based product detection + seeds `wpbot_response` table. Depends on **WPBot** (third-party) for any external LLM call. | Product Q&A on homepage (canned answers about ALFa bots/services) | `wp-content/plugins/` (manual today) |
| `market-bot-responsive-grid.php` | Market Bot Responsive Grid | 1.6 | None | Homepage bot grid + admin visibility toggles | `wp-content/mu-plugins/` (auto-loaded) via install script |
| `install-credit-check-bot-button.sh` | (shell) | — | N/A | Operator deploy: copies grid to mu-plugins | Run on `apps` with `sudo` |

### 1.3 Service contract (Option A — locked)

| Surface | URL from browser (visitor) | URL from PHP (server-side, admin assist only) |
|---|---|---|
| **Public chat (anonymous)** | `POST https://www.example.com/alfa-ai/api/guest/chat` | — (no PHP call) |
| **Admin assist (Stage 4)** | — (admin-only, JS in wp-admin) | `POST https://www.example.com/alfa-ai/api/chat` via WP REST proxy with operator JWT |
| **NEVER from WP PHP** | — | `http://hub` (LiteLLM) — direct calls **forbidden** |
| **NEVER from WP PHP** | — | `http://alfa-ai-litellm:4000` — not resolvable on `apps` |
| **NEVER from browser** | LiteLLM bearer tokens, LiteLLM URL | Browser must not see API keys |

| Component | Where | Owner repo |
|---|---|---|
| Public chat backend (anti-hallucination, rate limits, RAG, telemetry) | `alfa-ai-api` container on `tunnel_network` | `alfa-ai` |
| Nginx `/alfa-ai` proxy + edge rate limit | `alfa-nginx` | `alfaqd-website` |
| LiteLLM proxy | `http://hub` | `alfa-ai` on `hub` |
| Trust-zone keys | `alfa-ai/deploy/.env` on `hub` (LITELLM_MASTER_KEY + `LITELLM_API_KEY_PUBLIC`) | brain admin only |
| WordPress plugins (this repo) | `wp-content/(mu-)plugins/` in `alfa1_wp_data` volume | this repo |

**Telemetry sink:** **brain Postgres via `alfa-ai`** (extends existing guest activity logging with `feature=alfaqd_wp_chat`, `metadata.trust_zone=public_web`). Do **not** create a new MySQL table in WordPress for AI logs — wrong datastore; duplicates the central log; complicates fine-tune capture.

### 1.4 Stage 0 live inventory (must run on `apps`)

```bash
docker exec alfa_wordpress_1 ls -la /var/www/html/wp-content/plugins/
docker exec alfa_wordpress_1 ls -la /var/www/html/wp-content/mu-plugins/ 2>/dev/null || true
docker exec alfa-nginx curl -fsS http://alfa-ai-api:8000/health
curl -fsS https://www.example.com/alfa-ai/api/guest/config | jq .
```

Document which third-party chatbot (WPBot, etc.) is active today and whether it has an external LLM provider (OpenAI, etc.) configured. The Stage 2 chatbot refactor short-circuits that provider — operator decides at Stage 3 whether to fully deactivate WPBot.

### 1.5 Trust zones in scope (this repo)

| Zone | Scope here | Model alias | Auth |
|------|-----------|-------------|------|
| **`public_web`** | Stage 1 widget (anonymous homepage chat) | `public-chat` (in `alfa-ai` guest router) | None at WP layer; `alfa-ai` rate-limits per IP |
| **`operator_internal`** | Stage 4 admin assist (WP `manage_options`) | `agent` (in `alfa-ai`) | WP capability check + nonce + JWT proxy |

**Out of scope here:** `app_authenticated` (rankings-bot product apps own this), `internal` (host ops scripts).

---

## 2. Per-Plugin Integration Surfaces

### 2.1 NEW: `alfa-ai-guest-chat-widget` plugin (public homepage chat — MVP)

**Single approach:** Thin WordPress plugin that:

1. Enqueues a small JS bundle on the homepage (and any page where shortcode `[alfa_ai_chat]` is rendered).
2. Outputs the widget HTML container.
3. Provides a `wp_localize_script` payload with the **same-origin** endpoint path (`/alfa-ai/api/guest/chat`) and a WordPress nonce.

**The JS calls `/alfa-ai/api/guest/chat` directly from the browser (same-origin).** No PHP `wp_remote_post`. No LiteLLM URL or API key anywhere in WordPress.

**Why this is the single best path (vs PHP-side `wp_remote_post`):**

- **Defense in depth:** rate limits live in `alfa-ai/src/api/routers/guest.py` (`GUEST_MAX_MESSAGES=10` / `GUEST_WINDOW_SEC=3600`) **plus** nginx `limit_req` on `/alfa-ai/api/guest/` (Wave 3c Stage 2). Adding a third PHP layer is needless complexity.
- **Anti-hallucination + RAG** lives in the `alfa-ai` guest router system prompt with site corpus (Wave 3c Stage 5). Cannot be reliably enforced in PHP.
- **Single secret surface:** LiteLLM keys never leave `alfa-ai-api`. WordPress compromise does not leak LLM credentials.
- **Single telemetry sink:** brain Postgres (existing); no MySQL schema drift.
- **Consistency:** matches USPBF (Wave 3b) thin-client and the alfaqd-website (Wave 3c) edge plan.

**Security guardrails (mandatory per WordPress Plugin Handbook + OWASP ASVS):**

- All output escaped (`esc_html`, `esc_attr`, `esc_url`); all input sanitized (`sanitize_text_field`).
- WordPress nonce in `wp_localize_script` (defends against bot abuse beyond rate limits).
- No `current_user_can` bypass needed (anonymous public chat); rely on backend rate limit.
- "I don't know" fallback enforced **server-side** in `alfa-ai` guest router (out of scope here, documented in Wave 3c).
- **NOT FINANCIAL ADVICE** disclaimer appended to any response matching market/trading keywords — enforced **server-side** in `alfa-ai` guest router system prompt (per market-pie5-bot plan §2.1 disclaimer text).
- Plugin never exposes `wp_options`, user emails, or Contact Form 7 submissions to the widget.

**Files:** `alfa-ai-guest-chat-widget/alfa-ai-guest-chat-widget.php`, `assets/js/widget.js`, `assets/css/widget.css`. That's it. No Settings API. No LiteLLM client. No MySQL DDL.

---

### 2.2 REFACTOR: `chatbot-product-intelligence` (security fixes only)

**Current security issues (discovered in `chatbot-product-intelligence.php`):**

| Issue | Lines | Fix |
|---|---|---|
| **No nonce** on `wp_ajax_nopriv_get_chatbot_response` | 202–207, 223–224 | Add `check_ajax_referer( 'alfa_chatbot_nonce', 'nonce' )` |
| **`session_start()`** outside WP session API | 215–218 | Remove — no session needed; return JSON directly |
| **jQuery `$.ajax` monkey-patch** never read back | 307–332 | Remove — `window.chatbotProductResponse` was never set by PHP |
| **No rate limit** on public AJAX | 223–224 | Add transient-based per-IP throttle |
| **Unsafe direct broadcast to wpbot** | priority 5 handler | Priority **1**; short-circuit when product keyword matches |

**Single approach (refactor — does NOT add LiteLLM):**

1. Split into a directory plugin (`chatbot-product-intelligence/chatbot-product-intelligence.php` + `includes/`) with `Requires Plugins: alfa-ai-guest-chat-widget` (since the widget supersedes any "general question" path).
2. Keep `chatbot_get_product_knowledge()` arrays (lines 22–96) — this is the **RAG seed** for Wave 3c Stage 5 (`alfa-ai` corpus indexer reads this PHP file or an exported JSON).
3. Keep `chatbot_detect_product_question()` + `chatbot_generate_product_response()` — canned product responses remain as a zero-LLM fast path returned to wpbot (or removed entirely in Stage 3 if WPBot is fully deactivated).
4. Remove `session_start` and the jQuery monkey-patch.
5. Add nonce + rate limit to the AJAX handler.
6. **Do not add any LLM call.** For anything beyond canned product answers, the visitor uses the **alfa-ai widget (§2.1)** which has the proper guardrails.

---

### 2.3 EDIT: `market-bot-responsive-grid.php` (disclaimer pass — no AI)

**No LLM integration.** Static UI only.

**Single change:**

- Add **NOT FINANCIAL ADVICE** disclaimer block under the grid when the Market Bot card is visible (text from `market-pie5-bot/.cursor/plans/ALFA_AI_INTEGRATION_PLAN.md` §2.1).
- Add informational-only line under the Credit Check card (not legal/tax/credit advice; link to credit-check-bot app per Wave 2a).
- Bump `Version:` header to `1.7.0`; add `CHANGELOG.md`.

---

### 2.4 EDIT: `install-credit-check-bot-button.sh` (distribution glue)

**Single approach:** Wrap the existing grid mu-plugin install with a unified script `install-all-alfa-plugins.sh` that also copies the new `alfa-ai-guest-chat-widget` and the refactored `chatbot-product-intelligence` into `wp-content/plugins/`. Prints WP-CLI activation commands. Existing script either delegates or prints a deprecation notice.

---

### 2.5 NEW (Stage 4): `alfa-ai-wp-admin-assist` plugin (admin content drafts)

**Single approach:** Admin-only Gutenberg sidebar / metabox that calls `/alfa-ai/api/chat` (the **authenticated** ALFa route) via a WordPress REST proxy.

- Plugin registers `register_rest_route( 'alfa-ai/v1', '/admin-assist', ... )` with `permission_callback => current_user_can('manage_options')`.
- That REST handler is the **only** place this repo uses `wp_remote_post` — it forwards to `https://www.example.com/alfa-ai/api/chat` with an **operator-issued JWT** stored in `wp_options` (autoload=no, admin-only) or `wp-config.php` constant.
- Use case: draft blog intro, SEO meta description, headline variants. **Human publishes**; AI never auto-publishes.
- Model alias `agent` (operator_internal trust zone) — set in `alfa-ai` admin chat endpoint config.

**Why this single PHP `wp_remote_post` is acceptable here:** the WordPress-side capability check (`manage_options`) is the only place where WordPress can authoritatively assert "this is an admin," and the JWT issuance/refresh happens out-of-band by an operator. No LiteLLM bearer key ever lives in WordPress.

---

### 2.6 Dev-time — AGENTS.md + Cursor rule

Add `AGENTS.md` and `.cursor/rules/alfa-ai-usage.mdc` documenting: **no PHP LiteLLM client in this repo**; public chat is widget → `/alfa-ai/api/guest/chat`; admin assist is REST → `/alfa-ai/api/chat`; LiteLLM URL/keys never live in WordPress.

---

### 2.7 Explicit non-goals (this repo, locked by Option A)

- ❌ PHP LiteLLM client (`wp_remote_post` to `:8413`)
- ❌ WP MySQL telemetry table (`{prefix}alfa_ai_activity`)
- ❌ WP Settings API page for LiteLLM URL / API key
- ❌ Transient-based PHP rate limiter for public chat (rate limits live in `alfa-ai` + nginx)
- ❌ PHP-side anti-hallucination logic (server-side in `alfa-ai`)
- ❌ Duplicating bot subdomain frontends
- ❌ `LITELLM_API_KEY*` in `wp_options` or `wp-config.php`

---

## 3. File-Level Plan

### 3.1 New plugin: `alfa-ai-guest-chat-widget/`

| Path | Action | Description |
|---|---|---|
| `alfa-ai-guest-chat-widget/alfa-ai-guest-chat-widget.php` | NEW | Plugin header (Version `1.0.0`); enqueue + shortcode + widget container; nonce; no LiteLLM imports |
| `alfa-ai-guest-chat-widget/assets/js/widget.js` | NEW | `fetch('/alfa-ai/api/guest/chat', { credentials: 'same-origin', headers: { 'X-WP-Nonce': ... } })`; handles streamed SSE responses if `alfa-ai` guest router uses SSE; graceful degrade on 5xx |
| `alfa-ai-guest-chat-widget/assets/css/widget.css` | NEW | Slate/sky theme matching ALFa branding |
| `alfa-ai-guest-chat-widget/CHANGELOG.md` | NEW | Semver |
| `alfa-ai-guest-chat-widget/README.txt` | NEW (optional) | WordPress.org-style plugin readme |

### 3.2 Refactor: `chatbot-product-intelligence/`

| Path | Action | Description |
|---|---|---|
| `chatbot-product-intelligence/chatbot-product-intelligence.php` | MOVE/EDIT | Split from monolithic file; remove `session_start`, jQuery monkey-patch; add nonce + rate limit to AJAX handler; **no LLM call**; declares `Requires Plugins: alfa-ai-guest-chat-widget` |
| `chatbot-product-intelligence/includes/class-product-knowledge.php` | NEW | Extracts lines 22–96 arrays; export helper for Wave 3c RAG seed |
| `chatbot-product-intelligence/includes/class-ajax-handler.php` | NEW | Priority-1 AJAX with nonce + rate limit; canned product answers only |
| `chatbot-product-intelligence/assets/js/chatbot-frontend.js` | NEW | Replace monkey-patch; localized `ajaxurl` + nonce |
| `chatbot-product-intelligence/CHANGELOG.md` | NEW | Semver |

### 3.3 Edit: `market-bot-responsive-grid.php`

| Path | Action | Description |
|---|---|---|
| `market-bot-responsive-grid.php` | EDIT | Add disclaimer HTML block after grid; bump `Version: 1.7.0`; constants for disclaimer copy |
| `CHANGELOG-market-bot-responsive-grid.md` | NEW | Semver changelog |

### 3.4 Edit: install scripts + docs

| Path | Action | Description |
|---|---|---|
| `install-all-alfa-plugins.sh` | NEW | Single operator entry: copies grid to mu-plugins + widget plugin + chatbot plugin (+ Stage 4 admin assist when ready); prints WP-CLI activation lines |
| `install-credit-check-bot-button.sh` | EDIT | Delegate to `install-all-alfa-plugins.sh` (or print deprecation notice + call through) |
| `README.md` | EDIT | Rewrite to reflect Option A architecture; list plugins; link this plan + how-to |
| `AGENTS.md` | NEW | "No PHP LiteLLM client; widget proxies to `/alfa-ai/api/guest/chat`; admin assist proxies to `/alfa-ai/api/chat`" |
| `.cursor/rules/alfa-ai-usage.mdc` | NEW | Cursor guardrails |

### 3.5 Stage-4 admin assist (separate plugin)

| Path | Action | Description |
|---|---|---|
| `alfa-ai-wp-admin-assist/alfa-ai-wp-admin-assist.php` | NEW (Stage 4) | Plugin header; registers REST route with `manage_options` permission |
| `alfa-ai-wp-admin-assist/includes/class-rest-proxy.php` | NEW (Stage 4) | `wp_remote_post` to `/alfa-ai/api/chat` with JWT from `wp_options` (autoload=no) |
| `alfa-ai-wp-admin-assist/assets/js/sidebar.js` | NEW (Stage 4) | Gutenberg sidebar / classic editor metabox |
| `alfa-ai-wp-admin-assist/CHANGELOG.md` | NEW (Stage 4) | Semver |

### 3.6 Cross-repo deliverables (not in this repo, but required for MVP)

| Repo | File | Action |
|---|---|---|
| `alfa-ai` | `src/api/routers/guest.py` | VERIFY: existing `POST /alfa-ai/api/guest/chat` is wired to `public-chat` alias (Wave 3c open question #2) |
| `alfa-ai` | guest system prompt | EDIT: load ALFa product corpus (seed from `chatbot_get_product_knowledge()` export) + "I don't know" fallback + Market Bot disclaimer append |
| `alfa-ai` | guest activity logging | EDIT: persist `feature=alfaqd_wp_chat`, `metadata.trust_zone=public_web` with PII regex redaction (per credit-check-bot redaction pattern) |
| `alfaqd-website` | `nginx-config/alfa-nginx.conf` | EDIT (Wave 3c Stage 2): `limit_req_zone` + `limit_req` on `/alfa-ai/api/guest/` |
| `alfa-ai` | LiteLLM virtual key | OPERATOR: issue dedicated `LITELLM_API_KEY_PUBLIC` on `hub` per host plan §1 |

---

## 4. Staged Rollout

### Stage 0 — Preflight + WordPress inventory

**Prerequisites:** SSH `apps`; alfaqd-website stack running; `alfa-ai-api` up.

```bash
set -euo pipefail
docker exec alfa-nginx curl -fsS http://alfa-ai-api:8000/health
curl -fsS https://www.example.com/alfa-ai/api/guest/config | jq .
docker exec alfa_wordpress_1 ls -la /var/www/html/wp-content/plugins/
docker exec alfa_wordpress_1 ls -la /var/www/html/wp-content/mu-plugins/ 2>/dev/null || true
# Document active chatbot plugin (WPBot, etc.) and any external LLM provider it uses today.
```

**Exit criteria:** `/alfa-ai/api/guest/chat` reachable through nginx; WordPress filesystem accessible; current chatbot state documented.

**Rollback:** N/A.

---

### Stage 1 — `alfa-ai-guest-chat-widget` plugin (public chat MVP)

**Prerequisites:** Stage 0; Wave 3c Stage 1 (docs) and Stage 2 (nginx rate limits) in `alfaqd-website` have landed; `alfa-ai` guest router uses `public-chat` and emits PII-redacted activity rows.

**Work:**

1. Build the widget plugin per §3.1.
2. `sudo bash install-all-alfa-plugins.sh` (after §3.4 lands) — copies plugin to `wp-content/plugins/`.
3. Activate: `sudo docker exec alfa_wordpress_1 wp plugin activate alfa-ai-guest-chat-widget --allow-root`.
4. Add `[alfa_ai_chat]` shortcode to homepage or enable automatic homepage embed via plugin option.

**Exit criteria:** Homepage shows widget; anonymous message round-trips through `/alfa-ai/api/guest/chat` and returns grounded product answer; out-of-corpus question triggers server-side "I don't know" fallback; Market Bot question includes NOT FINANCIAL ADVICE disclaimer; `alfa-ai` activity log shows row with `trust_zone=public_web` and **no** raw browser-side email/IP in prompt.

**Rollback:** `wp plugin deactivate alfa-ai-guest-chat-widget --allow-root`; widget vanishes; WordPress + nginx unaffected.

---

### Stage 2 — `chatbot-product-intelligence` security refactor

**Prerequisites:** Stage 1 stable.

**Work:**

1. Migrate plugin to directory layout per §3.2.
2. Remove `session_start` (lines 215–218) and jQuery monkey-patch (lines 307–332).
3. Add nonce check and rate-limit (transients) on AJAX handler.
4. Keep canned product responses; **no LLM call**.
5. Deploy via `install-all-alfa-plugins.sh`.
6. Activate refactored plugin: `wp plugin activate chatbot-product-intelligence --allow-root`.

**Exit criteria:** PHPCS/WPCS clean on new PHP; nonce required for AJAX (verify with manual cross-site POST → 403); product keyword path returns canned answer (zero LLM tokens); WPBot integration still works for any retained surface, or operator deactivates WPBot entirely.

**Rollback:** Revert to monolithic file (one git revert); reactivate original.

---

### Stage 3 — Grid disclaimers + WPBot decision

**Prerequisites:** Stage 2.

**Work:**

1. Add NOT FINANCIAL ADVICE block to `market-bot-responsive-grid.php` Market Bot card; informational-only block to Credit Check card; bump `1.7.0`.
2. Run `sudo bash install-all-alfa-plugins.sh` to redeploy mu-plugin.
3. **Operator decision (Stage 0 inventory result):** deactivate WPBot entirely now that ALFa widget + canned product responses cover all chat surfaces. If WPBot retains a widget shell people use, keep deactivated LLM provider only.

**Exit criteria:** Grid renders with disclaimers; WPBot status decided and documented; no LLM call originates from WordPress except admin assist Stage 4 REST proxy.

**Rollback:** Restore previous mu-plugin from git.

---

### Stage 4 — `alfa-ai-wp-admin-assist` (admin content drafts)

**Prerequisites:** Stage 3 stable 48h; operator has issued an ALFa admin JWT (or long-lived service token) and placed it in `wp_options` (autoload=no) or `wp-config.php` constant.

**Work:**

1. Build plugin per §3.5.
2. REST route `POST /wp-json/alfa-ai/v1/admin-assist` with `permission_callback => current_user_can('manage_options')` + nonce.
3. Server-side `wp_remote_post` to `https://www.example.com/alfa-ai/api/chat` with `Authorization: Bearer <JWT>`.
4. Gutenberg sidebar with prompt + suggestion list.

**Exit criteria:** Admin user generates draft text; non-admin → 401 from REST route; JWT never appears in browser dev tools network panel beyond the SSL boundary.

**Rollback:** Deactivate plugin.

---

### Stage 5 — Validation + cross-repo doc sync

**Prerequisites:** Stages 1–4.

**Tests:**

| Test | Method | Gate |
|---|---|---|
| Widget reachability | Browser → homepage → widget message | 200 from `/alfa-ai/api/guest/chat`; rendered answer |
| Rate limit (alfa-ai) | 11 messages in 1h same IP | 429 from `alfa-ai` |
| Rate limit (nginx) | Burst > zone | 429/503 from nginx before app |
| Out-of-corpus | "What is ALFa Q3 revenue?" | "I don't know / contact us" fallback, no fabricated numbers |
| Disclaimer | Market Bot question | NOT FINANCIAL ADVICE block present |
| Chatbot AJAX nonce | Cross-site `POST` without nonce | 403 |
| Admin assist auth | Anonymous `POST /wp-json/alfa-ai/v1/admin-assist` | 401 |
| WPCS | `phpcs --standard=WordPress` on new PHP | Zero errors |
| Telemetry redaction | Inspect `alfa-ai` guest activity rows | No emails, IPs, or JWT-like strings |
| doc_maker quality | 10 gold product Q&A | ≥80% factual per `alfa-ai/docs/EVALUATION_FRAMEWORK.md` |

Update `README.md`, `alfaqd-website/README.md` (Wave 3c coordination), and `ALFA_WORDPRESS_SETUP.md` to point at this plan.

---

## 5. Risks / Rollback

| Risk | Mitigation |
|---|---|
| `alfa-ai-api` down → widget 502 | Widget JS shows "AI temporarily unavailable; use Contact page"; WordPress + nginx + bot subdomains unaffected |
| Visitor sends PII in chat | Server-side redaction in `alfa-ai` guest logger; widget shows no chat history persistence by default |
| Public AI abuse | Multiple rate-limit layers (alfa-ai per-IP + nginx `limit_req` + optional Cloudflare rule) |
| WPBot legacy widget conflicts | Stage 3 explicit deactivation decision after inventory |
| WP plugin attempts to embed LiteLLM key | **Forbidden** in §2.7; CI guard via `grep -r 'LITELLM' . --exclude-dir=node_modules` on PR (Stage 5+) |
| Admin assist JWT leaks | Stored `autoload=no`; rotated by operator; never localized to JS |
| `chatbot-product-intelligence` nonce regression | Stage 5 test fixture |

**Full rollback:** Deactivate all new plugins via `wp plugin deactivate ...`; revert grid mu-plugin from git; WordPress reverts to pre-AI state. No data migration to undo (no new MySQL tables).

---

## 6. Validation

Stage 5 test table above. Add manual operator sign-off checklist in `docs/ALFA_AI_HOW_TO_USE.md`.

---

## 7. Resolved / Open Decisions

### Resolved (by Wave 3 sign-off)

| Decision | Resolution |
|---|---|
| Chat backend architecture | **Option A** — proxy via `alfa-ai-api`; no PHP LiteLLM client; no WP MySQL telemetry table; no WP Settings API for LiteLLM URL/key |
| Public chat path | `POST /alfa-ai/api/guest/chat` (same-origin) |
| Admin assist path | `POST /alfa-ai/api/chat` via WP REST proxy with operator JWT |
| Telemetry sink | Brain Postgres via `alfa-ai` |
| LiteLLM API key location | **`hub` `alfa-ai/deploy/.env` only** — never in WordPress |
| Public model alias | `public-chat` |
| Admin model alias | `agent` |
| Grid plugin LLM | None — UI only + disclaimer |
| Distribution | `install-all-alfa-plugins.sh` (unified) |

### Open — operator confirms during Stage 0

| # | Question | Plan default |
|---|---|---|
| 1 | Is WPBot active today, and which external LLM provider does it use? | Document at Stage 0; deactivate at Stage 3 if no other dependency |
| 2 | Issue dedicated `LITELLM_API_KEY_PUBLIC` virtual key on `hub`? | **Yes** — per host plan §1 |
| 3 | Stage 0 container egress test `docker exec alfa-nginx curl alfa-ai-api:8000/health` passes? | Must pass; if not, fix Docker network before any plugin work |
| 4 | Stage 4 admin assist now or deferred? | Defer until Stages 1–3 stable in production |

**Estimated stages-to-MVP:** **3 stages** (Stage 0 preflight → Stage 1 widget plugin → Stage 2 chatbot security refactor) for public homepage chat on LiteLLM via the same-origin proxy. **5 stages** total for full disclaimer pass + admin assist + validation sign-off.
