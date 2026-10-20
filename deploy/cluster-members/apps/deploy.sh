#!/usr/bin/env bash
set -euo pipefail

# Deploy runner for apps (Ubuntu, apps host).
#
# apps is NO LONGER the brain (brain + its Postgres/Redis are on hub). It hosts:
#   - apps-local Postgres + Redis for bots that elect to use them (non-critical)
#   - Websites + bots still on apps (contracts-bot, example-site-perch, alfaqd, ...)
#   - Dockge agent on :5001
# Petals/Hivemind (gateway + worker + DHT bootstrap) is retired.
#
# Reads the declarative manifest at ./stacksapps.yml and brings each stack up
# idempotently. Intended to be the single entry point operators run after
# `git pull` on apps. See docs/DOCKGE_105_OPERATOR.md.
#
# CROSS-RULE-008 / backlog #35: Compose and systemd must not both publish alfa-ai-api.
# Stacks that define `alfa-ai-api` run scripts/preflight_api_ownership.sh before `docker compose up`.
# If this host intentionally uses systemd for the API, stop/disable that unit first,
# or omit compose stacks that start the API — see docs/DEPLOYMENT_BASELINE.md § Runtime ownership.
#
# Prereqs:
#   - deploy/.env.apps on this host (gitignored; see docs/DOCKGE_105_OPERATOR.md section 2).
#   - Registry mirror on hub reachable (docker pulls go through it).
#   - NFS mount /mnt/cluster (auto: scripts/install-nfs-hub-systemd.sh)
#
# Usage:
#   bash deploy/cluster-members/apps/deploy.sh               # bring everything up
#   bash deploy/cluster-members/apps/deploy.sh --list        # show manifest, do not act
#   bash deploy/cluster-members/apps/deploy.sh --only=postgres,redis
#   bash deploy/cluster-members/apps/deploy.sh --only rankings-bot,probilliards-nginx
#   bash deploy/cluster-members/apps/deploy.sh --skip rankings-bot
#   bash deploy/cluster-members/apps/deploy.sh --down        # stop everything listed
#
# Exit codes:
#   0  all critical stacks up (non-critical misses warned only)
#   1  a critical stack failed (env missing, compose missing, or up failed)
#   2  manifest parse / yaml error

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MANIFEST="$SCRIPT_DIR/stacksapps.yml"

if [[ ! -f "$MANIFEST" ]]; then
  echo "ERROR: manifest not found: $MANIFEST" >&2
  exit 2
fi

# --- Shared network preflight -----------------------------------------------
# alfa-shared-network is declared `external: true` by docker-compose.{postgres,redis}.yml
# and docker-compose.dockge-agent.yml. Create it idempotently here so the per-stack
# compose files don't race on first-bring-up. See audit CROSS-105-001.
if ! docker network inspect alfa-shared-network >/dev/null 2>&1; then
  echo "Creating prerequisite Docker network: alfa-shared-network"
  docker network create --driver bridge alfa-shared-network >/dev/null
fi

# alfa-ai-edge-api requires tunnel_network (external in docker-compose.edge-api.yml).
if ! docker network inspect tunnel_network >/dev/null 2>&1; then
  echo "Creating prerequisite Docker network: tunnel_network"
  docker network create tunnel_network >/dev/null
fi

# --- CLI parsing ------------------------------------------------------------
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
      sed -n '1,35p' "${BASH_SOURCE[0]}"
      exit 0 ;;
  esac
done
# Normalize whitespace in comma lists (operators paste "a, b" sometimes).
ONLY="$(echo "$ONLY" | tr -d ' ')"
SKIP="$(echo "$SKIP" | tr -d ' ')"

# --- YAML parsing: require Python (pyyaml) ----------------------------------
# We deliberately avoid adding a shell yaml-parser dependency; python3 is
# present on every Ubuntu host we target.
PY=python3
if ! command -v "$PY" >/dev/null; then
  echo "ERROR: python3 required to parse $MANIFEST" >&2
  exit 2
fi
# Emit per-stack tab-separated records: name TAB path TAB compose[,...] TAB env TAB critical TAB enabled TAB stop_projects[,...]
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

echo "== ALFa AI Cluster Deploy: apps-105 =="
echo "  Role:    apps host (websites/bots + apps-local Postgres/Redis for bots)"
echo "  Brain:   hub (hub) — ALFA_AI_API_URL=http://hub"
echo "  Repo:    $REPO_ROOT"
echo "  Stacks:  $STACKS_DIR"
echo "  Mode:    $MODE"
[[ -n "$ONLY" ]] && echo "  Only:    $ONLY"
[[ -n "$SKIP" ]] && echo "  Skip:    $SKIP"
echo ""

