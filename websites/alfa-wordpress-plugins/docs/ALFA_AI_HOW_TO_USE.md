# ALFa AI — WordPress Plugins Operator Guide

**Repo:** `/home/operator/alfa-wordpress-plugins` 
**WordPress site:** `https://www.example.com/` 
**WordPress container:** `alfa_wordpress_1` on `apps` (volume `alfa1_wp_data`) 
**Brain / LiteLLM:** `http://hub` on `hub` (hub) — **WordPress never calls this directly** 
**Authority:** [.cursor/plans/ALFA_AI_INTEGRATION_PLAN.md](../.cursor/plans/ALFA_AI_INTEGRATION_PLAN.md)

---

## Architecture in one diagram

```
Visitor browser
    │
    ▼  fetch('/alfa-ai/api/guest/chat', { credentials: 'same-origin' })
www.example.com  ──►  Cloudflare  ──►  cf-alfa  ──►  alfa-nginx
                                                                      │
                                                                      ▼
                                                              alfa-ai-api:8000   (tunnel_network on apps)
                                                                      │
                                                                      ▼
                                                              http://hub   (LiteLLM on hub)
                                                                      │
                                                                      ▼
                                                              public-chat alias  →  qwen3.6:35b-a3b MoE (orchestrator + inference)
```

WordPress PHP is **not** in this path. The plugin in this repo only **renders the widget** and **enqueues the JS** that talks to the same-origin `/alfa-ai/api/guest/chat` endpoint. No LiteLLM URL, no LiteLLM API key, no `wp_remote_post` to `:8413` lives in WordPress.

Why: rate limits, anti-hallucination, RAG corpus, "I don't know" fallback, NOT FINANCIAL ADVICE disclaimer, and PII-redacted activity logging all live in `alfa-ai-api` where they already exist (`alfa-ai/src/api/routers/guest.py`). Wave 3 sign-off locked this as the single best path (vs adding a PHP LiteLLM client that would duplicate all of that and put API keys in WordPress).

---

## Which WordPress instance hosts these plugins

| Site | Container | Plugins from this repo |
|---|---|---|
| www.example.com | `alfa_wordpress_1` | **Yes** — all plugins here |
| USPBF (uspbf.com) | `uspbf_wordpress_1` | **No** — separate stack; USPBF uses static-site widget delegating to rankings-bot |

Compose project: `/home/operator/alfaqd-website` 
WP files on host: `/var/lib/docker/volumes/alfa1_wp_data/_data/`

---

## Plugin inventory

| Plugin | Type | Purpose | Calls LiteLLM? |
|---|---|---|---|
| `alfa-ai-guest-chat-widget` | Regular plugin | Public chat widget (all WP sites) | **No** (browser JS → `/alfa-ai/api/guest/chat`) |
| ~~`chatbot` (WPBot)~~ | ~~Removed~~ | ~~Legacy third-party chat~~ | N/A |
| ~~`chatbot-product-intelligence`~~ | ~~Archived~~ | ~~Rule-based WPBot hook~~ | N/A |
| `market-bot-responsive-grid` | mu-plugin | Homepage bot grid + disclaimers | **No** (static UI) |
| `alfa-ai-wp-admin-assist` (Stage 4) | Regular plugin | Admin Gutenberg sidebar for content drafts | Indirect — WP REST proxy to `/alfa-ai/api/chat` with operator JWT |

---

## Trust zones (WordPress)

| Zone | Audience | Plugin | `alfa-ai` model alias |
|---|---|---|---|
| `public_web` | Anonymous visitors | `alfa-ai-guest-chat-widget` | `public-chat` |
| `operator_internal` | WP admins (`manage_options`) | `alfa-ai-wp-admin-assist` | `agent` |

There is **no** signed-in-customer Ask AI dock in WordPress — that lives in the product apps (rankings-bot, contracts-bot, etc.).

---

## Pre-install preflight

From `apps`:

```bash
set -euo pipefail
# Brain reachable from hub
curl -fsS http://hub/health/liveliness

# alfa-ai-api reachable from alfa-nginx (same network as WordPress)
docker exec alfa-nginx curl -fsS http://alfa-ai-api:8000/health

# Same-origin guest endpoint reachable through Cloudflare
curl -fsS https://www.example.com/alfa-ai/api/guest/config | jq .

# Document the current chatbot plugin (WPBot, etc.)
docker exec alfa_wordpress_1 ls -la /var/www/html/wp-content/plugins/
docker exec alfa_wordpress_1 ls -la /var/www/html/wp-content/mu-plugins/ 2>/dev/null || true
```

