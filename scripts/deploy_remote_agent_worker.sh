#!/usr/bin/env bash
# Deploy alfa-ai-worker on a Linux member using hub NFS secrets + member compose overlay.
# Usage: bash scripts/deploy_remote_agent_worker.sh <member-dir>
# Example: bash scripts/deploy_remote_agent_worker.sh deploy/cluster-members/apps
set -euo pipefail

MEMBER_DIR="${1:?usage: deploy_remote_agent_worker.sh <member-dir>}"
if [[ -f "${MEMBER_DIR}/docker-compose.agent-worker.yml" ]]; then
  WORKDIR="$(cd "${MEMBER_DIR}" && pwd)"
else
  REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
  WORKDIR="${REPO_ROOT}/${MEMBER_DIR}"
fi
SECRETS="/mnt/cluster/agent-worker-brain.env"

if [[ ! -d "${WORKDIR}" ]]; then
  echo "ERROR: missing ${WORKDIR}" >&2
  exit 1
fi
if [[ ! -f "${WORKDIR}/env.agent-worker.example" ]]; then
  echo "ERROR: missing env.agent-worker.example in ${WORKDIR}" >&2
  exit 1
fi
if [[ ! -f "${SECRETS}" ]]; then
  echo "ERROR: missing ${SECRETS} (run bootstrap_agent_worker_brain.sh on hub first)" >&2
  exit 1
fi

# shellcheck source=/dev/null
set -a
source "${SECRETS}"
set +a

python3 - "${WORKDIR}" <<'PY'
import os
import sys
from pathlib import Path
from urllib.parse import quote_plus

workdir = Path(sys.argv[1])
example = workdir / "env.agent-worker.example"
out = workdir / ".env.agent-worker"
pg = quote_plus(os.environ["POSTGRES_PASSWORD"])
redis = quote_plus(os.environ["REDIS_PASSWORD"])
lit = os.environ["LITELLM_MASTER_KEY"]
lines = []
for raw in example.read_text().splitlines():
    if raw.startswith("DATABASE_URL="):
        lines.append(f"DATABASE_URL=postgresql://alfaai@hub/alfaai")
    elif raw.startswith("REDIS_URL="):
        lines.append(f"REDIS_URL=redis://hub/0")
    elif raw.startswith("LITELLM_API_KEY="):
        lines.append(f"LITELLM_API_KEY={lit}")
    else:
        lines.append(raw)
out.write_text("\n".join(lines) + "\n")
os.chmod(out, 0o600)
print(f"wrote {out}")
PY

# Export for compose variable substitution into container environment block.
set -a
source "${WORKDIR}/.env.agent-worker"
set +a
export ALFA_AI_APP_IMAGE=alfa-ai-app:latest

cd "${WORKDIR}"
TARBALL="/mnt/cluster/docker-images/alfa-ai-app-latest.tar.gz"
if ! docker image inspect alfa-ai-app:latest >/dev/null 2>&1; then
  if [[ ! -f "${TARBALL}" ]]; then
    echo "ERROR: missing image and ${TARBALL}" >&2
    exit 1
  fi
  echo "==> docker load -i ${TARBALL}"
  docker load -i "${TARBALL}"
fi
if ! docker image inspect alfa-ai-app:latest >/dev/null 2>&1; then
  LOADED_REF="$(docker images --format '{{.Repository}}:{{.Tag}}' | grep -m1 '^alfa-ai-app:' || true)"
  if [[ -z "${LOADED_REF}" ]]; then
    echo "ERROR: no alfa-ai-app image after load" >&2
    exit 1
  fi
  docker tag "${LOADED_REF}" alfa-ai-app:latest
fi
sed -i 's|^ALFA_AI_APP_IMAGE=.*|ALFA_AI_APP_IMAGE=alfa-ai-app:latest|' "${WORKDIR}/.env.agent-worker"
export ALFA_AI_APP_IMAGE=alfa-ai-app:latest
docker compose -f docker-compose.agent-worker.yml up -d --force-recreate

HOST_ID="$(grep -E '^ALFA_AI_WORKER_HOST=' .env.agent-worker | cut -d= -f2- | tr -d '\r')"
echo "== logs alfa-ai-worker-${HOST_ID} =="
docker logs "alfa-ai-worker-${HOST_ID}" --tail 10 2>&1 || docker logs alfa-ai-worker --tail 10 2>&1
echo "deploy_remote_agent_worker OK host=${HOST_ID}"
