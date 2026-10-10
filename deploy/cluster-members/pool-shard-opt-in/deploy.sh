#!/usr/bin/env bash
set -euo pipefail

# Deploy runner for VM100 (orchestrator) — inference shard host only.
#
# Proxmox guest on pve-i5 (hypervisor). 1660S runs the inference rpc-server shard (:31354,
# operator-cluster-100.sh start-shard). RAG is on rag; brain + DB on hub;
# edge on inference → hub:8420. The manifest's legacy RAG stacks are disabled.
#
# Reads deploy/cluster-members/pool-shard-opt-in/stackspool-opt-in.yml.
# See docs/DOCKGE_100_OPERATOR.md and .cursor/plans/VM100_ALFA_AI_MIGRATION.md.
#
# Usage:
#   bash deploy/cluster-members/pool-shard-opt-in/deploy.sh
#   bash deploy/cluster-members/pool-shard-opt-in/deploy.sh --list
#   bash deploy/cluster-members/pool-shard-opt-in/deploy.sh --only=dockge-agent
#   bash deploy/cluster-members/pool-shard-opt-in/deploy.sh --down

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/stackspool-opt-in.yml"

if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: manifest not found: $MANIFEST" >&2
  exit 2
fi

# Remaining stacks (dockge-agent) use the default bridge — no shared network required.

MODE="up"
ONLY=""
SKIP=""
args=("$@")
for ((i=0; i<${#args[@]}; i++)); do
  case "${args[$i]}" in
    --list)       MODE="list" ;;
    --down)       MODE="down" ;;
    --only=*)     ONLY="${args[$i]#--only=}" ;;
    --only)       ONLY="${args[$((i+1))]:-}" ;;
    --skip=*)     SKIP="${args[$i]#--skip=}" ;;
    --skip)       SKIP="${args[$((i+1))]:-}" ;;
    -h|--help)
      sed -n '1,20p' "${BASH_SOURCE[0]}"
      exit 0 ;;
  esac
done
ONLY="$(echo "$ONLY" | tr -d ' ')"
SKIP="$(echo "$SKIP" | tr -d ' ')"

PY=python3
if ! command -v "$PY" >/dev/null; then
  echo "ERROR: python3 required to parse $MANIFEST" >&2
  exit 2
fi

MANIFEST_TSV="$("$PY" - "$MANIFEST" <<'PY'
import sys, yaml, pathlib
m = yaml.safe_load(pathlib.Path(sys.argv[1]).read_text())
repo = m.get("repo_root", "/home/operator/alfa-ai")
stacks_dir = m.get("stacks_dir", "/opt/stacks")
gstops = ",".join(m.get("global_stop_projects", []) or [])
print(f"#REPO\t{repo}")
print(f"#STACKSDIR\t{stacks_dir}")
print(f"#GSTOPS\t{gstops}")
for s in m.get("stacks", []):
    name = s["name"]
    path = s["path"]
    comp = ",".join(s.get("compose", []))
    envf = s.get("env_file") or "-"
    crit = "yes" if s.get("critical", False) else "no"
    en = "yes" if s.get("enabled", True) else "no"
    stops = ",".join(s.get("stop_projects", []) or []) or "-"
    print("\t".join([name, path, comp, envf, crit, en, stops]))
PY
)"

REPO_ROOT=""
STACKS_DIR=""
GLOBAL_STOPS=""
declare -a STACK_LINES=()
while IFS= read -r line; do
  case "$line" in
    \#REPO*)      REPO_ROOT="$(cut -f2 <<<"$line")" ;;
    \#STACKSDIR*) STACKS_DIR="$(cut -f2 <<<"$line")" ;;
    \#GSTOPS*)    GLOBAL_STOPS="$(cut -f2 <<<"$line")" ;;
    *)            STACK_LINES+=("$line") ;;
  esac
done <<<"$MANIFEST_TSV"

[[ -d "$REPO_ROOT" ]] || { echo "ERROR: repo_root missing: $REPO_ROOT" >&2; exit 2; }

if [[ -x "$REPO_ROOT/deploy/cluster-members/_common/preflight-nfs-hub.sh" ]]; then
  ALFA_REPO_DIR="$REPO_ROOT" bash "$REPO_ROOT/deploy/cluster-members/_common/preflight-nfs-hub.sh"
  echo ""
fi

echo "== ALFa AI Cluster Deploy: vm100-alfa-ai =="
echo "  Role:    inference rpc-server shard host (:31354 via operator-cluster-100.sh start-shard)"
echo "  Brain:   hub (hub) — API, LiteLLM, Postgres, Redis, hub"
echo "  RAG:     rag — embed :11435 + rerank :8360 (not on this host)"
echo "  Repo:    $REPO_ROOT"
echo "  Stacks:  $STACKS_DIR"
echo "  Mode:    $MODE"
[[ -n "$ONLY" ]] && echo "  Only:    $ONLY"
[[ -n "$SKIP" ]] && echo "  Skip:    $SKIP"
echo ""

