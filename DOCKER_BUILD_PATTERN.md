# Docker build pattern — alfa-ai

**This repo's default:** Pattern B — **hub hub** (`/mnt/HDDs/Alfa-AI/`).

alfa-ai builds are hub-backed by policy: every wheel ≥ 200 MB, every HF
model shard, every Ollama blob, and every prebuilt worker image tarball
comes from hub `hub` over NFS/SMB. A build that hits pypi.org,
huggingface.co, download.pytorch.org, or ollama.com for a hub artifact is
a hub gap — file it and seed the hub, don't work around it.

**Do not use the server cache at `/srv/dep-cache` from this repo.** That
cache is scoped to the 4 bots + atems. Large artifacts belong on the hub
regardless, and the hub already stages them for cluster workers.

See the full hub spec and procedures:

→ [`docs/HUB_ARTIFACTS.md`](docs/HUB_ARTIFACTS.md) — inventory, seeding,
  SMB share setup, audit.
→ [`/home/operator/docs/DOCKER_BUILD_PATTERNS.md`](../docs/DOCKER_BUILD_PATTERNS.md)
  § "Pattern B — hub hub" — Dockerfile recipes, the
  `--build-context wheels=…` pattern, and the preferred `docker load`
  path from prebuilt image tarballs.

**Frontend (`deploy/Dockerfile.frontend`):** npm resolves through **Verdaccio**
at **`http://hub`** via **`NPM_REGISTRY`** (same hub-first policy as the bots).

## When the user might still ask about pattern A

Only if the build is something small and non-worker (e.g. a one-off utility
image that doesn't ship to the cluster). In that case, ask explicitly:

> This build only needs ordinary pip wheels / debs. Use the server cache at
> `/srv/dep-cache`, or keep it on the hub hub for consistency?

Default answer unless the user says otherwise: stay on the hub.

## Quick verification

```bash
# On any Linux worker — check no pypi/HF/pytorch/ollama traffic during the build.
sudo timeout 600 tcpdump -l -n 'udp port 53' 2>/dev/null \
  | grep -iE 'pypi|huggingface|docker\.io|ollama|pytorch' | sort -u
```

If anything shows up, the hub is incomplete. File a hub gap and seed on
`hub` per `docs/HUB_ARTIFACTS.md` § "Seeding the hub".
