# Archived: pre-Qwen3 Ollama tier sizing tables (historical)

**Inactive.** Current tiers: [QWEN3_MIGRATION.md](../QWEN3_MIGRATION.md) and
[ROADMAP.md](../ROADMAP.md) § Model tier plan.

These tables recorded quantization choices for **older** Ollama tags on `hub`
before tier 2 moved to **`qwen3-coder:30b-a3b`** on **`gaming-b`**.

---

## Tier 1 — inline (on `hub`, 3060 12 GB) — historical

| Candidate | Size (Q) | Fits in 12 GB VRAM? | Expected tok/s | Quality vs baseline |
|-----------|----------|---------------------|----------------|---------------------|
| `qwen2.5-coder:14b-q5_K_M` (baseline) | 10.5 GB | yes, fully | 40–50 | baseline |
| **`qwen2.5-coder:14b-q8_0`** (recommended) | 15.0 GB | no — ~3 GB spill, but to fast DDR5 | **25–35** | **+~3% on HumanEval / MBPP**, negligible hallucination drop |
| `qwen2.5-coder:14b-fp16` | 28 GB | heavy spill | 10–15 | marginal over Q8 (< 0.5%) |

## Tier 2 — agent (on `hub`, 3060 12 GB + 7900X + DDR5) — historical

| Candidate | Size (Q) | VRAM / CPU spill | Expected tok/s | Quality vs baseline |
|-----------|----------|-------------------|----------------|---------------------|
| `qwen2.5-coder:32b-q4_K_M` (baseline) | 19.9 GB | ~12 of 64 layers on GPU | 8–12 | baseline |
| **`qwen2.5-coder:32b-q5_K_M`** (recommended) | 23.3 GB | ~10 of 64 layers on GPU, ~13 GB spill to 7900X | **6–9** | **+~2–3% HumanEval**, better multi-file reasoning |
| `qwen2.5-coder:32b-q6_K` | 26.9 GB | ~8 of 64 layers on GPU, ~17 GB spill | 4–6 | +~0.5–1% over Q5; not worth the slowdown |
