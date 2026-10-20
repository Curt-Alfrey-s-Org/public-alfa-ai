#!/usr/bin/env bash
set -euo pipefail

# Deploy script for hub (hub Scale 25.04, hub).
#
# CLUSTER: hub is the MAIN BRAIN + llama.cpp RPC coordinator host +
# cluster artifact hub. **No sub-frontier chat LLM on hub** (June 2026 -- 30B MoE
# retired; hub runs no chat LLM). CPU chat is the
# two-host pool: qwen3.5:27b on gaming-c (quality) + qwen3.6:35b-a3b on orchestrator (speed).
# See deploy/.env + litellm_config.yaml on this host.
#   - Docker registry mirror (:5000) - pull-through for LAN
#   - NFS + SMB exports of /mnt/hub/alfa-ai (configured via hub UI)
#
# Does NOT run on hub:
#   - Websites / bots (live on apps)
#
# Dedicated protected DB stacks on hub:
#   postgres (docker-compose.postgres.yml) and redis (docker-compose.redis.yml)
#   declared in stackshub.yml. These are brought up BEFORE the brain stack.
#   They own the data volumes and provide alfa-postgres / alfa-redis for DNS.
#   Cluster stop never downs them.
#
# Prereqs before running this:
#   - Ollama App removed from hub entirely (2026-07-05) -- no hot storage
#     dataset needed for it anymore (see docs/ROADMAP.md "auxiliary CPU roles").
#   - Optional: dedicated NVMe data pool /mnt/nvme for Docker root (if not using boot-only NVMe).
#   - ZFS ARC capped (NVMe doc section 7).
#   - Dedicated DB stacks (postgres, redis) reachable (loopback or via shared net).
#   - deploy/.env configured (see docs/DOCKGE_111_OPERATOR.md section "First-
#     time setup") with:
#       ALFA_AI_API_HOST_PORT=8420
#       ALFA_AI_LITELLM_HOST_PORT=8413
#       OLLAMA_FLEET_59_URL=http://orchestrator   # CPU chat quality (qwen3.5:27b)
#       OLLAMA_FLEET_93_URL=http://orchestrator   # CPU chat speed (qwen3.6:35b-a3b)
#       # DBs via dedicated stacks (defaults now point at alfa-postgres/alfa-redis on shared net):
#       # DATABASE_URL=postgresql://alfaai@alfa-postgres:5432/alfaai
#       # REDIS_URL=redis://alfa-redis:6379/0
#       LITELLM_MASTER_KEY=<openssl rand -hex 32; set only in deploy/.env>
#       ALFA_WORKER_HEARTBEAT_TOKEN=<same as every worker; deploy/.env only>
#       # Optional for hub DB stacks network alignment:
#       # ALFA_SHARED_DOCKER_NETWORK=alfa-ai-network
#     LiteLLM Prisma migrations (audit LITELLM-006 / backlog #23): only one LiteLLM instance per
#     shared Postgres may own migrations — set USE_PRISMA_MIGRATE=True in deploy/.env on hub and
#     DISABLE_SCHEMA_UPDATE=true on any secondary LiteLLM host (e.g. apps-105 env.apps).
#     LiteLLM Prisma migrations (audit LITELLM-006 / backlog #23): only one LiteLLM instance per
#     shared Postgres may own migrations — set USE_PRISMA_MIGRATE=True in deploy/.env on hub and
#     DISABLE_SCHEMA_UPDATE=true on any secondary LiteLLM host (e.g. apps-105 env.apps).
#
# Usage (SSH to hub as root):
#   sudo bash deploy.sh
#   sudo bash deploy.sh --skip-pull      # skip git pull
#   sudo bash deploy.sh --skip-images    # skip docker image import
#   sudo bash deploy.sh --registry-only  # just the registry mirror (no brain)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="/mnt/hub/alfa-ai/repo/alfa-ai"
DEPLOY_DIR="$REPO_DIR/deploy"
CLUSTER_COMMON="$REPO_DIR/deploy/cluster/_common"
HUB_ROOT="/mnt/hub/alfa-ai"
# Default main; production may track rebalance branch — see docs/DOCUMENTATION_CANONICAL.md
GIT_BRANCH="${GIT_BRANCH:-main}"

SKIP_PULL=0
SKIP_IMAGES=0
REGISTRY_ONLY=0
LITELLM_HOST_PORT="${ALFA_AI_LITELLM_HOST_PORT:-8413}"
ENV_FILE="$DEPLOY_DIR/.env"
if [[ -f "$ENV_FILE" ]]; then
  _p="$(grep -E '^ALFA_AI_LITELLM_HOST_PORT=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r')"
  [[ -n "$_p" ]] && LITELLM_HOST_PORT="$_p"
  unset _p
