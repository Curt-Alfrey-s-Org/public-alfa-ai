#!/usr/bin/env bash
# Apply agent runtime tables (runs, tasks, artifacts) to brain Postgres.
#
# Idempotent: infra/db/schema.sql uses CREATE TABLE IF NOT EXISTS.
#
# Usage (From hub as operator):
#   bash scripts/ensure-runtime-schema.sh
#
# Official psql: https://www.postgresql.org/docs/current/app-psql.html
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SCHEMA_FILE="$REPO_ROOT/infra/db/schema.sql"

# shellcheck source=/dev/null
source "$SCRIPT_DIR/_alfa_compose_env.sh"

PG_CONTAINER="${ALFA_POSTGRES_CONTAINER:-alfa-postgres}"
PG_USER="${ALFA_POSTGRES_USER:-alfaai}"
PG_DB="${ALFA_POSTGRES_DB:-alfaai}"

if [[ ! -f "$SCHEMA_FILE" ]]; then
  echo "ERROR: missing $SCHEMA_FILE" >&2
  exit 1
fi

if ! "${ALFA_AI_DOCKER[@]}" ps --format '{{.Names}}' | grep -qx "$PG_CONTAINER"; then
  echo "ERROR: postgres container '$PG_CONTAINER' is not running" >&2
  echo "Start the dedicated postgres stack first (Dockge stack 'postgres' on hub)." >&2
  exit 1
fi

echo "== ensure-runtime-schema: apply $SCHEMA_FILE =="
"${ALFA_AI_DOCKER[@]}" exec -i "$PG_CONTAINER" psql -v ON_ERROR_STOP=1 -U "$PG_USER" -d "$PG_DB" <"$SCHEMA_FILE"

echo "== ensure-runtime-schema: verify runs table =="
"${ALFA_AI_DOCKER[@]}" exec "$PG_CONTAINER" psql -U "$PG_USER" -d "$PG_DB" -c "\dt runs"

echo "== ensure-runtime-schema: ok =="
