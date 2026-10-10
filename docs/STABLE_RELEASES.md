# Stable releases (our projects)

**Checked:** 2026-10-03 against upstream release pages. This file is the live pin policy.
Older audit tables (for example the 2026-06-09 block in [ROADMAP.md](ROADMAP.md)) are snapshots.

Agents follow [.cursor/rules/stable-releases-only.mdc](../.cursor/rules/stable-releases-only.mdc).

## Rule

1. **Production** uses a vendor **stable** tag: numbered `vX.Y.Z` (or the vendor's documented stable channel). Not `:latest`, `main`, `master`, `nightly`, `edge`, `rc`, or `beta`.
2. **Do not** turn this cluster into a beta test for someone else's project. Help their beta only when the operator says that thread is for their project.
3. A build upstream still marks **pre-release** may be pinned for **our** code only after a written check: changelog, same tag on every host, and what would break. "Usable" is a decision recorded here or in the component operator doc, not a silent bump.
4. A feature the vendor still calls **beta** stays off. LiteLLM [request prioritization](https://docs.litellm.ai/docs/scheduler) stays off; slot caps are in [inference_PERF_AND_SHARDS.md](inference_PERF_AND_SHARDS.md).

LiteLLM documents numbered tags as the production form and treats rolling tags as pointers at the newest image ([Docker image security](https://docs.litellm.ai/docs/proxy/docker_image_security)). Docker Compose image pinning: [Compose image](https://docs.docker.com/reference/compose-file/services/#image).

## Live pins

| Component | Live pin | Where |
|-----------|----------|--------|
| LiteLLM | `ghcr.io/berriai/litellm:v1.103.2` | `deploy/docker-compose.yml` |
| llama.cpp RPC image | `b10355` | `deploy/llamacpp-rpc` / [LLAMACPP_RPC_OPERATOR.md](LLAMACPP_RPC_OPERATOR.md) |
| Postgres | `postgres:16.14` and `16.14-alpine` | `deploy/docker-compose.postgres.yml`, backup compose |
| Redis | `redis:7.4-alpine` | `deploy/docker-compose.redis.yml` |
| nginx | `nginx:1.30.5-alpine` | `deploy/docker-compose.yml` |
| Ollama image | `ollama/ollama:0.35.1` | embed compose files and `scripts/hub_hub_models.sh` |
| SearXNG | `docker.io/searxng/searxng:2026.10.2-19ffbcd30` | `deploy/searxng/docker-compose.yml` |
| aria2-pro | `p3terx/aria2-pro:202209060423` | `deploy/aria2/docker-compose.yml` |

`v1.103.2` is the newest non-prerelease LiteLLM image as of 2026-10-03 ([v1.103.2](https://github.com/BerriAI/litellm/releases/tag/v1.103.2)). `v1.104` / `v1.105` tags on that date were release candidates. Before the next `hub` recreate, if `LiteLLM_SpendLogs` is large, build `LiteLLM_SpendLogs_api_key_startTime_idx` with `CREATE INDEX CONCURRENTLY` ([v1.103.0 notes](https://docs.litellm.ai/release_notes/v1.103.0/v1-103-0)).

Ollama `0.35.1` is GA ([v0.35.1](https://github.com/ollama/ollama/releases/tag/v0.35.1)). Do not pin `0.40.0-rc0`.

SearXNG has no GitHub Releases. The date-commit tag is the immutable pin of the image that `:latest` pointed at on 2026-10-02 (same digest). After loading the existing hub tarball, tag it locally ([docker tag](https://docs.docker.com/reference/cli/docker/image/tag/)) instead of pulling again. aria2-pro `202209060423` is the dated publish tag that matches `:latest` from 2022-09-06. Do not use `p3terx/aria2-pro:test`.

## Not adopted

| Candidate | Why it stays off |
|-----------|------------------|
| llama.cpp `v0.5.0` (2026-09-23) | Semver, not a nightly. [v0.5.0](https://github.com/ggml-org/llama.cpp/releases/tag/v0.5.0) uses RPC protocol **major 7**. Fleet image `b10355` uses **major 5**. The handshake rejects a mismatch (`ggml-rpc.cpp` `negotiate_hello`). One hub rebuild must move the coordinator and every shard together. Do not flip `LLAMACPP_TAG` in git until that image exists on the hub. Do not pin nightly `b11146`. |
| llama.cpp `v0.5.0` for **`qwen4exp` / Qwen3.8-Flash-Next** | Stock minimum for Flash-Next architecture is **`v0.5.0`** ([release](https://github.com/ggml-org/llama.cpp/releases/tag/v0.5.0)). **Still not the fleet pin** — cluster stays **`b10355`** until a coordinated hub image exists; upgrading the tag without fit analysis does not enable Flash-Next Q8 ([FLASH_NEXT_Q8_FIT.md](FLASH_NEXT_Q8_FIT.md): **CANNOT FIT** at Q8_0 on current VRAM/RAM). |
