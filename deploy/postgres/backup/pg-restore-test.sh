#!/usr/bin/env bash
# pg-restore-test.sh — restore drill for the brain Postgres backups.
#
# "A backup that has never been restored does not count" (docs/ROADMAP.md
# Phase 3 item 2). This script restores a daily dump into a THROWAWAY
# postgres:16.13-alpine container (never touches alfa-ai-postgres or its
# volume), verifies pg_restore exits clean and that restored tables exist,
# then removes the container. Idempotent and safe to re-run; run quarterly
# per docs/operations/POSTGRES_BACKUP_RESTORE_111.md.
#
# Usage (on the host that holds the backups, e.g. hub as root):
#   sudo bash deploy/postgres/backup/pg-restore-test.sh                 # newest daily dump
#   sudo bash deploy/postgres/backup/pg-restore-test.sh /path/to/x.dump # specific dump
#
# Env:
#   ALFA_AI_BACKUP_HOST_DIR  backup root (default /mnt/hub/alfa-ai/backups/postgres)
#
# Exits non-zero with a clear message on any failure (fail-loud per
# script-creation-standards). No AI/LiteLLM dependency.

set -euo pipefail

BACKUP_ROOT="${ALFA_AI_BACKUP_HOST_DIR:-/mnt/hub/alfa-ai/backups/postgres}"
# Pin must track alfa-ai-postgres in deploy/docker-compose.yml (pg_restore
# major must match the dump's server major — PostgreSQL 16 manual).
IMG="postgres:16.13-alpine"
NAME="alfa-pg-restore-test"

die() { echo "ERROR: $*" >&2; exit 1; }

# --- Preflight ---------------------------------------------------------------
command -v docker >/dev/null 2>&1 || die "docker not on PATH (run with sudo on hub)"
docker info >/dev/null 2>&1 || die "cannot talk to the Docker daemon (sudo required?)"

DUMP="${1:-}"
if [[ -z "$DUMP" ]]; then
  # Default: newest dump of a real application DB. The `postgres` maintenance
  # DB is dumped too but has no user tables, so it makes a meaningless drill.
  DUMP="$(find "$BACKUP_ROOT/daily" -maxdepth 1 -type f -name '*.dump' ! -name 'postgres-*' 2>/dev/null | sort -r | head -1 || true)"
fi
[[ -n "$DUMP" && -f "$DUMP" ]] || die "no dump found (looked in $BACKUP_ROOT/daily; pass a path explicitly)"

BASE="$(basename "$DUMP" .dump)"
# Filenames are <db>-YYYYmmdd-HHMMSS.dump (written by pg-backup.sh).
DB="$(echo "$BASE" | sed -E 's/-[0-9]{8}-[0-9]{6}$//')"
[[ -n "$DB" && "$DB" != "$BASE" ]] || die "cannot derive database name from $(basename "$DUMP")"

echo "== Restore drill: $(basename "$DUMP") (database: $DB) =="

cleanup() { docker rm -f "$NAME" >/dev/null 2>&1 || true; }
trap cleanup EXIT
cleanup

# --- Throwaway server (no published ports, no shared network/volume) ---------
docker run -d --name "$NAME" \
  -e POSTGRES_PASSWORD=restore-drill \
  -v "$(cd "$(dirname "$DUMP")" && pwd)":/restore:ro \
  "$IMG" >/dev/null

# Probe over TCP: during init the entrypoint runs a TEMPORARY bootstrap server
# that only listens on the Unix socket, so a socket-based pg_isready reports
# ready too early (official postgres image init flow).
echo -n "waiting for throwaway postgres "
READY=0
for _ in $(seq 1 60); do
  if docker exec "$NAME" pg_isready -h 127.0.0.1 -U postgres -q 2>/dev/null; then
    READY=1
    echo " ready"
    break
  fi
  echo -n "."
  sleep 1
done
[[ "$READY" -eq 1 ]] || {
  docker logs --tail 30 "$NAME" >&2 || true
  die "throwaway postgres did not become ready in 60s"
}

# --- Restore + verify ---------------------------------------------------------
# Restore into a scratch DB (no --create): works for any dump including the
# `postgres` maintenance DB. --no-owner/--no-privileges because the source
# roles do not exist in the throwaway instance — the drill verifies data
# readability; role wiring is covered by the globals restore in the runbook
# (https://www.postgresql.org/docs/16/app-pgrestore.html).
docker exec "$NAME" createdb -U postgres restoredrill
docker exec "$NAME" pg_restore -U postgres -d restoredrill --no-owner --no-privileges \
  --exit-on-error "/restore/$(basename "$DUMP")" || {
  docker logs --tail 30 "$NAME" >&2 || true
  die "pg_restore failed for $(basename "$DUMP")"
}

TABLES="$(docker exec "$NAME" psql -U postgres -d restoredrill -Atc \
  "SELECT count(*) FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
   WHERE c.relkind = 'r' AND n.nspname NOT IN ('pg_catalog','information_schema')")"
echo "restored ordinary tables from $DB dump: $TABLES"

if [[ "$TABLES" =~ ^[0-9]+$ ]] && (( TABLES >= 1 )); then
  echo "== RESULT: OK — $(basename "$DUMP") restores cleanly ($TABLES tables) =="
else
  die "restore produced no user tables in $DB — investigate the dump before trusting this backup line"
fi
