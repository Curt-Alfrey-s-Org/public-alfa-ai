# ALFa AI chat widgets - single-source package, design, and rollout

**Authoritative.** alfa-ai owns the chat widget design and the ALFa avatar for
every consumer app. As of 2026-07-06 the widget is delivered as a **single
shared npm package** published to the cluster Verdaccio registry, not copied
file-by-file into each repo. One version bump changes every app
(see [.cursor/rules/alfa-ai-authoritative.mdc](../.cursor/rules/alfa-ai-authoritative.mdc)).

This file is the single place to find **every** in-app "ALFa AI" chat window and
the one source that drives them all.

## Single source of truth: `@alfa-ai/chat-widget`

- **Package source (the ONE place to edit):** `alfa-ai/packages/chat-widget/`
- **Published to:** cluster Verdaccio registry `http://hub`
  (private `@alfa-ai` scope). See [../deploy/npm-proxy/README.md](../deploy/npm-proxy/README.md).
- **Consumed by every SPA** via `npm install @alfa-ai/chat-widget` and one mount
  of `<AlfaAskAiDock />`.
- **Change flow:** edit `packages/chat-widget/` -> `npm version` bump ->
  publish to Verdaccio -> each consumer rebuilds its frontend and picks up the
  new version. No per-repo widget source to maintain.

Rollout runbook (Composer-executable, per repo/host):
[.cursor/plans/UNIFIED_CHAT_WIDGET.md](../.cursor/plans/UNIFIED_CHAT_WIDGET.md).

### Why a package (not copy-paste, submodule, or monorepo)

| Option | Verdict |
|---|---|
| **Private npm package on Verdaccio** | **Chosen.** True single source; one bump updates all; fits existing `NPM_REGISTRY` Docker build args. |
| Copy the file set into each repo | Rejected - previous method; drifts, must re-paste to 6+ repos. |
| Git submodule of alfa-ai | Forbidden by `alfa-ai-authoritative.mdc`. |
| Monorepo of all bots | Rejected - fights per-host clone policy (`orchestrator`/`apps`/`market`/`atems`). |

## Operator intent (look vs size vs brain UX)

| Surface | Theme / chrome | Size / layout | Answers about |
|---------|----------------|---------------|---------------|
| **alfa-ai** (`/alfa-ai` guest + signed-in chat) | SSoT (`theme.ts` / `alfaChatTheme.ts`) | **Full-page** ChatGPT/Grok-style (not the floating dock) | General ALFa; **no** consumer-bot business data |
| **contracts-bot, rankings, USPBF demo, WP guest** | Same theme + avatar | **Contracts dock geometry** (below) | **Only** that site/app (isolation) |

**Normal users** never see admin Ask ALFa, model pickers, or other bots' data.
Executable conformity plan: [.cursor/plans/CHAT_WIDGET_CONFORMITY.md](../.cursor/plans/CHAT_WIDGET_CONFORMITY.md).

## Knowledge scope (the only content difference between docks)

Chrome/theme is shared. **What the model may talk about is not.** Each dock may
answer only about **the site it is mounted on**:

| Surface | Allowed knowledge | How it is supplied |
|---------|-------------------|--------------------|
| **contracts-bot / rankings / other SPAs** | That app's own backend/DB | Same-origin `/api/ai-narrative/*` ([chat-data-isolation.mdc](../.cursor/rules/chat-data-isolation.mdc)). **No** internet search. |
| **WordPress guest** (e.g. example.com) | Published **pages and posts of that WordPress site** | Plugin builds a primer from `get_pages()` / `get_posts()` (`post_status=publish` only). Not a shared product FAQ. Not other subdomains. **No** internet search. |
| **alfa-ai `/guest` SPA** | General demo assistant; **no** consumer-bot business data | Brain `GUEST_SYSTEM_PROMPT` only (no WP corpus). **No** internet search. |
| **Ask ALFa admin dock** (LAN admin) | Cluster console + in-chat inspect (HA, SSH reads, `web_search` when enabled) | `POST /monitoring-agent/stream` → gather → deterministic hot paths or pre_inspect + LLM → `done.reply` in this dock ([AI_ACTIONS.md](AI_ACTIONS.md) chat pipe). **No** consumer-bot data. |
| **Missions** (explicit backend jobs only) | Multi-step agent runs (`Audit host N`, `Review errors`, …) | `POST /api/runs` worker loop: `web_search` + allowlisted `fetch_url` ([AGENT_RESEARCH_TOOLS.md](AGENT_RESEARCH_TOOLS.md)). Not the Q&A channel for weather/research. |

