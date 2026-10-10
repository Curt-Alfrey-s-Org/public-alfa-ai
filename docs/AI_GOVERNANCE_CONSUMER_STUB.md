# AI governance (consumer stub)

**Canonical source:** [alfa-ai `docs/AI_GOVERNANCE.md`](https://github.com/example/alfa-ai/blob/main/docs/AI_GOVERNANCE.md)

This consumer repo follows the ALFa cluster AI oversight model:

- **L1 default:** programmatic routing; AI enriches and suggests only.
- **L2 mutate:** human Approve before any SSH, settings, or remediation apply.
- **L3 auto-fix:** off by default; allowlisted playbooks only after drills.

Consumer bots do not implement host actions or incident remediation. They call the
shared LiteLLM gateway over HTTP with env-configured model aliases.

**Production requirements (audit 2026-07-11):**

- `LITELLM_BASE_URL` → brain (`http://hub` unless shared Docker DNS).
- `LITELLM_API_KEY` unique (prefer LiteLLM virtual keys) — no shared `sk-*-dev` defaults.
- When `LITELLM_ENABLED=true`, fail closed on Ollama unless `LITELLM_ALLOW_OLLAMA_FALLBACK=true`.

Standards extracts: alfa-ai `docs/standards/README.md`.

Autonomy matrix: alfa-ai `docs/AI_AUTONOMY_AND_OVERSIGHT.md`.

Do not duplicate the full governance doc here — link and comply with env boundaries.
