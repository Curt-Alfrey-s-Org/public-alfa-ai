# Model fit audit — official vendor docs vs repo stack

> **Benchmark reference (not live routing).** Live routing SoT is
> [`deploy/litellm_config.yaml`](../deploy/litellm_config.yaml) and the **primary
> working set SSoT** [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md):
> frontier on the four always-on hosts via **llama.cpp RPC** (coordinator
> `orchestrator:31360`) - **Qwen3.5-122B-A10B** (chat) / **Qwen3.6-27B** (code, highest
> fitting SWE-bench Verified) / agentic alt **Qwen3-Coder-Next-80B-A3B**. The
> dense-vs-MoE and quant/fit comparisons below are the *rationale* that fed those
> choices; the CPU Ollama pool is the opportunistic boost layer.

**Role:** Auditor summary. **Single source of truth** for capability claims is **model creators’** published model cards and technical reports—not this repo, not forum posts, unless explicitly labeled third-party.

**Your stated quality dimensions:** coding, emails, contracts, stories. Industry-standard **proxies** that vendors actually publish:

| Your dimension | Common published proxy | Primary definers |
|----------------|------------------------|------------------|
| **Coding** | HumanEval / MBPP / EvalPlus; LiveCodeBench; SWE-bench (agentic, scaffold-dependent) | Meta model cards; Qwen3 Technical Report (arXiv:2505.09388); SWE-bench site |
| **Emails** (structure, tone, constraints) | **IFEval** “verifiable instructions” (length, format, keywords)—*not* “business email” labeled | Google [IFEval paper arXiv:2311.07911](https://arxiv.org/abs/2311.07911); vendors report scores |
| **Stories** | **Creative Writing V3** (and similar) in Qwen3 report; Meta card does not use the same creative-writing column | Qwen3 Technical Report Table 12–16 |
| **Contracts** | **No** widely cited single “contract accuracy” benchmark in Meta or Qwen flagship cards. Legal-domain evals exist in research but are **not** the default vendor SSoT for these models. | Treat as **unevaluated in creator SSoT**; use human/legal review for production |

---

## 1. Official numbers relevant to this repo’s **three** serving classes

### 1A. Tier 3a — `Llama-3.3-70B-Instruct` (Petals)

**Source:** [Meta `MODEL_CARD.md` (llama-models)](https://github.com/meta-llama/llama-models/blob/main/models/llama3_3/MODEL_CARD.md) and [Hugging Face `meta-llama/Llama-3.3-70B-Instruct`](https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct) (instruction-tuned table).

| Category | Benchmark | Llama-3.3-70B-Instruct (reported) |
|----------|-----------|-----------------------------------|
| General | MMLU (CoT) | 86.0 |
| Instruction-following | IFEval | **92.1** |
| Code | HumanEval (pass@1) | **88.4** |
| Code | MBPP EvalPlus (base) (pass@1) | **87.6** |
| Math | MATH (CoT) | 77.0 |
| Tool use | BFCL v2 | 77.3 |

**Creative Writing V3 / LiveCodeBench:** not in this Meta table (different eval suite than Qwen3’s post-training tables).

---

### 1B. Tiers 0/1/2 — `qwen3-coder:30b-a3b-q4_K_M` (Ollama CPU MoE)

**Architecture alignment:** Same family as **Qwen3-30B-A3B** (MoE, ~3B activated) per [Qwen3 blog](https://qwenlm.github.io/blog/qwen3/) and [Qwen3-Coder model card](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct). The **Ollama tag** is a **distribution artifact**; strict 1:1 parity with every row in the technical report should not be assumed without re-measurement on the exact Ollama build and quant.

**Source for *in-family* instruct metrics:** [Qwen3 Technical Report](https://arxiv.org/abs/2505.09388) **Table 16** — *Qwen3-30B-A3B (Non-thinking)* vs baselines:

| Task bucket | Benchmark | Qwen3-30B-A3B (Non-thinking) |
|-------------|-----------|------------------------------|
| Alignment | IFEval strict prompt | **83.7** |
| Alignment | Creative Writing v3 | **68.1** |
| Coding / agent | LiveCodeBench v5 | **29.8** |
| Coding / agent | BFCL v3 | 58.6 |

**Table 15** — *Qwen3-30B-A3B (Thinking)* (when “thinking” is enabled in the stack):

| Benchmark | Qwen3-30B-A3B (Thinking) |
|-----------|---------------------------|
| LiveCodeBench v5 | **62.6** |
| IFEval strict prompt | **86.5** |
| Creative Writing v3 | **79.1** |

**Implication:** If the CPU fleet runs **non-thinking** chat templates only, published **LiveCodeBench** is much lower than **thinking** mode in Qwen’s own harness—this is a **product/config** effect, not just “MoE vs dense.”

---

### 1C. Tier 3b — llama.cpp RPC (GGUF): **`Qwen3-Coder-Next-80B-A3B-Instruct`** (target)

**Cluster plan:** **GPU** **`frontier-code`** uses **Coder-Next 80B-A3B** GGUF (e.g. Q4_K_M; file sizes in [Qwen/Qwen3-Coder-Next-GGUF](https://huggingface.co/Qwen/Qwen3-Coder-Next-GGUF)). **CPU** tiers stay **`qwen3-coder:30b-a3b-q4_K_M`** (MoE) — unrelated to this GGUF path.

**Source (family + positioning):** [Qwen3-Coder announcement](https://qwenlm.github.io/blog/qwen3-coder/) (Coder line); for **Coder-Next** specifically use the **model card / blog** linked from the HF GGUF repo above. Treat **SWE-bench-class** headline numbers as tied to **flagship** Coder variants and **eval harness** — re-measure on your **frozen** `llama.cpp` build and agent scaffold before claiming parity.

**Retired from GPU RPC (this repo’s plan):** **`Qwen3-Coder-30B-A3B-Instruct`** GGUF — [HF card](https://huggingface.co/Qwen/Qwen3-Coder-30B-A3B-Instruct) remains valid for **in-family** discussion; the **480B** Coder variant is what the blog highlights for SWE-Bench-class **headline** results. **30B-A3B** HF card does **not** establish a single vendor SWE number comparable across scaffolds.

---

### 1D. Accuracy-focused comparison: **Qwen3-32B** (dense) vs **Qwen3-30B-A3B** vs **Llama-3.3-70B** on published proxies

**Qwen3-32B (Non-thinking)** — Qwen3 Technical Report **Table 14**:

| Benchmark | Qwen3-32B (Non-thinking) |
|-----------|---------------------------|
| IFEval strict prompt | **83.2** |
| Creative Writing v3 | **78.3** |
| LiveCodeBench v5 | **31.3** |

**Qwen3-30B-A3B (Non-thinking)** — **Table 16**: IFEval **83.7**, Creative Writing **68.1**, LiveCodeBench **29.8**.

**Cross-vendor caveat:** Meta **IFEval 92.1** vs Qwen **IFEval strict prompt ~83.x** may use **different prompt aggregation** (Meta table column is labeled “IFEval”; Qwen reports “strict prompt”). They are **directionally comparable** but not guaranteed identical protocols.

| Proxy | Llama-3.3-70B-Instruct | Qwen3-32B (non-thinking) | Qwen3-30B-A3B (non-thinking) |
|-------|------------------------|---------------------------|-------------------------------|
| Instruction-following (vendor IFEval / strict) | **92.1** (Meta) | 83.2 (Qwen Table 14) | **83.7** (Qwen Table 16) |
| Creative / story-like (Creative Writing v3) | *not in Meta card* | **78.3** | 68.1 |
| Coding (LiveCodeBench v5, Qwen suite) | *not in Meta card* | **31.3** | 29.8 |
| Coding (HumanEval / MBPP EvalPlus, Meta suite) | **88.4 / 87.6** | *not in same Meta row* | *use Qwen tables or separate runs* |

**Dense 32B vs MoE 30B-A3B (same vendor, same report, non-thinking):** Qwen3-32B wins **Creative Writing v3** and **LiveCodeBench v5** by the margins above; **IFEval strict prompt** is essentially a tie (**83.2** vs **83.7**).

**70B Llama vs Qwen3-32B:** On **Meta-published code** benchmarks, **Llama-3.3-70B-Instruct** is very strong (**HumanEval 88.4**). On **Qwen-published** **LiveCodeBench v5** **non-thinking**, **Qwen3-32B** is **31.3**—you **cannot** merge those into one ranking without a **unified** evaluation run.

---

## 2. Fit to **this repo’s hosts** (constraints from vendor + Petals, not benchmarks)

| Goal | Best *accuracy-first* direction per vendor evidence | Blocker on your stack |
|------|-----------------------------------------------------|------------------------|
| **Frontier chat + instruction-following (email-like)** | Meta **IFEval 92.1** favors **Llama-3.3-70B-Instruct** in **their** table | Requires **Petals + Llama** path you already use |
| **Creative/story-style generation** | **Qwen3-32B** > **Qwen3-30B-A3B** on **Creative Writing v3** (same report) | **Petals** [README](https://github.com/bigscience-workshop/petals) lists **Llama / Mixtral / Falcon / BLOOM**, not Qwen3; **Qwen3 in Transformers** needs **`transformers>=4.51.0`** per [Qwen docs](https://qwen.readthedocs.io/en/latest/inference/transformers.html)—your Petals image pins **4.43.x** (see `QWEN3_MIGRATION.md`) |
| **Repo-scale / agentic coding** | **Qwen3-Coder** line + optional **thinking** for Qwen’s own LiveCodeBench gains | Tier **3b** = **llama.cpp RPC**; tiers **0/1/2** = **Ollama** (verify thinking/template alignment if you need Table-15-class coding scores) |
| **Contracts** | No creator SSoT benchmark | **Do not** infer legal correctness from MMLU/HumanEval; use **human review** or domain-specific eval you own |

**Conclusion (fit):** The **documented** split—**Llama 3.3 70B on Petals** for general/high-instruction frontier chat, **Qwen3-Coder MoE** for code-weighted tiers and RPC—is **consistent with vendor tables** and **with Petals’ supported families**. **Replacing** frontier chat with **Qwen3-32B** would be **accuracy-interesting** on Qwen’s **creative** column but is **not** supported as a drop-in Petals path in the official Petals README + your current **transformers** pin.

---

## 3. Repo defects corrected (previously unsourced claims)

The following appeared in `QWEN3_MIGRATION.md` and are **not** established in **Qwen or Meta** flagship model cards as stated:

- Fixed numeric **“~40% SWE-bench”** for **Qwen3-Coder-30B-A3B** without citation to a **frozen** scaffold + leaderboard row.
- **“Claude Opus 4.5 ≈ 80.9% SWE-bench Verified”** as a baseline—vendor comparison belongs to **Anthropic** or **SWE-bench** published results, not this repo’s migration doc unless cited.
- **Phase 5 “~70% SWE-bench”** for **Coder-Next 80B** as if guaranteed—treat as **roadmap hypothesis**, not Qwen SSoT.

See updated `QWEN3_MIGRATION.md` for **conservative** wording and pointers here.

---

## 4. Repo doc drift (watchlist)

Some files still mention **`qwen3:4b` / `qwen3:8b`** or older tier splits for historical context. **Canonical routing** for April 2026 is duplicated verbatim in:

- [deploy/litellm_config.yaml](../deploy/litellm_config.yaml) (`model_list` + fallbacks)
- [QWEN3_MIGRATION.md](QWEN3_MIGRATION.md) § Tier matrix

When those disagree, treat **compose + LiteLLM config + QWEN3_MIGRATION** as authoritative for operations; use **MODEL_FIT_AUDIT** only for **vendor benchmark** claims.

---

## 5. References (bookmark)

- Meta: [Llama 3.3 MODEL_CARD.md](https://github.com/meta-llama/llama-models/blob/main/models/llama3_3/MODEL_CARD.md), [HF Llama-3.3-70B-Instruct](https://huggingface.co/meta-llama/Llama-3.3-70B-Instruct)
- Qwen: [Qwen3 blog](https://qwenlm.github.io/blog/qwen3/), [Qwen3 Technical Report PDF](https://arxiv.org/pdf/2505.09388), [Qwen3-Coder blog](https://qwenlm.github.io/blog/qwen3-coder/)
- Petals: [README — supported models](https://github.com/bigscience-workshop/petals)
- IFEval: [arXiv:2311.07911](https://arxiv.org/abs/2311.07911)
