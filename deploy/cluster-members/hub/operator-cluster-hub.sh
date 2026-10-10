#!/usr/bin/env bash
# Single hub operator entry for orchestrator Start-Stop-AlfaAi.ps1 paste blocks.
#
# Run as operator on hub (script calls sudo where Docker needs root):
#   bash /mnt/hub/alfa-ai/repo/alfa-ai/deploy/cluster-members/hub/operator-cluster-111.sh stop
#     (internally uses --app-only so dedicated postgres/redis stacks stay up)
#   bash .../operator-cluster-111.sh start-pool   # switch-pool-27b + 3050 shard + CPU coordinator
#   bash .../operator-cluster-111.sh start-pool72 # exclusive Qwen2.5-72B Q5 (docs/GREV72_72B_OPERATOR.md)
#   bash .../operator-cluster-111.sh start-pool80 # exclusive Coder-Next 80B Q5 (docs/GREV80_80B_OPERATOR.md)
#   bash .../operator-cluster-111.sh start-pool35 # switch-pool-35b + CPU coordinator (shared shards)
#   bash /mnt/hub/alfa-ai/repo/alfa-ai/deploy/cluster-members/hub/operator-cluster-111.sh start-brain
#   bash .../operator-cluster-111.sh tail-logs
#   inference_LOG_SESSION_ID=... bash .../operator-cluster-111.sh start-error-logs  # step 0 (Start-Stop-AlfaAi.ps1)
#   inference_LOG_SESSION_ID=... bash .../operator-cluster-111.sh stop-error-logs   # end of cycle / replace recorder
#   inference_LOG_SESSION_ID=... bash .../operator-cluster-111.sh record-logs      # optional live foreground tail
#   bash .../operator-cluster-111.sh repair-rerank   # DEPRECATED - RAG on pool-opt-in; use operator-cluster-100.sh start-rag
#   bash .../operator-cluster-111.sh repair-shard    # redeploy RTX 3050 inference shard (:31353) if wedged/unreachable
#   bash .../operator-cluster-111.sh install-keep-warm   # cron: localhost LiteLLM every 15 min
#
# restart-shard is an alias for repair-shard.
#
# Env:
#   ALFA_AI_REPO   repo root (default /mnt/hub/alfa-ai/repo/alfa-ai)
#   SKIP_PULL=1    skip git pull (orchestrator --SkipPull)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="${ALFA_AI_REPO:-/mnt/hub/alfa-ai/repo/alfa-ai}"
COMMON="$REPO_DIR/deploy/cluster-members/_common"
LLC="$REPO_DIR/deploy/llamacpp-rpc"
ENV_RPC="$LLC/.env.rpc"

usage() {
  sed -n '1,12p' "$0" | tail -n +2
  exit 1
}

# hub sudo resets the caller env; pass inference session vars explicitly.
sudo_inference_log_env() {
  # Avoid hub `env` shim; pass vars directly on sudo (see inference-log-helpers PATH).
  sudo \
    ALFA_AI_REPO="${REPO_DIR}" \
    inference_LOG_SESSION_ID="${inference_LOG_SESSION_ID}" \
    HOST_LABEL=111 \
    PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
    "$@"
}

# Restore ownership of paths that runtime containers rewrite as root, so a
# non-root git reset --hard does not fail with "unable to unlink ...: Permission
# denied". The aria2-pro container (PUID=0) chowns its bind-mounted config tree;
# config/ is git-ignored runtime (template: deploy/aria2/config.example/), but a
# root-owned config/ dir still blocks git from managing the working tree.
# See deploy/aria2/README.md and docs/CLUSTER_START_STOP_OPERATOR.md.
restore_container_owned_paths() {
  local aria2_config="$REPO_DIR/deploy/aria2/config"
  if [[ -d "$aria2_config" ]] && [[ ! -w "$aria2_config" ]]; then
    echo "== restoring ownership of container-managed deploy/aria2/config =="
    sudo chown -R "$(id -un)":"$(id -gn)" "$aria2_config" 2>/dev/null || true
  fi
}

