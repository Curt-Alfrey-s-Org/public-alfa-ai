#!/usr/bin/env bash
# Track A only — dry-run DB/data inventory for brain+DB move to VM100.
# Track B (selected): skip; brain+DB stay on hub. Embed only moves to VM100.
# Does not copy data or change running services.
#
# Usage:
#   bash deploy/cluster-members/pool-shard-opt-in/preflight-migrate-inventory.sh
#   SOURCE_111=operator@hub bash .../preflight-migrate-inventory.sh
set -euo pipefail

SOURCE_111="${SOURCE_111:-operator@hub}"
SOURCE_105="${SOURCE_105:-operator@apps}"
TARGET="${TARGET:-/var/lib/alfa-ai}"

echo "== VM100 migration inventory (dry-run) =="
echo "  Source brain:  $SOURCE_111"
echo "  Source apps:   $SOURCE_105"
echo "  Target paths:  $TARGET/{postgres,redis,app-state,workspace}"
echo ""

check_remote() {
  local host="$1" path="$2"
  if ssh -o BatchMode=yes -o ConnectTimeout=5 "$host" "test -e '$path'" 2>/dev/null; then
    local size
    size="$(ssh -o BatchMode=yes "$host" "du -sh '$path' 2>/dev/null | cut -f1" || echo '?')"
    echo "  OK   $host:$path ($size)"
  else
    echo "  MISS $host:$path"
  fi
}

echo "-- hub (canonical brain data) --"
check_remote "$SOURCE_111" /mnt/ssd/alfa-ai/postgres
check_remote "$SOURCE_111" /mnt/ssd/alfa-ai/redis
check_remote "$SOURCE_111" /mnt/nvme/alfa-ai/app-state
check_remote "$SOURCE_111" /mnt/hub/alfa-ai/repo/alfa-ai/deploy/.env

echo ""
echo "-- apps (apps host — verify before decommission) --"
check_remote "$SOURCE_105" /home/operator/alfa-ai/deploy/.env.apps
ssh -o BatchMode=yes -o ConnectTimeout=5 "$SOURCE_105" \
  "docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E 'alfa-postgres|alfa-redis|alfa-ai-workspace' || true" \
  | sed 's/^/  vol  /'

echo ""
echo "-- pool-opt-in target dirs (local) --"
for d in postgres redis app-state workspace; do
  if [[ -d "$TARGET/$d" ]]; then
    echo "  OK   $TARGET/$d ($(du -sh "$TARGET/$d" 2>/dev/null | cut -f1))"
  else
    echo "  MISS $TARGET/$d (create before rsync)"
  fi
done

echo ""
echo "Next: see .cursor/plans/VM100_ALFA_AI_MIGRATION.md Phase 2–3"