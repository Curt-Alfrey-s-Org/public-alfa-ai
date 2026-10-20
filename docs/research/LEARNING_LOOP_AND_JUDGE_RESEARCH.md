# Closing the ALFa learning loop — research synthesis

**Date:** 2026-07-11  
**Status:** Research complete → **implementation SSoT** is the plan below  
**Implementation plan (SSoT):** [`.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md`](../../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md)  
**Roadmap:** [docs/ROADMAP.md](../ROADMAP.md) Priority **#7**; master plan Program Wave **I**  
**Scope:** Multi-agent missions (audit → research → error catalogs → corrective actions), **judge** dual-check of **Qwen3.6-27B**, and **sleep-hour learning** on existing hardware (trainer island — `gaming-c` / `gaming-b`, optional `gaming-a`; `inference` stays on 27B core).

---

## 1. What you already have (baseline)

| Layer | Today | Evidence |
|-------|--------|----------|
| **Producer (code/agents)** | Qwen3.6-27B `frontier-code` via inference RPC | [GREV27_27B_OPERATOR.md](../GREV27_27B_OPERATOR.md), `ALFA_AI_AGENT_MODEL` |
| **Agent loop + tools** | JSON-in-text tools; grep/read/edit/fetch/web_search | [AGENT_RESEARCH_TOOLS.md](../AGENT_RESEARCH_TOOLS.md), `src/agent/loop.py` |
| **Skills** | `audit-repo`, `implement`, `review`, `check-work`, `senior-auditor` | `skills/*/SKILL.md` |
| **Mission memory** | Append-only `$ALFA_AI_DATA/implement-memory/*.md` | AGENT_RESEARCH_TOOLS § memory |
| **Eval design** | Role suites + gates documented; not fully wired as nightly job | [EVALUATION_FRAMEWORK.md](../EVALUATION_FRAMEWORK.md) |
| **Verifier stub** | `check-work` → `VERDICT: PASS/FAIL`; incident `copy_for_verifier` | skills + `src/incident/analyze.py` |
| **Human Measure** | Thumbs on host actions / proposals | [AI_ACTIONS.md](../AI_ACTIONS.md), AI_GOVERNANCE Measure |
| **Training island** | `alfa-train` QLoRA on `gaming-c`+`gaming-b` (optional `gaming-a`); `inference` stays on 27B core | [alfa-train ROADMAP](../../../alfa-train/docs/ROADMAP.md) |
| **Planned workflow** | implement→review→fix; WorkflowRunner Phase 2 | [AGENT_PLATFORM_GROK_ALIGNMENT.md](../../.cursor/plans/AGENT_PLATFORM_GROK_ALIGNMENT.md) |

**Gap:** There is no closed loop that (1) systematically runs audit/research fleets, (2) dual-checks 27B with an independent judge model, (3) turns failures + human feedback into durable memory *and* optional weight updates during idle hours.

---

## 2. Target learning loop (product shape)

```text
┌─────────────────────────────────────────────────────────────────────┐
│ DAY (always-on inference: orchestrator / apps / hub / inference / pool-opt-in)             │
│  Operator or scheduler → mission queue                               │
│    Auditor (read-only repos) ──► findings.md                         │
│    Researcher (repo + SearXNG + allowlist docs) ──► research.md      │
│    Error cataloger (CI/logs/incidents) ──► errors.jsonl              │
│    Analyst ──► corrective_actions.md (human-gated apply)             │
│    Coder (gated) ──► patch; Check-work (tests + skill)               │
│    Judge (independent model) ──► dual-check subjective claims        │
│  Store: artifacts + tool traces + feedback + human feedback          │
└───────────────────────────────┬─────────────────────────────────────┘
                                │ nightly export
┌───────────────────────────────▼─────────────────────────────────────┐
│ SLEEP (idle windows)                                                 │
│  A. Memory sleep (no weight train) — consolidate implement-memory,   │
│     distill error patterns, pre-research queued topics               │
│  B. Preference pack — (prompt, chosen, rejected) from thumbs + tests │
│  C. Optional QLoRA on trainer island (full Blackwell or gaming subset) when free       │
│  D. Morning eval gate — promote adapter/memory only if metrics hold  │
└─────────────────────────────────────────────────────────────────────┘
```