pull_repo() {
  if [[ "${SKIP_PULL:-0}" == "1" ]]; then
    echo "== git pull skipped (SKIP_PULL=1) =="
    return 0
  fi
  if [[ ! -d "$REPO_DIR/.git" ]]; then
    echo "ERROR: not a git repo: $REPO_DIR" >&2
    exit 1
  fi
  echo "== git sync (fetch + reset --hard origin/main) =="
  cd "$REPO_DIR"
  restore_container_owned_paths
  local sync="$REPO_DIR/deploy/cluster-members/_common/sync-git-origin-hub-lan.sh"
  if [[ -f "$sync" ]]; then
    bash "$sync" "$REPO_DIR"
    git clean -fd
  else
    git fetch origin main
    git clean -fd
    git reset --hard origin/main
  fi
}

cmd_stop() {
  # A stop must always tear the cluster down. Git sync is best-effort here: if it
  # fails (permissions, offline remote, dirty tree), warn and continue - never let
  # a code-sync problem block a teardown. start-pool/start-brain keep pull_repo fatal
  # so the pool never comes up on stale code.
  pull_repo || echo "WARN: git sync failed; continuing stop (teardown must proceed)"
  echo "== scripts/stop.sh --app-only (dedicated postgres/redis stacks are protected; never downed) =="
  sudo bash "$REPO_DIR/scripts/stop.sh" --app-only
  echo "== inference-stop-local.sh =="
  sudo HOST_LABEL=111 bash "$COMMON/inference-stop-local.sh"
  echo "== stop-rag-sidecars (hub RAG sidecars; canonical embed/rerank on pool-opt-in via orchestrator orchestrator) =="
  sudo HOST_LABEL=111 bash "$COMMON/stop-rag-sidecars.sh"
  echo "== operator-cluster-111 stop complete =="
}

cmd_start_pool() {
  pull_repo
  # Orchestrator syncs inference-shards.active.env from orchestrator before start-pool.
  # Default to committed core-only list when active file is absent.
  local shards_file="${inference_SHARDS_FILE:-$REPO_DIR/deploy/llamacpp-rpc/inference-shards.active.env}"
  if [[ ! -f "$shards_file" ]]; then
    shards_file="$REPO_DIR/deploy/llamacpp-rpc/inference-shards.env"
  fi
  export inference_SHARDS_FILE="$shards_file"
  echo "== inference shard list: $inference_SHARDS_FILE =="
  echo "== promote RPC tarball to NVMe/SSD (permanent fast path) =="
  sudo bash "$SCRIPT_DIR/promote-rpc-image-to-nvme.sh" || \
    echo "WARN: NVMe/SSD promote skipped (dataset missing?); load will use HDD hub" >&2
  echo "== promote 27B GGUF to SSD/NVMe (HDD archive only) inference_MODEL_FILE=${inference_MODEL_FILE:-Qwen3.8-27B-Q8_0.gguf} =="
  sudo inference_MODEL_FILE="${inference_MODEL_FILE:-Qwen3.8-27B-Q8_0.gguf}" bash "$SCRIPT_DIR/promote-gguf-to-ssd.sh" || \
    echo "WARN: GGUF promote skipped; coordinator will read MODELS_DIR on HDD" >&2
  echo "== switch-pool-27b.sh =="
  sudo inference_MODEL_FILE="${inference_MODEL_FILE:-Qwen3.8-27B-Q8_0.gguf}" bash "$SCRIPT_DIR/switch-pool-27b.sh"
  echo "== deploy-grev27-pool-shard.sh (RTX 3050 :31353) =="
  sudo FORCE_HUB_RPC_LOAD="${FORCE_HUB_RPC_LOAD:-}" bash "$SCRIPT_DIR/deploy-grev27-pool-shard.sh"
  STAGGER="${inference_SHARD_STAGGER_SEC:-20}"
  echo "== stagger ${STAGGER}s before CPU coordinator (all shards must settle) =="
  sleep "$STAGGER"
  echo "== deploy-grev27-pool-coordinator.sh (CPU :31360) =="
  # The coordinator deploy runs a real-decode self-test (guard 1) that proves every shard
  # computes. B42: do NOT probe :31353 with nc afterward - rpc-server is single-client and
  # busy serving the coordinator, so a post-load probe is racy and redeploying the shard
  # would kill the coordinator's backend session (SIGABRT). A genuinely dead shard already
  # fails the coordinator self-test above. See GREV27_27B_OPERATOR.md guard 4.
  # hub sudo clears env -- pass inference_SHARDS_FILE explicitly.
  sudo \
    inference_LOG_SESSION_ID="${inference_LOG_SESSION_ID:-}" \
    inference_SHARDS_FILE="${inference_SHARDS_FILE}" \
    inference_MODEL_FILE="${inference_MODEL_FILE:-}" \
    FORCE_HUB_RPC_LOAD="${FORCE_HUB_RPC_LOAD:-}" \
    CTX_SIZE="${CTX_SIZE:-}" \
    PARALLEL="${PARALLEL:-}" \
    bash "$SCRIPT_DIR/deploy-grev27-pool-coordinator.sh"
  echo "== operator-cluster-111 start-pool complete =="
}

