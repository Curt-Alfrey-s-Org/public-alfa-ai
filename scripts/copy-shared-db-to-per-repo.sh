#!/usr/bin/env bash
# Safe copy of a database from the shared alfa-postgres (dedicated stack)
# into a new per-repo database (for isolation or pre-VM migration).
#
# NEVER uses -v / volume rm. Only logical dumps + CREATE DATABASE.
# Run on the host where alfa-postgres container is running (apps or hub).
#
# Usage:
#   bash scripts/copy-shared-db-to-per-repo.sh <source_db> <target_db> [target_owner]
#
# Example:
#   bash scripts/copy-shared-db-to-per-repo.sh alfaai rankingsbot rankingsbot_user
#
# Requirements:
#   - docker (or sudo docker) available
#   - POSTGRES_PASSWORD or the password for the source user in env or prompt
#   - The dedicated postgres stack is up (container "alfa-postgres")
#
# After copy:
#   - Update the repo's .env DATABASE_URL to point at the new DB
#   - The original source DB and its data are untouched.

set -euo pipefail

SRC_DB="${1:-}"
TGT_DB="${2:-}"
TGT_OWNER="${3:-${TGT_DB}_user}"

if [[ -z "$SRC_DB" || -z "$TGT_DB" ]]; then
  echo "Usage: $0 <source_db> <target_db> [target_owner]"
  echo "  e.g. $0 alfaai rankingsbot rankingsbot_user"
  exit 1
fi

if ! docker ps --format '{{.Names}}' | grep -q '^alfa-postgres$'; then
  echo "ERROR: alfa-postgres container not running. Start the dedicated postgres stack first."
  exit 1
fi

echo "== Safe DB copy (no volume operations) =="
echo "  source: $SRC_DB  -> target: $TGT_DB (owner: $TGT_OWNER)"

# Prompt or use env for password if needed (the script connects as a superuser or the source owner).
# For simplicity we exec into the container and use the POSTGRES_PASSWORD if present in container env,
# or fall back to prompting (operator pastes).
PGPASSWORD="${POSTGRES_PASSWORD:-}"
if [[ -z "$PGPASSWORD" ]]; then
  read -r -s -p "Enter password for postgres user in alfa-postgres (or set POSTGRES_PASSWORD): " PGPASSWORD
  echo
fi

echo "Creating target database if missing..."
docker exec -e PGPASSWORD="$PGPASSWORD" -i alfa-postgres \
  psql -U "${ALFA_POSTGRES_USER:-alfaai}" -d postgres \
  -c "CREATE DATABASE ${TGT_DB} OWNER ${TGT_OWNER};" 2>/dev/null || true

echo "Dumping source (custom format) and restoring into target (no owner/privs to keep simple)..."
# We pipe inside one docker exec to avoid temp files on host.
docker exec -e PGPASSWORD="$PGPASSWORD" -i alfa-postgres \
  sh -c "pg_dump -U ${ALFA_POSTGRES_USER:-alfaai} -Fc ${SRC_DB}" \
| docker exec -i -e PGPASSWORD="$PGPASSWORD" alfa-postgres \
  pg_restore -U "${ALFA_POSTGRES_USER:-alfaai}" -d "${TGT_DB}" --no-owner --no-privileges --clean --if-exists || {
    echo "  (restore may report non-fatal errors for extensions/roles; verify below)"
  }

echo "Verifying target DB has objects..."
docker exec -e PGPASSWORD="$PGPASSWORD" -i alfa-postgres \
  psql -U "${ALFA_POSTGRES_USER:-alfaai}" -d "${TGT_DB}" -c '\dt' | cat

echo ""
echo "Done. Original '$SRC_DB' is unchanged."
echo "Update the consuming app .env to:"
echo "  DATABASE_URL=postgresql://...@${TGT_OWNER}@<host>:5432/${TGT_DB}"
echo ""
echo "Reminder: never run 'docker compose down -v' on the postgres or redis stacks."