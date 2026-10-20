# Grok Bot + Ask ALFa script loop

**Status:** Binding operator loop for ALFa Reviewer / ALFa Brain and Ask ALFa.
**Oversight:** [AI_AUTONOMY_AND_OVERSIGHT.md](AI_AUTONOMY_AND_OVERSIGHT.md),
[AI_GOVERNANCE.md](AI_GOVERNANCE.md) (NIST: program executes; model judges).
**Host actions:** [ADMIN_AI_HOST_ACTIONS.md](ADMIN_AI_HOST_ACTIONS.md).
**Token policy:** [.cursor/rules/grok-bot-token-efficiency.mdc](../.cursor/rules/grok-bot-token-efficiency.mdc).
**Official Grok Bot audit of files:** [files and results](https://docs.x.ai/grok-bot/files-and-results).
**Official Ask ALFa Approve:** operator must Approve every host action (no auto-run).

Grok Bot does **not** SSH, call Ask ALFa, or run cluster scripts. It **names** a
catalog action. You Approve in Ask ALFa. The script's **exit code** is the primary
gate. Reviewer dual-checks a **truncated** excerpt you copy from the widget.

## Loop

1. Reviewer (or you) writes: `Propose <action_key> on host <nnn>`
2. Paste that line into **Ask ALFa** (admin). Deterministic router creates a pending action.
3. You **Approve** (tier-2 checkbox when the card asks).
4. Ask ALFa shows stdout and a **Copy for Grok Bot audit** excerpt (exit code + last 80 lines).
5. Paste the excerpt into **ALFa Reviewer**. It replies PASS/FAIL. Do not dump the full log.
6. On FAIL, Reviewer returns a Cursor handoff. This session (Grok 4.6 on `orchestrator`) fixes code/docs.

There is no Grok Bot connector to the brain API
([chat and collaboration](https://docs.x.ai/grok-bot/chat-and-collaboration) is Bot-to-Bot only).

## Catalog actions (read-only script verify)

Pack `script_verify` (default **on**). Prefer these over `run_command`.

| action_key | Host | Script | Notes |
|------------|------|--------|-------|
| `brain_verify` | `hub` | `scripts/brain_verify.sh` | HTTP health of brain stack. |
| `hub_diag_read` | `inference` | `scripts/diagnose-inference-ai.sh` | Read-only snapshot (allowed diagnose). Not a shard restart. |
| `ps_syntax_check` | `orchestrator` or `apps` | `Test-AlfaPowerShellScriptSyntax.ps1 -Recurse deploy` | ASCII + PS 5.1 parse. |
| `draft_judge_guide` | `orchestrator` or `hub` | `scripts/eval/run_7b_27b_guide.py` | params: `task`. 7B draft + 27B judge loop; PASS/FAIL + JSONL excerpt. See [ALFA_7B_27B_WORK_JUDGE.md](operations/ALFA_7B_27B_WORK_JUDGE.md). |

Ask ALFa examples (no LLM):

```text
Propose brain_verify on host 111
Propose hub_diag_read on host 148
Propose ps_syntax_check on host 93
Propose draft_judge_guide on host 111 with task Summarize inference health checks for docs
```

## Forbidden (Bot must not name these as a "fix")

- `keep-inference-warm.sh`, shard deploy scripts, shard RPC port probes
- `run_command` that matches the inference/RPC blocklist
- Piecemeal `docker compose` on `llamacpp-rpc-*`

Cluster lifecycle stays `cluster_start` / `cluster_stop` on `orchestrator` only.

## Grok Bot standing text (Reviewer and Brain profiles)

Paste into each Bot description:

```text
Cheap path: git pull in /workspace/alfa-ai. No browser, no re-clone, no .env, no LAN.
When work is a known script, do not run it. Return exactly:
Propose <action_key> on host <nnn>
Then stop. After the operator pastes an Ask ALFa audit excerpt, judge exit code first
(non-zero = FAIL). Dual-check PASS/FAIL lines. Max 8 leftover bullets. Cursor handoff if FAIL.
```

## Adding another script

1. Script must print `PASS`/`FAIL` (or equivalent) and **non-zero exit** on failure
   ([script-creation-standards.mdc](../.cursor/rules/script-creation-standards.mdc)).
2. Document it in [ADMIN_AI_HOST_ACTIONS.md](ADMIN_AI_HOST_ACTIONS.md) **before** code.
3. Add a **named** catalog action + `script_verify` pack membership (not freeform).
4. Keep `action_key` free of `rpc-server` / `llamacpp-rpc` / `inference` / `coordinator`
   so Ask ALFa blocklist does not treat a propose as piecemeal. The command may still
   call `diagnose-inference-ai.sh` by path.

## 7B/27B draft-judge JSONL audit

For the Path B work loop ([ALFA_7B_27B_WORK_JUDGE.md](operations/ALFA_7B_27B_WORK_JUDGE.md)),
Grok audits **offline excerpts** from `logs/draft-judge/sessions.jsonl` or the exit code of
`scripts/eval/run_7b_27b_guide.py` -- not live LiteLLM or inference inference. Paste the last N
JSONL lines (truncated; redact secrets) plus exit code into Reviewer; judge verdict progression,
27B guidance quality, final `decision`, and `project_auto_applied` / `applied_path` when the
sim-dump guardrail wrote a sandbox file. Official file handling:
[files and results](https://docs.x.ai/grok-bot/files-and-results).

## Related

- [AGENTS.md](../AGENTS.md) -- cloud clone cheap path
- [WAIT_POLL_OPERATOR.md](WAIT_POLL_OPERATOR.md) -- health wait helpers
- [CLUSTER_START_STOP_OPERATOR.md](CLUSTER_START_STOP_OPERATOR.md) -- orchestrator only
- [operations/ALFA_7B_27B_WORK_JUDGE.md](operations/ALFA_7B_27B_WORK_JUDGE.md) -- 7B draft + 27B judge loop SSoT
