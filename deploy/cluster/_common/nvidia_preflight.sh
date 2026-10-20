#!/usr/bin/env bash
# nvidia_preflight.sh — single source of truth for GPU identity on Linux / WSL nodes.
#
# Runs FIRST on every cluster deploy. Reads `nvidia-smi`, classifies each GPU,
# and writes a node profile JSON for downstream scripts.
#
# Usage:
#   source this file, then call alfa_nvidia_preflight [--role brain|gpu-worker|apps|agent-only] [--force]
#   or run directly:
#     ALFA_ROLE=brain bash nvidia_preflight.sh
#
# Exit codes:
#   0 = preflight passed, profile written
#   1 = nvidia-smi missing or errored
#   2 = role/hardware mismatch (use --force to override)
#   3 = compose variant file not found in repo
#
# Docs:
#   https://docs.nvidia.com/deploy/nvidia-smi/
#   https://github.com/louislam/dockge (consumes the compose files we select)

set -euo pipefail

# Resolve repo paths relative to this script so the file is portable between apps, hub,
# and WSL worker nodes that sync the repo to different roots.
_ALFA_PF_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALFA_REPO_ROOT="${ALFA_REPO_ROOT:-$(cd "${_ALFA_PF_SCRIPT_DIR}/../../.." && pwd)}"
ALFA_PROFILE_PATH="${ALFA_PROFILE_PATH:-/var/lib/alfa-ai/node_profile.json}"
ALFA_ML_WHEELS_DIR="${ALFA_ML_WHEELS_DIR:-${ALFA_REPO_ROOT}/deploy/ml-wheels}"

alfa_log() { printf '[nvidia-preflight] %s\n' "$*" >&2; }

alfa_nvidia_preflight() {
    local role="${ALFA_ROLE:-}" force=0 arg
    while [[ $# -gt 0 ]]; do
        arg="$1"; shift
        case "$arg" in
            --role) role="$1"; shift ;;
            --role=*) role="${arg#*=}" ;;
            --force) force=1 ;;
            *) alfa_log "unknown arg: $arg"; return 1 ;;
        esac
    done
    role="${role:-gpu-worker}"

    if ! command -v nvidia-smi >/dev/null 2>&1; then
        alfa_log "nvidia-smi not found on PATH; install NVIDIA driver + container toolkit first"
        [[ "$role" == "apps" || "$role" == "agent-only" ]] || return 1
    fi

    local gpus_csv=""
    if command -v nvidia-smi >/dev/null 2>&1; then
        # --query-gpu outputs: name, driver_version, compute_cap, memory.total [MiB]
        gpus_csv="$(nvidia-smi --query-gpu=name,driver_version,compute_cap,memory.total --format=csv,noheader 2>/dev/null || true)"
        if [[ -z "$gpus_csv" ]]; then
            alfa_log "nvidia-smi returned no GPUs"
            [[ "$role" == "apps" || "$role" == "agent-only" ]] || return 1
        else
            alfa_log "Detected GPUs:"
            printf '%s\n' "$gpus_csv" | sed 's/^/  /' >&2
        fi
    fi

    local compute_cap="" major=0 gpu_class="none"
    if [[ -n "$gpus_csv" ]]; then
        compute_cap="$(printf '%s\n' "$gpus_csv" | head -n1 | awk -F',' '{gsub(/ /,""); print $3}')"
        major="${compute_cap%%.*}"
        major="${major:-0}"
    fi

    if (( major >= 12 )); then
        gpu_class="blackwell"
    elif (( major >= 7 )); then
        gpu_class="ampere-or-newer"
    elif (( major > 0 )); then
        gpu_class="legacy"
    else
        gpu_class="none"
    fi

    # Role/hardware gate: refuse brain/gpu-worker on a box with no CUDA card unless --force.
    case "$role" in
        brain|gpu-worker)
            if [[ "$gpu_class" == "none" && $force -ne 1 ]]; then
                alfa_log "role '$role' expects a CUDA GPU but none found (rerun with --force to override)"
                return 2
            fi ;;
    esac

    # Persist profile so deploy scripts do not re-query on every run.
    sudo mkdir -p "$(dirname "$ALFA_PROFILE_PATH")" 2>/dev/null || mkdir -p "$(dirname "$ALFA_PROFILE_PATH")"
    local hostname_v ip_v first_card_name
    hostname_v="$(hostname -f 2>/dev/null || hostname)"
    ip_v="$(hostname -I 2>/dev/null | awk '{print $1}')"
    first_card_name="$(printf '%s\n' "$gpus_csv" | head -n1 | awk -F',' '{gsub(/^ +| +$/,"",$1); print $1}')"

    local tmp_profile
    tmp_profile="$(mktemp)"
    {
        printf '{\n'
        printf '  "hostname": "%s",\n' "${hostname_v:-unknown}"
        printf '  "ip": "%s",\n' "${ip_v:-unknown}"
        printf '  "role": "%s",\n' "$role"
        printf '  "gpu_class": "%s",\n' "$gpu_class"
        printf '  "first_gpu": "%s",\n' "${first_card_name:-none}"
        printf '  "compute_cap": "%s",\n' "$compute_cap"
        printf '  "generated_at": "%s"\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf '}\n'
    } > "$tmp_profile"

    if sudo test -w "$(dirname "$ALFA_PROFILE_PATH")" 2>/dev/null; then
        sudo mv "$tmp_profile" "$ALFA_PROFILE_PATH"
    else
        mv "$tmp_profile" "$ALFA_PROFILE_PATH" 2>/dev/null || sudo install -m 0644 "$tmp_profile" "$ALFA_PROFILE_PATH"
        rm -f "$tmp_profile" 2>/dev/null || true
    fi

    alfa_log "profile -> $ALFA_PROFILE_PATH (role=$role gpu_class=$gpu_class)"
    export ALFA_NODE_ROLE="$role"
    export ALFA_NODE_GPU_CLASS="$gpu_class"
    return 0
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    alfa_nvidia_preflight "$@"
fi
