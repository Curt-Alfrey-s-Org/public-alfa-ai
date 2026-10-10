#!/bin/sh
# pg-backup.sh — nightly logical backup (pg_dump custom format) for the ALFa AI
# brain Postgres. Phase 3 backup workstream (docs/ROADMAP.md) / audit PG-005.
#
# Runs INSIDE the postgres:16.13-alpine sidecar declared in
# deploy/docker-compose.postgres-backup.yml. POSIX sh on purpose: the alpine
# postgres image ships busybox ash, not bash (busybox >= 1.36 supports
# `set -o pipefail`). The sidecar image pin MUST track the dedicated postgres
# server image so pg_dump matches the server major. PGHOST etc come from the
# sidecar compose (defaults to 'alfa-postgres' container from dedicated stack).
# (PostgreSQL 16 manual: https://www.postgresql.org/docs/16/app-pgdump.html).
#
# What one run does (https://www.postgresql.org/docs/16/backup-dump.html):
#   1. pg_dumpall --globals-only  -> globals/globals-<ts>.sql  (roles/grants —
#      not included in per-database pg_dump; see
#      https://www.postgresql.org/docs/16/app-pg-dumpall.html)
#   2. pg_dump -Fc for EVERY non-template database (alfaai + litellm DB when
#      LiteLLM provisions one)            -> daily/<db>-<ts>.dump
#   3. verify each fresh dump with `pg_restore --list` (fail-loud on a dump
#      pg_restore cannot read: https://www.postgresql.org/docs/16/app-pgrestore.html)
#   4. promote at most one dump per db per 7 days  -> weekly/
#   5. rotate: KEEP_DAILY daily dumps + globals, KEEP_WEEKLY weekly dumps
#   6. write metrics/alfa_ai_pg_backup.prom (node_exporter textfile-collector
#      format) + state/last-success epoch — backup-freshness hook for the
#      monitoring stack (ROADMAP Phase 4).
#
# Scheduling: daemon mode runs the backup once per day at BACKUP_TIME, and
# also at container start when the newest success is older than MAX_AGE_HOURS
# (self-healing after host downtime; safe to re-run any time — each run writes
# new timestamped files and rotation cleans up).
#
# A failed run logs ERROR, records exit code 1 in the metrics file, and keeps
# the daemon alive (the freshness metric going stale IS the alert signal —
# crash-looping the sidecar on a transient DB outage would hide it).
#
# Modes:
#   pg-backup.sh            daemon loop (container entrypoint default)
#   pg-backup.sh once       single run; exit non-zero on failure
#
# Env (libpq vars consumed by pg_dump/psql directly):
#   PGHOST (alfa-ai-postgres)  PGPORT (5432)  PGUSER (alfaai)
#   PGPASSWORD (REQUIRED — POSTGRES_PASSWORD from deploy/.env)
#   BACKUP_DIR (/backups)  BACKUP_TIME (03:30, container clock = UTC)
#   KEEP_DAILY (7)  KEEP_WEEKLY (4)  MAX_AGE_HOURS (26)
#   LIVENESS_FILE (/run/alfa-pg-backup/liveness) — ephemeral daemon heartbeat;
#     compose mounts this parent on tmpfs so the 30 s touch does not dirty the
#     HDD backup bind (Docker tmpfs: https://docs.docker.com/engine/storage/tmpfs/).
#     last-success and dump-sizes stay under $BACKUP_DIR/state on the host bind.
#
# Restore runbook: docs/operations/POSTGRES_BACKUP_RESTORE_111.md

set -eu
set -o pipefail

PGHOST="${PGHOST:-alfa-ai-postgres}"
PGPORT="${PGPORT:-5432}"
PGUSER="${PGUSER:-alfaai}"
export PGHOST PGPORT PGUSER

BACKUP_DIR="${BACKUP_DIR:-/backups}"
BACKUP_TIME="${BACKUP_TIME:-03:30}"
KEEP_DAILY="${KEEP_DAILY:-7}"
KEEP_WEEKLY="${KEEP_WEEKLY:-4}"
MAX_AGE_HOURS="${MAX_AGE_HOURS:-26}"
LIVENESS_FILE="${LIVENESS_FILE:-/run/alfa-pg-backup/liveness}"

METRICS_FILE="$BACKUP_DIR/metrics/alfa_ai_pg_backup.prom"
STATE_DIR="$BACKUP_DIR/state"