cmd_start_pool72() {
  pull_repo
  local shards_file="${inference_SHARDS_FILE:-$REPO_DIR/deploy/llamacpp-rpc/inference-shards.active.env}"
  if [[ ! -f "$shards_file" ]]; then
    shards_file="$REPO_DIR/deploy/llamacpp-rpc/inference-shards.env"
  fi
  export inference_SHARDS_FILE="$shards_file"
  echo "== pool72 shard list: $inference_SHARDS_FILE =="
  echo "== promote RPC tarball to NVMe/SSD =="
  sudo bash "$SCRIPT_DIR/promote-rpc-image-to-nvme.sh" || \
    echo "WARN: NVMe/SSD promote skipped; load will use HDD hub" >&2
  echo "== promote 72B GGUF to SSD/NVMe =="
  sudo inference_MODEL_FILE=qwen2.5-72b-instruct-q5_k_m-00001-of-00014.gguf bash "$SCRIPT_DIR/promote-gguf-to-ssd.sh" || \
    echo "WARN: 72B GGUF promote skipped; coordinator will read MODELS_DIR on HDD" >&2
  echo "== switch-pool-72b.sh =="
  sudo bash "$SCRIPT_DIR/switch-pool-72b.sh"
  echo "== deploy-grev27-pool-shard.sh (RTX 3050 :31353) =="
  sudo bash "$SCRIPT_DIR/deploy-grev27-pool-shard.sh"
  STAGGER="${inference_SHARD_STAGGER_SEC:-20}"
  echo "== stagger ${STAGGER}s before CPU coordinator =="
  sleep "$STAGGER"
  echo "== deploy-grev72-pool-coordinator.sh (CPU :31360, Qwen2.5-72B Q5) =="
  sudo \
    inference_LOG_SESSION_ID="${inference_LOG_SESSION_ID:-}" \
    inference_SHARDS_FILE="${inference_SHARDS_FILE}" \
    CTX_SIZE="${CTX_SIZE:-}" \
    PARALLEL="${PARALLEL:-}" \
    bash "$SCRIPT_DIR/deploy-grev72-pool-coordinator.sh"
  echo "== operator-cluster-111 start-pool72 complete =="
}

