#!/usr/bin/env bash
# Shared helpers for inference crash-capture log sessions (errors only).
set -euo pipefail

# hub sudo can ship a broken PATH (mkdir/dirname "Function not implemented").
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin${PATH:+:$PATH}"

# Bash-native path (avoid external dirname — breaks under hub sudo).
inference_resolve_script_dir() {
  local src="${1:?}"
  local d="${src%/*}"
  [[ "$d" == "$src" || -z "$d" ]] && d="."
  (cd "$d" && pwd)
}

inference_repo_root() {
  if [[ -n "${ALFA_AI_REPO:-}" && -d "${ALFA_AI_REPO}/.git" ]]; then
    echo "$ALFA_AI_REPO"
    return
  fi
  local helpers_dir
  helpers_dir="$(inference_resolve_script_dir "${BASH_SOURCE[0]}")"
  echo "$(cd "$helpers_dir/../../.." && pwd)"
}

inference_resolve_host_label() {
  if [[ -n "${HOST_LABEL:-}" ]]; then
    echo "$HOST_LABEL"
    return
  fi
  hostname -s 2>/dev/null || hostname
}

inference_session_id() {
  if [[ -n "${inference_LOG_SESSION_ID:-}" ]]; then
    echo "$inference_LOG_SESSION_ID"
    return
  fi
  date +%Y%m%d-%H%M%S
}

inference_session_dir() {
  local repo session
  repo="$(inference_repo_root)"
  session="$(inference_session_id)"
  echo "${inference_LOG_DIR:-$repo/logs/inference-sessions}/$session"
}

# hub sudo-rs can return ENOSYS on mkdir even when the directory already exists.
inference_ensure_dir() {
  local dir="$1"
  [[ -d "$dir" ]] || command mkdir -p "$dir"
}

inference_log_file() {
  local dir label
  dir="$(inference_session_dir)"
  label="$(inference_resolve_host_label)"
  inference_ensure_dir "$dir"
  echo "$dir/inference-${label}-errors.log"
}

inference_dc() {
  if docker info >/dev/null 2>&1; then
    docker "$@"
  elif sudo -n docker info >/dev/null 2>&1; then
    sudo -n docker "$@"
  elif [[ -t 0 ]]; then
    sudo docker "$@"
  else
    echo "ERROR: docker not reachable on $(inference_resolve_host_label) (no TTY for sudo; run recorder via sudo on hub)" >&2
    return 1
  fi
}

inference_error_grep_pattern() {
  echo "${inference_ERROR_GREP:-error|fail|failed|fatal|crash|crashed|exception|traceback|panic|segfault|oom|out[[:space:]]+of[[:space:]]+memory|killed|SIG[A-Z]+|abort|refused|timeout|timed[[:space:]]+out|unreachable|wedge|wedged|disconnect|connection reset|Remote RPC|rpc server crashed|exit 134|exit code 134|\" [45][0-9]{2} |HTTP/[0-9.]+ [45][0-9]{2} |[45][0-9]{2} Bad|CUDA error|CUDA Error|illegal memory access|failed to initialize CUDA|nvml|NVML|NVRM|Xid|fallen off the bus|GPU has hung|rm_init_adapter|ECC|double bit|health check failed|unhealthy|Restarting \(|exited with code|corrupt|invalid argument}"
}

inference_gpu_kernel_grep_pattern() {
  echo "${inference_GPU_KERNEL_GREP:-NVRM|Xid|fallen off the bus|GPU has fallen|GPU has hung|rm_init_adapter|illegal memory access|failed to initialize CUDA|AER:.*PCIe|nvidia-uvm|double bit|ECC error}"
}

inference_line_matches_error() {
  local line="$1"
  echo "$line" | grep -qiE "$(inference_error_grep_pattern)"
}

inference_pick_containers() {
  local label
  label="$(inference_resolve_host_label)"
  case "$label" in
    111|hub|hub-111)
      printf '%s\n' llamacpp-server-111-grev27-pool llamacpp-rpc-111-gpu3050 alfa-ai-litellm alfa-ai-api alfa-ai-nginx alfa-ai-postgres alfa-ai-redis
      ;;
    148|ai-148|operator)
      printf '%s\n' llamacpp-server-148-grev27-pool llamacpp-rpc-148-gpu3060 llamacpp-rpc-148-gpu5060 alfa-ai-edge-api
      ;;
    93|Wolf1|operator-93|DESKTOP-*)
      printf '%s\n' llamacpp-rpc-server
      ;;
    100|vm100|alfa-ai-100)
      printf '%s\n' llamacpp-rpc-100-gpu1660s alfa-ai-embed-ollama
      ;;
    248|Nickey-Nakita|gpu-248)
      printf '%s\n' llamacpp-rpc-248-gpu1070
      ;;
    *)
      inference_dc ps --format '{{.Names}}' 2>/dev/null | grep -E 'llama|alfa-ai|contracts-bot-api' || true
      ;;
  esac
}