log() { printf '%s pg-backup: %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"; }

ensure_tree() {
  mkdir -p "$BACKUP_DIR/daily" "$BACKUP_DIR/weekly" "$BACKUP_DIR/globals" \
    "$BACKUP_DIR/metrics" "$STATE_DIR"
}

preflight() {
  if [ -z "${PGPASSWORD:-}" ]; then
    log "ERROR: PGPASSWORD is empty — set POSTGRES_PASSWORD in deploy/.env"
    return 1
  fi
  ensure_tree
  if ! touch "$STATE_DIR/.write-test" 2>/dev/null; then
    log "ERROR: $BACKUP_DIR is not writable (host bind: ALFA_AI_BACKUP_HOST_DIR)"
    return 1
  fi
  rm -f "$STATE_DIR/.write-test"
  if ! pg_isready -t 5 >/dev/null 2>&1; then
    log "ERROR: postgres not ready at $PGHOST:$PGPORT (pg_isready failed)"
    return 1
  fi
}

# Keep the $3 newest files matching $2* directly under $1; delete the rest.
# Filenames are machine-generated (no spaces/newlines) and timestamped, so
# lexicographic sort -r == newest first.
prune_keep() {
  _dir="$1"; _prefix="$2"; _keep="$3"; _i=0
  # shellcheck disable=SC2044 # machine-generated filenames, no whitespace
  for _f in $(find "$_dir" -maxdepth 1 -type f -name "${_prefix}*" | sort -r); do
    _i=$((_i + 1))
    if [ "$_i" -gt "$_keep" ]; then
      rm -f "$_f"
      log "rotated out $_f"
    fi
  done
}

# Copy the fresh daily dump ($2) for database $1 into weekly/ when the newest
# weekly dump for that db is missing or older than 6 days (self-healing — no
# dependence on the host being up on a specific weekday).
promote_weekly() {
  _db="$1"; _dump="$2"
  _newest_weekly="$(find "$BACKUP_DIR/weekly" -maxdepth 1 -type f -name "${_db}-*.dump" -mtime -6 | head -1)"
  if [ -z "$_newest_weekly" ]; then
    cp "$_dump" "$BACKUP_DIR/weekly/$(basename "$_dump")"
    log "promoted $(basename "$_dump") to weekly/"
  fi
}

# write_metrics <exit_code> <duration_seconds>
# node_exporter textfile-collector format; atomic tmp+mv so a scraper never
# reads a half-written file.
write_metrics() {
  _ec="$1"; _dur="$2"
  _last_ok=0
  [ -f "$STATE_DIR/last-success" ] && _last_ok="$(cat "$STATE_DIR/last-success")"
  _tmp="$BACKUP_DIR/metrics/.alfa_ai_pg_backup.prom.tmp"
  {
    echo "# HELP alfa_ai_pg_backup_last_success_timestamp_seconds Unix time of the last fully verified backup run."
    echo "# TYPE alfa_ai_pg_backup_last_success_timestamp_seconds gauge"
    echo "alfa_ai_pg_backup_last_success_timestamp_seconds $_last_ok"
    echo "# HELP alfa_ai_pg_backup_last_run_timestamp_seconds Unix time of the last attempted backup run."
    echo "# TYPE alfa_ai_pg_backup_last_run_timestamp_seconds gauge"
    echo "alfa_ai_pg_backup_last_run_timestamp_seconds $(date +%s)"
    echo "# HELP alfa_ai_pg_backup_last_run_exit_code Exit code of the last attempted backup run (0 = success)."
    echo "# TYPE alfa_ai_pg_backup_last_run_exit_code gauge"
    echo "alfa_ai_pg_backup_last_run_exit_code $_ec"
    echo "# HELP alfa_ai_pg_backup_last_run_duration_seconds Wall-clock duration of the last attempted backup run."
    echo "# TYPE alfa_ai_pg_backup_last_run_duration_seconds gauge"
    echo "alfa_ai_pg_backup_last_run_duration_seconds $_dur"
    echo "# HELP alfa_ai_pg_backup_dump_bytes Size of the newest verified daily dump per database."
    echo "# TYPE alfa_ai_pg_backup_dump_bytes gauge"
    if [ -f "$STATE_DIR/dump-sizes" ]; then
      while read -r _mdb _mbytes; do
        [ -n "$_mdb" ] && echo "alfa_ai_pg_backup_dump_bytes{database=\"$_mdb\"} $_mbytes"
      done < "$STATE_DIR/dump-sizes"
    fi
  } > "$_tmp"
  mv "$_tmp" "$METRICS_FILE"
}

run_backup() {
  _start="$(date +%s)"
  _ts="$(date -u '+%Y%m%d-%H%M%S')"
  _rc=0

  log "backup run starting (ts=$_ts host=$PGHOST)"
  if ! preflight; then
    write_metrics 1 0 2>/dev/null || true
    return 1
  fi

  # 1. Cluster globals (roles, grants) — required for a from-scratch restore.
  _gtmp="$BACKUP_DIR/globals/.globals-$_ts.sql.inprogress"
  if pg_dumpall --globals-only > "$_gtmp"; then
    mv "$_gtmp" "$BACKUP_DIR/globals/globals-$_ts.sql"
    log "globals dumped: globals-$_ts.sql"
  else
    rm -f "$_gtmp"
    log "ERROR: pg_dumpall --globals-only failed"
    _rc=1
  fi

  # 2+3. Per-database custom-format dump + pg_restore --list verification.
  _dbs="$(psql -d postgres -Atc \
    "SELECT datname FROM pg_database WHERE NOT datistemplate ORDER BY datname")" || {
    log "ERROR: could not enumerate databases"
    _dbs=""
    _rc=1
  }
  : > "$STATE_DIR/dump-sizes.new"
  for _db in $_dbs; do
    _dtmp="$BACKUP_DIR/daily/.${_db}-$_ts.dump.inprogress"
    _dout="$BACKUP_DIR/daily/${_db}-$_ts.dump"
    if pg_dump -Fc -d "$_db" -f "$_dtmp" && pg_restore --list "$_dtmp" >/dev/null; then
      mv "$_dtmp" "$_dout"
      _bytes="$(wc -c < "$_dout" | tr -d ' ')"
      printf '%s %s\n' "$_db" "$_bytes" >> "$STATE_DIR/dump-sizes.new"
      log "dumped + verified $_db ($_bytes bytes) -> $(basename "$_dout")"
      promote_weekly "$_db" "$_dout"
      prune_keep "$BACKUP_DIR/daily" "${_db}-" "$KEEP_DAILY"
      prune_keep "$BACKUP_DIR/weekly" "${_db}-" "$KEEP_WEEKLY"
    else
      rm -f "$_dtmp"
      log "ERROR: pg_dump or pg_restore --list verification failed for $_db"
      _rc=1
    fi
  done
  prune_keep "$BACKUP_DIR/globals" "globals-" "$KEEP_DAILY"

  _dur=$(( $(date +%s) - _start ))
  if [ "$_rc" -eq 0 ] && [ -n "$_dbs" ]; then
    date +%s > "$STATE_DIR/last-success"
    mv "$STATE_DIR/dump-sizes.new" "$STATE_DIR/dump-sizes"
    log "backup run OK (${_dur}s)"
  else
    rm -f "$STATE_DIR/dump-sizes.new"
    log "ERROR: backup run FAILED (${_dur}s) — freshness metric will go stale"
    _rc=1
  fi
  write_metrics "$_rc" "$_dur"
  return "$_rc"
}

last_success_stale() {
  [ -f "$STATE_DIR/last-success" ] || return 0
  _age=$(( $(date +%s) - $(cat "$STATE_DIR/last-success") ))
  [ "$_age" -gt $(( MAX_AGE_HOURS * 3600 )) ]
}

daemon() {
  ensure_tree
  _liveness_dir="$(dirname "$LIVENESS_FILE")"
  mkdir -p "$_liveness_dir"
  log "daemon starting (BACKUP_TIME=$BACKUP_TIME KEEP_DAILY=$KEEP_DAILY KEEP_WEEKLY=$KEEP_WEEKLY LIVENESS_FILE=$LIVENESS_FILE)"
  # Mark alive before the catch-up run: a long pg_dump here must not look like
  # a wedged loop to the healthcheck.
  touch "$LIVENESS_FILE"
  if last_success_stale; then
    log "no backup within ${MAX_AGE_HOURS}h — running catch-up backup now"
    run_backup || true
  fi
  _last_run_day=""
  while :; do
    touch "$LIVENESS_FILE"   # healthcheck freshness; not on the HDD backup bind
    _now_hm="$(date -u '+%H:%M')"
    _today="$(date -u '+%Y-%m-%d')"
    if [ "$_now_hm" = "$BACKUP_TIME" ] && [ "$_today" != "$_last_run_day" ]; then
      _last_run_day="$_today"
      run_backup || true
    fi
    sleep 30
  done
}

case "${1:-daemon}" in
  once)   run_backup ;;
  daemon) daemon ;;
  *)
    echo "usage: pg-backup.sh [daemon|once]" >&2
    exit 2
    ;;
esac
