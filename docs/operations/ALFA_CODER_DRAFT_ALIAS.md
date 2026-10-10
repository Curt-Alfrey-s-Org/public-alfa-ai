# `alfa-coder-draft` LiteLLM alias (7B homelab coder)

**Not production default.** Opt-in alias for home-trained **Qwen2.5-Coder-7B-Instruct**
QLoRA served standalone on `gaming-c` while inference 27B stays on `frontier-code`.

Full topology: [ALFA_7B_SERVE_ALONGSIDE_27B.md](ALFA_7B_SERVE_ALONGSIDE_27B.md).

## Today (before promote)

| Setting | Value |
|---------|--------|
| LiteLLM alias | `alfa-coder-draft` |
| Backend | `api_base: os.environ/LLAMACPP_7B_URL` in `deploy/litellm_config.yaml` ([LiteLLM env](https://docs.litellm.ai/docs/proxy/configs)). **Unset URL:** primary yaml cannot route. **inference overlay** may fall back to `frontier-code` (`model_group_alias` in `litellm_config.inference.yaml`). |
| `DEFAULT_MODEL` | **Must stay** `frontier-code` |
| CHAT_MODELS | Optional -- only add after live FAQ chat + operator asks for LiteLLM |
| Production LoRA GGUF | `pool-7b-qlora-v1.gguf` (v2 does not change LiteLLM until operator wires alias post live chat) |

Do **not** set `LLAMACPP_7B_URL` during sequential eval or live chat. The alias is unused until the operator asks.

Files: `deploy/litellm_config.yaml`, `deploy/litellm_config.inference.yaml`.

## Eval before LiteLLM (sequential, no LiteLLM)

v2 checkpoints use a **distinct** hub GGUF (`pool-7b-qlora-v2.gguf`); v1 is not overwritten.
Only one `llama-server` on `gaming-c:8470` at a time (12 GB -- no concurrent base + adapter).

Full SSoT: [ALFA_7B_SERVE_ALONGSIDE_27B.md](ALFA_7B_SERVE_ALONGSIDE_27B.md) **After training**
and **Measurement layers**.

1. Stop trainer; convert v2 on `hub` (`CHECKPOINT_DIR` + `ADAPTER_ID=pool-7b-qlora-v2`).
2. `Start-Alfa7bServe.ps1 -NoLora` -> `generate_7b_eval_answers.py` (base) -> stop.
3. `Start-Alfa7bServe.ps1 -LoraGguf pool-7b-qlora-v2.gguf` -> generate checkpoint answers.
4. `train_checkpoint_gate.py` -- **cluster smoke log** (10 `must_include_any` needles, 70%
   script threshold, `promote_allowed` in output). Informational regression signal only;
   not an official eval; LiteLLM does **not** enforce 70%
   ([NIST Measure 2.3](https://airc.nist.gov/airmf-resources/playbook/measure/),
   [LiteLLM proxy configs](https://docs.litellm.ai/docs/proxy/configs)).
5. **Live FAQ chat** on `:8470` -- three frozen Yes/No prompts (same as
   `scripts/build_7b_cluster_faq_chat.py` `UNIQUE_TURNS` first three). Deployment-like
   acceptance: wrong Yes/No = not ready to use, even if smoke scored 6/10 or
   `promote_allowed=true`. See SERVE doc frozen-prompt table.

**Do not** set `LLAMACPP_7B_URL` or recreate LiteLLM until step 5 passes **and** the operator
explicitly asks to wire the alias. `promote_allowed` is smoke-script output, not a LiteLLM gate.

Official: [llama-server --lora](https://github.com/ggml-org/llama.cpp/blob/master/tools/server/README.md),
[convert_lora_to_gguf.py](https://github.com/ggml-org/llama.cpp/blob/master/convert_lora_to_gguf.py).

## After operator asks for LiteLLM (post live chat)

Prerequisite: three frozen live FAQ prompts passed on `:8470` chat (SERVE doc).

1. Start standalone `llama-server` on **`gaming-c:8470`** with the approved GGUF (`Start-Alfa7bServe.ps1`).
2. Set on `hub` `deploy/.env`:

   ```env
   LLAMACPP_7B_URL=http://orchestrator/v1
   ```

3. Recreate LiteLLM; wait helper; smoke `/v1/models` lists `alfa-coder-draft`.
4. Opt-in clients only (never silent default for contracts-bot).

## Clients

```text
# Explicit opt-in only
CONTRACT_AI_MODEL=qwen3.6-27b          # production stays
# experimental: CONTRACT_AI_MODEL=alfa-coder-draft   # NOT until live FAQ chat + operator LiteLLM wire
```

## Dual-check (optional)

7B drafts via `alfa-coder-draft`; 27B judges via LiteLLM `frontier-code`
(`ALFA_AI_JUDGE_MODEL=frontier-code`, empty `ALFA_AI_JUDGE_API_BASE`).
Default off: `ALFA_AI_JUDGE_ENABLED=0`.

## Related

- [SLEEP_TRAIN_TIER_B.md](SLEEP_TRAIN_TIER_B.md)
- [TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md)
- [.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md](../../.cursor/plans/LEARNING_LOOP_JUDGE_SLEEP.md)
