#!/usr/bin/env bash
# One-time on hub: push alfa-ai-app to local registry and write LAN secrets for remote workers.
# Remote hosts read /mnt/cluster/agent-worker-brain.env (NFS). chmod 600 on hub.
set -euo pipefail

REPO="${REPO_ROOT:-/mnt/hub/alfa-ai/repo/alfa-ai}"
ENV="${ALFA_AI_ENV_FILE:-${REPO}/deploy/.env}"

if [[ ! -f "${ENV}" ]]; then
  echo "ERROR: missing ${ENV}" >&2
  exit 1
fi

PG="$(grep -E '^POSTGRES_PASSWORD=' "${ENV}" | cut -d= -f2- | tr -d '\r')"
REDIS="$(grep -E '^REDIS_PASSWORD=' "${ENV}" | cut -d= -f2- | tr -d '\r')"
LIT="$(grep -E '^LITELLM_MASTER_KEY=' "${ENV}" | cut -d= -f2- | tr -d '\r')"

if [[ -z "${PG}" || -z "${REDIS}" || -z "${LIT}" ]]; then
  echo "ERROR: POSTGRES_PASSWORD, REDIS_PASSWORD, or LITELLM_MASTER_KEY empty in ${ENV}" >&2
  exit 1
fi

BH="$("${REPO}/scripts/docker_build_hash.sh")"
echo "BUILD_HASH=${BH}"

IMAGE_TAG="alfa-ai-app:${BH}"
sudo docker tag "${IMAGE_TAG}" alfa-ai-app:latest
HUB_IMG_DIR="/mnt/hub/alfa-ai/docker-images"
TARBALL="${HUB_IMG_DIR}/alfa-ai-app-latest.tar.gz"
TMP="${HUB_IMG_DIR}/.alfa-ai-app-latest.tar.gz.tmp"
mkdir -p "${HUB_IMG_DIR}"
echo "==> docker save ${IMAGE_TAG} -> ${TARBALL}"
sudo docker save "${IMAGE_TAG}" | gzip > "${TMP}"
mv "${TMP}" "${TARBALL}"
echo "published ${TARBALL}"

umask 077
OUT="/mnt/hub/alfa-ai/agent-worker-brain.env"
TMP_OUT="/tmp/agent-worker-brain.env.$$"
printf '%s\n' "POSTGRES_PASSWORD=${PG}" "REDIS_PASSWORD=${REDIS}" "LITELLM_MASTER_KEY=${LIT}" > "${TMP_OUT}"
chmod 600 "${TMP_OUT}"
sudo install -m 644 "${TMP_OUT}" "${OUT}"
rm -f "${TMP_OUT}"
echo "Wrote ${OUT}"
echo "bootstrap_agent_worker_brain OK"