cmd_start_pool80() {
  pull_repo
  local shards_file="${inference_SHARDS_FILE:-$REPO_DIR/deploy/llamacpp-rpc/inference-shards.active.env}"
  if [[ ! -f "$shards_file" ]]; then
    shards_file="$REPO_DIR/deploy/llamacpp-rpc/inference-shards.env"
  fi
  export inference_SHARDS_FILE="$shards_file"
  # First Pool80 (and after hub image bump): reload alfa-llamacpp-rpc even if tag exists.
  export FORCE_HUB_RPC_LOAD="${FORCE_HUB_RPC_LOAD:-1}"
  echo "== pool80 shard list: $inference_SHARDS_FILE (FORCE_HUB_RPC_LOAD=$FORCE_HUB_RPC_LOAD) =="
  echo "== promote RPC tarball to NVMe/SSD =="
  sudo bash "$SCRIPT_DIR/promote-rpc-image-to-nvme.sh" || \
    echo "WARN: NVMe/SSD promote skipped; load will use HDD hub" >&2
  echo "== promote 80B GGUF to SSD/NVMe =="
  sudo inference_MODEL_FILE=Qwen3-Coder-Next-Q5_K_M/Qwen3-Coder-Next-Q5_K_M-00001-of-00004.gguf bash "$SCRIPT_DIR/promote-gguf-to-ssd.sh" || \
    echo "WARN: 80B GGUF promote skipped; coordinator will read MODELS_DIR on HDD" >&2
  echo "== switch-pool-80b.sh =="
  sudo bash "$SCRIPT_DIR/switch-pool-80b.sh"
  echo "== deploy-grev27-pool-shard.sh (RTX 3050 :31353) =="
  sudo FORCE_HUB_RPC_LOAD="$FORCE_HUB_RPC_LOAD" bash "$SCRIPT_DIR/deploy-grev27-pool-shard.sh"
  STAGGER="${inference_SHARD_STAGGER_SEC:-20}"
  echo "== stagger ${STAGGER}s before CPU coordinator =="
  sleep "$STAGGER"
  echo "== deploy-grev80-pool-coordinator.sh (CPU :31360, Coder-Next Q5) =="
  sudo \
    FORCE_HUB_RPC_LOAD="$FORCE_HUB_RPC_LOAD" \
    inference_LOG_SESSION_ID="${inference_LOG_SESSION_ID:-}" \
    inference_SHARDS_FILE="${inference_SHARDS_FILE}" \
    CTX_SIZE="${CTX_SIZE:-}" \
    PARALLEL="${PARALLEL:-}" \
    bash "$SCRIPT_DIR/deploy-grev80-pool-coordinator.sh"
  echo "== operator-cluster-111 start-pool80 complete =="
}

cmd_start_pool35() {
  pull_repo
  echo "== switch-pool-35b.sh =="
  sudo bash "$SCRIPT_DIR/switch-pool-35b.sh"
  STAGGER="${inference_SHARD_STAGGER_SEC:-20}"
  echo "== stagger ${STAGGER}s before 35B CPU coordinator (shared shards must settle) =="
  sleep "$STAGGER"
  echo "== deploy-grev35-coordinator.sh (CPU :31360) =="
  sudo inference_LOG_SESSION_ID="${inference_LOG_SESSION_ID:-}" bash "$SCRIPT_DIR/deploy-grev35-coordinator.sh"
  echo "== operator-cluster-111 start-pool35 complete =="
}

cmd_start_brain() {
  echo "== scripts/start.sh =="
  sudo bash "$REPO_DIR/scripts/start.sh"
  # B42: verify the COORDINATOR is healthy, not the shard RPC ports. The coordinator is
  # already serving (single-client rpc-server); probing shard ports here is racy. /health
  # is a passive read that confirms the pool answered. See GREV27_27B_OPERATOR.md guard 4.
  echo "== verify inference coordinator health from hub (must pass before orchestrator continues) =="
  bash "$COMMON/wait-llamacpp-coordinator-health.sh" "http://127.0.0.1:31360/health" "${inference_COORD_HEALTH_TIMEOUT:-120}"
  echo "== operator-cluster-111 start-brain complete =="
}

