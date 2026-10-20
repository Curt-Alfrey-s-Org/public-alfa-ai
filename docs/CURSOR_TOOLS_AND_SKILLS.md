# Cursor tools and skills inventory (daily ops)

Operator-facing inventory of **Cursor IDE** skills/agents and **ALFa product** agent
skills/tools. Add-only policy: nothing is removed without an explicit operator decision.

**SSoT plan:** [.cursor/plans/AGENT_PLATFORM_GROK_ALIGNMENT.md](../.cursor/plans/AGENT_PLATFORM_GROK_ALIGNMENT.md) section 12.

---

## When to use which (daily workflows)

| You want to... | Use |
|----------------|-----|
| Start/stop/restart the cluster | Cursor skill **`cluster-ops`** or agent **`cluster-operator`** |
| Deploy a code change across hosts | Cursor skill **`deploy-runbook`** |
| Commit/push and sync every clone | Cursor skill **`multi-host-git`** |
| Debug inference / frontier-code (read-only) | Cursor skill **`diagnose-inference`** |
| Edit contracts-bot, rankings-bot, USPBF, etc. | Cursor skill **`consumer-bot-boundary`** |
| Audit recent commits for critical bugs | Subagent **`critical-bug-hunter`** |
| Audit public login/API error strings | Subagent **`public-surface-cyber-audit`** |
| Run a LAN research mission on 27B | ALFa skill **`audit-repo`** via `POST /api/runs` (memory persists across missions) |
| Online research (SearXNG on `hub`) | Enable `ALFA_AI_WEB_SEARCH_ENABLED=1`; tool **`web_search`** in agent loop |
| Implement a change via operator mission | ALFa skill **`implement`** |
| Babysit a PR / fix CI | Cursor managed skill **`babysit`** |
| Split a large change into PRs | Cursor managed skill **`split-to-prs`** |

---

## Cursor IDE — project skills (`.cursor/skills/`)

Loaded by Cursor Agent when the task matches the skill `description`.

| Skill | Triggers |
|-------|----------|
| **cluster-ops** | Cluster start/stop/restart; orchestrator-only; no piecemeal inference |
| **deploy-runbook** | Multi-host rollout; Status + numbered steps; hub-first; health waits |
| **multi-host-git** | Per-host commit/push; pull every consumer; GitHub sync bus |
| **diagnose-inference** | inference failures; read-only logs and coordinator health |
| **consumer-bot-boundary** | Consumer repo work; one-way coupling to alfa-ai |

---

## Cursor IDE — project agents (`.cursor/agents/`)

| Agent | Use when |
|-------|----------|
| **cluster-operator** | Long cluster diagnose/deploy threads; delegates to project skills above |
| **critical-bug-hunter** | High-severity bugs in recent commits (data loss, crashes, auth bypass) |
| **public-surface-cyber-audit** | Public-surface compliance before launch or after auth/infra changes |

See [.cursor/rules/use-subagents.mdc](../.cursor/rules/use-subagents.mdc).

---

## Cursor IDE — managed skills (`~/.cursor/skills-cursor/`)

Shipped with Cursor; not repo-local. Common daily use:

| Skill | Purpose |
|-------|---------|
| **babysit** | Keep PR merge-ready (CI, comments, conflicts) |
| **split-to-prs** | Split work into smaller PRs |
| **review-bugbot** / **review-security** | Code review subagents |
| **create-rule** / **create-skill** | Author new rules or skills |
| **shell** | Shell command patterns |
| **automate** | Cursor Automations |
| **canvas** | Live React analytical artifacts |
| **sdk** | Cursor SDK integration |
| **loop** | Recurring prompt runs |
| **update-cursor-settings** | Edit settings.json |

Full list: see Cursor skills UI or `~/.cursor/skills-cursor/`.

---

## ALFa product — skills (`skills/`)

Used by the **operator agent loop** (`POST /api/runs`), not Cursor IDE directly.
Loaded via [src/agent/skills.py](../src/agent/skills.py).

| Skill | Default role | Purpose |
|-------|--------------|---------|
| **audit-repo** | researcher | Read-only repo audit with structured findings |
| **implement** | coder | Minimal focused code changes |
| **check-work** | debugger | Verify goal; VERDICT PASS/FAIL |
| **review** | doc_maker | Read-only structured code review |

Details: [AGENT_RESEARCH_TOOLS.md](AGENT_RESEARCH_TOOLS.md).

---

## ALFa product — agent tools (`src/agent/tools.py`)

| Tool | Purpose |
|------|---------|
| **grep_repo** | Ripgrep under workspace root |
| **glob_files** | File pattern search |
| **fetch_url** | Allowlisted vendor-doc HTTP GET |
| **web_search** | LAN SearXNG JSON search (gated; default off) |
| **read_file** | Read file (size cap) |
| **list_dir** | List directory |
| **create_file** | New file in workspace |
| **edit_file** | Search/replace patch |
| **run_cmd** | Shell (blocked destructive fragments) |

---

## Ask ALFa — host actions (`src/ops/host_catalog.py`)

Admin **Ask ALFa** widget proposes these; operator **Approve** required every time.
Gated by `ALFA_AI_HOST_ACTIONS_ENABLED=0` default.

| Action | Mutating |
|--------|----------|
| docker_ps, docker_logs, disk_usage, health_check, git_status, brain_verify, hub_diag_read, ps_syntax_check | no |
| git_pull, docker_restart, brain_redeploy_api, cluster_start, cluster_stop, run_command | yes |

Details: [ADMIN_AI_HOST_ACTIONS.md](ADMIN_AI_HOST_ACTIONS.md), [AI_ACTIONS.md](AI_ACTIONS.md).

---

## MCP (Cursor session)

| Server | Tools |
|--------|-------|
| **cursor-ide-browser** | Browser navigate, snapshot, click, CDP |
| **cursor-app-control** | Move agent, create project, open automation |

---

## Related

| Doc | Purpose |
|-----|---------|
| [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) | Orchestrator start/stop |
| [GREV27_27B_OPERATOR.md](GREV27_27B_OPERATOR.md) | inference topology |
| [SOURCE_OF_TRUTH_AND_SYNC.md](SOURCE_OF_TRUTH_AND_SYNC.md) | Git per-host clone |
| [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md) | Hub-first artifacts |
