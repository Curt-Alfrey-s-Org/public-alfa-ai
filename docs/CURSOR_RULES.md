# Cursor rules in alfa-ai

This repo is the **canonical home** for cluster operator and agent rules. Cursor loads
them from `.cursor/rules/` (41+ `.mdc` files) plus [RULES.md](../.cursor/rules/RULES.md).

## Already in this repo (no separate copy needed)

| Location | Purpose |
|----------|---------|
| `.cursor/rules/*.mdc` | Always-on or glob-scoped agent rules (cluster sync, hub-first, PS 5.1, Ask ALFa, inference, etc.) |
| `.cursor/agents/*.md` | Project subagents (cluster-operator, critical-bug-hunter, public-surface-cyber-audit) |
| `.cursor/skills/*/SKILL.md` | Deploy, git sync, inference diagnose skills |

There is **no** `~/.cursor/rules` folder on the operator workstation -- user-specific
Cursor **User Rules** (from Cursor Settings -> Rules) live in the Cursor app, not in
this git repo. To version those, paste them into a new `.cursor/rules/*.mdc` here and
commit.

## Ask ALFa vs Cursor rules

- **Cursor rules** (this folder) guide **developers/agents editing the repo**.
- **Ask ALFa** (`_MONITORING_AGENT_SYSTEM` in `src/api/routers/admin.py`) guides
  **operators in the admin SPA** -- including end-to-end navigation after Approve
  ([achange-me.mdc](../.cursor/rules/achange-me.mdc)).

You do **not** need a separate "27b rule" for mission navigation if the system prompt
and deterministic `navigation_hint` UI are present. The LLM supplements when intent
is ambiguous; programs own enqueue, fleet status, and post-approve deep links.

## Sync to other clones

After `git pull` on `orchestrator`, `apps`, `pool-opt-in`, `hub`, every clone gets the same
`.cursor/rules/`. Sibling consumer repos may carry copies of boundary rules per
[alfa-ai-authoritative.mdc](../.cursor/rules/alfa-ai-authoritative.mdc).

## Related

- [CURSOR_TOOLS_AND_SKILLS.md](CURSOR_TOOLS_AND_SKILLS.md)
- [AI_ACTIONS.md](AI_ACTIONS.md) -- Ask ALFa widget
- [ADMIN_MISSIONS.md](ADMIN_MISSIONS.md) -- mission output path
