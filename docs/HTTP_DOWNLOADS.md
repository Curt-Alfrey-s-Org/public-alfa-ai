# Large HTTP(S) downloads — aria2-only policy

## DO NOT use curl for large files

**Forbidden for operators and agents:**

| Anti-pattern | Why it fails | Use instead |
|--------------|--------------|-------------|
| `curl …/api/pull` to Ollama on another host (e.g. `apps` → `hub:11434`) | Long-lived HTTP stream; drops mid-download (exit 18/52); no reliable resume from the client | On **`hub`**: `sudo bash scripts/hub_hub_models.sh pull quality` (or `embed`) — runs `ollama pull` locally into the hub via Docker |
| `curl -L -o big.gguf https://…` for multi-GB assets | Single stream; HTTP/2 CANCEL / truncate; weak resume | **`aria2c`** (local) or **aria2 JSON-RPC** on `hub` (`:6800`); **`scripts/lib/http_fetch.sh`** (aria2 only) |
| `curl` from `apps` to seed the hub hub | NFS export is root-squashed; writes fail even with sudo | Run hub seed scripts **on `hub`** as root (`hub_hub_models.sh`, `http_fetch.sh`, aria2 RPC) |
| Leaving **partial GGUF** shards on the hub after a failed fetch | Wastes hundreds of GB; next run may skip a truncated file | `sudo bash scripts/cleanup-partial-gguf-hub.sh` then re-`pull` |

**`curl` is allowed only for:** **short** health/API probes (`curl -fsS …/health`, `api/tags`) and **aria2 JSON-RPC** control-plane POSTs (not the file body). It is **not** a download fallback in `http_fetch.sh`.

Cluster scripts that fetch **single-file HTTPS assets** (GGUF weights, raw
installers, etc.) **must** use **`scripts/lib/http_fetch.sh`**:

1. **`aria2c`** on the local machine (`-x16 -s16 -c` multi-connection + continue) when installed.
2. Else **remote aria2 JSON-RPC** (Dockge stack **`deploy/aria2/`** on hub `hub` at `:6800`) when **`ARIA2_RPC_URL`** is set and **`python3`** is available.
3. **Fail hard** if neither path works — **no curl fallback** (truncated multi-GB files caused by curl HTTP/2 CANCEL are not acceptable on the hub).

Helper: **`scripts/lib/aria2_jsonrpc_fetch.py`** (called by `http_fetch.sh`).

On **`hub`**, prefer:

```bash
source /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/hub/aria2-env.sh
# or:
bash deploy/cluster-members/hub/aria2-pull-gguf.sh
# / aria2-pull-gguf72.sh etc. once those wrappers exist
```

Ensure the aria2 Dockge stack is up (`aria2-bootstrap.sh` / `aria2-smoke.sh`) before multi-hour GGUF pulls.

## What does *not* use this stack

- **Ollama model tags** (`qwen3.5:27b`, `qwen3.6:35b-a3b`, `qwen3-embedding:4b`, …) — Ollama’s own
  registry/blob layout. **Never** proxy `ollama pull` through curl from another
  host. On hub **`hub`**, seed the hub with (**requires Ollama `0.30.x`** — Gated-DeltaNet):
  ```bash
  cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
  sudo bash scripts/hub_hub_models.sh pull quality --stores cold   # qwen3.5:27b (~19 GB)
  sudo bash scripts/hub_hub_models.sh pull embed --stores cold     # qwen3-embedding:4b
  ```
  Fleet hosts sync via `pull-models.sh` / `pull-models.ps1` (hub-first merge,
  then `ollama pull` only for missing tags). See [HUB_ARTIFACTS.md](HUB_ARTIFACTS.md).
- **`git` / `docker pull` / HF multi-file repos** — use `git`, `docker`, or
  `hub_hub_models.sh pull hf REPO_ID` (huggingface-cli + hf_transfer,
  resume-safe).

## Environment (typical on LAN clients pulling through hub aria2)