All three curls must succeed before Stage 1.

---

## Install + activate

After plan Stage 1 lands `install-all-alfa-plugins.sh`:

```bash
cd /home/operator && git pull --ff-only origin main
sudo bash /home/operator/alfa-wordpress-plugins/install-all-alfa-plugins.sh
```

What gets copied:

| Plugin | Destination |
|---|---|
| `market-bot-responsive-grid.php` | `wp-content/mu-plugins/` (auto-loaded; no activation needed) |
| `alfa-ai-guest-chat-widget/` | `wp-content/plugins/alfa-ai-guest-chat-widget/` |
| ~~`chatbot-product-intelligence/`~~ | Deprecated — archived on volume; FAQ merged into `faq.md` |
| `alfa-ai-wp-admin-assist/` (Stage 4) | `wp-content/plugins/alfa-ai-wp-admin-assist/` |

Activate via WP Admin or WP-CLI:

```bash
sudo bash /home/operator/alfa-wordpress-plugins/install-alfa-ai-guest-chat.sh
cd /home/operator/alfaqd-website && sudo bash bin/wp-cli.sh plugin activate alfa-ai-guest-chat-widget
```

Legacy WPBot removal (if needed):

```bash
sudo bash /home/operator/alfa-wordpress-plugins/scripts/remove-legacy-wpbot.sh
```

---

## Configuration

### Public chat widget

**No WordPress configuration of LiteLLM URL or API key.** The widget reads only:

- Same-origin endpoint path: `/alfa-ai/api/guest/chat` (hardcoded; documented per host plan §1)
- WordPress nonce: generated per page load

To embed manually on any page/post:

```
[alfa_ai_chat]
```

By default the plugin also injects a floating button on the homepage; toggle in WP Admin → **Settings → ALFa AI Widget**.

### Admin assist (Stage 4)

Stored once by an operator (admin-only):

- `wp_options` key `alfa_ai_admin_jwt` (autoload=no) **or** `define( 'ALFA_AI_ADMIN_JWT', '...' );` in `wp-config.php`.

Issue the JWT from `alfa-ai` (operator console at `http://hub/operator/`) with the `admin` role. Rotate on a schedule per `alfa-ai/docs/OPERATOR_CONSOLE.md`.

---

## Verify the widget end-to-end

1. Visit `https://www.example.com/` and open the chat widget.
2. Ask: "What is ATEMS?" → grounded answer from product corpus.
3. Ask: "What is ALFa's Q3 revenue?" → **"I don't have verified information on that. Please use Contact or consult a human ALFa representative."** (server-side fallback)
4. Ask about Market Bot trading → response ends with **NOT FINANCIAL ADVICE** block.
5. Send 11 messages in an hour from the same browser → 11th returns 429.

In `alfa-ai` operator console → **Activity Log**, confirm rows with `feature=alfaqd_wp_chat`, `trust_zone=public_web`, redacted prompts (no emails/IPs).

---

## End-user UX per plugin

### `alfa-ai-guest-chat-widget`

- **Where:** Floating button on all public pages (toggle in Settings → ALFa AI Chat); shortcode `[alfa_ai_chat]` anywhere.
- **Behavior:** Browser fetches same-origin `/alfa-ai/api/guest/chat`; FAQ primer in client; degraded message if `alfa-ai-api` is down.
- **Disclaimers:** Server-side appended on market/trading topics.

### ~~`chatbot-product-intelligence`~~ (removed)

Replaced by `alfa-ai-guest-chat-widget` + `faq.md`. Run `scripts/remove-legacy-wpbot.sh` if WPBot returns.

### `market-bot-responsive-grid`

- **Where:** Homepage (auto-injected after social-links block by Spectra One).
- **Behavior:** Static grid + disclaimers. No AI.

### `alfa-ai-wp-admin-assist` (Stage 4)

- **Where:** Gutenberg editor sidebar for `manage_options` users.
- **Behavior:** Suggest blog intro, SEO meta, headlines. AI never publishes; admin pastes/edits.
- **Model:** `agent` via `/alfa-ai/api/chat` with operator JWT.