If a visitor asks about something that is not on **that** site's published
content (or that app's own API), the assistant must say it does not have it
and point to that site's Contact/help path -- not invent, and not answer from
another ALFa product.

WordPress APIs:
[get_pages](https://developer.wordpress.org/reference/functions/get_pages/),
[get_posts](https://developer.wordpress.org/reference/functions/get_posts/),
[wp_strip_all_tags](https://developer.wordpress.org/reference/functions/wp_strip_all_tags/).
Corpus is cached with [set_transient](https://developer.wordpress.org/reference/functions/set_transient/)
and cleared on `save_post`.

## Canonical design = contracts-bot dock (now packaged)

The reference **dock geometry** is contracts-bot's dock; its files were moved into
the package and parametrized. All **consumer** chat windows (not the brain full-page
chat) are visually and structurally identical because they render the same package
components (or mirrored CSS for WP/USPBF).

- **Launcher:** fixed bottom-right pill (`fixed bottom-4 right-4 z-[90]`),
  rounded-full, avatar + "ALFa AI" label (`text-sky-400`).
- **Panel:** `w-[min(calc(100vw-2rem),28rem)] h-[min(85dvh,36rem)]`, rounded-xl,
  header with avatar + per-page hint + popup / fullscreen / close buttons.
- **Popup window** 520x720 (`/alfa-chat` on package SPAs; WordPress guest
  `?alfa_ai_popup=1`) and fullscreen (Esc to close).
- **Avatar:** `<img src={avatarSrc} className="rounded-full object-cover" />`.

### Background: SOLID deep navy-royal (not transparent)

The panel background is now a **solid, opaque deep navy-royal** in the ALFaQD
brand-blue family - no `bg-slate-950/98`, no `backdrop-blur`. The signature
colors are JS constants in the package (single source), applied as inline
styles so they render regardless of each app's Tailwind purge config:

| Token | Value | Applied to |
|---|---|---|
| `ALFA_PANEL_BG` | `#0a1838` | panel body, launcher pill, fullscreen shell |
| `ALFA_HEADER_BG` | `#07122c` | header bar |
| `ALFA_PANEL_BORDER` | `#142452` | panel + pill border |
| `ALFA_DOCK_WIDTH` | `min(calc(100vw - 2rem), 28rem)` | consumer dock width (CSS `--alfa-dock-width`) |
| `ALFA_DOCK_HEIGHT` | `min(85dvh, 36rem)` | consumer dock height (**fixed**, not `height: auto`) |

To change the color for every app: edit these constants in
`packages/chat-widget/src/theme.ts`, bump the version, publish, rebuild consumers.

Non-package surfaces (WordPress, USPBF) copy geometry from
`packages/chat-widget/assets/theme.css` (`--alfa-dock-width`, `--alfa-dock-height`).
Sync helper: `bash scripts/sync-chat-widget-theme-css.sh` (WordPress `:root` colors).

### Brain SPA vs consumer dock (do not conflate)

| Surface | Layout |
|---|---|
| **alfa-ai** `/alfa-ai/guest`, signed-in chat, admin Chat | **Full viewport** (`GuestChat` uses `h-screen`) — ChatGPT/Grok-style, **not** the floating dock |
| **contracts-bot, rankings, USPBF, WP guest** | **Fixed-size floating dock** — `28rem` max width, `36rem` max height via `85dvh` cap |

The brain SPA never mounts `<AlfaAskAiDock />` for its primary chat UX. Chrome
colors come from `frontend/src/lib/alfaChatTheme.ts` (mirrors package hex tokens).
Only consumer docks use `ALFA_DOCK_WIDTH` / `ALFA_DOCK_HEIGHT`.

### Ask ALFa admin dock (do not invent a third chat)

Ask ALFa is the **official LAN-admin AI chat** (inspect/tools in this dock, model reply
here). It is **not** a Missions enqueue UI for weather or online research Q&A. It is **not**
a second chat renderer and **must not** mount `<AlfaAskAiDock />` (that package talks to
consumer `/api/ai-narrative/*`, not `/monitoring-agent/stream`). It is the brain SPA chat
primitives plus admin cards. Edit the file that owns the surface -- do not copy bubbles into
the widget.

**Pipe:** widget `POST /monitoring-agent/stream` → gather activity/ops/catalog → router
(deterministic hot paths **or** pre_inspect + LLM) → SSE `done.reply`. Guest/SPA/consumer
surfaces never `web_search` ([AI_ACTIONS.md](AI_ACTIONS.md) chat pipe).

| Want to change | Edit this |
|----------------|-----------|
| Bubble, markdown, Expand/Collapse, think tags, timing | `frontend/src/components/ChatMessage.tsx`, `frontend/src/components/ExpandableClip.tsx` |
| Composer (Enter to send) | `frontend/src/components/ChatInput.tsx` |
| Theme / avatar / dock navy | `frontend/src/lib/alfaChatTheme.ts` (mirror `packages/chat-widget/src/theme.ts`) |
| Approve / Reject, host result terminal, Cursor handoff, Missions next-step | `frontend/src/components/admin/AskAlfaCards.tsx` |
| Session / SSE payload TypeScript types | `frontend/src/components/admin/askAlfaTypes.ts` |
| Inspect stdout blocks | `frontend/src/components/admin/InspectionSteps.tsx` |
| Context ring | `frontend/src/components/admin/ContextUsageRing.tsx` |
| Tabs, SSE, FIFO queue, sessionStorage | `frontend/src/components/admin/AskAlfaWidget.tsx` |

Guest and signed-in `/alfa-ai` chat reuse `ChatMessage` / `ChatInput` -- a bubble
change lands on Ask ALFa automatically.

### Brain SPA response timing (benchmark)

The admin **Ask ALFa** dock keeps **Approve / Reject** in a bar above the composer
(not under a long reply). Long assistant markdown and fenced `<pre>` start
**collapsed** with an Expand control (WAI-ARIA disclosure) so the dock can
scroll to Approve; expanded replies are fully readable
([AI_ACTIONS.md](AI_ACTIONS.md) Ask ALFa dock layout;
[APG Disclosure](https://www.w3.org/WAI/ARIA/apg/patterns/disclosure/);
[CSS Overflow](https://www.w3.org/TR/css-overflow-3/#overflow-properties)).
Each fenced code box has a **Copy** control (top-right, Clipboard
[`writeText`](https://developer.mozilla.org/en-US/docs/Web/API/Clipboard/writeText))
like Cursor chat. Guest and signed-in `/alfa-ai` chat use the same
`ChatMessage` markdown renderer.

Signed-in chat (`frontend/src/pages/Chat.tsx`) and the admin **Ask ALFa** dock
(`frontend/src/components/admin/AskAlfaWidget.tsx`) show a **per-turn timer**
under the assistant bubble after each reply completes (Ask ALFa uses the same
`ChatMessage` / `formatTiming` helper; the thinking row still shows live
elapsed seconds + Stop while busy). Composer stays enabled during a busy turn so
follow-ups can queue ([CHAT_AGENT_STREAMING.md](CHAT_AGENT_STREAMING.md)):

| Metric | Meaning |
|--------|---------|
| **total** | Wall time from send until SSE stream complete |
| **first token** | Signed-in chat: time to first content delta. Ask ALFa: time to first `status` or `heartbeat` (LLM wait started); omitted on immediate deterministic `done` |
| **~tok/s** | Rough rate from reply character count (chars/4); decode window when streaming, else wall time when total >= 1s |

This is a client-side benchmark aid, not the admin Health pool probe
(`decode_tok_per_sec` from keep-warm / `benchmark-inference-litellm.sh`).

**Ask ALFa context ring:** the admin dock shows a Cursor-style usage ring left of
the composer ([Cursor context usage](https://cursor.com/docs/agent/prompting)).
It reports packed Ask ALFa messages vs one llama.cpp slot (`CTX_SIZE / PARALLEL`,
52428 tokens on inference). The widget resends the last dock turns as `history` on
each POST ([CHAT_AGENT_STREAMING.md](CHAT_AGENT_STREAMING.md)). Payload and
categories: [AI_ACTIONS.md](AI_ACTIONS.md) "Context window ring".
Guest/signed-in chat and consumer docks do not show the ring in v1.

**Why a short "hi" can still take ~90 seconds:** usually **coordinator TTFT on the
RPC pool**, not the SPA thinking orb. Measured 2026-08-06 against
`hub:31360`: many short prompts show **`first ~80-95 s`** then **`~3.5 tok/s`**,
including with `enable_thinking: false`. Historical warm short TTFT was ~3.7 s /
~8 tok/s (fewer shards). Keep-warm should ping all `PARALLEL` slots
([inference_BENCHMARKS.md](inference_BENCHMARKS.md)); if TTFT stays ~90 s after that,
narrow the active shard set (opt out gaming / `secondary` / `pool-opt-in`) and re-measure.

**Secondary:** default mode for `frontier-code` is **Thinking (precise)**
(`QWEN_THINKING_BUDGET` default **8192`). Long `<think>` blocks add visible wait
when reasoning streams into `content`. Switch to **Instruct** for short answers,
or lower `QWEN_THINKING_BUDGET` on the brain.

### Model selection: centrally controlled by the single-source admin

The chat model is **not** picked by consumer users. It is a central setting owned
by the **admin of the single source (the ALFa brain)**:

- Consumer docks render **no model picker**. They call the app's models endpoint
  and use the server-designated available model automatically.
- The package exposes `showModelPicker` (default `false`). Only the ALFa brain
  admin surface passes `showModelPicker={true}` (gated by the brain's admin
  role) to change the active tier.
- Approved tiers (LiteLLM aliases): `frontier-code` / `qwen3.6-27b` (primary,
inference). Alias `qwen3.6:35b-a3b` is **retired** (remaps to 27B). Backends must
ignore client model overrides for non-admins (defense in depth).

## The avatar (single asset, shipped in the package)

Canonical file **`alfa-ai-avatar.png`** (338088 bytes, updated 2026-07-06):

- Master copy: `alfa-ai/frontend/public/branding/alfa-ai-avatar.png`.
- Shipped inside the package at `packages/chat-widget/assets/alfa-ai-avatar.png`.
- Default web path consumers serve it at: `/branding/alfa-ai-avatar.png`
  (overridable via the `avatarSrc` config). A postinstall/copy step places the
  asset in each consumer's `frontend/public/branding/` (and `api/static/branding/`
  if the API serves the SPA).
- **Public WordPress guest widgets** load the same file from the brain edge:
  `https://www.example.com/alfa-ai/branding/alfa-ai-avatar.png`
  (served by the **alfa-ai-api** image build, not git on disk alone).

### Avatar-only rollout (git commit is not enough)

Replacing the PNG in git updates source trees only. Each **runtime surface**
must rebuild or recopy static assets:

| Surface | What serves the avatar | Required deploy step |
|---|---|---|
| **alfa-ai login / guest SPA** | `alfa-ai-api` embeds `frontend/dist` ([`deploy/Dockerfile.api`](../deploy/Dockerfile.api)) | On `hub`: `sudo bash scripts/brain_redeploy_api.sh` (pulls `main`, rebuilds API + SPA; not `start.sh --rebuild` alone — see runbook Section 8). Do not split into a separate `git pull` plus `--skip-pull`. |
| **WordPress guest chat** | Same public URL as brain SPA (`/alfa-ai/branding/...`) | Same brain rebuild as above; hard-refresh browser / purge CDN if cached |
| **contracts-bot Ask AI** | `frontend/dist/branding` copied to `api/static/branding` | `./scripts/build_and_deploy.sh` on `apps` |
| **rankings-bot Ask AI + home default** | `frontend/dist/branding` via nginx | `./scripts/build_frontend_with_docker.sh` on owning host (`probilliards`), reload nginx |
| **Package consumers** | URL `/branding/alfa-ai-avatar.png` (not bundled in JS) | Copy PNG into `frontend/public/branding/` then app rebuild; **no** Verdaccio bump unless you changed widget **code** |

**Sync helper (master -> package asset):**

```bash
bash scripts/sync-alfa-avatar.sh
git add frontend/public/branding/alfa-ai-avatar.png packages/chat-widget/assets/alfa-ai-avatar.png
```

**Verify (must be 338088 bytes after 2026-07-06 ALF artwork):**

```bash
curl -fsS -o /dev/null -w '%{size_download}\n' http://127.0.0.1:8420/alfa-ai/branding/alfa-ai-avatar.png
```

Full numbered runbook: [.cursor/plans/UNIFIED_CHAT_WIDGET.md](../.cursor/plans/UNIFIED_CHAT_WIDGET.md) Section 8.

## Consumer integration contract (per app)

Each SPA supplies app-specific bits to `<AlfaWidgetProvider>` (auth token
resolver, storage-key prefix, page hints, avatar path, `isAdmin`); everything
else comes from the package. Chat traffic stays **same-origin** through each
app's backend (`/api/ai-narrative/*`), which proxies LiteLLM
(`LITELLM_BASE_URL=http://hub`) server-side. Frontends never call
LiteLLM directly.

## Location map (rollout status)

Repos live on their owning hosts per
[docs/REPO_HOST_MAPPING.md](REPO_HOST_MAPPING.md) and
[.cursor/rules/git-per-host-clone.mdc](../.cursor/rules/git-per-host-clone.mdc).
**rankings-bot and USPBF both run on `probilliards` (ProBilliards)** — not `apps`.

### Package consumers (`@alfa-ai/chat-widget`)

| Repo | Owning host | Status |
|---|---|---|
| **contracts-bot** | `apps` | **Done** — `@alfa-ai/chat-widget@^1.0.2` (publish `1.0.5` for nebula thinking swirl) |
| **rankings-bot** (signed-in SPA) | `probilliards` | **Done** — `@alfa-ai/chat-widget@^1.0.2`; popup `/alfa-chat`, dock padding (`main-with-alfa-dock`); Admin **Refresh app UI** in Settings |
| **market-pie5-bot** | `market` | **Verify rebuild** — dependency bumped; confirm `frontend/dist` exists after Docker build |
| **credit-check-bot / atems / rv-auto-finder** | `apps` / `atems` | Not wired yet (Section 6) |

### Non-package surfaces (npm rebuild does **not** update these)

| Surface | Source | Deploy |
|---|---|---|
| **USPBF public demo** (`uspbf.com`) | `USPBF/nginx-config/site/` **and** `nginx-config/maintenance/` on **`probilliards`** | `bash scripts/apply-uspbf-demo-chat-theme.sh` (syncs **both** trees + patches `uspbf-nginx-maintenance.conf` for `/api/`) then rebuild `uspbf-nginx` |
| **WordPress guest chat** (ALFaQD, etc.) | `websites/alfa-wordpress-plugins/alfa-ai-guest-chat-widget/` | `install-alfa-ai-guest-chat.sh` on `apps`; avatar URL from brain edge |
| **alfa-ai brain SPA** (login, `/guest`, admin Chat) | `frontend/src/lib/alfaChatTheme.ts` + pages | `hub`: `sudo bash scripts/brain_redeploy_api.sh` (pull is the default; `--skip-pull` only if this clone is already on `origin/main`) |

**USPBF maintenance default:** `uspbf-nginx` Dockerfile bakes **maintenance** as
`default.conf`, so public `www.uspbf.com` / `uspbf.com` serves
`nginx-config/maintenance/index.html` until `./scripts/switch-site.sh production`.
Widget theme/avatar/size fixes must land in **maintenance** as well as `site/` —
maintenance mode only swaps nginx `root`; it does not auto-copy demo assets.
LAN preview `:8089` serves `site/` and is not what Cloudflare shows when maintenance
is active. **Do not** run `switch-site.sh production` unless the operator explicitly
requests a public cutover ([uspbf-nginx-maintenance-default](../.cursor/rules/uspbf-nginx-maintenance-default.mdc)).

**WordPress dock chrome (example.com):** match **contracts-bot**
`AlfaAskAiDock`, not a right-edge slide-out. Closed = pill launcher (avatar +
"ALFa AI"). Open = solid navy panel (`#0a1838`, no transparency) at
`--alfa-dock-width` / `--alfa-dock-height`. Header: sky title, page hint,
popup (`?alfa_ai_popup=1` at 520x720), fullscreen (Esc), close. No model
picker. Messages scroll inside the flex column (`flex: 1; min-height: 0` on
the log). Answers come only from **this WordPress site's published pages/posts**
(not a hand-maintained multi-product FAQ). Popup page uses WordPress `template_include` (not `template_redirect`
+ `exit`) per
[template_include](https://developer.wordpress.org/reference/hooks/template_include/).

Colors for non-package docks must mirror `packages/chat-widget/src/theme.ts`
(`#0a1838`, `#07122c`, `#142452`) and dock geometry vars in
`packages/chat-widget/assets/theme.css` (`--alfa-dock-width`, `--alfa-dock-height`).
Sync helper: `scripts/sync-chat-widget-theme-css.sh` (WordPress plugin).
USPBF static demo: `websites/uspbf-static-demo-chat/`. Avatar PNG master:
`frontend/public/branding/alfa-ai-avatar.png` (338088 bytes).

## Thinking swirl (`QuantumOrbLoader`)

While the LLM generates a reply, consumer docks and the brain SPA show a **dense
blue nebula orb** (`packages/chat-widget/src/components/QuantumOrbLoader.tsx`).
Implementation: canvas + ~150 particles, multi-layer swirl, palette
`#0ea5e9` / `#38bdf8` / `#67e8f9` on **transparent** background (chat panel
navy `#0a1838` shows through). `prefers-reduced-motion: reduce` renders a static
soft glow with no animation.

**This is aesthetic only** — it does not encode data and must not be scanned by
a camera for auth. Future **optical session pairing** (phone/iPad app linking to
the brain via QR + short code) is a separate feature; see
[.cursor/plans/ALFA_OPTICAL_SESSION_PAIRING.md](../.cursor/plans/ALFA_OPTICAL_SESSION_PAIRING.md).
Do not copy Apple's patented temporal chrominance optical-label encoding.

Brain SPA mirrors the same loader in
[`frontend/src/components/QuantumOrbLoader.tsx`](../frontend/src/components/QuantumOrbLoader.tsx)
(keep aligned with the package when changing motion or palette).

## Connectivity / self-test badges (why "Degraded" / "Self-Test FAIL" appears)

These are **consumer-side probes of the ALFa AI brain**, not bugs in the bot:

- **contracts-bot "ALFa Degraded":** `GET /api/health/connectivity` reflects the
  27B pool warm state via LiteLLM. "Degraded" = proxy up but pool loading.
- **rankings-bot "Self-Test FAIL":** self-test panel probes ALFa reachability.

The connectivity header stays app-side (each app has its own health endpoint);
the package does not bundle it.

## Related

- [.cursor/plans/UNIFIED_CHAT_WIDGET.md](../.cursor/plans/UNIFIED_CHAT_WIDGET.md) - rollout runbook
- [.cursor/plans/CHAT_WIDGET_CONFORMITY.md](../.cursor/plans/CHAT_WIDGET_CONFORMITY.md) - dock geometry + WP/USPBF conformity (2026-07-10)
- [.cursor/rules/alfa-ai-authoritative.mdc](../.cursor/rules/alfa-ai-authoritative.mdc)
- [deploy/npm-proxy/README.md](../deploy/npm-proxy/README.md) - Verdaccio + publish
- [docs/HUB_ARTIFACTS.md](HUB_ARTIFACTS.md) - hub/registry policy
