# Fleet agent rules (synced from alfa-ai)

**Authority:** alfa-ai `.cursor/rules/` is the **master** for cluster-wide agent handoff rules.
Consumer and sibling repos carry **copies** so Cursor on any host sees the same git and mistake policy.

## Master files (always synced)

| File | Purpose |
|------|---------|
| [agent-mistake-create-rule.mdc](../.cursor/rules/agent-mistake-create-rule.mdc) | Agent mistake -> add a rule; do not only apologize |
| [git-no-pull-on-push-host.mdc](../.cursor/rules/git-no-pull-on-push-host.mdc) | Never `git pull` on the host that just pushed |
| [git-per-host-clone.mdc](../.cursor/rules/git-per-host-clone.mdc) | Commit/push on owner; pull on other clones only |
| [stable-releases-only.mdc](../.cursor/rules/stable-releases-only.mdc) | Numbered stable releases for our projects |

## Sync script

From a host with sibling clones next to `alfa-ai` (e.g. `apps` `/home/operator`, or `orchestrator` `C:/Users/operator`):

```bash
cd /path/to/alfa-ai
bash scripts/sync-fleet-agent-rules.sh
```

Windows (`orchestrator` colocated clones):

```powershell
wsl -d Ubuntu bash -lc 'cd /mnt/c/Users/operator/alfa-ai && bash scripts/sync-fleet-agent-rules.sh'
```

Then **commit and push each updated repo from the host that owns that clone**
([git-per-host-clone.mdc](../.cursor/rules/git-per-host-clone.mdc)).

## When to run

- After adding or editing any file in the master list above in alfa-ai.
- After operator establishes a new fleet-wide agent rule (per `agent-mistake-create-rule.mdc`).

## Do not hand-edit copies

Edit the alfa-ai master, run sync, then commit in each target repo. Copies may include
[fleet-agent-rules-source.mdc](../.cursor/rules/fleet-agent-rules-source.mdc) (stamp only).