---

## When ALFa AI is down

| Surface | Degraded behavior |
|---|---|
| Public chat widget | "AI temporarily unavailable. Please try again later." Page itself loads. |
| Bot grid | Works (static UI) |
| Admin assist (Stage 4) | Sidebar shows error toast; editor unaffected |
| WordPress core | Unaffected |

Quick checks:

```bash
docker exec alfa-nginx curl -fsS --max-time 3 http://alfa-ai-api:8000/health || echo "alfa-ai-api unreachable"
curl -fsS --max-time 3 http://hub/health/liveliness || echo "LiteLLM down on hub"
curl -fsS --max-time 3 https://www.example.com/alfa-ai/api/guest/config || echo "edge → alfa-ai broken"
```

Fix brain on `hub` per `alfa-ai/docs/DOCKGE_111_OPERATOR.md`. Restart `alfa-ai-api` on `apps` if upstream is the problem.

---

## Security checklist (operators)

- [ ] No LiteLLM URL or API key anywhere in `wp_options`, `wp-config.php`, or plugin PHP files
- [ ] WordPress nonces present on every AJAX/REST handler (`chatbot-product-intelligence`, `alfa-ai-wp-admin-assist`)
- [ ] `current_user_can('manage_options')` on admin REST routes
- [ ] Output escaped (`esc_html`/`esc_attr`/`esc_url`); input sanitized (`sanitize_text_field`)
- [ ] WPCS clean: `phpcs --standard=WordPress` on `alfa-ai-guest-chat-widget/` and `chatbot-product-intelligence/`
- [ ] `DISALLOW_FILE_EDIT` set in `wp-config.php`
- [ ] Strong admin passwords; limited `manage_options` users
- [ ] Stage 5 validation tests recorded

---

## Production hardening (WordPress-specific)

In the `alfa1_wp_data` volume's `wp-config.php` (not in git):

```php
define( 'DISALLOW_FILE_EDIT', true );
define( 'DISALLOW_FILE_MODS', true );
define( 'WP_DEBUG', false );
define( 'WP_DEBUG_LOG', false );
define( 'WP_DEBUG_DISPLAY', false );
```

Optional: Cloudflare rate limit on `/wp-admin/admin-ajax.php` for anonymous POST volume (defense in depth alongside `alfa-ai` rate limits).

---

## Distribution workflow

1. Edit plugins in `/home/operator/alfa-wordpress-plugins/` on `apps`.
2. Bump `Version:` in plugin headers + update `CHANGELOG.md` per plugin.
3. Commit + push from `apps` when approved (per `git-push-from-105.mdc`).
4. On deploy host: `git pull` → `sudo bash install-all-alfa-plugins.sh` → activate/update in WP Admin if needed.

---

## Related docs

- [ALFA_AI_INTEGRATION_PLAN.md](../.cursor/plans/ALFA_AI_INTEGRATION_PLAN.md) — full staged plan (this repo)
- [alfaqd-website plan](/home/operator/alfaqd-website/.cursor/plans/ALFA_AI_INTEGRATION_PLAN.md) — edge/proxy owner (sibling)
- [alfaqd-website how-to](/home/operator/alfaqd-website/docs/ALFA_AI_HOW_TO_USE.md) — stack operations
- [USPBF plan](/home/operator/USPBF/.cursor/plans/ALFA_AI_INTEGRATION_PLAN.md) — thin-client precedent (Wave 3b)
- [host-105 plan](/home/operator/.cursor/plans/ALFA_AI_INTEGRATION_PLAN_HOST_105.md) — service contract source
- [host-105 how-to](/home/operator/docs/ALFA_AI_HOST_105_USAGE.md) — host/brain operations
- [ALFA_WORDPRESS_SETUP.md](/home/operator/ALFA_WORDPRESS_SETUP.md) — volume paths, theme
- [market-pie5-bot disclaimer reference](/home/operator/market-pie5-bot/docs/ALFA_AI_HOW_TO_USE.md)
- [credit-check-bot integration](/home/operator/credit-check-bot/.cursor/plans/ALFA_AI_INTEGRATION_PLAN.md) — in-app credit AI (not WordPress)
