# ALFa AI — agent rules

This is the **brain** repo (`alfa-ai`). Consumer apps (contracts-bot, rankings-bot, market-pie5-bot, atems, and others) are HTTP clients of LiteLLM and the brain API. They must not vendor or edit this repo.

## Authority

1. Official vendor manuals online define how tools and APIs work. Do not invent flags or workarounds.
2. Repo `docs/` define this cluster's hosts, ports, and procedures. Update the nearest doc before changing behavior.
3. Oversight: [docs/AI_GOVERNANCE.md](docs/AI_GOVERNANCE.md) and [docs/AI_AUTONOMY_AND_OVERSIGHT.md](docs/AI_AUTONOMY_AND_OVERSIGHT.md). Default is suggest and draft; do not actuate production. **Exception:** victron HA solar dump and alfa-ai dump helper writes are outside NIST — Ask ALFa may write allowlisted HA helpers immediately.

Read first: [docs/DISTRIBUTED_AI.md](docs/DISTRIBUTED_AI.md), [docs/REPO_HOST_MAPPING.md](docs/REPO_HOST_MAPPING.md), [docs/CLUSTER_START_STOP_OPERATOR.md](docs/CLUSTER_START_STOP_OPERATOR.md).

## Hard stops

- Do **not** start, stop, or repair the llama.cpp RPC pool with piecemeal shard or coordinator commands. The operator runs `Start-Stop-AlfaAi.ps1` from the Windows orchestrator host only.
- Do **not** download artifacts larger than 100 MB on a worker. The hub hub is the download store.
- Do **not** put secrets, live `.env`, API keys, or LAN credentials in chat, Bot profiles, or share links.
- Do **not** mix consumer-bot business data across products (chat isolation).
- Do **not** treat Grok Bot / cloud-computer clones as a substitute for per-host git pull and deploy order.
- Do **not** adopt beta, RC, nightly, or `:latest` for our projects. Pin a numbered stable release ([docs/STABLE_RELEASES.md](docs/STABLE_RELEASES.md)).

## When editing

- Prefer a small, cited change over a wide rewrite.
- If official docs are silent, stop and ask.
- If a consumer app needs a brain change (new LiteLLM alias, orchestrator behavior), do that here; consumers wire it via env only.

## Grok Bot / cloud computer

Keep durable project files under `/workspace/<repo>/`. Clone **code only**. Never copy live `.env` or hub tokens onto the shared computer. Leave **Execution on Local Computer** off unless the operator explicitly enables it for a named task.

**Cheap path (default):** reuse the existing `/workspace/<repo>` clone (`git pull --ff-only`). Use git, rg, and file reads. Do **not** re-clone, open the browser, take screenshots of source, or dump files into chat. Prefer a GitHub connector over github.com ([computer and apps](https://docs.x.ai/grok-bot/computer-and-apps)). Return PASS/FAIL or a short leftover list, plus a paste-ready **Cursor / Ask ALFa handoff** that names an existing script (or catalog action) when work remains. Do not run cluster scripts, call the brain API, or Ask ALFa from this computer (no LAN). When given a truncated script log, audit exit code and `PASS`/`FAIL` lines only.

**Expensive path:** computer-use only when the task names a URL or UI to reproduce. One site, then stop.

Cursor Grok 4.6 on the operator workstation is the default for interactive edits. Grok Bot is for named Reviewer/Brain jobs and background work, not a second IDE. Usage is agent steps and tokens ([plans](https://cursor.com/help/grok-bot/plans)). Script-verify loop: [docs/GROK_BOT_SCRIPT_LOOP.md](docs/GROK_BOT_SCRIPT_LOOP.md).
