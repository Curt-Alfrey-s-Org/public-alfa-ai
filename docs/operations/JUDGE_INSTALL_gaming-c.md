# OP-LL-1 — Install independent judge model on `gaming-c` (gaming-worker-c)

Learning-loop **L1**. Dual-checks 27B narratives and freeform `run_command` proposals.
**Never auto-approves** mutate. Default: `ALFA_AI_JUDGE_ENABLED=0`.

SSoT: [.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md](../../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md) § L1.

## Candidates (pick one)

| ID | Model | Notes |
|----|-------|-------|
| **J1a (recommended)** | DeepSeek-R1-Distill-Qwen-14B (Q4 / Ollama tag e.g. `deepseek-r1:14b`) | Reasoning independence |
| **J1b** | Qwen2.5-Coder-14B or Qwen3 coder 14B Q4 | Code critique |

Host: **`gaming-c` RTX 5070 12 GB**. Do not train, 7B serve (`:8470`), and Ollama judge on the
same GPU at once. See [ALFA_7B_SERVE_ALONGSIDE_27B.md](ALFA_7B_SERVE_ALONGSIDE_27B.md)
for **7B draft + 27B judge** via LiteLLM (`ALFA_AI_JUDGE_MODEL=frontier-code`, empty
`ALFA_AI_JUDGE_API_BASE`) instead of Ollama on `gaming-c`.

## Hub-first

Pull GGUF / Ollama blobs via existing hub / aria2 policy — do not invent multi-GB public download paths outside [HUB_ARTIFACTS.md](../HUB_ARTIFACTS.md).

## Install sketch (Ollama on `gaming-c`)

```powershell
# On gaming-c when idle (operator)
ollama pull deepseek-r1:14b
# OpenAI-compatible API typically :11434
curl http://127.0.0.1:11434/v1/models
```

Firewall: allow brain `hub` → `gaming-c:11434` on LAN only if not already open.

## Brain env (`hub` deploy/.env)

```env
ALFA_AI_JUDGE_ENABLED=0
ALFA_AI_JUDGE_MODEL=judge
ALFA_AI_JUDGE_API_BASE=http://orchestrator/v1
ALFA_AI_JUDGE_API_KEY=ollama
ALFA_AI_JUDGE_REMOTE_MODEL=deepseek-r1:14b
ALFA_AI_JUDGE_ON=high_risk,research,merge,freeform,run_command
```

Recreate `alfa-ai-api` after env change. Enable only after smoke:

```env
ALFA_AI_JUDGE_ENABLED=1
```

## Smoke

1. From brain network: `curl -sS "$ALFA_AI_JUDGE_API_BASE/models"` (or Ollama tags).
2. With judge enabled, propose freeform `run_command` via Ask ALFa — response should include `Judge: confirm|revise|reject` and proposal.judge JSON; **Approve still required**.
3. Unit parse: `pytest tests/test_judge.py -q`.

## Calibration (OP-LL-2)

Label 20 samples in `eval/judge-calibration.jsonl` (good/bad freeform or research claims). Track agreement later; not required for install smoke.

## Explicit non-goals

- Judge on every tool call.
- Using production 27B as the only judge (correlated blind spots).
- Auto-approve host actions on `verdict=confirm`.
