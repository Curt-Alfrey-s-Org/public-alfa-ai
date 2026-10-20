# 7B draft + 27B judge work loop (Path B)

**SSoT** for the iterative draft-judge loop: 7B (`alfa-coder-draft`) drafts work;
27B (`frontier-code`) judges **and** guides revision; every role turn is appended to
JSONL for Grok audit. **Not** the sequential eval gate in
[ALFA_7B_SERVE_ALONGSIDE_27B.md](ALFA_7B_SERVE_ALONGSIDE_27B.md) (base vs adapter
scoring on `gaming-c:8470`).

**Production chat stays `frontier-code` (inference 27B).** The work-judge loop is
opt-in, default **off**, and requires 7B eval gate pass + operator LiteLLM promote
before use.

This loop does **not** switch Home Assistant loads. Dump on/off is Home Assistant
(`sim_dump_control.yaml`). Brain `solar_dump.py` / `ha_dump_tick` observe and audit
only and work with **neither** 7B nor 27B
([HOME_ASSISTANT_BRAIN_INTEGRATION.md](../HOME_ASSISTANT_BRAIN_INTEGRATION.md)
Dump vs 7B / 27B). The sim-plug allowlist is only a Path B **file-write** rail.

Official references:

- LiteLLM OpenAI-compatible `api_base`: [docs](https://docs.litellm.ai/docs/providers/openai_compatible)
- llama-server (7B standalone on `gaming-c`): [server README](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md)
- NIST oversight matrix: [AI_AUTONOMY_AND_OVERSIGHT.md](../AI_AUTONOMY_AND_OVERSIGHT.md)
- Grok Bot file audit: [files and results](https://docs.x.ai/grok-bot/files-and-results)

Related: [ALFA_7B_SERVE_ALONGSIDE_27B.md](ALFA_7B_SERVE_ALONGSIDE_27B.md),
[ALFA_CODER_DRAFT_ALIAS.md](ALFA_CODER_DRAFT_ALIAS.md),
[src/llm/draft_guide.py](../../src/llm/draft_guide.py),
[src/llm/judge.py](../../src/llm/judge.py),
[scripts/eval/run_7b_27b_guide.py](../../scripts/eval/run_7b_27b_guide.py),
[GROK_BOT_SCRIPT_LOOP.md](../GROK_BOT_SCRIPT_LOOP.md).

## Topology

```text
operator / task prompt
    -> 7B (alfa-coder-draft, gaming-c:8470 via LiteLLM)
    -> 27B (frontier-code, inference via LiteLLM)
         verdict: confirm | revise | reject
         guidance: concrete revision instructions when revise
    -> if revise: 7B receives guidance and drafts again (max 3 rounds)
    -> if confirm and sim-dump guardrail holds: write sandbox file under
         ALFA_AI_WORKSPACE_ROOT/draft-judge/applied/
    -> every role turn appended to JSONL
    -> Grok audits JSONL excerpts (truncated; no secrets)
```

| Role | Model alias | Backend | Purpose |
|------|-------------|---------|---------|
| Draft / revise | `alfa-coder-draft` | `LLAMACPP_7B_URL` -> `gaming-c:8470` | First draft and revised drafts |
| Judge + guide | `frontier-code` | LiteLLM -> inference `:31360` | confirm / revise / reject + guidance text |

**Path B judge config** (not Path A Ollama on `gaming-c:11434`):

- `ALFA_AI_JUDGE_MODEL=frontier-code` (loop **forces** LiteLLM `frontier-code` even if env still says `judge`)
- `ALFA_AI_JUDGE_API_BASE=` empty -- loop **skips** if this is set (Path A mutex)
- `LLAMACPP_7B_URL` must be set -- loop **skips** if unset so LiteLLM cannot silently
  fall back `alfa-coder-draft` -> `frontier-code` ([proxy fallbacks](https://docs.litellm.ai/docs/proxy/reliability))
- If the draft completion `model` field is a inference alias (`frontier-code` / `qwen3.6-27b` /
  `qwen3.8-27b`), the loop skips that round as a fallback ([Chat Completions `model`](https://platform.openai.com/docs/api-reference/chat/object))
- `ALFA_AI_JUDGE_ENABLED=0` until operator enables after 7B promote + smoke

Path A (`gaming-c` Ollama 14B) mutexes with 7B serve on the same GPU -- do **not** use
for this loop. See [JUDGE_INSTALL_59.md](JUDGE_INSTALL_59.md).

**Forbidden:** llama.cpp speculative decoding (`-md`) between 7B and 27B (vocab mismatch).
See [ALFA_7B_SERVE_ALONGSIDE_27B.md](ALFA_7B_SERVE_ALONGSIDE_27B.md).

## Oversight (NIST / SRE)

**Operator 2026-09-15:** 7B and 27B have **full control of this project's sandbox**
after 27B **confirms**. The **guardrail is simulated dump loads**
(`switch.sim_ac_plug_*` only on `ha_switch_allowlist`, Home Assistant ready). See
[HOME_ASSISTANT_BRAIN_INTEGRATION.md](../HOME_ASSISTANT_BRAIN_INTEGRATION.md)
and `path_b_sim_dump_guardrail()` in [solar_dump.py](../../src/ops/solar_dump.py).
This is **L3 bounded project write**, not L4 cluster / SSH.

| Rule | Value |
|------|-------|
| Autonomy | L3 project files on 27B `confirm` when sim-dump guardrail holds |
| Host / cluster / secrets | **Never** from this loop. `safe_to_auto_apply` stays `false` |
| Energy rail | HA ready + live `ha_switch_allowlist` (AI Config / `AiSettingStore` when `DATABASE_URL` is set) is **only** `switch.sim_ac_plug_*`. Real house plugs pause auto-write |
| Applied files | `{ALFA_AI_WORKSPACE_ROOT}/draft-judge/applied/{session_id}.md` (sanitized) |
| Kill switch | `ALFA_AI_JUDGE_ENABLED=0` (default); also HA off or non-sim allowlist |
| Human gate | Operator enables Path B; no silent routing of production chat to 7B |
| Catalog `draft_judge_guide` | Still **Approve** (SSH script_verify). Autonomous path is in-process Ask ALFa |
| Audit | `logs/draft-judge/sessions.jsonl` (runtime, gitignored) plus applied markdown |

## Session log (JSONL)

**Path (ASCII):** `logs/draft-judge/sessions.jsonl`

Runtime only -- not committed. Create the directory once on the host that runs the loop
(brain API container or operator workstation):

```bash
mkdir -p logs/draft-judge
```

Ignored in repo root (`.gitignore`: `logs/draft-judge/` and `draft-judge/applied/`).

Each line is one JSON object. Append **every** role turn in order:

| Field | Required | Description |
|-------|----------|-------------|
| `utc` | yes | ISO-8601 UTC timestamp |
| `session_id` | yes | Stable id for one operator task |
| `round` | yes | 1-based round index (max 3) |
| `role` | yes | `7b_draft` \| `27b_judge` \| `7b_revise` \| `decision` |
| `model` | yes | LiteLLM alias used (`alfa-coder-draft`, `frontier-code`) |
| `verdict` | when judge | `confirm` \| `revise` \| `reject` |
| `guidance` | when revise | 27B revision instructions passed to 7B |
| `text` | yes | Truncated content (~8k chars max per field) |
| `decision` | on `decision` role | Final outcome summary (`confirmed`, `rejected`, `max_rounds`) |

**Never log:** API keys, bearer tokens, `.env` values, SSH private keys, or other LAN secrets.
Redact or omit host credentials; internal LAN IPs in operator-only logs are acceptable when
the excerpt stays on /LAN.

Example (single line, pretty-printed for reading):

```json
{
  "utc": "2026-09-15T19:00:00Z",
  "session_id": "task-abc123",
  "round": 1,
  "role": "27b_judge",
  "model": "frontier-code",
  "verdict": "revise",
  "guidance": "Add error handling for empty input; cite the official FastAPI docs URL.",
  "text": "... truncated draft excerpt ..."
}
```

## Loop behavior

1. **Draft** -- 7B produces initial work from the operator task.
2. **Judge** -- 27B returns structured verdict via existing judge schema
   (`confirm` / `revise` / `reject`) plus guidance when `revise`.
3. **Revise** -- if `revise` and `round < 3`, 7B drafts again with guidance in context.
4. **Decision** -- on `confirm` or `reject`, or after round 3, append a `decision` record.
5. **Return** -- final text (or rejection reason) to the caller; no auto-apply of file/host mutate.

Implementation: [src/llm/draft_guide.py](../../src/llm/draft_guide.py) (loop + JSONL append)
and [scripts/eval/run_7b_27b_guide.py](../../scripts/eval/run_7b_27b_guide.py) (CLI).
This doc is authoritative for fields and topology; code must match.

## Operator enablement (default OFF)

Prerequisites (all required before enabling the work-judge loop):

1. 7B QLoRA eval gate passed (`promote_allowed=true` in sequential eval SSoT).
2. Operator promoted `LLAMACPP_7B_URL` and LiteLLM lists `alfa-coder-draft`.
3. inference `frontier-code` healthy (`:31360/health`).
4. Smoke: one manual draft + judge round via eval script or Ask ALFa path.

## Ask ALFa (admin only, default OFF)

Normal Ask ALFa chat stays on `frontier-code` (inference 27B). Path B is **opt-in**
via an explicit message prefix so production chat is unchanged.

| Rule | Value |
|------|-------|
| Prefix | `draft-judge:` (case-insensitive); strip before calling the loop |
| Gate | `ALFA_AI_JUDGE_ENABLED=1` **and** `research` in `ALFA_AI_JUDGE_ON` |
| Surface | Reply includes `verdict`, last-round `guidance`, `log_path`, `project_auto_applied`, `applied_path`, `safe_to_auto_apply=false` (host mutate) |
| Skip | When disabled or 7B/judge unavailable: `skip_reason` in reply; no crash |
| Host actions | Does **not** replace catalog `propose` / `run_command` paths (no prefix = unchanged) |
| Event loop | Prefix path runs `try_handle_deterministic` via `asyncio.to_thread` so LiteLLM rounds do not block FastAPI ([concurrency](https://fastapi.tiangolo.com/async/), [`asyncio.to_thread`](https://docs.python.org/3/library/asyncio-task.html#asyncio.to_thread)) |
| Durable JSONL | Prefer catalog `draft_judge_guide` or CLI on `orchestrator`/`hub` (repo `logs/draft-judge/`). In-container Ask ALFa writes `/app/logs/draft-judge/` (not hub `agent-audit-logs`, which is `:ro`) |

Example (admin Ask ALFa chat):

```text
draft-judge: Summarize how inference coordinator health is verified after cluster start.
```

Implementation: [src/api/ask_alfa_router.py](../../src/api/ask_alfa_router.py)
(`parse_draft_judge_task` + `run_draft_guide_loop`). Guest chat never exposes this path.
The admin routes offload this prefix with `asyncio.to_thread` ([src/api/routers/admin.py](../../src/api/routers/admin.py)).

Then on `hub` `deploy/.env` (operator-owned, not committed):

```env
LLAMACPP_7B_URL=http://orchestrator/v1
ALFA_AI_JUDGE_ENABLED=1
ALFA_AI_JUDGE_MODEL=frontier-code
# ALFA_AI_JUDGE_API_BASE=   # leave unset for LiteLLM Path B
```

Recreate brain/LiteLLM per [ALFA_CODER_DRAFT_ALIAS.md](ALFA_CODER_DRAFT_ALIAS.md).
Do **not** enable during sequential eval or before promote.

## CLI

Run one work-judge loop from the repo root (requires `src/llm/draft_guide.py` and
Path B env on the host that calls LiteLLM):

```bash
python scripts/eval/run_7b_27b_guide.py --task "Your operator task prompt here"
```

### Ask ALFa catalog action (script verify)

Prefer the named catalog action over `run_command` ([GROK_BOT_SCRIPT_LOOP.md](../GROK_BOT_SCRIPT_LOOP.md)):

| action_key | Hosts | params |
|------------|-------|--------|
| `draft_judge_guide` | `orchestrator`, `hub` | `task` (required; full text shown on Approve card) |

Deterministic propose (operator pastes into Ask ALFa):

```text
Propose draft_judge_guide on host 111 with task Summarize inference health checks for docs
```

Or with explicit params in the agent tool. **Approve** runs
`python scripts/eval/run_7b_27b_guide.py --task '<task>'` via SSH on the chosen host.
The Approve result includes `bot_audit_excerpt` (exit code + last 80 stdout lines) for
ALFa Reviewer. This does **not** flip `ALFA_AI_JUDGE_ENABLED`; the script still requires
Path B env on the target host or it exits FAIL with judge skipped/disabled.

| Flag | Default | Purpose |
|------|---------|---------|
| `--task` | (required) | Task prompt for the 7B draft |
| `--max-rounds` | `3` | Max revise rounds (matches loop cap) |
| `--log` | `logs/draft-judge/sessions.jsonl` | Session JSONL append path |

The script prints `PASS/FAIL` (PASS only on judge `confirm`; FAIL on skipped/disabled
judge, `reject`, `revise` without confirm, or exception), then `GROK_AUDIT_EXCERPT`
(last ~40 JSONL lines, secrets redacted). Exit code `0` on PASS, non-zero on FAIL.

## Grok audit

Grok Bot does **not** call LiteLLM or read live cluster inference. Audit **offline**:

1. Run `python scripts/eval/run_7b_27b_guide.py` or complete a manual loop session.
2. Paste the script **exit code** and the **last N lines** of `logs/draft-judge/sessions.jsonl`
   into ALFa Reviewer (truncate; no secrets).
3. Reviewer checks: verdict progression, guidance quality, `decision` outcome, no credential leaks.

Official Grok file handling: [files and results](https://docs.x.ai/grok-bot/files-and-results).

See [GROK_BOT_SCRIPT_LOOP.md](../GROK_BOT_SCRIPT_LOOP.md).

## What this is not

| Not this | SSoT instead |
|----------|----------------|
| Sequential 7B base vs adapter eval | [ALFA_7B_SERVE_ALONGSIDE_27B.md](ALFA_7B_SERVE_ALONGSIDE_27B.md) |
| Trainer / QLoRA GUI | [TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md) |
| Path A Ollama judge on `gaming-c` | [JUDGE_INSTALL_59.md](JUDGE_INSTALL_59.md) |
| Scheduled audit judge JSONL | [SCHEDULED_AUDIT_MISSIONS.md](SCHEDULED_AUDIT_MISSIONS.md) (`agent-audit-logs/judged.jsonl`) |
