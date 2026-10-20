# SearXNG on `hub` (LAN search for ALFa agent missions)

Self-hosted metasearch for the `web_search` agent tool. Brain API reaches SearXNG
over Docker network `alfa-searxng` (container DNS `alfa-searxng:8080`). SearXNG
calls upstream engines. Workers never use public search API keys.

**LAN admin only:** guest chat, WordPress docks, and consumer widgets must not
call SearXNG. Host publish is loopback `127.0.0.1:8888`. See
[AGENT_RESEARCH_TOOLS.md](../../docs/AGENT_RESEARCH_TOOLS.md).

**Official:** [Docker install](https://docs.searxng.org/admin/installation-docker.html),
[Search API](https://docs.searxng.org/dev/search_api.html) (`format=json` required),
[Compose external networks](https://docs.docker.com/compose/how-tos/networking/).

## Image pin

Compose uses **`docker.io/searxng/searxng:2026.10.2-19ffbcd30`** (immutable
`YYYY.M.D-sha` tag from upstream
[container/.env.example](https://github.com/searxng/searxng/blob/master/container/.env.example)).
Upstream install docs still show `:latest`; we pin the date tag instead. Same
digest as `searxng/searxng:latest` at pin time (`sha256:c642712fcedcdaa78fac44f71eada86aff510745826ba1bd1a368211fea2ce7f`).

## Hub-first (image > 100 MB)

Canonical tarball (filename unchanged): `/mnt/HDDs/Alfa-AI/docker-images/searxng-searxng-latest.tar.gz`

The existing hub tarball is the same digest as the pinned tag. After load, tag
the image so compose resolves the pin without re-downloading ([`docker image tag`](https://docs.docker.com/reference/cli/docker/image/tag/)):

```bash
sudo docker load -i /mnt/HDDs/Alfa-AI/docker-images/searxng-searxng-latest.tar.gz
sudo docker tag searxng/searxng:latest docker.io/searxng/searxng:2026.10.2-19ffbcd30
```

To (re)publish the tarball from a host that already has the pinned image, use official
[`docker save` + gzip](https://docs.docker.com/reference/cli/docker/image/save/):

```bash
sudo docker save docker.io/searxng/searxng:2026.10.2-19ffbcd30 | gzip | sudo tee /mnt/HDDs/Alfa-AI/docker-images/searxng-searxng-latest.tar.gz > /dev/null
```

Do not `docker pull` this image on workers.

## Deploy on `hub`

**Step 1 -- From `hub` (operator):** create shared network (idempotent; also done by `scripts/start.sh`):

```bash
sudo docker network create alfa-searxng 2>/dev/null || true
```

**Step 2 -- From `hub` (operator):**

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/searxng
sudo docker compose up -d
```

**Step 3 -- From `hub` (operator):**

```bash
curl -fsS 'http://127.0.0.1:8888/search?q=fastapi&format=json' | head -c 400
```

Expect JSON with a `results` array (not HTTP 403).

## Brain env

In `deploy/.env` on `hub`:

```
ALFA_AI_WEB_SEARCH_ENABLED=1
ALFA_AI_SEARXNG_URL=http://alfa-searxng:8080
```

Recreate `alfa-ai-api` after change. Default is **disabled** (`ALFA_AI_WEB_SEARCH_ENABLED=0`).
Brain compose attaches `alfa-ai-api` (and optional `alfa-ai-worker`) to external
network `alfa-searxng` -- no manual `docker network connect` after recreate.

## Port

Host `127.0.0.1:8888` -> container `8080`. See [PORT_ASSIGNMENTS.md](../../docs/PORT_ASSIGNMENTS.md).

Loopback publish is for host smoke tests only. Brain containers use Docker DNS on
`alfa-searxng`, not the host port.

## Policy

- Operator/LAN missions only (`POST /api/runs`, not guest chat)
- Manual mission trigger only ([no-automatic-scraping.mdc](../../.cursor/rules/no-automatic-scraping.mdc))
- Prefer repo grep + allowlisted `fetch_url`; use `web_search` for discovery

## Pool72 one-shot enable

After Pool72 coordinator is green ([GREV72_72B_OPERATOR.md](../../docs/GREV72_72B_OPERATOR.md)):

```bash
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai
bash scripts/operator-pool72-research-enable.sh
bash scripts/verify-pool72-research-smoke.sh --enqueue-mission
```

Sets `ALFA_AI_AGENT_MODEL=frontier`, enables `web_search`, starts SearXNG, redeploys API + worker.

## Related

- [AGENT_RESEARCH_TOOLS.md](../../docs/AGENT_RESEARCH_TOOLS.md)
