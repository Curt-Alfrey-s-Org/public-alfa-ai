#!/usr/bin/env bash
set -euo pipefail

# Install Dockge agent on a Linux host and symlink app stacks into STACKS_DIR.
# Image: louislam/dockge:1 from hub tarball (never docker pull).
# Official: https://github.com/louislam/dockge
#
# Usage:
#   bash deploy/cluster-members/_common/install-dockge-agent-linux.sh \
#     deploy/cluster-members/market stacksmarket.yml market
#
# Args:
#   $1 member_dir   (e.g. deploy/cluster-members/market)
#   $2 manifest     (e.g. stacksmarket.yml, relative to member_dir)
#   $3 lan_ip       (printed for primary UI registration)

MEMBER_DIR="${1:-}"
MANIFEST_NAME="${2:-}"
LAN_IP="${3:-}"

if [[ -z "$MEMBER_DIR" || -z "$MANIFEST_NAME" || -z "$LAN_IP" ]]; then
	echo "Usage: $0 <member_dir> <manifest.yml> <lan_ip>" >&2
	exit 2
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
MEMBER_ABS="$(cd "$REPO_ROOT/$MEMBER_DIR" && pwd)"
MANIFEST="$MEMBER_ABS/$MANIFEST_NAME"
COMMON_COMPOSE="$SCRIPT_DIR/docker-compose.dockge-agent.yml"
ENV_EXAMPLE="$MEMBER_ABS/env.dockge.example"
ENV_LIVE="$MEMBER_ABS/.env.dockge"
WAIT_HTTP="$SCRIPT_DIR/wait-http.sh"

if [[ ! -f "$MANIFEST" ]]; then
	echo "ERROR: manifest not found: $MANIFEST" >&2
	exit 2
fi
if [[ ! -f "$COMMON_COMPOSE" ]]; then
	echo "ERROR: compose not found: $COMMON_COMPOSE" >&2
	exit 2
fi

if [[ ! -f "$ENV_LIVE" ]]; then
	if [[ -f "$ENV_EXAMPLE" ]]; then
		cp "$ENV_EXAMPLE" "$ENV_LIVE"
		echo "Created $ENV_LIVE from example"
	else
		cat >"$ENV_LIVE" <<'EOF'
DOCKGE_STACKS_DIR=/opt/stacks
DOCKGE_AGENT_HOST_PORT=5001
DOCKGE_AGENT_BIND_ADDR=0.0.0.0
EOF
		echo "Created default $ENV_LIVE"
	fi
fi

# shellcheck disable=SC1090
set -a
# shellcheck source=/dev/null
source "$ENV_LIVE"
set +a

DOCKGE_PORT="${DOCKGE_AGENT_HOST_PORT:-5001}"
STACKS_DIR="${DOCKGE_STACKS_DIR:-/opt/stacks}"

echo "== install Dockge agent ($LAN_IP) =="
echo "  Member:  $MEMBER_ABS"
echo "  Stacks:  $STACKS_DIR"
echo "  Port:    $DOCKGE_PORT"
echo ""

if ! command -v docker >/dev/null 2>&1; then
	echo "ERROR: docker not found" >&2
	exit 2
fi
if ! docker info >/dev/null 2>&1; then
	echo "ERROR: docker daemon not reachable" >&2
	exit 2
fi

load_dockge_image() {
	if docker image inspect louislam/dockge:1 >/dev/null 2>&1; then
		echo "  image present: louislam/dockge:1"
		return 0
	fi
	local cand
	for cand in \
		"${ALFA_DOCKGE_TARBALL:-}" \
		"${HOME}/alfa-ai-cache/docker-images/louislam-dockge-1.tar.gz" \
		/mnt/cluster/docker-images/louislam-dockge-1.tar.gz
	do
		[[ -n "$cand" ]] || continue
		if [[ -f "$cand" ]]; then
			echo "  docker load -i $cand"
			docker load -i "$cand"
			return 0
		fi
	done
	echo "ERROR: louislam/dockge:1 missing and no hub tarball (set ALFA_DOCKGE_TARBALL or copy louislam-dockge-1.tar.gz to ~/alfa-ai-cache/docker-images/)" >&2
	exit 1
}

load_dockge_image

if docker ps --format '{{.Names}}' | grep -qx 'dockge-agent'; then
	echo "  dockge-agent already running; compose up will replace it"
elif command -v ss >/dev/null 2>&1 && ss -H -lnt 2>/dev/null | grep -qE ":${DOCKGE_PORT}([[:space:]]|$)"; then
	echo "ERROR: port $DOCKGE_PORT already in use (not dockge-agent)" >&2
	exit 1
fi

if [[ ! -d "$STACKS_DIR" ]]; then
	mkdir -p "$STACKS_DIR" 2>/dev/null \
		|| sudo -n mkdir -p "$STACKS_DIR" 2>/dev/null \
		|| { echo "ERROR: cannot create $STACKS_DIR (need write or passwordless sudo)" >&2; exit 1; }
fi

PY=python3
if ! command -v "$PY" >/dev/null; then
	echo "ERROR: python3 required to parse $MANIFEST" >&2
	exit 2
fi

while IFS=$'\t' read -r name abs_path; do
	[[ -z "$name" ]] && continue
	[[ "$name" == \#* ]] && continue
	if [[ ! -d "$abs_path" ]]; then
		echo "  WARN: stack path missing, skip symlink: $abs_path"
		continue
	fi
	target="$STACKS_DIR/$name"
	if [[ ! -L "$target" ]] || [[ "$(readlink -f "$target" 2>/dev/null || readlink "$target")" != "$(readlink -f "$abs_path")" ]]; then
		ln -sfn "$abs_path" "$target" 2>/dev/null \
			|| sudo -n ln -sfn "$abs_path" "$target" 2>/dev/null \
			|| { echo "  FAIL: could not symlink $target -> $abs_path" >&2; exit 1; }
		echo "  symlink: $target -> $abs_path"
	else
		echo "  symlink OK: $target"
	fi
done < <("$PY" - "$MANIFEST" <<'PY'
import pathlib, sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8")
name = None
for raw in text.splitlines():
    s = raw.strip()
    if not s or s.startswith("#"):
        continue
    if s.startswith("- name:"):
        name = s.split(":", 1)[1].strip().strip('"').strip("'")
        continue
    if name and s.startswith("path:"):
        path = s.split(":", 1)[1].strip().strip('"').strip("'")
        print(f"{name}\t{path}")
        name = None
        continue
    if "\t" in s and not s.startswith("version") and ":" not in s.split("\t", 1)[0]:
        n, p = s.split("\t", 1)
        print(f"{n}\t{p}")
PY
)

cd "$MEMBER_ABS"
docker compose -f "$COMMON_COMPOSE" --env-file "$ENV_LIVE" up -d

echo ""
echo "Agent ready:"
echo "  local: http://127.0.0.1:${DOCKGE_PORT}/"
echo "  LAN:   http://${LAN_IP}:${DOCKGE_PORT}/  <-- add in primary Dockge on orchestrator"
echo ""
docker ps --format 'table {{.Names}}\t{{.Status}}' | grep -E 'dockge|NAMES' || true

if [[ -f "$WAIT_HTTP" ]]; then
	bash "$WAIT_HTTP" "http://127.0.0.1:${DOCKGE_PORT}/" 60 5
fi
