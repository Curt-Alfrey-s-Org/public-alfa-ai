# Plugins for www.example.com (alfa_wordpress_1)

These plugins are for the ALFa WordPress site served at **https://www.example.com/**.

- **WordPress container:** `alfa_wordpress_1`
- **WP files (theme, plugins):** Docker volume `alfa1_wp_data` → host path `/var/lib/docker/volumes/alfa1_wp_data/_data`
- **DB:** `alfa_db_1` (MySQL) — used by WordPress only

## Canonical ALFa AI on public websites

All **public WordPress sites** use the same guest chat stack:

| Layer | What |
|---|---|
| **Plugin** | `alfa-ai-guest-chat-widget` (this repo) |
| **Browser** | `POST /alfa-ai/api/guest/chat` (same-origin) |
| **Edge** | Site nginx → `alfa-ai-api:8000` on `tunnel_network` |
| **Brain** | LiteLLM on `hub` (`public-chat` alias) |

**Not the same as product apps.** Signed-in Ask AI in contracts-bot, rankings-bot, etc. uses `POST /api/ai-narrative/ask` with `AlfaChatPanel` — that is the most updated **in-app** UI, but public sites intentionally use the guest API (no login, FAQ primer, rate limits).

### Per-site differences (FAQ + optional relay only)

| Site | Plugin | FAQ source | Off-FAQ relay |
|---|---|---|---|
| example.com | `alfa-ai-guest-chat-widget` | `faq.md` (products) | Contact page (no email relay) |
| example-siteperch.com | `example-site-chat-widget` (fork) | `docs/FAQ_CONTENT.md` | `example-site-contact-relay` → owner email |

example-site keeps a thin site-specific wrapper for email relay; the **API contract and JS logic** match `alfa-ai-guest-chat-widget`.

### Legacy WPBot — removed

The old **WPBot** (`chatbot` plugin) and **chatbot-product-intelligence** mu-plugin are **deprecated**. Install the canonical widget instead:

```bash
sudo bash /home/operator/alfa-wordpress-plugins/install-alfa-ai-guest-chat.sh
cd /home/operator/alfaqd-website && sudo bash bin/wp-cli.sh plugin activate alfa-ai-guest-chat-widget
```

To remove legacy chatbot if it returns:

```bash
sudo bash /home/operator/alfa-wordpress-plugins/scripts/remove-legacy-wpbot.sh
```

Operator guide: [docs/ALFA_AI_HOW_TO_USE.md](docs/ALFA_AI_HOW_TO_USE.md)

## ALFa Projects Portfolio

Customer-facing product catalog (no internal stack or infrastructure entries). Renders on **`/projects/`** via shortcode `[alfa_projects]`.

- **File:** `alfa-projects-portfolio.php`
- **Install:** `sudo bash install-alfa-projects-portfolio.sh` (copies to mu-plugins and creates/updates the Projects page)

## Site chrome (nav + unified layout + footer)

The homepage uses custom block content and does not always render the theme header template part.
**ALFa Site Chrome** injects a sticky top menu on every public page, applies the same black background / blue gradient panel / font scale on inner pages, and enforces a single-line footer.

- **Plugin:** `alfa-site-chrome/`
- **Install:** `sudo bash install-alfa-site-chrome.sh` (also removes legacy `test-tagline.php` footer injection)
- **Pages:** `sudo bash install-alfa-site-pages.sh` (creates About, Blog, Contact if missing)

Top menu: Home, About, Projects, Blog, Contact. Inner pages get the ALFaQD brand bar, homepage tagline, page title, and gradient content panel (Spectra page hero/featured image/comments are hidden).

## Homepage hero background video

The homepage **Blog Home** template uses the rankings-bot splash MP4 on the existing UAG hero container (no overlay).

- **Video:** `rankings-bot/frontend/public/assets/video/grok-video-a1fee053-2343-4013-a0de-0445458248cf.mp4`
- **Apply/re-apply:** `sudo bash install-homepage-hero-video.sh`
- **Script:** `scripts/swap-homepage-hero-video.py` (updates template post ID 56, block `be170361`)

Do **not** use `install-alfa-splash-screen.sh` for this — that added a full-screen overlay (removed via `uninstall-alfa-splash-screen.sh`).

## example Alfrey meme (homepage easter egg)

Iron Man "box of scraps" clip with three speech-label captions, matching the rankings-bot
`ExampleAlfreyMeme.tsx` look/behavior (video autoplays muted, replays every 10s).

- **Plugin:** `alfa-example-meme/` (+ `alfa-example-meme-loader.php`)
- **Video:** bundled in the plugin at `alfa-example-meme/assets/memes/example-alfrey-cave-scraps.mp4` (no rankings-bot hotlink)
- **Install:** `sudo bash install-alfa-example-meme.sh`
- **Pages:** homepage only (`is_front_page() || is_home()`), rendered at `wp_footer`
- **Placement:** desktop (>=1024px) fixed bottom-left overlay (380px, 420px on xl); mobile/tablet
  in normal document flow so it never overlaps content.

The `/alfa-ai` SPA (alfa-ai-api) has a parity component at
`frontend/src/components/ExampleAlfreyMeme.tsx`, shown on the `/alfa-ai` landing (Login) page.

## Header pattern (theme template part)

- **Source:** `/home/operator/alfa-wordpress-header-pattern.php`
- **Install:** `sudo bash install-alfa-header.sh` (theme file) or `install-alfa-site-chrome.sh` (syncs WP template part #57)

## Market Bot Responsive Grid (deprecated)

Previously injected the bot grid on the homepage. **v1.7+** — grid moved to `/projects/`; this plugin is kept only for legacy admin-toggle hooks. Safe to remove from mu-plugins after confirming `/projects/` is live.

- **File:** `market-bot-responsive-grid.php`
- **Install:** `sudo bash install-credit-check-bot-button.sh`