| Variable | Meaning |
|----------|---------|
| `ARIA2_MODE` | `auto` (default: **cli then rpc, never curl**) \| `cli` \| `rpc` \| `curl` (**emergency only** — not for hub GGUF) |
| `ARIA2_CONN` | Segments for `aria2c` (default `16`) |
| `ARIA2_RPC_URL` | e.g. `http://hub/jsonrpc` |
| `ARIA2_RPC_KEY` | **Required for RPC** (no default). Must match the aria2 stack's `ARIA2_RPC_KEY`; RPC fetches fail with a clear error when unset |
| `ARIA2_RPC_DIR` | Server-side download dir inside the container (default `/downloads`) |
| `ARIA2_HOST_STAGING` | Host path bound to container `/downloads` on the **aria2 server** (default **`/mnt/HDDs/Alfa-AI/models/downloads`** — must match `ARIA2_DOWNLOADS_HOST_PATH` in `deploy/aria2/docker-compose.yml`) |
| `HF_TOKEN` | Sent as `Authorization: Bearer` for HF when the bare `resolve` URL returns **401** |
| `HUGGING_FACE_HUB_TOKEN` | If `HF_TOKEN` is unset, `http_fetch` uses this (same Bearer) |
| `HTTP_FETCH_PROGRESS` | `1` (default): when **stderr is a TTY**, show **aria2c** `--summary-interval=1`, and **RPC** byte/speed lines. Set `0` to silence (cron / logs). |
| `HTTP_FETCH_SKIP_EXISTING` | `1` to skip if dest already exists (default **off** — incomplete files must be resumed or removed) |

If **`ARIA2_HOST_STAGING`** does not match your compose bind mount, set it to
the host directory where finished files appear **before** `http_fetch` moves
them into the final path (e.g. `/mnt/HDDs/Alfa-AI/models/downloads` if you
rebind aria2 there).

### Hugging Face `401` / `404` on `pull gguf` (hub)

- **401** — missing or invalid token on a gated URL. Fix with steps (1)–(3) below.
- **404** with a token — wrong **repo id** or filename for that URL. The tier-3b
  GGUF target is **`Qwen3-Coder-Next-80B-A3B-GGUF`** (the 30B-A3B GGUF is
  legacy/retired); set `REPO=…` if you mirror elsewhere.

1. Create a **read** token at [Hugging Face access tokens](https://huggingface.co/settings/tokens).
2. On the model repo page, **accept the license** / community agreement if the gate asks for it.
3. Export before running the hub script, e.g.  
   `export HF_TOKEN=hf_…`  
   or  
   `export HUGGING_FACE_HUB_TOKEN=hf_…`  
   then `sudo -E bash scripts/hub_hub_models.sh pull gguf` so the token reaches the child process.

`huggingface-cli download` uses the same tokens from env when installed.

### Partial / failed hub GGUF cleanup

After a failed curl or truncated shard (e.g. 480B shard1 ~37G vs ~47G expected):

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
sudo bash scripts/cleanup-partial-gguf-hub.sh
# then ensure aria2 is up and re-pull:
source deploy/cluster-members/hub/aria2-env.sh
sudo -E MODELS_DIR=/mnt/HDDs/Alfa-AI/llama-cpp/models \
  REPO=unsloth/Qwen3-Coder-480B-A35B-Instruct-GGUF \
  MODEL_LEAD=Q4_K_M/Qwen3-Coder-480B-A35B-Instruct-Q4_K_M-00001-of-00006.gguf \
  HF_INCLUDE='Q4_K_M/*.gguf' \
  bash deploy/llamacpp-rpc/scripts/fetch-qwen3-coder.sh
```

Default cleanup target: incomplete **Qwen3-Coder-480B** Q4_K_M under
`/mnt/HDDs/Alfa-AI/llama-cpp/models/`. Pass `--dry-run` first if unsure.
See script header for flags.

## Consumers in this repo

- `deploy/llamacpp-rpc/scripts/fetch-qwen3-coder.sh` — GGUF via `http_fetch`
  (aria2-only), then `huggingface-cli` on failure unless `FETCH_GGUF_HF_CLI_FIRST=1`.
- `scripts/hub_hub_models.sh` `pull gguf*` — sources `aria2-env.sh` when present;
  delegates to fetch script or `http_fetch.sh`.
- `scripts/cleanup-partial-gguf-hub.sh` — remove truncated / incomplete hub GGUFs.
- `scripts/setup_hub_hub.sh` — Ollama `install.sh` cache via `http_fetch`
  when present.

## Other workspace repos

Use the same library by path (repos are siblings under the same machine):

```bash
source /path/to/alfa-ai/scripts/lib/http_fetch.sh
http_fetch_to "https://example.com/big.bin" /tmp/big.bin
```

See also: [CLUSTER_SHARED_STORAGE.md](CLUSTER_SHARED_STORAGE.md) (aria2 RPC,
`models/downloads/` staging). **Dockge rollout:** [deploy/aria2/README.md](../deploy/aria2/README.md).