inference_running_containers() {
  local -a want running=()
  mapfile -t want < <(inference_pick_containers)
  local name
  for name in "${want[@]}"; do
    [[ -z "$name" ]] && continue
    if inference_dc ps --format '{{.Names}}' 2>/dev/null | grep -qx "$name"; then
      running+=("$name")
    fi
  done
  if [[ ${#running[@]} -eq 0 ]]; then
    return 1
  fi
  printf '%s\n' "${running[@]}"
}

inference_probe_targets() {
  printf '%s\n' \
    orchestrator \
    orchestrator \
    hub \
    orchestrator \
    orchestrator \
    hub \
    hub \
    orchestrator \
    orchestrator \
    orchestrator
}

inference_write_gpu_oc_baseline() {
  local log_file="$1"
  if ! command -v nvidia-smi >/dev/null 2>&1; then
    return 0
  fi
  {
    echo "======== GPU OC baseline ========"
    nvidia-smi --query-gpu=index,name,power.limit,clocks.max.graphics,clocks.max.memory,clocks_throttle_reasons.active,clocks_throttle_reasons.gpu_idle --format=csv 2>/dev/null || true
    if [[ -r /etc/lact/config.yaml ]]; then
      echo "--- lact offsets (live config) ---"
      grep -E '10DE:|gpu_clock_offsets|mem_clock_offsets|power_cap' /etc/lact/config.yaml 2>/dev/null || true
    fi
    echo ""
  } >>"$log_file"
}

inference_write_error_baseline() {
  local log_file="$1"
  local label
  label="$(inference_resolve_host_label)"
  local -a problems=()
  {
    echo "======== inference error baseline ($label) ========"
    echo "session_id: $(inference_session_id)"
    echo "host: $(hostname -f 2>/dev/null || hostname)"
    echo "at: $(date -Iseconds 2>/dev/null || date)"
    echo ""
  } >>"$log_file"

  if ! inference_dc info >/dev/null 2>&1; then
    problems+=("docker unreachable")
    echo "[baseline] ERROR docker unreachable" >>"$log_file"
  fi

  local line name status
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    name="${line%%	*}"
    status="${line#*	}"
    if echo "$status" | grep -qiE 'exit|unhealthy|restarting|dead'; then
      echo "[baseline] container $name status=$status" >>"$log_file"
      problems+=("container:$name")
    fi
  done < <(inference_dc ps --format '{{.Names}}	{{.Status}}' 2>/dev/null | grep -E 'llama|alfa-ai|contracts-bot' || true)

  local hp host port
  for hp in $(inference_probe_targets); do
    host="${hp%:*}"
    port="${hp#*:}"
    if command -v nc >/dev/null 2>&1; then
      if ! nc -z -w2 "$host" "$port" 2>/dev/null; then
        echo "[baseline] TCP FAIL $hp" >>"$log_file"
        problems+=("tcp:$hp")
      fi
    fi
  done

  local ping_host
  for ping_host in orchestrator hub orchestrator orchestrator apps; do
    if command -v ping >/dev/null 2>&1; then
      if ! ping -c 1 -W 2 "$ping_host" >/dev/null 2>&1; then
        echo "[baseline] ping FAIL $ping_host" >>"$log_file"
        problems+=("ping:$ping_host")
      fi
    fi
  done

  inference_write_gpu_oc_baseline "$log_file"

  if command -v dmesg >/dev/null 2>&1; then
    dmesg -T 2>/dev/null | tail -80 | grep -iE "$(inference_gpu_kernel_grep_pattern)" | while IFS= read -r line; do
      echo "[baseline] dmesg $line" >>"$log_file"
    done || true
  fi

  if [[ ${#problems[@]} -eq 0 ]]; then
    echo "[baseline] no problems detected at recorder start" >>"$log_file"
  fi
  echo "" >>"$log_file"
}

inference_recorder_unit_name() {
  local label session
  label="$(inference_resolve_host_label)"
  session="$(inference_session_id)"
  echo "inference-recorder-${label}-${session}"
}

inference_scp_to_93() {
  local session_dir session_id remote_host remote_dir
  session_dir="$(inference_session_dir)"
  session_id="$(inference_session_id)"
  remote_host="${inference_LOG_SCP_HOST:-operator@orchestrator}"
  remote_dir="${inference_LOG_REMOTE_DIR:-/c/Users/operator/alfa-ai/logs/inference-sessions/$session_id}"

  if [[ ! -d "$session_dir" ]]; then
    echo "WARN: session dir missing: $session_dir" >&2
    return 1
  fi

  local local_base parent_dir
  parent_dir="${session_dir%/*}"
  [[ "$parent_dir" == "$session_dir" || -z "$parent_dir" ]] && parent_dir="."
  local_base="$(cd "$parent_dir" && pwd -P)"
  if [[ "$local_base" == *"/logs/inference-sessions" ]] && [[ "$(uname -s 2>/dev/null)" == Linux ]] \
    && [[ -d "/mnt/c/Users/operator/alfa-ai/logs/inference-sessions/$session_id" ]]; then
    echo "inference-log: session already on orchestrator via WSL mount ($session_dir)"
    return 0
  fi

  echo "inference-log: SCP session to ${remote_host}:${remote_dir}/"
  shopt -s nullglob
  local -a files=("$session_dir"/*)
  shopt -u nullglob
  if [[ ${#files[@]} -eq 0 ]]; then
    echo "WARN: no files in $session_dir" >&2
    return 1
  fi
  if ssh -o BatchMode=yes -o ConnectTimeout=10 -o StrictHostKeyChecking=accept-new \
       "$remote_host" "mkdir -p '${remote_dir}'" \
    && scp -o BatchMode=yes -o ConnectTimeout=30 -o StrictHostKeyChecking=accept-new \
         "${files[@]}" "${remote_host}:${remote_dir}/"; then
    echo "inference-log: copied -> ${remote_host}:${remote_dir}/"
    return 0
  fi

  echo "WARN: SCP to orchestrator failed (authorize SSH key: bash scripts/setup_ssh_keys.sh)" >&2
  echo "  Manual: scp -r '$session_dir/'* '${remote_host}:${remote_dir}/'" >&2
  return 1
}