cmd_repair_rerank() {
  echo "ERROR: rerank moved to pool-opt-in (Jul 2026). On VM100 run:" >&2
  echo "  bash ~/alfa-ai/deploy/cluster-members/pool-shard-opt-in/operator-cluster-100.sh start-rag" >&2
  echo "Or full cluster: Start-Stop-AlfaAi.ps1 stop then start from orchestrator." >&2
  exit 1
}

cmd_repair_shard() {
  pull_repo
  echo "== redeploy RTX 3050 inference shard (:31353) =="
  sudo bash "$SCRIPT_DIR/deploy-grev27-pool-shard.sh"
  if nc -z -w 5 127.0.0.1 31353 2>/dev/null; then
    echo "  OK 127.0.0.1:31353 listening"
  else
    echo "ERROR: :31353 still not reachable after redeploy" >&2
    exit 1
  fi
  echo "== operator-cluster-111 repair-shard complete =="
}

cmd_restart_shard() {
  cmd_repair_shard
}

cmd_install_keep_warm() {
  pull_repo
  bash "$SCRIPT_DIR/install-inference-keep-warm-cron.sh"
  echo "== operator-cluster-111 install-keep-warm complete =="
}

cmd_tail_logs() {
  pull_repo
  HOST_LABEL=111 bash "$COMMON/tail-inference-host-logs.sh"
}

cmd_start_error_logs() {
  pull_repo || echo "WARN: git sync failed; continuing start-error-logs (recorder does not require fresh code)"
  if [[ -z "${inference_LOG_SESSION_ID:-}" ]]; then
    echo "ERROR: set inference_LOG_SESSION_ID (printed by Start-Stop-AlfaAi.ps1 on orchestrator)" >&2
    exit 1
  fi
  echo "== inference error-only recorder (background) session $inference_LOG_SESSION_ID on hub =="
  sudo_inference_log_env bash "$COMMON/start-inference-log-session.sh"
  echo "== operator-cluster-111 start-error-logs OK =="
  echo "Leave recorder running. orchestrator orchestrator collects at CLUSTER COMPLETE."
}

cmd_stop_error_logs() {
  if [[ -z "${inference_LOG_SESSION_ID:-}" ]]; then
    echo "ERROR: set inference_LOG_SESSION_ID" >&2
    exit 1
  fi
  echo "== inference stop error recorder session $inference_LOG_SESSION_ID on hub =="
  sudo_inference_log_env bash "$COMMON/stop-inference-log-session.sh"
  echo "== operator-cluster-111 stop-error-logs OK =="
}

cmd_record_logs() {
  pull_repo
  if [[ -z "${inference_LOG_SESSION_ID:-}" ]]; then
    echo "ERROR: set inference_LOG_SESSION_ID (printed by Start-Stop-AlfaAi.ps1 on orchestrator)" >&2
    exit 1
  fi
  echo "== inference error-only live tail session $inference_LOG_SESSION_ID on hub =="
  sudo_inference_log_env TEE_LOG=1 SCP_TO_93=1 bash "$COMMON/record-inference-host-logs.sh"
}

if [[ $# -ne 1 ]]; then
  usage
fi

case "$1" in
  stop)        cmd_stop ;;
  start-pool)   cmd_start_pool ;;
  start-pool72) cmd_start_pool72 ;;
  start-pool80) cmd_start_pool80 ;;
  start-pool35) cmd_start_pool35 ;;
  start-brain)  cmd_start_brain ;;
  repair-rerank) cmd_repair_rerank ;;
  repair-shard)  cmd_repair_shard ;;
  restart-shard) cmd_restart_shard ;;
  install-keep-warm) cmd_install_keep_warm ;;
  tail-logs)        cmd_tail_logs ;;
  start-error-logs) cmd_start_error_logs ;;
  stop-error-logs)  cmd_stop_error_logs ;;
  record-logs)      cmd_record_logs ;;
  -h|--help)   usage ;;
  *)
    echo "ERROR: unknown subcommand: $1" >&2
    usage
    ;;
esac