This matches industry practice: **harness + telemetry + eval first**, then **sleep-time memory**, then **PEFT on top of frozen base** — not “train a new foundation model.”

### Design principles (from research + your rules)

1. **Execution beats LLM opinion for code.** Pytest / lint / typecheck / docker health are the primary judges; LLM judges only score *subjective* quality (clarity, risk, completeness).
2. **Separate generate from judge.** Same-model re-prompt correlates errors; use a different family/size or a specialized judge.
3. **Binary / rubric scores, not 1–10.** Calibrate judges against a small human-labeled set.
4. **Human gate on write/mutate** until eval gates are green (NIST/SRE progressive autonomy you already track).
5. **Hub-first artifacts** for datasets, adapters, GGUF; gaming hosts are intermittent.
6. **No automatic public scraping** — scheduled research still uses allowlisted `fetch_url` + gated SearXNG, operator-owned cron.

---

## 3. Agent fleet — roles and first missions

Build as **skills + scheduled `POST /api/runs`**, not a new product surface. Reuse Pattern C (orchestrator) and keep Pattern A consumers (contracts-bot) as LiteLLM-only.

| Agent / skill | Purpose | Tools / inputs | Output artifact | Autonomy |
|---------------|---------|----------------|-----------------|----------|
| **repo-auditor** | Simple error checking of host repos | `ALFA_AI_AUDIT_ROOTS`, grep, pytest discovery | `audit-report.md` (severity, file:line) | Read-only always |
| **project-analyst** | Architecture / feature gaps | repo tools + memory | `analysis.md` | Read-only |
| **best-practice-researcher** | Online research for features & practices | `web_search` + allowlisted `fetch_url` | `research.md` + Sources | Read-only; no auto-scrape |
| **error-cataloger** | Lists errors from CI, logs, incidents, failed runs | Prometheus snippets, incident store, pytest JUnit, mission traces | `errors.jsonl` (stable schema) | Read-only |
| **corrective-analyst** | Clusters errors → ordered corrective actions | catalog + docs | `corrective_actions.md` | Propose only |
| **implementer** | Apply approved actions | edit_file, run_cmd (gated) | patch + summary | Human approve |
| **check-work** | Deterministic + skill verify | pytest/lint + `VERDICT` | pass/fail + evidence | Auto after implement |
| **judge** | Dual-check 27B narrative / risky proposals | structured rubric prompt | `judge.json` | Never auto-approve mutate |
| **sleep-curator** | Nightly memory consolidation | implement-memory, feedback, error catalog | compacted memory + lessons | Write memory only |

### Error list schema (recommended)

```json
{
  "id": "uuid",
  "source": "pytest|incident|mission|lint|operator",
  "repo": "alfa-ai",
  "severity": "critical|high|medium|low",
  "summary": "…",
  "evidence": ["path or command snippet"],
  "first_seen": "ISO-8601",
  "count": 1,
  "fingerprint": "stable-hash-of-normalized-message",
  "proposed_action_id": null
}
```

Analyst groups by `fingerprint`, ranks by severity×count, emits corrective actions with **acceptance criteria** (test to re-run). Aligns with ErrorProbe-style “symptom → attribution → verified patch pattern” without adopting a full research framework day one.

### Suggested mission pack (v1 queue)

1. **Nightly:** `research_only` audit of `alfa-ai` + one bot repo (rotate).  
2. **Nightly:** error-cataloger over last 24h failed missions + open incidents.  
3. **Weekly:** best-practice researcher (e.g. “LiteLLM virtual keys production”, “llama.cpp parallel slots”) → compare to code.  
4. **On demand:** implement→review→check-work on a single approved corrective action.  
5. **Always:** judge only on high-blast proposals (host commands, security findings, merge-ready patches).

---

## 4. Judge model — research findings and install candidates

### 4.1 What “double-check 27B” should mean