fi

for arg in "$@"; do
  case "$arg" in
    --skip-pull)     SKIP_PULL=1 ;;
    --skip-images)   SKIP_IMAGES=1 ;;
    --registry-only) REGISTRY_ONLY=1 ;;
    -h|--help)       sed -n '1,50p' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)               echo "Unknown: $arg" >&2; exit 1 ;;
  esac
done

echo "== ALFa AI Cluster Deploy: hub hub (brain + agent + hub) =="
echo "  Repo:    $REPO_DIR"
echo "  Hub:     $HUB_ROOT"
echo ""

# hub SSH accounts often lack /var/run/docker.sock access unless they are in
# the `docker` group. Try plain docker first, then sudo docker (matches DOCKGE doc).
docker_wrap() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  elif sudo docker info >/dev/null 2>&1; then
    sudo docker "$@"
  else
    echo "ERROR: cannot access Docker (permission denied on /var/run/docker.sock)." >&2
    echo "  Fix one of:" >&2
    echo "    sudo usermod -aG docker \"\$USER\"   # then log out and back in" >&2
    echo "    sudo bash ${BASH_SOURCE[0]} $*" >&2
    exit 1
  fi
}

# Dockge (hub Apps :31014) lists stacks under DOCKGE_STACKS_DIR.
# hub root is read-only — use the Apps dataset, not /opt/stacks.
STACKS_DIR="${ALFA_DOCKGE_STACKS_DIR:-/mnt/HDDs/apps/Dockge}"
alfa_dockge_symlink_stack() {
  local name="$1" target="$2"
  mkdir -p "$STACKS_DIR" 2>/dev/null || sudo mkdir -p "$STACKS_DIR" 2>/dev/null || true
  if [[ -d "$STACKS_DIR" ]]; then
    ln -sfn "$target" "$STACKS_DIR/$name" 2>/dev/null \
      || sudo ln -sfn "$target" "$STACKS_DIR/$name" 2>/dev/null \
      || echo "  WARN: could not symlink $STACKS_DIR/$name"
  fi
}
alfa_compose_cwd() {
  local name="$1" fallback="$2"
  if [[ -L "$STACKS_DIR/$name" ]]; then
    echo "$STACKS_DIR/$name"
  else
    echo "$fallback"
  fi
}

# --- 0. Preflight: nvidia-smi + LAN registry mirror (this host hosts it) -----
if [[ -f "$CLUSTER_COMMON/nvidia_preflight.sh" ]]; then
    # shellcheck source=/dev/null
    source "$CLUSTER_COMMON/nvidia_preflight.sh"
    # Brain role expects a GPU for Ollama tier 0/1; still non-fatal if missing so
    # the registry mirror path can come up on a GPU-less rescue boot.
    ALFA_ROLE=brain alfa_nvidia_preflight --role brain || \
        echo "WARN: nvidia preflight returned non-zero (continuing)"
fi

if [[ -f "$CLUSTER_COMMON/configure-docker-mirror.sh" ]]; then
    ALFA_REGISTRY_MIRROR="http://hub" \
        bash "$CLUSTER_COMMON/configure-docker-mirror.sh" || \
        echo "WARN: mirror configuration skipped"
fi

# --- 1. Git sync (as clone owner; not root -- root has no GitHub SSH key) ----
GIT_SYNC="$REPO_DIR/deploy/cluster-members/_common/git-sync-repo-clone.sh"
if [[ "$SKIP_PULL" -eq 0 ]] && [[ -d "$REPO_DIR/.git" ]]; then
  echo "== 1. Git sync =="
  if [[ -f "$GIT_SYNC" ]]; then
    bash "$GIT_SYNC" "$REPO_DIR" "$GIT_BRANCH" 2>&1 || \
      echo "WARN: git sync failed. As operator: bash $GIT_SYNC"
  else
    (cd "$REPO_DIR" && git pull --ff-only origin "$GIT_BRANCH" 2>&1) || \
      echo "WARN: git pull failed. Resolve manually."
  fi
  echo ""
fi

