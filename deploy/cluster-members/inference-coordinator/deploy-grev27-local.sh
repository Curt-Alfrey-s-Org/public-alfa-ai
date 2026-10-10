#!/usr/bin/env bash
# SUPERSEDED (Phase H): use deploy-grev27-pool-shard.sh + hub switch-pool-27b.sh instead.
# Local dual-GPU :31358 OOM'd at runtime (~25-30 GB projected vs 18 GB VRAM).
#
# G-rev27: one-shot deploy Qwen3.6-27B on inference (:31358).
#
# Official phased load (multi-gpu.md):
#   Phase 1 -- RTX 3060 (12 GB, device 1) only: --split-mode none, --fit on (GPU + CPU spill).
#   Phase 2 -- RTX 3050 + 3060: --split-mode layer -ts 1,2, ngl/ctx from phase-1 --fit.
#
# No automatic retries. Any failure exits immediately.
# Load timers: LOAD_TIMEOUT_GPU1 (default 600s), LOAD_TIMEOUT_DUAL (default 900s).
# Official docs silent on 27B load duration; timeouts are cluster baseline for ~17 GB NFS mmap.
#
# Usage (on inference):
#   bash deploy/cluster-members/inference-coordinator/deploy-grev27-local.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_REPO_DIR:-$(cd "$SCRIPT_DIR/../../.." && pwd)}"
LLC="$REPO_DIR/deploy/llamacpp-rpc"
COMMON="$REPO_DIR/deploy/cluster-members/_common"
IMAGE='alfa-llamacpp-rpc:cuda128'
TARBALL='alfa-llamacpp-rpc-cuda128-b10355.tar.gz'
PREFLIGHT_CONTAINER='llamacpp-server-148-preflight-gpu1'
PROD_CONTAINER='llamacpp-server-148-local'

die() {
  echo "ERROR: $*" >&2
  exit 1
}

parse_fit_from_logs() {
  local container="$1"
  local log ngl ctx
  log="$(docker logs "$container" 2>&1)"
  ngl="$(printf '%s\n' "$log" | sed -n 's/.*offloaded \([0-9][0-9]*\)\/[0-9][0-9]* layers to GPU.*/\1/p' | tail -1)"
  ctx="$(printf '%s\n' "$log" | sed -n 's/.*llama_context: n_ctx         = \([0-9][0-9]*\).*/\1/p' | tail -1)"
  [[ -n "$ngl" ]] || return 1
  [[ -n "$ctx" ]] || return 1
  printf '%s %s\n' "$ngl" "$ctx"
}

stop_container() {
  local name="$1"
  docker stop "$name" 2>/dev/null || true
  docker rm -f "$name" 2>/dev/null || true
}

if [[ ! -d "$LLC" ]]; then
  die "missing $LLC (git pull or rsync deploy from inference)"
fi

bash "$SCRIPT_DIR/write-grev27-env.sh"

ENV_RPC="$LLC/.env.rpc"
# shellcheck disable=SC1090
source "$ENV_RPC"

MODEL_PATH="${MODELS_DIR}/${MODEL_FILE:-Qwen3.6-27B-Q4_K_M.gguf}"
[[ -f "$MODEL_PATH" ]] || die "GGUF missing at $MODEL_PATH (hub verify + NFS on hub first)"
echo "== GGUF present: $MODEL_PATH ($(du -h "$MODEL_PATH" | awk '{print $1}')) =="

for hub_root in /mnt/cluster/docker-images /mnt/hub/alfa-ai/docker-images; do
  tb="$hub_root/$TARBALL"
  if [[ -f "$tb" ]]; then
    echo "== docker load: $tb =="
    docker load -i "$tb"
    break
  fi
done
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "$IMAGE missing -- load hub tarball first"

echo "== stop stale llama / Code27 / Ollama =="
stop_container "$PREFLIGHT_CONTAINER"
stop_container "$PROD_CONTAINER"
docker stop llamacpp-rpc-148-gpu0 llamacpp-rpc-148-gpu1 llamacpp-server 2>/dev/null || true
docker rm -f llamacpp-rpc-148-gpu0 llamacpp-rpc-148-gpu1 llamacpp-server 2>/dev/null || true
if [[ -f "$LLC/docker-compose.rpc-serverinference-code27.yml" ]]; then
  (cd "$LLC" && docker compose -f docker-compose.rpc-serverinference-code27.yml down --remove-orphans 2>/dev/null) || true
