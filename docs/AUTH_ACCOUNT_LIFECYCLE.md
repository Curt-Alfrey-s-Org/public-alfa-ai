# Account lifecycle: register -> verify email -> admin approval

**Update (2026-09-25):** failed-login account lockout is now enforced and
failed logins are rate-limited per client IP. See
[Failed-login lockout and per-IP limit](#failed-login-lockout-and-per-ip-limit).

**Status (2026-09-11):** Self-service register creates an inactive-for-login
`role=user` row. The public **Register** page shows the API success message and
does **not** auto-login (a session would fail the verify/approval gates). Login
shows the backend gate messages for unverified / unapproved accounts
([FastAPI `HTTPException` `detail`](https://fastapi.tiangolo.com/tutorial/handling-errors/#use-httpexception)).
**Admin -> Users** can create a user in-page (no visit to `/register`), resend
verification, mark email verified (SMTP bypass), and approve. Admin-created
users start **email verified and approved** so they can sign in immediately.

Self-service registration on the public ALFa AI login/register pages
(`/alfa-ai/register`, `/alfa-ai/login`) does **not** grant an immediately usable
account. Every new `role=user` account must clear two independent gates before it
can log in:

1. **Email verification** — user clicks a link emailed to the address they
   registered with, **or** an admin clicks **Mark verified** when mail never
   arrives.
2. **Admin approval** — an admin explicitly approves the account from
   **Admin -> Users**.

2FA remains **optional** (unchanged) — a user may enable it from **Account ->
Password** after their first successful login; it is not required to register or
to be approved.

## Why two gates

- Email verification proves the address is real and reachable when SMTP works
  (also how `notify_email`-style AI alert delivery assumes a valid mailbox).
- Admin approval is an explicit human control point — no self-registered
  account becomes usable without a person clicking Approve, regardless of
  email verification status.
- **Mark verified** exists because `send_email` is best-effort: registration
  still succeeds when SMTP is unconfigured or the send fails. Without an admin
  bypass, those accounts stay stuck on the verify gate forever.

## Data model (`users` table, `src/api/models/user.py`)

| Column | Default (existing rows) | Default (new self-registration) | Meaning |
|---|---|---|---|
| `email_verified` | `TRUE` (migration backfill) | `FALSE` | Set `TRUE` when the emailed link is clicked, or by admin **Mark verified** |
| `email_verify_token` | `NULL` | random `secrets.token_urlsafe(32)` | Cleared once verified |
| `email_verify_expires` | `NULL` | now + 24h | Token is a dead link once past this |
| `approved` | `TRUE` (migration backfill) | `FALSE` | Set `TRUE` only by an admin action |
| `approved_by` | `NULL` | `NULL` | Admin email that approved |
| `approved_at` | `NULL` | `NULL` | Timestamp of approval |
| `is_active` | unchanged | `TRUE` | **Unchanged meaning** — admin ban/deactivate switch (Admin -> Users -> Deactivate). Independent of `approved`. |

Migration backfills existing rows to `email_verified=TRUE, approved=TRUE` so no
currently-active account (including the primary admin bootstrap flow in
`ensure_primary_admin`) is retroactively locked out. Only rows created through
`POST /alfa-ai/api/auth/register` start with both flags `FALSE`.

## Registration flow

1. `POST /alfa-ai/api/auth/register` — same required fields as before (email,
   username, password; all standard validation unchanged). Creates the user row
   with `approved=FALSE`, `email_verified=FALSE`, a random verify token, and a
   24h expiry. Attempts a verification email (see below). Does **not** return a
   session token. The response `message` tells the user the account was created,
   to open a confirmation link **if** mail arrives, and otherwise to wait for
   an administrator. Conflict (`409`) stays `REGISTRATION_FAILED_MSG` (no
   "email already registered" leak). Per-IP cooldown (`429`) is
   `REGISTER_COOLDOWN_SEC` (120s).
2. Frontend `AuthContext.register` returns that `message` and **must not** call
   `login`. `Register.tsx` shows a success panel (not a red error). A 429 on
   retry tells the user to wait a couple of minutes and that a prior submit may
   already have created the account (without naming which field collided).
3. `POST /alfa-ai/api/auth/verify-email` `{ "token": "..." }` — clears the token
   fields and sets `email_verified=TRUE`. Routed at `/alfa-ai/verify-email`
   (`VerifyEmail.tsx`).
4. `POST /alfa-ai/api/auth/resend-verification` `{ "login": "..." }` — issues a
   fresh token/expiry if the account exists and is not yet verified. Always
   returns the same generic `{ ok: true }` message regardless of whether the
   account exists, to avoid leaking registration status by email/username probing.
5. Admin reviews **Admin -> Users** (self-registered rows still need both gates):
   - **Resend verification** (when `email_verified=FALSE`) —
     `POST /alfa-ai/api/admin/users/{id}/resend-verification`. Reuses
     `auth._new_verify_token` + `auth._send_verification_email` (same SMTP
     helper as public register; no second mail stack). Audit
     `user_verification_resent_by_admin`. This is an **admin** route: it may
     say the send was attempted. Public `POST /auth/resend-verification` stays
     generic so it cannot probe whether an email is registered.
   - **Mark verified** (when `email_verified=FALSE`) —
     `PATCH /alfa-ai/api/admin/users/{id}/email-verified` `{ "verified": true }`.
     Calls `UserStore.mark_email_verified`. Audit `user_email_verified_by_admin`.
     One-way (cannot un-verify). Use this when SMTP never delivered.
   - **Approve** — `PATCH /alfa-ai/api/admin/users/{id}/approve`
     `{ "approved": true }`. Audit `user_approved`.
   Both gates are still required for **self-registered** accounts. Approve
   alone does not unlock login.

## Admin-created users (no public register)

Operators create accounts from **Admin -> Users** without opening `/register`.

`POST /alfa-ai/api/admin/users` ([FastAPI request body](https://fastapi.tiangolo.com/tutorial/body/))
accepts `email`, `username`, `password`, `password_confirm` (same length/charset
rules as public register). The creating admin **is** the human gate, so the row
is stored with:

| Flag | Admin-created default | Why |
|---|---|---|
| `email_verified` | `TRUE` | Operator already chose the mailbox; skip SMTP |
| `approved` | `TRUE` | Operator already clicked Create |
| `is_active` | `TRUE` | Same as self-register |
| `role` | `user` | Elevate later via the Role column |

No verification email is sent on admin create. The user can sign in with the
password the admin set. Duplicate email/username returns HTTP 409 with an
admin-only "already in use" detail (this string is **not** used on the public
register route, which stays `REGISTRATION_FAILED_MSG`).

Audit: `user_created_by_admin`.

## Login gate order (`POST /alfa-ai/api/auth/login`)

Before password verification, in order:

1. Honeypot IP block / honeypot username (unchanged).
2. **Per-IP failed-login limit** -> HTTP `429` `RATE_LIMIT_GENERIC` with
   `Retry-After` (see [Failed-login lockout and per-IP limit](#failed-login-lockout-and-per-ip-limit)).
3. **Active account lock** -> generic `INVALID_CREDENTIALS_MSG`, even when the
   password is correct. The password is not checked.

After password verification, in order:

1. `is_active == FALSE` -> generic `INVALID_CREDENTIALS_MSG` (unchanged — admin
   ban must not be distinguishable from a wrong password).
2. `email_verified == FALSE` -> `EMAIL_NOT_VERIFIED_MSG` ("Please verify your
   email address first...").
3. `approved == FALSE` -> `ACCOUNT_PENDING_APPROVAL_MSG` ("Your account is
   pending admin approval. Please contact the administrator.").
4. 2FA branch (optional; code attempts are limited, see
   [2FA attempt limit](#2fa-attempt-limit)).

**Operator-accepted tradeoff:** steps 2 and 3 return distinct messages (unlike
step 1), which confirms to whoever is testing that login an account with that
email/username exists but is unverified/unapproved. This is a deliberate product
decision (the operator wants new users to know exactly what to do next) that
trades a small amount of account-enumeration resistance for onboarding clarity.
It does not reveal password correctness or any other account detail. The SPA
login client must **surface those two `detail` strings** on HTTP 401; it must
not replace every 401 with the generic credentials line. Wrong-password and
deactivated accounts stay generic.

If this tradeoff needs to be revisited, tighten steps 2-3 back to the generic
message and rely on the email itself for verification-status feedback.

## Failed-login lockout and per-IP limit

Added 2026-09-25 (org code review finding 15). Before this change the lock was
written but never checked, and a correct password cleared it.

### Account lockout (per user)

| Setting | Value | Where |
|---|---|---|
| Threshold | **5** wrong passwords (`MAX_LOGIN_ATTEMPTS`) | `src/api/models/audit.py` |
| Counting window | **15 min** (`LOGIN_WINDOW_MINUTES`), `login_failed` rows in `audit_log` | same |
| Lock duration | **15 min** from the 5th failure (`users.account_locked_until`) | same |

- While the lock is active, login is refused **even with the correct password**.
  The response is the same generic `INVALID_CREDENTIALS_MSG` as a wrong password
  (it reveals neither the lock nor whether the password was right). The SPA shows
  that line, so a locked user just sees "invalid" until the lock expires.
- Refused attempts are audited as `login_locked_refused`. They do **not** count as
  `login_failed`, so they don't extend the lock. They **do** count toward the
  per-IP limit below.
- A correct password never clears an active lock. After a lock **expires**, the
  next successful login resets the counter and clears the expired lock
  (`SecurityStore.clear_expired_lock`).
- The lock applies to admins too. An attacker who knows an admin username can
  keep that account locked (standard lockout tradeoff). Use the unlock paths below
  or the -only admin allowlist (`ALFA_AI_ADMIN_ALLOWED_CIDRS`) to limit
  this.

**How an admin unlocks an account** (any of these clears `account_locked_until`
immediately):

1. `POST /alfa-ai/api/admin/users/{user_id}/unlock`. Admin JWT only, admin network
   allowlist applies. Clears the lock **without** changing the password or 2FA.
   Audit: `admin_account_unlocked`. There is no Admin UI button yet (follow-up),
   so call it with the admin session's bearer token, e.g.
   `curl -X POST -H "Authorization: Bearer <admin access token>" http://<brain>:8420/alfa-ai/api/admin/users/<id>/unlock`.
   Get user ids from `GET /alfa-ai/api/admin/users`.
2. **Admin -> Users -> set password** (`PATCH /alfa-ai/api/admin/users/{id}/password`).
   Also clears the lock, but it **replaces the password and disables 2FA**.
3. Locked-out primary admin with no other admin: `scripts/reset_admin_password.py`
   inside the API container (it also clears the lock columns).
4. Or wait for the 15 min lock to expire.

### Per-IP failed-login limit (per client)

`src/api/login_rate_limit.py`. It counts every failed login from a client IP:
wrong password, unknown username, and attempts refused by an active lock. Once the
limit is reached, **all** login attempts from that IP get HTTP `429`
(`RATE_LIMIT_GENERIC`, `Retry-After: <window>`) until older failures age out of
the sliding window. Successful logins do not reset it. Lifecycle-gate failures that
already passed the password (unverified / unapproved / deactivated) are not counted.

| Env var | Default | Meaning |
|---|---|---|
| `ALFA_AI_LOGIN_IP_MAX_FAILURES` | `20` | Failed logins allowed per client IP per window. `0` disables the limit. |
| `ALFA_AI_LOGIN_IP_WINDOW_SEC` | `900` (15 min) | Sliding window length and `Retry-After` value. |

Storage matches guest chat (audit D-011): a Redis ZSET `alfaai:login:ipfail:<ip>`
shared by all API workers when `REDIS_URL` is set. If Redis is unset or
unreachable it falls back to per-process memory (bounded to 10k IPs). To clear one
IP early, delete that key in `alfa-redis` (`DEL alfaai:login:ipfail:<ip>`) or
restart the API when running on the memory fallback.

**Which IP is used.** The key is `request.client.host` as resolved by Uvicorn's
trusted-proxy handling (`get_proxy_resolved_client_ip` in
`src/api/admin_network.py`). `Dockerfile.api` runs Uvicorn with `--proxy-headers
--forwarded-allow-ips=$FORWARDED_ALLOW_IPS`, so `X-Forwarded-For` is only honoured
when the direct peer is a trusted proxy, and then the **right-most untrusted** hop
is used. The key is **not** the raw first `X-Forwarded-For` value, which any client
can set. (The admin allowlist, guest limit, and honeypot still use the raw header
via `get_client_ip`. That is review medium finding 8, tracked separately.)

**Operator check:** the brain must see the public edge as a trusted proxy.
Otherwise every public request shares the edge's IP and the limit applies to all
public users together. Public traffic arrives from the `inference` edge nginx
(`deploy/nginx-edge/alfa-ai-edge.conf` -> `hub`). If the brain sees
that peer as `orchestrator` rather than a Docker bridge address, add it to
`FORWARDED_ALLOW_IPS` in `deploy/.env` (e.g.
`FORWARDED_ALLOW_IPS=127.0.0.1,10.0.0.0/8,172.16.0.0/12,orchestrator`). Never use
`*`. To verify, check the `ip_address` column of recent `login_locked_refused` /
API log lines, or temporarily log `request.client.host`.

### 2FA attempt limit

`POST /alfa-ai/api/auth/verify-2fa` (org review 2026-09-25). A `2fa_pending` token
lives 5 minutes; before this change it allowed unlimited code guesses.

- The per-IP limit above also applies: the check runs before the code is verified
  (HTTP `429`, `Retry-After`), and every wrong code or refused attempt counts as a
  failure in the same `alfaai:login:ipfail:<ip>` window as failed logins.
- An **active account lock** refuses verification even with the right code
  (generic `AUTH_FAILED_MSG`, audit `2fa_locked_refused`).
- `MAX_LOGIN_ATTEMPTS` (5) wrong codes within `LOGIN_WINDOW_MINUTES` (15) lock the
  account for 15 minutes, like wrong passwords (audit `2fa_failed` per miss,
  `2fa_locked` when the lock is set). Unlock paths are the same as above.

No new env vars.

### 2FA setup and password length (round-2 review 2026-09-26)

- `POST /alfa-ai/api/auth/setup-2fa` returns HTTP `409` ("2FA is already enabled")
  when 2FA is on. Re-running setup used to replace the secret with 2FA disabled, so
  any access-token holder could switch 2FA off. To move 2FA to a new device, an
  admin uses **Admin -> Users -> set password** (which disables 2FA), then the user
  enrolls again.
- Passwords are bcrypt hashed, and bcrypt uses at most **72 bytes**. bcrypt 5
  raises instead of truncating, so a new password longer than 72 UTF-8 bytes
  (register, change password, admin create / set password) now returns HTTP `422`
  instead of a 500. Login truncates to 72 bytes exactly like bcrypt 4 did, so
  older hashes still verify and an over-long guess is an ordinary wrong password.

## Email delivery (`src/api/email_util.py`)

Generic `send_email(to_addr, subject, body)` helper reused for verification
links (and available for future account emails). It reuses the **incident SMTP
relay** (`ALFA_AI_INCIDENT_SMTP_*` in `deploy/env.example`) by default, since
most deployments only configure one relay. Set `ALFA_AI_SMTP_HOST` /
`ALFA_AI_SMTP_PORT` / `ALFA_AI_SMTP_USER` / `ALFA_AI_SMTP_PASSWORD` /
`ALFA_AI_SMTP_FROM` / `ALFA_AI_SMTP_TLS` to point account emails at a **different**
relay/from-address than incident alerts; otherwise the incident SMTP vars are
used as-is. See [src/incident/notify.py](../src/incident/notify.py) for the
sibling incident-email code path (kept separate/unrefactored to avoid touching
working incident-notify logic).

The verification link is built from `ALFA_AI_PUBLIC_URL` (default
`https://www.example.com`) + `/alfa-ai/verify-email?token=...`. Set
`ALFA_AI_PUBLIC_URL` in `deploy/.env` if the public domain ever changes.

If SMTP is not configured or the send fails, `send_email` logs and returns
`False` without raising — registration still succeeds (the row is created). The
user then has no working link. **Operator path for a stuck self-signup:**
Admin -> Users -> **Resend verification** (retry the same SMTP path) and/or
**Mark verified**, then **Approve**. Or create the person from **Create user**
(starts verified + approved). Public register copy must not assume the inbox
received a message.

## Guest chat message limit

Guest (anonymous) chat at `/guest` allows **3 messages** total (was 10) before
requiring an account. `GUEST_MAX_MESSAGES` env var in
[src/api/routers/guest.py](../src/api/routers/guest.py) (default now `3`, live).

**Roles (org review 2026-09-25):** `POST /alfa-ai/api/guest/chat` accepts only
`user` and `assistant` messages (at most 6). Any other role — `system`, `tool`,
`developer`, … — is rejected with HTTP `422` before anything reaches LiteLLM, so a
caller cannot replace the server's own guest system prompt. Integrations that need
a primer send it as a leading user/assistant pair (example-site-perch's
`/wp-json/wpr/v1/chat` already does this: primer pair + last 4 visitor turns).

## Admin Users tab

[frontend/src/pages/admin/UsersPage.tsx](../frontend/src/pages/admin/UsersPage.tsx):

- **Create user** form on the same page (email, username, password, confirm).
  Does not send the operator to `/register`.
- **Email Verified**: `verified` (green), or `unverified` plus **Resend
  verification** and **Mark verified** when `email_verified=FALSE`.
- **Approval**: `approved` (green) or an **Approve** button (amber) when
  `approved=FALSE`. Approving while still unverified shows a reminder that
  login still requires **Mark verified**.

The existing **Deactivate/Activate** button and `is_active` column are
unchanged — deactivation is a separate, independent control from approval.
