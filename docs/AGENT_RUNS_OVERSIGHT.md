# Agent runs oversight (mission `/api/runs`)

**Authority:** [docs/AI_GOVERNANCE.md](AI_GOVERNANCE.md), [docs/AI_AUTONOMY_AND_OVERSIGHT.md](AI_AUTONOMY_AND_OVERSIGHT.md), tier **1b** [nist-sre-ai-oversight.mdc](../.cursor/rules/nist-sre-ai-oversight.mdc).

Background mission agents (`POST /api/runs`, `src/agent/loop.py`) are **not** on the public
alert hot path. They still mutate the workspace when enabled, so tool access is gated.

## Defaults (Wave 1)

| Control | Default | Effect |
|---------|---------|--------|
| `ALFA_AI_AGENT_MUTATE_ENABLED` | `0` | Blocks `create_file`, `edit_file`, `run_cmd` for most roles |
| `research_only` on run | per request | Researcher path is read-only regardless of mutate flag |
| Role | varies | See allowlist table below |

## Per-role tool allowlists

| Role | Tools when `ALFA_AI_AGENT_MUTATE_ENABLED=0` | Tools when mutate `=1` |
|------|---------------------------------------------|-------------------------|
| `researcher` | `grep_repo`, `read_file`, `glob_files`, `list_dir`, `fetch_url`, `web_search` | same (read-only) |
| `contracts` | `list_dir`, `read_file`, `create_file` | same |
| `coder` | read-only set | full `TOOL_MAP` |
| `debugger`, `doc_maker`, `default` | read-only set | full `TOOL_MAP` |

Blocked tool calls return `{"ok": false, "error": "... not allowed ..."}` in the run timeline;
they are not executed.

## Operator enablement

Set `ALFA_AI_AGENT_MUTATE_ENABLED=1` in brain `deploy/.env` only when you accept filesystem
and shell mutation from mission agents. Recreate `alfa-ai-api` / agent worker after change.
Prefer short-lived runs with `research_only=true` for audits.

## Related

- [AI_ACTIONS.md](AI_ACTIONS.md) -- alert/notify domain (separate from mission agents)
- [ADMIN_AI_HOST_ACTIONS.md](ADMIN_AI_HOST_ACTIONS.md) -- SSH host actions (L2 Approve)
- [GROK_BOT_SCRIPT_LOOP.md](GROK_BOT_SCRIPT_LOOP.md) -- Grok Bot / script-verify loop