| Check type | Best judge | Why |
|------------|------------|-----|
| Code correctness | **Tests / linters / typecheck** | Objective; specialized LLM judges still weak vs execution |
| Structured JSON / schema | Schema validator + small model | Cheap, high accuracy |
| Hallucinated facts / missing evidence | **Independent LLM judge** + citation rules | Subjective / open-ended |
| Risky ops / host actions | Human + optional LLM second pass | Already planned “freeform-only LLM judge, never auto-approve” |
| Research quality | Rubric (sources, assumptions, decision clarity) | Matches EVALUATION_FRAMEWORK researcher suite |

**Do not** replace `check-work` with an LLM judge. **Do** add an LLM judge *after* tools when the output is a narrative claim or a freeform command proposal.

### 4.2 Independence over raw size

Research consensus (LLM-as-judge surveys, 2025–2026 practice):

- Stronger is not always better; **task-calibrated** judges and **rubrics** matter more.
- Same model as generator (27B judging 27B) is a weak control (shared blind spots).
- **Different architecture or family** (e.g. MoE vs dense, or R1-distill vs coder) improves independence.
- Specialized small evaluators (3B–8B class) often beat huge general judges on *objective* checks; for *subjective* review, mid-size reasoning/code models are fine.

### 4.3 Install candidates (homelab-fit)

Production **27B** already occupies inference. A judge should live **off that path** so day-time agent latency is not destroyed.

| Priority | Model (examples) | Fits where | Role | Notes |
|----------|------------------|------------|------|-------|
| **J0 (now, zero install)** | Same stack: `check-work` + pytest | inference | Hard gates | Ship first |
| **J1 (recommended first install)** | **DeepSeek-R1-Distill-Qwen-14B** Q4_K | **`gaming-c` 12 GB** (Ollama or llama.cpp) | Reasoning dual-check | Distinct training lineage; ~8–10 GB Q4; MIT-friendly distill class |
| **J1b** | **Qwen2.5-Coder-14B-Instruct** or current **Qwen3-*-14B** coder Q4 | `gaming-c` / `gaming-b` 12 GB | Code review judge | Strong code critique; same vendor as 27B but different size/checkpoint |
| **J2 (reuse existing alias)** | **35B-A3B MoE** (`agent` fallback path) | When inference **stopped** and MoE pool up | Night batch judge | Already in LiteLLM story; **mutually exclusive** with 27B on shared GPUs — use for sleep batch, not concurrent dual-check |
| **J3 (later)** | 7B QLoRA **judge adapter** trained on your labeled prefs | trainer pool → hub GGUF/adapter | Domain-calibrated judge | alfa-train Phase 6–7; promote only after eval |
| **J4 (HW unlock)** | Dense ~70–72B as future `frontier` | expanded RPC | Strong general judge | Matches your roadmap “frontier reserved for dense 70–72B” |

**Not recommended as first judge:** 70B+/480B open models — wrong VRAM for intermittent gaming hosts and hub policy.

### 4.4 Wire-in design (LiteLLM)

```yaml
# Conceptual — deploy/litellm_config.yaml style
model_list:
  - model_name: judge
    litellm_params:
      model: openai/<backend>   # e.g. ollama/deepseek-r1-distill-qwen-14b on gaming-c
      api_base: http://orchestrator/v1
```

Env (proposed):

| Env | Default | Purpose |
|-----|---------|---------|
| `ALFA_AI_JUDGE_MODEL` | `judge` | LiteLLM alias |
| `ALFA_AI_JUDGE_ENABLED` | `0` | Fail closed |
| `ALFA_AI_JUDGE_ON` | `high_risk,research,merge` | When to call |
| `ALFA_AI_JUDGE_MAX_TOKENS` | `1024` | Rubric JSON only |

**Judge response contract (JSON only):**

```json
{
  "verdict": "confirm|revise|reject",
  "confidence": "high|medium|low",
  "issues": [{"severity": "high", "claim": "…", "reason": "…"}],
  "missing_evidence": ["…"],
  "safe_to_auto_apply": false
}
```

`safe_to_auto_apply` must remain **false** for host mutate paths until explicit policy change.