in_csv() {
  local n="$1" list="${2:-}"
  [[ -z "$list" ]] && return 1
  IFS=',' read -ra arr <<<"$list"
  for i in "${arr[@]}"; do
    [[ "$(echo "$i" | xargs)" == "$n" ]] && return 0
  done
  return 1
}

_stack_defines_alfa_ai_api() {
  local abs="$1"
  shift
  local cf
  for cf in "$@"; do
    cf="$(echo "$cf" | xargs)"
    [[ -z "$cf" ]] && continue
    [[ -f "$abs/$cf" ]] || continue
    if grep -qE '^[[:space:]]*alfa-ai-api:[[:space:]]*(#.*)?$' "$abs/$cf"; then
      return 0
    fi
  done
  return 1
}

stop_legacy_projects() {
  [[ -n "$ONLY" ]] && return 0
  [[ -z "$GLOBAL_STOPS" ]] && return 0
  echo "== Stopping legacy monolithic projects =="
  IFS=',' read -ra names <<<"$GLOBAL_STOPS"
  for proj in "${names[@]}"; do
    proj="$(echo "$proj" | xargs)"
    [[ -z "$proj" ]] && continue
    if docker compose ls --all --format json 2>/dev/null | grep -q "\"Name\":\"$proj\""; then
      echo "  Stopping legacy project: $proj"
      docker compose -p "$proj" down --remove-orphans 2>&1 | sed 's/^/    /' || true
    fi
  done
  echo ""
}

FAILED_CRITICAL=0
SKIPPED_NONCRIT=0
SUCCEEDED=0

[[ "$MODE" == "up"   ]] && stop_legacy_projects
[[ "$MODE" == "list" ]] && printf "  %-20s %-30s %-12s %s\n" NAME PATH CRITICAL COMPOSE

