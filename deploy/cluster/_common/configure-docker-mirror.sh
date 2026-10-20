#!/usr/bin/env bash
# Configure /etc/docker/daemon.json to use the hub (hub) pull-through registry mirror.
#
# Idempotent: only rewrites daemon.json when the mirror list changes, and only reloads
# the docker daemon when something actually changed. Runs on Ubuntu/apps, WSL workers,
# and hub itself (where the mirror and client coexist).
#
# Docs:
#   https://docs.docker.com/reference/cli/dockerd/#daemon-configuration-file
#   https://docs.docker.com/docker-hub/image-library/mirror/
#
# Usage:
#   ALFA_REGISTRY_MIRROR=http://hub \
#     bash deploy/cluster/_common/configure-docker-mirror.sh

set -euo pipefail

MIRROR_URL="${ALFA_REGISTRY_MIRROR:-http://hub}"
DAEMON_JSON="/etc/docker/daemon.json"

echo "== configure-docker-mirror =="
echo "  mirror:  $MIRROR_URL"
echo "  target:  $DAEMON_JSON"

# Registry is plain HTTP on the LAN -> mark as insecure so Docker does not try TLS.
# Keep any other existing keys intact via a merge.
have_jq=1
command -v jq >/dev/null 2>&1 || have_jq=0

sudo mkdir -p "$(dirname "$DAEMON_JSON")"
sudo touch "$DAEMON_JSON"
current="$(sudo cat "$DAEMON_JSON" 2>/dev/null || true)"
[[ -z "$current" ]] && current='{}'

if [[ $have_jq -eq 1 ]]; then
    merged="$(printf '%s' "$current" | jq --arg m "$MIRROR_URL" '
        .["registry-mirrors"] = ((.["registry-mirrors"] // []) | map(select(. != $m)) | [$m] + .)
        | .["insecure-registries"] = ((.["insecure-registries"] // []) | map(select(. != ($m | sub("^https?://"; "")))) | [($m | sub("^https?://"; ""))] + .)
    ')"
else
    # Fallback when jq is missing: overwrite with a minimal, well-formed daemon.json.
    host_no_scheme="${MIRROR_URL#http://}"; host_no_scheme="${host_no_scheme#https://}"
    merged=$(cat <<JSON
{
  "registry-mirrors": ["$MIRROR_URL"],
  "insecure-registries": ["$host_no_scheme"]
}
JSON
)
fi

if diff <(printf '%s' "$current") <(printf '%s' "$merged") >/dev/null 2>&1; then
    echo "  daemon.json already current; no restart needed"
    exit 0
fi

tmp="$(mktemp)"
printf '%s\n' "$merged" > "$tmp"
sudo install -m 0644 "$tmp" "$DAEMON_JSON"
rm -f "$tmp"

echo "  daemon.json updated, restarting docker daemon..."
if command -v systemctl >/dev/null 2>&1 && systemctl is-system-running >/dev/null 2>&1; then
    sudo systemctl reload docker || sudo systemctl restart docker
elif command -v service >/dev/null 2>&1; then
    sudo service docker restart
else
    echo "  WARN: no systemctl/service; restart Docker Desktop or dockerd manually"
fi

echo "  done. verify: docker info | grep -A2 'Registry Mirrors'"