### 4.5 Where to install J1 (operator steps — draft)

1. On **`gaming-c`** when idle (not training): install/verify Ollama or llama.cpp server (member README pattern).  
2. Hub-first: pull GGUF/blob via existing aria2/hub paths — do not invent multi-GB download locations outside hub policy.  
3. Smoke: structured rubric on 20 frozen samples (half good / half bad human labels).  
4. Register LiteLLM `judge` alias from brain `.env` / config.  
5. Hook: after researcher final report and after freeform host-command proposal only.  
6. Log `ai_actions` type `judge_verdict` for Measure.

---

## 5. Sleep-hour learning — three tiers

Industry framing: **continual learning needs a sleep phase** (consolidate experience offline to avoid catastrophic forgetting). Two complementary lines:

1. **Sleep-time compute** (Letta / MemGPT line): refine *memory and context* offline without weight updates; amortize “thinking” before the next query.  
2. **PEFT sleep jobs** (LoRA/QLoRA on open weights): update a small overlay on a frozen base from curated day data.

Your constraint (“not training my own model yet unless on top of what we already run”) maps cleanly to **Tier A now**, **Tier B on trainer island**, **never full pretrain**.

### Tier A — Sleep-time memory (no weight training) — **start here**

| Job | Host | Action |
|-----|------|--------|
| Memory curator | inference idle or `hub` CPU | Compact `implement-memory`; drop noise; extract “lessons” blocks |
| Error rollup | brain worker | Merge `errors.jsonl`; promote recurring fingerprints |
| Preference export | `hub` hub | Write day’s thumbs + test outcomes to hub JSONL |
| Research queue drain | inference | Process operator-queued research goals only |
| Eval smoke | inference | Run small gold suite from EVALUATION_FRAMEWORK |

**Success metric:** next-day missions cite better memory; fewer repeated mistakes; zero weight risk.

This is the homelab equivalent of Letta sleep-time agents: **background reorganization of learned context**, not a new base model.

### Tier B — QLoRA / preference on trainer island (full Blackwell or gaming subset)

**Full pool:** `gaming-c` / `gaming-b` / `gaming-a` / `inference` GPU 0 (**40 GB**) — requires full cluster stop.  
**Gaming subset:** `gaming-c` / `gaming-b` / `gaming-a` (**32 GB**) — inference can stay up.

Aligns with existing **alfa-train** Stage I:

| Sleep window | Job | Config path |
|--------------|-----|-------------|
| Bootstrap evening | 3B QLoRA smoke | `example-qlora-code-sft.yaml` on `gaming-c` only |
| Multi-night | 7B QLoRA SFT on *your* code + docs | `pool-7b-qlora-sft.yaml` |
| After preference data exists | DPO/ORPO on (chosen, rejected) | TRL / Axolotl preference section |
| Optional | CPT on raw repo text | `pool-7b-cpt.yaml` |

**What you train (overlays, not “new foundation”):**

- **7B domain helper** (`alfa-coder-v1` working name) for fast local edits / drafts.  
- **Judge adapter** (later) on labeled dual-check disagreements.  
- **Not first:** full retrain of production 27B GGUF on inference (high risk, heavy export path).

**Promotion rule (alfa-train already targets this):** checkpoint beats base on ≥70% of `eval/prompts.jsonl` before any LiteLLM route points at it.

**Scheduling reality:** gaming hosts are intermittent — sleep jobs must be **idempotent, hub-checkpointed, interruptible** (NCCL resume / max steps per night).

**Adaptive learning (7B GUI — continued QLoRA):** When the operator adds fleet code,
rebuild the **full** multi-repo JSONL (not git diffs), then **Start 7B** continues the
existing v2 LoRA via Axolotl `lora_model_dir` (`--lora-model-dir` from Start — not
`auto_resume_from_checkpoints`, which is mid-run crash resume). This is continued QLoRA
on the frozen 7B base with full corpus replay; operator-facing name **adaptive learning**.
See [TRAIN_7B_QLORA_GUI.md](../operations/TRAIN_7B_QLORA_GUI.md) and
[MULTI_REPO_CORPUS_OPERATOR.md](../operations/MULTI_REPO_CORPUS_OPERATOR.md).

