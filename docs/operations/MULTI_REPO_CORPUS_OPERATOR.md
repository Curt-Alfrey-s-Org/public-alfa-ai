# Multi-repo code corpus for 7B QLoRA

Build a **completion** JSONL corpus from the repos you actively develop, then point
Axolotl `pool-7b-qlora-sft.yaml` at it. This is the step that was missing when the
GUI Start used a hub file that contained **only `alfa-ai`**.

Related: [TRAIN_7B_QLORA_GUI.md](TRAIN_7B_QLORA_GUI.md),
[TRAIN_PACK_MANIFEST.md](TRAIN_PACK_MANIFEST.md) (Tier B chat packs are **different**),
[REPO_HOST_MAPPING.md](../REPO_HOST_MAPPING.md).

Official dataset shape: Axolotl [dataset formats](https://docs.axolotl.ai/docs/dataset-formats/)
with `type: completion`. Rows use field **`content`** because
`configs/pool-7b-qlora-sft.yaml` sets `field: content`
([config reference](https://docs.axolotl.ai/docs/config-reference.html)); the docs default
column name `text` is overridden by that field.

## What this is / is not

| This corpus | Cluster FAQ chat (7B GUI) | Tier B `from-alfa-ai` pack |
|-------------|---------------------------|----------------------------|
| Raw repo source/docs as completion text | OpenAI `messages` Q&A for cluster facts the completion dump mis-answers | Chat/lessons/DPO from sleep flywheel |
| Built by `scripts/build_multi_repo_corpus.py` | Built by `scripts/build_7b_cluster_faq_chat.py` (Start stages to hub) | Built by `scripts/export_train_pack.py` |
| `type: completion` in `pool-7b-qlora-sft.yaml` | Second yaml dataset `type: chat_template` | Night QLoRA chat configs |

Axolotl allows mixing completion and chat in one `datasets:` list
([dataset formats](https://docs.axolotl.ai/docs/dataset-formats/)). The FAQ does **not**
replace this multi-repo corpus. `weight` on a dataset **subsamples** only (0 exclusive,
1 inclusive; cannot upsample). Bounds live in the official schema
(`gt=0.0`, `le=1.0` on `SFTDataset.weight` in
[datasets.py](https://github.com/axolotl-ai-cloud/axolotl/blob/main/src/axolotl/utils/schemas/datasets.py));
the HTML [config reference](https://docs.axolotl.ai/docs/config-reference.html) may omit
that field. FAQ row count
is raised by `scripts/build_7b_cluster_faq_chat.py --repeats` (default 50) plus `--extra-repeats-gate-fact13` (default 50) during **cluster
JSONL preprocess** -- not an Axolotl `weight` upsample. FAQ yaml entry uses
`type: chat_template` with `chat_template: tokenizer_default`
([conversation](https://docs.axolotl.ai/docs/dataset-formats/conversation.html)); base
[Qwen2.5-Coder-7B-Instruct](https://huggingface.co/Qwen/Qwen2.5-Coder-7B-Instruct) ships
`chat_template` and `eos_token` `<\|im_end\|>`. Do **not** claim train `tokenizer_default`
matches llama.cpp `--chat-template chatml` until GGUF metadata is verified. Axolotl is
**silent** on mix-time global `special_tokens.eos_token` -- do **not** add yaml
`special_tokens` from this doc.

## Fleet repo set (all GitHub product repos)

The 7B job trains on **one GitHub clone per repo on `orchestrator`**, not a copy of every host
working tree. The same `alfa-ai` (or rankings-bot, …) checkout on `pool-opt-in` / `apps` /
`hub` is the same git history. GitHub is the sync bus
([git clone](https://git-scm.com/docs/git-clone),
[git pull --ff-only](https://git-scm.com/docs/git-pull),
[scp-direction.mdc](../../.cursor/rules/scp-direction.mdc)). **Do not** SCP trees from
`market` / `atems` / `apps` / `probilliards`.

Builder rows are **`git ls-tree -r --name-only HEAD`** files
([git ls-tree](https://git-scm.com/docs/git-ls-tree)), filtered by the YAML
extensions/denies. Untracked host dirt is not trained.

Every listed repo is **required**. Missing clones fail the build. Ensure clones first
(`git clone` / `git pull --ff-only` with `core.longpaths=true` on Windows
([git-config core.longpaths](https://git-scm.com/docs/git-config#Documentation/git-config.txt-corelongPaths))):

```powershell
cd C:/Users/operator\alfa-ai
python scripts/ensure_multi_repo_corpus_clones.py --repos-file deploy/training/multi-repo-corpus.repos.yaml
```

| Repo | `orchestrator` clone | GitHub (origin) | Owning host |
|------|-------------|-----------------|-------------|
| alfa-ai | `C:/Users/operator\alfa-ai` | `example/alfa-ai` | `orchestrator` / `pool-opt-in` / `hub` |
| alfa-train | `C:/Users/operator\alfa-train` | `alfa-train` | `orchestrator` |
| contracts-bot | `C:/Users/operator\contracts-bot` | `contracts-bot` | `apps` |
| rankings-bot | `C:/Users/operator\rankings-bot` | `Rankings-Bot` | `probilliards` |
| monitoring | `C:/Users/operator\monitoring` | `monitoring` | `monitor` |
| victron-ble2mqtt-integration | `C:/Users/operator\victron-ble2mqtt-integration` | `victron-ble2mqtt-integration` | `solar-broker` / `edge` |
| market-pie5-bot | `C:/Users/operator\market-pie5-bot` | `market-pie5-bot` | `market` |
| atems | `C:/Users/operator\atems` | `ATEMS` | `atems` |
| USPBF | `C:/Users/operator\USPBF` | `USPBF` | `probilliards` |
| credit-check-bot | `C:/Users/operator\credit-check-bot` | `credit-check-bot` | `apps` |
| rv-auto-finder | `C:/Users/operator\rv-auto-finder` | `auto-rv` | `apps` |
| example-site-perch | `C:/Users/operator\example-site-perch` | `example-site-perch` | `apps` |
| alfa-homelab | `C:/Users/operator\alfa-homelab` | `alfa-homelab` | `orchestrator` |

Manifest file: [deploy/training/multi-repo-corpus.repos.yaml](../../deploy/training/multi-repo-corpus.repos.yaml).

**Not in this corpus** (no GitHub remote; `apps` trees have live `.env` and are not git
checkouts -- do **not** copy them onto `orchestrator`):

| Path on `apps` | Why blocked |
|----------------|-------------|
| `/home/operator/auth-service` | No `origin`; live `.env` |
| `/home/operator/alfaqd-website` | No `origin`; live `.env` |

Put those on GitHub without secrets, add a `github:` row, then re-run ensure + build.

## Output layout

Staging (local) then hub:

```text
<out-dir>/
  CORPUS_MANIFEST.json
  alfa-corpus-multirepo-train.jsonl
  alfa-corpus-multirepo-val.jsonl
```

Hub (after publish):

```text
/mnt/HDDs/Alfa-AI/training/alfa-train/datasets/
  alfa-corpus-multirepo-train.jsonl
  alfa-corpus-multirepo-val.jsonl
  CORPUS_MANIFEST-multirepo.json
```

Canonical Axolotl paths used by the 7B GUI config (after you promote):

```text
/mnt/cluster/training/alfa-train/datasets/alfa-corpus-train.jsonl
/mnt/cluster/training/alfa-train/datasets/alfa-corpus-val.jsonl
```

**Do not overwrite** `alfa-corpus-*.jsonl` on the hub while `alfa-train.lock` is set
(a live job may be reading them). Stop trainer first, then promote.

Each JSONL row:

```json
{"repo": "alfa-ai", "path": "docs/FOO.md", "content": "..."}
```

## Operator flow (`orchestrator` operator)

1. Clone or fast-forward every required GitHub repo (script above).
2. Build:

```powershell
cd C:/Users/operator\alfa-ai
python scripts/build_multi_repo_corpus.py --repos-file deploy/training/multi-repo-corpus.repos.yaml --out-dir D:\alfa-ai-cache\train-corpus\multirepo
```

3. Secret scan (must be clean before hub):

```powershell
python scripts/scan_pass_jsonl.py D:\alfa-ai-cache\train-corpus\multirepo
```

4. Verify counts / per-repo coverage:

```powershell
python scripts/verify_multi_repo_corpus.py D:\alfa-ai-cache\train-corpus\multirepo
```

5. **Stop trainer** if a 7B job is running (`ALFa Trainer 7B r5` GUI -> Stop trainer). Desktop shortcut: `ALFa Trainer 7B.lnk`.
6. Publish to hub (via `gaming-c` WSL NFS `/mnt/cluster`, or any host with the mount):

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\deploy\cluster-members\orchestrator\Publish-MultiRepoCorpus.ps1 -SourceDir D:\alfa-ai-cache\train-corpus\multirepo -PromoteCanonical
```

`-PromoteCanonical` copies multirepo files over `alfa-corpus-train.jsonl` /
`alfa-corpus-val.jsonl` (same dataset paths in yaml). Live `output_dir` is
`pool-7b-qlora-v2` so the finished v1 adapter is not overwritten.

7. On **`gaming-c` and `gaming-b`**, fast-forward the trainer clone so Start uses yaml
   `output_dir` **v2** (not v1):

```powershell
cd C:\alfa-ai-train
git pull --ff-only origin main
```

   Finished August adapter checkpoints stay at hub
   `alfa-train/checkpoints/pool-7b-qlora-v1/` — **never** continue or resume into v1.
   The next **Start 7B** **continues** the v2 adapter when `adapter_config.json`
   exists under `alfa-train/checkpoints/pool-7b-qlora-v2/` (Start passes Axolotl
   `--lora-model-dir`; [LoRA continuing training](https://docs.axolotl.ai/docs/lora.html),
   [config `lora_model_dir`](https://docs.axolotl.ai/docs/config-reference.html)).
   Opt out with CLI `-FreshAdapter` or GUI **Fresh adapter (from base)** for a new LoRA
   from zeros on the frozen 7B base. Rebuild the **full** fleet JSONL every time you
   add code (not git diffs only). **Stop trainer** before hub promote. Yaml
   `dataset_prepared_path: last_run_prepared_v2` is the yaml base only. Axolotl **reuses**
   an explicit prepared path when it already exists
   ([dataset preprocessing](https://docs.axolotl.ai/docs/dataset_preprocessing.html)).
   When corpus **or** cluster FAQ content changes, Start passes
   `--dataset-prepared-path last_run_prepared_v2_<sha256-12>` from
   `qlora_continue.py --corpus` **and** `--extra-jsonl` (FAQ chat JSONL). The
   `_<sha256-12>` suffix is **cluster** hashing in `qlora_continue.py`, not Axolotl's
   internal cache key
   ([CLI](https://docs.axolotl.ai/docs/cli.html)).

8. Start 7B again from the `ALFa Trainer 7B r5` GUI (`train-desktop-menu.ps1`). Do not Start parked 14B.

## Exclusions (mandatory)

Builder skips: `.git`, `node_modules`, `dist`, `build`, `.venv`, `__pycache__`,
`*.pyc`, `.env*`, `*.pem`, `secrets/`, binary/media, lockfile giants beyond size cap,
fixture files under `**/fixtures/**` named `*secret*`, and paths matching deny globs in
the YAML. USPBF should exclude `wp-content/uploads` and live env.

Before writing each JSONL row, the builder redacts heuristic secret-like spans
(same patterns as `scripts/scan_pass_jsonl.py`) with placeholders such as
`[REDACTED_POSTGRES_URL]` so the corpus can pass the secret scan.

## Current lock / running train

If Status shows **Trainer LOCK on**, leave the job or Stop it deliberately. Building
the corpus locally is safe anytime; **hub promote** waits until Stop trainer.
