# USPBF static demo chat (non-package surface)

USPBF on **`probilliards`** (`/home/operator/USPBF`) serves a **static** ALFa demo dock on uspbf.com. It is
**not** `@alfa-ai/chat-widget`; it POSTs to rankings-bot `POST /api/ai-narrative/demo-ask` on the same host.

Canonical host map: [docs/REPO_HOST_MAPPING.md](../../docs/REPO_HOST_MAPPING.md).

## Align with canonical design

1. **On `probilliards` (operator):** run the helper (copies avatar from rankings-bot branding, patches JS/CSS, bumps cache buster):
   ```bash
   cd /home/operator/USPBF
   git pull --ff-only origin main   # after alfa-ai script is pushed, or copy script from alfa-ai clone
   bash /path/to/alfa-ai/scripts/apply-uspbf-demo-chat-theme.sh /home/operator/USPBF
   ```
   Expect avatar **338088** bytes at `nginx-config/site/branding/alfa-ai-avatar.png`.

2. **JS:** header must use `<img class="alfa-demo__avatar" src="/branding/alfa-ai-avatar.png" ...>`
   (not a teal letter "A"). File: `nginx-config/site/js/alfa-demo-chat.js`.

3. **CSS:** colors match `packages/chat-widget/src/theme.ts` (see `alfa-demo-theme.css` in this folder).

4. **Deploy on `probilliards`:**
   ```bash
   cd /home/operator/USPBF && docker compose build uspbf-nginx && docker compose up -d --force-recreate uspbf-nginx
   ```

5. Commit/push **USPBF** from `probilliards`; other clones pull before deploy.

See also `docs/ALFA_AI_CHAT_WIDGETS.md` (non-package surfaces table).
