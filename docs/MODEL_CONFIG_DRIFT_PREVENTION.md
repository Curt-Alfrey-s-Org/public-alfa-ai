# Model config drift prevention

**Problem:** Silent mismatches between git templates, operator `deploy/.env`, Docker
image stamps, and LiteLLM routing cause production to look healthy while serving
stale models or untraceable builds. Example: `DEFAULT_MODEL=qwen3.5:27b` in `.env`
while compose defaults say `qwen3.6:35b-a3b`; or `BUILD_HASH=bfa808e` on `build`
then plain `compose up` rebaking `/app/.build-hash` as `unknown`.

**SSoT chain (read in order):**

1. [.cursor/plans/FOUR_HOST_FRONTIER_POOL.md](../.cursor/plans/FOUR_HOST_FRONTIER_POOL.md) -- fleet intent
2. [`deploy/model_config_manifest.json`](../deploy/model_config_manifest.json) -- machine-readable defaults, picker, retired list
3. [`deploy/litellm_config.yaml`](../deploy/litellm_config.yaml) -- routing
4. [`src/api/llm_config.py`](../src/api/llm_config.py) -- API blocklist + picker (must match manifest)
5. [`deploy/env.example`](../deploy/env.example) -- operator template (copy to `deploy/.env`)

---

## Audit tool (run before every brain deploy)

```bash
# Committed templates only (CI / pre-push on apps)
python3 scripts/audit_model_config.py --skip-env

# Include live deploy/.env (on hub)
python3 scripts/audit_model_config.py --env deploy/.env

# Include running API build stamp
python3 scripts/audit_model_config.py --env deploy/.env --live http://127.0.0.1:8412
```

Exit **1** on errors. Warnings (e.g. `DEFAULT_MODEL` drift that is not retired) print
but do not fail unless `--strict`.

| Code | Meaning | Fix |
|------|---------|-----|
| `LIVE_ENV_RETIRED_DEFAULT` | `deploy/.env` has a retired chat alias | Edit `.env`; recreate API |
| `LIVE_ENV_RETIRED_PICKER` | `CHAT_MODELS` lists retired alias | Remove from `CHAT_MODELS` |
| `LIVE_ENV_DEFAULT_DRIFT` | `.env` default != manifest (warn) | Align with `deploy/env.example` |
| `LIVE_BUILD_HASH` | Container has `unknown`/`local` stamp | Use `scripts/brain_redeploy_api.sh` |
| `BUILD_HASH_SPLIT` | compose build-arg default != image tag default | Keep both `${BUILD_HASH:-local}` |
| `LITELLM_PICKER` | Picker alias missing from LiteLLM yaml | Add row to `litellm_config.yaml` |
| `RETIRED_MISMATCH` | Python blocklist != manifest | Sync `llm_config.py` + manifest |

`scripts/full_deploy.sh` runs `--skip-env` audit automatically before build.

---

## Correct brain API redeploy (hub)

**Do not** run bare `docker compose build` then `up` with different `BUILD_HASH` env.
Compose interpolates `image: alfa-ai-app:${BUILD_HASH:-local}` from the process
environment ([Compose interpolation](https://docs.docker.com/compose/how-tos/environment-variables/variable-interpolation/)).
If `BUILD_HASH` is unset on `up`, Compose starts **`alfa-ai-app:local`** even when
`start.sh` just built a content-hash tag -- the chat picker then keeps stale labels
(for example Qwen3.6) while inference is already on Qwen3.8 GGUF.

`scripts/start.sh` (`hub` `start-brain`) and `alfa_compose_brain_up` must export
the same `BUILD_HASH` used for `compose build`. Preferred dedicated path remains
`brain_redeploy_api.sh`.

Use one of:

```bash
# Preferred: audit + consistent hash + force-recreate
bash scripts/brain_redeploy_api.sh
```

```bash
# Full stack
bash scripts/full_deploy.sh
```

Manual equivalent:

```bash
export BUILD_HASH="$(bash scripts/docker_build_hash.sh)"
echo "BUILD_HASH=$BUILD_HASH"
cd deploy
BUILD_HASH="$BUILD_HASH" sudo -E docker compose build alfa-ai-api
BUILD_HASH="$BUILD_HASH" sudo -E docker compose up -d --force-recreate alfa-ai-api
```

Verify:

```bash
curl -fsS http://127.0.0.1:8412/api/health
# expect build_hash = content hash (64-char sha256), not unknown/local
sudo docker exec alfa-ai-api cat /app/.build-hash
```

---

## After editing `deploy/.env` model vars

`docker compose restart alfa-ai-api` **does not** reload env file changes on all hosts.
Use **`up -d --force-recreate alfa-ai-api`** (or `brain_redeploy_api.sh`).

Checklist:

1. Edit `deploy/.env` to match `deploy/env.example` / manifest
2. `python3 scripts/audit_model_config.py --env deploy/.env`
3. `bash scripts/brain_redeploy_api.sh`
4.  admin: chat picker shows Phase G aliases only

---

## CI / author workflow (apps)

Before push:

```bash
python3 scripts/audit_model_config.py --skip-env
python3 -m pytest tests/test_llm_config.py tests/test_audit_model_config.py -q
pwsh -NoProfile -File deploy/cluster-members/_common/Test-AlfaPowerShellScriptSyntax.ps1 -Recurse deploy
```

---

## Classes of silent failure (historical)

| Failure | Why silent | Prevention |
|---------|------------|------------|
| Stale `.env` in running container | Process keeps old env until recreate | `--force-recreate`; audit `--env` |
| Retired model in `.env` | API sanitizes at runtime; picker may shrink with only a log | Audit `LIVE_ENV_RETIRED_*`; blocklist in `llm_config.py` |
| `BUILD_HASH` split (`unknown` baked, `:local` tagged) | `/health` still returns 200 | Unified `${BUILD_HASH:-local}`; `brain_redeploy_api.sh` |
| Hub seed vs LiteLLM embed tag | Pull succeeds but wrong model | Align hub scripts to manifest (follow-up) |
| Docs vs routing | Ops trust stale runbooks | P0 docs + manifest as audit input |

---

## Related docs

- [DOCUMENTATION_CANONICAL.md](DOCUMENTATION_CANONICAL.md) -- prod verification checklist
- [DEPLOYMENT_BASELINE.md](DEPLOYMENT_BASELINE.md) -- startup env keys
- [LAN_OPERATOR_TROUBLESHOOTING.md](LAN_OPERATOR_TROUBLESHOOTING.md) -- LiteLLM model list smoke