fi
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet ollama 2>/dev/null; then
  echo "== stop Ollama (free GPUs) =="
  sudo systemctl stop ollama
fi

mkdir -p "$LLC/slot-cache-148"
cd "$LLC"

COMPOSE_BASE=(docker compose --env-file .env.rpc -f docker-compose.rpc-main.yml)
COMPOSE_LOAD=(-f docker-compose.rpc-main.grev27-load.yml)

# --- Phase 1: 3060 (12 GB) preflight ---
echo ""
echo "== Phase 1: preflight RTX 3060 (12 GB) only, port ${PREFLIGHT_PORT:-31359} =="
echo "   timeout ${LOAD_TIMEOUT_GPU1:-600}s (official docs silent; cluster baseline)"
"${COMPOSE_BASE[@]}" \
  -f docker-compose.rpc-main.grev27-preflight-gpu1.yml \
  "${COMPOSE_LOAD[@]}" \
  up -d --no-build --force-recreate --remove-orphans

if ! bash "$COMMON/wait-http.sh" "http://127.0.0.1:${PREFLIGHT_PORT:-31359}/health" "${LOAD_TIMEOUT_GPU1:-600}" 10; then
  echo "== Phase 1 FAILED -- container logs ==" >&2
  docker logs --tail 40 "$PREFLIGHT_CONTAINER" 2>&1 || true
  stop_container "$PREFLIGHT_CONTAINER"
  die "3060 preflight did not reach /health within ${LOAD_TIMEOUT_GPU1:-600}s"
fi

read -r N_GPU_LAYERS CTX_SIZE < <(parse_fit_from_logs "$PREFLIGHT_CONTAINER") || {
  docker logs --tail 60 "$PREFLIGHT_CONTAINER" 2>&1 || true
  stop_container "$PREFLIGHT_CONTAINER"
  die "could not parse --fit n-gpu-layers / ctx from phase-1 logs"
}
echo "== Phase 1 OK: 3060 preflight healthy (fit ngl=${N_GPU_LAYERS} ctx=${CTX_SIZE}) =="
export N_GPU_LAYERS CTX_SIZE
grep -q '^N_GPU_LAYERS=' "$ENV_RPC" && sed -i "s/^N_GPU_LAYERS=.*/N_GPU_LAYERS=${N_GPU_LAYERS}/" "$ENV_RPC" || echo "N_GPU_LAYERS=${N_GPU_LAYERS}" >>"$ENV_RPC"
grep -q '^CTX_SIZE=' "$ENV_RPC" && sed -i "s/^CTX_SIZE=.*/CTX_SIZE=${CTX_SIZE}/" "$ENV_RPC" || echo "CTX_SIZE=${CTX_SIZE}" >>"$ENV_RPC"
stop_container "$PREFLIGHT_CONTAINER"

# --- Phase 2: dual-GPU layer split + CPU spill ---
echo ""
echo "== Phase 2: dual-GPU layer split (-ts 1,2) + CPU spill, port ${MAIN_PORT:-31358} =="
echo "   timeout ${LOAD_TIMEOUT_DUAL:-900}s"
"${COMPOSE_BASE[@]}" \
  -f docker-compose.rpc-main.local-dual-gpu.yml \
  "${COMPOSE_LOAD[@]}" \
  up -d --no-build --force-recreate --remove-orphans

if ! bash "$COMMON/wait-http.sh" "http://127.0.0.1:${MAIN_PORT:-31358}/health" "${LOAD_TIMEOUT_DUAL:-900}" 10; then
  echo "== Phase 2 FAILED -- container logs ==" >&2
  docker logs --tail 40 "$PROD_CONTAINER" 2>&1 || true
  stop_container "$PROD_CONTAINER"
  die "dual-GPU server did not reach /health within ${LOAD_TIMEOUT_DUAL:-900}s"
fi

echo ""
echo "G-rev27 OK. LiteLLM frontier-code -> http://orchestrator:${MAIN_PORT:-31358}/v1"
curl -fsS "http://127.0.0.1:${MAIN_PORT:-31358}/v1/models" | head -c 400
echo ""