# --- 2. Load Docker images ---------------------------------------------------
if [[ "$SKIP_IMAGES" -eq 0 ]]; then
  echo "== 2. Loading Docker images from hub =="
  # Canonical location after April 2026 is $HUB_ROOT/docker/images
  # (see docs/CLUSTER_SHARED_STORAGE.md section 1). Fall back to legacy
  # /mnt/hub/alfa-ai-cluster/docker-images if that symlink is still there.
  IMAGES_DIR="$HUB_ROOT/docker/images"
  if [[ ! -d "$IMAGES_DIR" ]]; then
    IMAGES_DIR="$HUB_ROOT/docker-images"
  fi
  if [[ -d "$IMAGES_DIR" ]] && ls "$IMAGES_DIR"/*.tar.gz &>/dev/null 2>&1; then
    for tb in "$IMAGES_DIR"/*.tar.gz; do
      echo "  Loading $(basename "$tb") ..."
      docker_wrap load < <(gunzip -c "$tb") 2>&1 | tail -1
    done
  else
    echo "  No image tarballs in $IMAGES_DIR; relying on registry mirror + build"
  fi
  echo ""
fi

# --- 3. Registry mirror (pull-through proxy for the whole cluster) -----------
echo "== 3. Docker registry mirror =="
REGISTRY_COMPOSE="$SCRIPT_DIR/docker-compose.registry.yml"
if [[ -f "$REGISTRY_COMPOSE" ]]; then
    alfa_dockge_symlink_stack alfa-registry "$SCRIPT_DIR"
    cd "$(alfa_compose_cwd alfa-registry "$SCRIPT_DIR")"
    docker_wrap compose -f docker-compose.registry.yml up -d 2>&1 | sed 's/^/  /' || \
        echo "  WARN: registry mirror compose up failed"
    echo "  mirror: http://hub/ (every LAN dockerd should"
    echo "  list this in /etc/docker/daemon.json registry-mirrors)"
else
    echo "  SKIP: $REGISTRY_COMPOSE not found"
fi
echo ""

if [[ "$REGISTRY_ONLY" -eq 1 ]]; then
  echo "== --registry-only given; stopping here =="
  exit 0
fi

# --- 4. Ensure tunnel_network exists ----------------------------------------
echo "== 4. Docker networks =="
if ! docker_wrap network inspect tunnel_network >/dev/null 2>&1; then
  echo "  Creating tunnel_network (external shared ingress)"
  docker_wrap network create tunnel_network
else
  echo "  tunnel_network exists"
fi
echo ""

# --- 4b. LiteLLM image cosign verify ----------------------------------------
# Audit LITELLM-001 (docs/audit/audit-findings.md): every BerriAI stable release
# ships with a Sigstore-keyless cosign signature. Verify the pinned image before
# bringing up the brain stack. The expected tag is read from docker-compose.yml
# so this guard catches operator drift (someone editing the pin without bumping
# the cosign cadence).
echo "== 4b. LiteLLM image cosign verify =="
LITELLM_EXPECTED_TAG="$(grep -oE 'ghcr\.io/berriai/litellm:[A-Za-z0-9._-]+' "$DEPLOY_DIR/docker-compose.yml" | head -1)"
echo "  expected: $LITELLM_EXPECTED_TAG"
if command -v cosign >/dev/null 2>&1; then
  if cosign verify "$LITELLM_EXPECTED_TAG" \
       --certificate-identity-regexp '^https://github\.com/BerriAI/litellm/' \
       --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
       >/dev/null 2>&1; then
    echo "  cosign: OK (Sigstore keyless verified)"
  else
    echo "  cosign: FAIL — signature could not be verified."
    echo "          Refusing to bring up the brain stack with an unverified image."
    echo "          Bump the pinned tag in deploy/docker-compose.yml to the current"
    echo "          BerriAI weekly stable and re-run, or set ALFA_AI_SKIP_COSIGN=1"
    echo "          to override (NOT recommended in production)."
    if [[ "${ALFA_AI_SKIP_COSIGN:-0}" != "1" ]]; then
      exit 1
    fi
    echo "  cosign: SKIPPED (ALFA_AI_SKIP_COSIGN=1)"
  fi
else
  echo "  cosign: SKIPPED (binary not installed)."
  echo "          Install via: go install github.com/sigstore/cosign/v2/cmd/cosign@latest"
  echo "          or download from https://github.com/sigstore/cosign/releases"
  echo "          Skipping the audit-recommended supply-chain check."
fi
echo ""

# --- 4c. API ownership — systemd vs Compose (audit CROSS-RULE-007) ----------
echo "== 4c. API ownership preflight =="
if [[ -f "$REPO_DIR/scripts/preflight_api_ownership.sh" ]]; then
  bash "$REPO_DIR/scripts/preflight_api_ownership.sh" compose-will-manage-api || exit 1
  echo "  OK (Compose may publish alfa-ai-api — systemd unit not active)"
else
  echo "  WARN: $REPO_DIR/scripts/preflight_api_ownership.sh missing — skipping guard"
fi
echo ""

# --- 5. Bring up the brain stack --------------------------------------------
ENV_FILE="$DEPLOY_DIR/.env"
if [[ ! -f "$ENV_FILE" ]]; then
  echo "ERROR: $ENV_FILE missing. Create deploy/.env on this host (gitignored)."
  echo "       See docs/DOCKGE_111_OPERATOR.md section 'Configure deploy/.env'"
  exit 1
fi

# --- Dedicated protected DB stacks (before brain) ----------------------------
# These own the DB containers/volumes and are excluded from cluster stop.
# They must be up (and healthy) before brain services that depend on them.
echo "== Dedicated DB stacks (postgres, redis) =="

# Ensure the shared network that DBs and brain will use for DNS.
# (On hub this is typically alfa-ai-network so alfa-postgres/alfa-redis resolve.)
ALFA_SHARED_DOCKER_NETWORK="${ALFA_SHARED_DOCKER_NETWORK:-alfa-ai-network}"
export ALFA_SHARED_DOCKER_NETWORK
if ! docker_wrap network inspect "$ALFA_SHARED_DOCKER_NETWORK" >/dev/null 2>&1; then
  echo "  Creating $ALFA_SHARED_DOCKER_NETWORK (for dedicated DBs + brain)"
  docker_wrap network create --driver bridge "$ALFA_SHARED_DOCKER_NETWORK" 2>&1 | sed 's/^/  /' || true
fi

# Export LAN bind vars for optional merge compose files (dual loopback + LAN publish).
set -a
# shellcheck source=/dev/null
source "$ENV_FILE"
set +a
# shellcheck source=scripts/_brain_db_compose_args.sh
source "$REPO_DIR/scripts/_brain_db_compose_args.sh"

# Postgres dedicated stack
alfa_dockge_symlink_stack postgres "$DEPLOY_DIR"
cd "$(alfa_compose_cwd postgres "$DEPLOY_DIR")"
echo "  up dedicated postgres stack (protected infra)..."
docker_wrap compose --env-file "$ENV_FILE" "${POSTGRES_COMPOSE_ARGS[@]}" up -d --wait 2>&1 | sed 's/^/  /' || \
  echo "  WARN: dedicated postgres up had issues (continuing)"

# Redis dedicated stack
alfa_dockge_symlink_stack redis "$DEPLOY_DIR"
cd "$(alfa_compose_cwd redis "$DEPLOY_DIR")"
echo "  up dedicated redis stack (protected infra)..."
docker_wrap compose --env-file "$ENV_FILE" "${REDIS_COMPOSE_ARGS[@]}" up -d --wait 2>&1 | sed 's/^/  /' || \
  echo "  WARN: dedicated redis up had issues (continuing)"

echo ""

# Return to deploy dir for brain
cd "$DEPLOY_DIR"

echo "== 5. Brain stack: alfa-ai API + LiteLLM + nginx =="
alfa_dockge_symlink_stack alfa-ai "$DEPLOY_DIR"
cd "$(alfa_compose_cwd alfa-ai "$DEPLOY_DIR")"

# External network required by alfa-ai-api and alfa-ai-nginx (tunnel attachment).
if ! docker_wrap network inspect tunnel_network >/dev/null 2>&1; then
  echo "  Creating Docker network tunnel_network..."
  docker_wrap network create tunnel_network 2>&1 | sed 's/^/  /' || {
    echo "ERROR: could not create tunnel_network"
    exit 1
  }
fi

# Port preflight (non-fatal if Ollama binds 11434 as a hub App)
if [[ -x "$REPO_DIR/scripts/preflight_ports.sh" ]]; then
  "$REPO_DIR/scripts/preflight_ports.sh" "$ENV_FILE" --allow-in-use || true
fi

# Brain stack via shared helpers (litellm, api, nginx -- DBs are in dedicated protected stacks).
_ALFA_SCRIPT_DIR="$REPO_DIR/scripts"
SCRIPT_DIR="$_ALFA_SCRIPT_DIR"
# shellcheck source=/dev/null
source "$_ALFA_SCRIPT_DIR/_alfa_compose_env.sh"

alfa_compose_build_api_if_needed || exit 1
alfa_compose_brain_up || exit 1
unset _ALFA_SCRIPT_DIR
echo ""

# --- 5b. Postgres nightly backup sidecar (ROADMAP Phase 3 / audit PG-005) ----
# pg_dump -Fc + verify + 7 daily / 4 weekly rotation onto the canonical HDD
# hub tier. Separate compose project. Targets dedicated protected postgres stack
# (container 'alfa-postgres' from docker-compose.postgres.yml). Network must match
# the dedicated DB stack (ALFA_SHARED_DOCKER_NETWORK or alfa-ai-network).
# Runbook: docs/operations/POSTGRES_BACKUP_RESTORE_111.md
echo "== 5b. Postgres backup sidecar =="
BACKUP_COMPOSE="$DEPLOY_DIR/docker-compose.postgres-backup.yml"
if [[ -f "$BACKUP_COMPOSE" ]]; then
  BACKUP_HOST_DIR="$(grep -E '^ALFA_AI_BACKUP_HOST_DIR=' "$ENV_FILE" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r')"
  BACKUP_HOST_DIR="${BACKUP_HOST_DIR:-/mnt/hub/alfa-ai/backups/postgres}"
  mkdir -p "$BACKUP_HOST_DIR" 2>/dev/null || sudo mkdir -p "$BACKUP_HOST_DIR" 2>/dev/null || \
    echo "  WARN: could not create $BACKUP_HOST_DIR (compose bind will create it root-owned)"
  docker_wrap compose --env-file "$ENV_FILE" -f "$BACKUP_COMPOSE" up -d 2>&1 | sed 's/^/  /' || \
    echo "  WARN: postgres backup sidecar compose up failed (brain stack unaffected)"
  echo "  backups land in $BACKUP_HOST_DIR (daily/ weekly/ globals/ metrics/)"
else
  echo "  SKIP: $BACKUP_COMPOSE not found"
fi
echo ""

# --- 6. Ollama sanity check --------------------------------------------------
# Ollama App was removed from hub entirely on 2026-07-05 (operator_internal
# routes to the RPC pool now; see docs/ROADMAP.md "auxiliary CPU roles").
# hub is expected to have NO Ollama listening on :11434 going forward.
echo "== 6. Ollama sanity (hub expects NONE) =="
if curl -fsS --max-time 5 http://127.0.0.1:11434/api/tags >/dev/null; then
  echo "  WARN: Ollama reachable on :11434 but hub should run no Ollama App -- investigate stray install"
  curl -fsS http://127.0.0.1:11434/api/tags | \
    python3 -c 'import sys,json; d=json.load(sys.stdin); print("  models:", ", ".join(m["name"] for m in d.get("models",[])))' \
    2>/dev/null || true
else
  echo "  OK: no Ollama on :11434 (expected)"
fi
echo ""

# --- 7. Smoke (brain_verify: deps + API + LiteLLM + nginx + 27B coordinator) -
echo "== 7. Brain verify (full stack + G-rev27) =="
_COMMON_WAIT="$REPO_DIR/deploy/cluster-members/_common"
if [[ -x "$REPO_DIR/scripts/brain_verify.sh" ]]; then
  bash "$REPO_DIR/scripts/brain_verify.sh" || {
    echo "ERROR: brain_verify failed -- fix stack before declaring deploy OK"
    exit 1
  }
else
  echo "  WARN: scripts/brain_verify.sh missing -- falling back to legacy smoke"
  if [[ -x "$_COMMON_WAIT/wait-litellm-liveliness.sh" ]]; then
    bash "$_COMMON_WAIT/wait-litellm-liveliness.sh" 120 || exit 1
  fi
  if [[ -x "$_COMMON_WAIT/wait-brain-health.sh" ]]; then
    bash "$_COMMON_WAIT/wait-brain-health.sh" 120 || exit 1
  fi
fi
echo -n "  registry /v2/ ... "
curl -fsS --max-time 5 http://127.0.0.1:5000/v2/ >/dev/null && echo OK || echo WARN
unset _COMMON_WAIT
echo ""

# --- 8. Summary --------------------------------------------------------------
echo "== hub (hub) brain deploy complete =="
echo ""
echo "  Host role:  Main brain + artifact hub (no chat LLM on :11434)"
echo "  CPU chat:   gaming-c qwen3.5:27b (quality) + orchestrator qwen3.6:35b-a3b (speed) -- not on hub"
echo "  RAM:        48 GB DDR5    (ARC capped; see hub_111_NVME_POOL.md)"
echo "  HDD hub:    /mnt/hub/alfa-ai (NFS, SMB, registry mirror, HF cache)"
echo ""
echo "  Brain API:  http://hub"
echo "  LiteLLM:    http://hub:${LITELLM_HOST_PORT}"
echo "  Registry:   http://hub"
echo "  Dockge:     http://hub (hub Apps)"
echo ""
echo "  Register on orchestrator primary Dockge (http://127.0.0.1:5002):"
echo "    Settings -> Remote agents -> http://hub"
echo ""
