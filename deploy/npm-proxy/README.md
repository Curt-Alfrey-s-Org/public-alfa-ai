# Verdaccio npm registry (hub hub)

Two jobs:

1. **Pull-through cache** for npmjs.org. Packages populate on first request from LAN builders.
2. **Private `@alfa-ai` scope host** - e.g. `@alfa-ai/chat-widget` (the single-source
   chat window). These packages live only on this registry and require auth to publish
   (`config.yaml`).

## Deploy on `hub`

Requires Docker or Compose plugin on hub; hub path must exist:

The image runs as **uid 10001 / gid 65533** ([Verdaccio Docker](https://verdaccio.org/docs/docker)). Bind mounts must be readable (and storage writable) by that user.

The hub git clone often creates `config.yaml` as mode **660** (`operator:builtin_administrators`). uid 10001 then fails with `cannot open config file /verdaccio/conf/config.yaml`. Storage owned by anyone else fails with `EACCES` on `.sinopia-db.json`. After `git pull` / `reset --hard`, re-apply the chmod if `ls -ld config.yaml` is not other-readable.

```bash
sudo mkdir -p /mnt/HDDs/Alfa-AI/npm/storage
sudo chown -R 10001:65533 /mnt/HDDs/Alfa-AI/npm/storage
chmod a+r /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/npm-proxy/config.yaml
cd /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/npm-proxy
docker compose -f docker-compose.verdaccio.yml up -d
bash /mnt/HDDs/Alfa-AI/repo/alfa-ai/deploy/cluster-members/_common/wait-http.sh http://127.0.0.1:4873/-/ping 60
```

## Consume from builders

Set npm registry (CI-safe fallback remains npmjs by overriding):

```bash
export NPM_REGISTRY=${NPM_REGISTRY:-http://hub}
```

Dockerfiles use `npm ci --registry "${NPM_REGISTRY:-http://hub}"`.

If `hub` is unreachable during development, override:

```bash
NPM_REGISTRY=https://registry.npmjs.org docker compose build ...
```

## Private `@alfa-ai` scope (publish `@alfa-ai/chat-widget`)

The `config.yaml` (mounted into the container) defines the `@alfa-ai/*` scope as
private (not proxied) and requires an authenticated user to publish.

### One-time: create the publisher account

From any LAN host with npm (e.g. `apps` or `orchestrator`):

```bash
npm adduser --registry http://hub --scope @alfa-ai
```

This writes the token to `~/.npmrc`. After the account exists, you may set
`max_users: -1` in `config.yaml` and recreate the container to lock down
self-registration.

### Publish the chat widget

Build + publish from the alfa-ai repo (the package owner):

```bash
cd packages/chat-widget
npm ci --registry http://hub
npm run build
npm publish --registry http://hub
```

Or use the helper: `scripts/publish-chat-widget-to-verdaccio.sh`.

### Consume a private package in a build

Consumers set the registry for the `@alfa-ai` scope (in `.npmrc` or via
`--registry`); public deps still uplink through npmjs:

```
@alfa-ai:registry=http://hub
```

## SMB note

Verdaccio uses HTTP on LAN - expose firewall port **4873/tcp** from build hosts to `hub`.
