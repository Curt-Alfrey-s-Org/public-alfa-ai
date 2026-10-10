# ALFa AI Users Manual (in-app how-to)

Customer-facing how-to for the ALFa AI chat app. The SPA renders this content at
**`/alfa-ai/manual`**. Keep public sections free of LAN IPs, hostnames, VPN product
names, and stack topology ([public-surface-security.mdc](../.cursor/rules/public-surface-security.mdc)).

**In-app:** [frontend/src/pages/ManualPage.tsx](../frontend/src/pages/ManualPage.tsx)
and [frontend/src/content/manualSections.tsx](../frontend/src/content/manualSections.tsx).

**Related:** [About](../frontend/src/pages/AboutPage.tsx) (`/about`) is a short
overview; this manual is the step-by-step how-to.

## Audience

| Section | Who sees it |
|---------|-------------|
| Getting started, chat, account, models | Everyone (guest + signed-in) |
| Admin console how-to | Only when `user.is_admin === true` (frontend); `/admin/*` still requires admin JWT + network allowlist |

## User topics (public)

1. **Sign in / guest** — Register, login, guest chat limits.
2. **Chat basics** — Send, edit, model picker, streaming.
3. **Account** — Password change, 2FA setup.
4. **Models** — Point to About model tiers (no internal routing detail).

## Admin topics (admin-only in UI)

High-level console how-to only (not full cluster runbooks):

1. Open **Admin** from chat header (admins only).
2. **Health** — service status overview.
3. **Monitoring** — incidents queue.
4. **AI Actions** — settings, Ask ALFa, host actions (approve before run).
5. **Models / Editor / Users / Audit** — what each tab is for.
6. Pointers to operator docs in the repo (`docs/INDEX.md`, `CLUSTER_START_STOP_OPERATOR.md`) for deploy — not pasted into the public SPA.

## Deploy note

After changing manual content or routes, rebuild/recreate `alfa-ai-api` on the brain
host so the SPA bundle updates.