### Tier C — Full SFT / larger models

Already in alfa-train Phase 3 track B and Phase 7 — only after A/B eval and operator time. Still not “from scratch.”

### What not to do

| Anti-pattern | Why |
|--------------|-----|
| Online RL on production 27B during day traffic | Stability, KV, inference load |
| Uncurated “train on all chat logs” | Secrets, noise, catastrophic forgetting |
| Self-training on unfiltered model outputs | Model collapse |
| Judge auto-approving host actions | Governance violation |
| Concurrent train + inference on same gaming GPU after Stage II | Contention; stop inference first |

---

## 6. Closing the loop — data plane

```text
Day traces ──► Postgres (runs, artifacts, ai_actions, feedback)
            ──► implement-memory (Tier A)
            ──► hub JSONL preference packs (Tier B input)
                    │
                    ▼
            alfa-train QLoRA / DPO  ──► hub checkpoints
                    │
                    ▼
            morning eval gate ──► promote LiteLLM alias OR discard
```

| Dataset | Source | Used for |
|---------|--------|----------|
| Code SFT | `repo_to_jsonl.py` owned repos | Tier B SFT |
| Ops chat SFT | docs + rules + approved answers | Chat alignment |
| Preference | thumbs up/down, judge confirm vs reject, test pass/fail pairs | DPO |
| Error patterns | catalog fingerprints + successful fixes | Memory lessons + SFT “fix” examples |

Reuse [OWN_REPOS_DATASET.md](../../../alfa-train/docs/OWN_REPOS_DATASET.md) and secret scan gates.

---

## 7. Phased roadmap (recommended)

### Phase L0 — Wire the harness (1–2 weeks, no new models)

1. Finish **WorkflowRunner** implement→review→check-work (AGENT_PLATFORM Phase 2).  
2. Structured **error catalog** exporter from failed runs + incidents.  
3. **Scheduled read-only missions** (cron on brain / operator console queue) for audit rotation.  
4. Expand **EVALUATION_FRAMEWORK** into a runnable nightly script (even 10 gold tasks).  
5. Log human feedback into exportable JSONL.

**Exit:** You can produce error lists + corrective action memos without new GPUs.

### Phase L1 — Judge install (when `gaming-c` free)

1. Deploy **J1** 14B distill or coder on `gaming-c`.  
2. LiteLLM `judge` alias + env kill switch.  
3. Dual-check path for research finals + freeform host commands (never auto-approve).  
4. 20-example human calibration set; track agreement rate.

**Exit:** `judge_verdict` appears in audit trail; agreement ≥ human baseline on calibration set.

### Phase L2 — Sleep Tier A automation

1. `sleep-curator` skill + nightly job.  
2. Preference pack exporter to hub.  
3. Research queue drain (operator-queued only).

**Exit:** Memory files stay bounded and useful; morning digest of “what we learned.”

### Phase L3 — Sleep Tier B (trainer island)

1. alfa-train Phase 0–1 complete (dataset + 3B bootstrap).  
2. Nightly/weekend 7B QLoRA when full Blackwell pool or gaming subset online.  
3. Eval gate + optional internal alias `alfa-coder-draft` (not production default).

**Exit:** Measurable win rate vs base 7B on your prompts; production 27B unchanged.

### Phase L4 — Optional judge adapter + progressive autonomy

1. Train judge LoRA from disagreements.  
2. Raise autonomy only where gates pass (lint/test + judge confirm + human for mutate).  
3. Opportunistic gaming-host boost only when not training (FOUR_HOST plan §9).

---

## 8. Mapping to your hosts