# --- helpers ---------------------------------------------------------------
in_csv() { # in_csv needle comma-list
  local n="$1" list="${2:-}"
  [[ -z "$list" ]] && return 1
  IFS=',' read -ra arr <<<"$list"
  for i in "${arr[@]}"; do
    [[ "$(echo "$i" | xargs)" == "$n" ]] && return 0
  done
  return 1
}

# True if any compose file in this stack defines service alfa-ai-api (audit CROSS-RULE-007).
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

# Stop legacy project names before the new layout comes up (once, not per stack).
# Stop legacy monolithic projects only on full-fleet deploy (not targeted --only).
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

# --- Process each stack ----------------------------------------------------
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

  # filter --only / --skip (before any stack output)
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

  # Edge (:8420) moved to inference hub (Jul 2026). Cluster start runs start-edge-api.sh on inference.
  if [[ "$NAME" == "alfa-ai-edge-api" ]]; then
    echo "  SKIP: alfa-ai-edge-api retired on apps — use inference: bash deploy/cluster-members/_common/start-edge-api.sh"
    echo ""
    continue
  fi

  # Preflight: paths + files
  if [[ -z "$ABS_PATH" || ! -d "$ABS_PATH" ]]; then
    if [[ "$CRIT" == "yes" ]]; then
      echo "  FAIL: path missing: $RELPATH (resolved from $REPO_ROOT)"
      FAILED_CRITICAL=$((FAILED_CRITICAL+1))
    else
      echo "  SKIP: path missing: $RELPATH"
      SKIPPED_NONCRIT=$((SKIPPED_NONCRIT+1))
    fi
    echo ""
    continue
  fi

  # Validate each compose file exists
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
      echo "  preflight: API ownership (stack defines alfa-ai-api)"
      if ! bash "$PF" compose-will-manage-api; then
        echo "  FAIL: systemd vs Compose conflict — see docs/DEPLOYMENT_BASELINE.md"
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

  # per-stack legacy project stops
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

  # Symlink /opt/stacks/<name> -> absolute stack path (Dockge-friendly)
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

  # Dockge derives project name from the parent folder under DOCKGE_STACKS_DIR.
  # cd into the symlink (not the resolved repo path) so project name == stack name.
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

echo "== apps-105 deploy summary =="
echo "  succeeded:            $SUCCEEDED"
echo "  skipped (non-crit):   $SKIPPED_NONCRIT"
echo "  failed (critical):    $FAILED_CRITICAL"
echo ""

if [[ "$FAILED_CRITICAL" -gt 0 ]]; then
  echo "RESULT: FAIL — one or more critical stacks did not come up." >&2
  exit 1
fi

# Rankings public ingress: nginx stack + Cloudflare tunnel (not compose-managed).
if [[ "$MODE" == "up" ]]; then
  RANKINGS_DEPLOYED=0
  if [[ -z "$ONLY" ]] || in_csv "rankings-bot" "$ONLY" || in_csv "probilliards-nginx" "$ONLY"; then
    if [[ -z "$SKIP" ]] || { ! in_csv "rankings-bot" "$SKIP" && ! in_csv "probilliards-nginx" "$SKIP"; }; then
      RANKINGS_DEPLOYED=1
    fi
  fi
  if [[ "$RANKINGS_DEPLOYED" -eq 1 ]]; then
    TUNNEL_SCRIPT="$REPO_ROOT/deploy/cluster-members/_common/start-rankings-public-ingress-105.sh"
    VERIFY_SCRIPT="$REPO_ROOT/deploy/cluster-members/_common/verify-rankings-public-ingress-105.sh"
    if [[ -f "$TUNNEL_SCRIPT" ]]; then
      echo "== Rankings public ingress: Cloudflare tunnel =="
      if bash "$TUNNEL_SCRIPT" 2>&1 | sed 's/^/    /'; then
        echo ""
      else
        echo "  FAIL: cf-probilliards did not register (see above)" >&2
        exit 1
      fi
    fi
    if [[ -f "$VERIFY_SCRIPT" ]]; then
      echo "== Rankings public ingress: verify =="
      if ! bash "$VERIFY_SCRIPT"; then
        echo "RESULT: FAIL — rankings public ingress verify failed." >&2
        exit 1
      fi
      echo ""
    fi
  fi
fi

echo "RESULT: OK"