for sl in "${STACK_LINES[@]}"; do
  [[ -z "$sl" ]] && continue
  IFS=$'\t' read -r NAME RELPATH COMP ENVF CRIT ENABLED STOPS <<<"$sl"

  [[ "$ENVF" == "-" ]] && ENVF=""
  [[ "$STOPS" == "-" ]] && STOPS=""

  if [[ -n "$ONLY" ]] && ! in_csv "$NAME" "$ONLY"; then continue; fi
  if [[ -n "$SKIP" ]] &&   in_csv "$NAME" "$SKIP"; then continue; fi

  if [[ "$ENABLED" == "no" ]]; then
    echo "-- Stack: $NAME (disabled in manifest; skip) --"
    continue
  fi

  ABS_PATH="$(cd "$REPO_ROOT" && cd "$RELPATH" 2>/dev/null && pwd || echo "")"
  ENV_ABS=""
  if [[ -n "$ENVF" ]]; then
    if [[ "$ENVF" = /* ]]; then ENV_ABS="$ENVF"
    else                         ENV_ABS="$REPO_ROOT/$ENVF"
    fi
  fi

  if [[ "$MODE" == "list" ]]; then
    printf "  %-20s %-30s %-12s %s\n" "$NAME" "$RELPATH" "$CRIT" "$COMP"
    continue
  fi

  echo "-- Stack: $NAME (critical=$CRIT) --"

  if [[ -z "$ABS_PATH" || ! -d "$ABS_PATH" ]]; then
    if [[ "$CRIT" == "yes" ]]; then
      echo "  FAIL: path missing: $RELPATH"
      FAILED_CRITICAL=$((FAILED_CRITICAL+1))
    else
      echo "  SKIP: path missing: $RELPATH"
      SKIPPED_NONCRIT=$((SKIPPED_NONCRIT+1))
    fi
    echo ""
    continue
  fi

  compose_args=()
  missing_compose=0
  IFS=',' read -ra comp_arr <<<"$COMP"
  for cf in "${comp_arr[@]}"; do
    cf="$(echo "$cf" | xargs)"
    [[ -z "$cf" ]] && continue
    if [[ ! -f "$ABS_PATH/$cf" ]]; then
      missing_compose=1
      if [[ "$CRIT" == "yes" ]]; then
        echo "  FAIL: compose missing: $ABS_PATH/$cf"
      else
        echo "  SKIP: compose missing: $ABS_PATH/$cf"
      fi
    fi
    compose_args+=("-f" "$cf")
  done
  if [[ "$missing_compose" -eq 1 ]]; then
    if [[ "$CRIT" == "yes" ]]; then FAILED_CRITICAL=$((FAILED_CRITICAL+1))
    else                            SKIPPED_NONCRIT=$((SKIPPED_NONCRIT+1))
    fi
    echo ""
    continue
  fi

  if [[ "$MODE" == "up" ]] && _stack_defines_alfa_ai_api "$ABS_PATH" "${comp_arr[@]}"; then
    PF="$REPO_ROOT/scripts/preflight_api_ownership.sh"
    if [[ -f "$PF" ]]; then
      echo "  preflight: API ownership"
      if ! bash "$PF" compose-will-manage-api; then
        echo "  FAIL: systemd vs Compose conflict"
        FAILED_CRITICAL=$((FAILED_CRITICAL+1))
        echo ""; continue
      fi
    fi
  fi

  env_flag=()
  if [[ -n "$ENV_ABS" ]]; then
    if [[ -f "$ENV_ABS" ]]; then
      env_flag+=(--env-file "$ENV_ABS")
    else
      if [[ "$CRIT" == "yes" ]]; then
        echo "  FAIL: env missing: $ENV_ABS"
        FAILED_CRITICAL=$((FAILED_CRITICAL+1))
        echo ""; continue
      else
        echo "  SKIP: env missing: $ENV_ABS (non-critical)"
        SKIPPED_NONCRIT=$((SKIPPED_NONCRIT+1))
        echo ""; continue
      fi
    fi
  fi

  if [[ -n "$STOPS" ]]; then
    IFS=',' read -ra stoparr <<<"$STOPS"
    for p in "${stoparr[@]}"; do
      p="$(echo "$p" | xargs)"
      [[ -z "$p" ]] && continue
      if docker compose ls --all --format json 2>/dev/null | grep -q "\"Name\":\"$p\""; then
        echo "  stopping legacy project $p"
        docker compose -p "$p" down --remove-orphans 2>&1 | sed 's/^/    /' || true
      fi
    done
  fi

  if [[ -n "$STACKS_DIR" ]]; then
    if [[ ! -d "$STACKS_DIR" ]]; then
      sudo mkdir -p "$STACKS_DIR" 2>/dev/null || mkdir -p "$STACKS_DIR" 2>/dev/null || true
    fi
    if [[ -d "$STACKS_DIR" && -w "$STACKS_DIR" ]] || sudo -n true 2>/dev/null; then
      if [[ ! -L "$STACKS_DIR/$NAME" ]] || [[ "$(readlink "$STACKS_DIR/$NAME")" != "$ABS_PATH" ]]; then
        ln -sfn "$ABS_PATH" "$STACKS_DIR/$NAME" 2>/dev/null \
          || sudo ln -sfn "$ABS_PATH" "$STACKS_DIR/$NAME" 2>/dev/null \
          || echo "  WARN: could not symlink $STACKS_DIR/$NAME"
      fi
    fi
  fi

  COMPOSE_CWD="$ABS_PATH"
  if [[ -n "$STACKS_DIR" && -L "$STACKS_DIR/$NAME" ]]; then
    COMPOSE_CWD="$STACKS_DIR/$NAME"
  fi
  cd "$COMPOSE_CWD"
  if [[ "$MODE" == "down" ]]; then
    echo "  docker compose ${compose_args[*]} ${env_flag[*]} down"
    if docker compose "${compose_args[@]}" "${env_flag[@]}" down 2>&1 | sed 's/^/    /'; then
      SUCCEEDED=$((SUCCEEDED+1))
    fi
  else
    echo "  docker compose ${compose_args[*]} ${env_flag[*]} up -d"
    if docker compose "${compose_args[@]}" "${env_flag[@]}" up -d 2>&1 | sed 's/^/    /'; then
      SUCCEEDED=$((SUCCEEDED+1))
    else
      if [[ "$CRIT" == "yes" ]]; then
        echo "  FAIL: $NAME up -d returned non-zero"
        FAILED_CRITICAL=$((FAILED_CRITICAL+1))
      else
        echo "  WARN: $NAME up -d returned non-zero (non-critical)"
        SKIPPED_NONCRIT=$((SKIPPED_NONCRIT+1))
      fi
    fi
  fi
  echo ""
done

[[ "$MODE" == "list" ]] && exit 0

echo "== vm100-alfa-ai deploy summary =="
echo "  succeeded:            $SUCCEEDED"
echo "  skipped (non-crit):   $SKIPPED_NONCRIT"
echo "  failed (critical):    $FAILED_CRITICAL"
echo ""

if [[ "$FAILED_CRITICAL" -gt 0 ]]; then
  echo "RESULT: FAIL — one or more critical stacks did not come up." >&2
  exit 1
fi

echo "RESULT: OK"