| Host | Day role | Sleep role |
|------|----------|------------|
| **`hub` brain** | API, LiteLLM, queue, Postgres/Redis | Export datasets; schedule jobs; hub checkpoints |
| **inference (inference/orchestrator/pool-opt-in/hub GPU)** | 27B producer agents | Idle: Tier A curator / eval smoke (keep-warm aware) |
| **`gaming-c` gaming-worker-c 12 GB** | Optional **judge J1** when not training | Train rank 0 coordinator |
| **`gaming-b` gaming-worker-b 12 GB** | Optional second judge / embed | Train rank 1 |
| **`gaming-a` gaming-worker-a 8 GB** | Light Ollama only if needed | Train rank 2 (smaller shard) |
| **`apps`** | Edge / git author | No heavy train |

---

## 9. Open decisions (operator)

1. **Judge first install:** R1-distill-14B vs Qwen coder-14B on `gaming-c`?  
2. **Sleep train priority:** domain **7B coder** first, or **preference/judge** data first? (Recommend: memory L2 + data pipeline, then 7B SFT.)  
3. **Should 35B MoE batch-judge at night** (pool switch) vs dedicated `gaming-c` 14B always-on when PC awake?  
4. **Which repos in first audit rotation?** (Suggest: alfa-ai, contracts-bot, rankings-bot.)

---

## 10. Sources (research + internal)

### External (primary themes)

- LLM-as-a-judge survey / practice: [Awesome-LLM-as-a-judge](https://github.com/llm-as-a-judge/Awesome-LLM-as-a-judge), [Evidently guide](https://www.evidentlyai.com/llm-guide/llm-as-a-judge), [DeepEval 2026](https://deepeval.com/blog/llm-as-a-judge)  
- Specialized small evaluators vs giant judges (objective tasks): industry eval platform comparisons (e.g. Luna-class 3B–8B evaluators)  
- Sleep-time compute: [Letta sleep-time compute](https://www.letta.com/blog/sleep-time-compute/), [arXiv:2504.13171](https://arxiv.org/abs/2504.13171), [continual learning in token space](https://www.letta.com/blog/continual-learning/)  
- Continual learning / sleep for LLMs: Turing Post “AI models need sleep”, PEFT/LoRA overlays for incremental update  
- Self-improving coding agents: harness + traces + eval (Arize, Anthropic long-running harness notes; implement→review→fix patterns)  
- Multi-agent failure attribution: ErrorProbe-style pipelines (taxonomy → backward trace → verified memory)  
- Training efficiency: TRL SFT, PEFT LoRA, Axolotl multi-node (already in alfa-train research notes)

### Internal SSoT

- [AGENT_PLATFORM_GROK_ALIGNMENT.md](../../.cursor/plans/AGENT_PLATFORM_GROK_ALIGNMENT.md)  
- [AGENT_RESEARCH_TOOLS.md](../AGENT_RESEARCH_TOOLS.md)  
- [EVALUATION_FRAMEWORK.md](../EVALUATION_FRAMEWORK.md)  
- [AI_GOVERNANCE.md](../AI_GOVERNANCE.md) / [AI_ACTIONS.md](../AI_ACTIONS.md)  
- [GREV27_27B_OPERATOR.md](../GREV27_27B_OPERATOR.md)  
- [alfa-train ROADMAP / TRAINING_PATHS](../../../alfa-train/docs/ROADMAP.md)

---

## 11. Executive recommendation

| Priority | Do this | Avoid |
|----------|---------|--------|
| **1** | Close the **agent harness**: audit / error catalog / corrective actions / check-work loops on 27B | Waiting for a bigger model before any loop |
| **2** | Treat **tests + `check-work`** as primary judge; add **independent 14B judge on `gaming-c`** for narratives and freeform ops | 27B self-judging only |
| **3** | **Sleep Tier A** (memory + preference export) every night on always-on brain/pool | Uncurated weight updates on production GGUF |
| **4** | **Sleep Tier B** QLoRA on trainer island (full Blackwell or gaming subset) using alfa-train when PCs free — **adapters on top of open bases you already plan to run** | Full pretrain / public weight upload |
| **5** | Morning **eval gate** before any alias promotion | Silent model swaps |

**Bottom line:** Closing the learning loop is mostly **orchestration + telemetry + sleep memory**, with **optional QLoRA overlays on the trainer island**. The “new judge model” to install first is a **14B-class independent scorer on `gaming-c`**, not a replacement for inference 27B.
