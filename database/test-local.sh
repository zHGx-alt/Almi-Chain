#!/usr/bin/env bash
# Runs init/run-all.sh against a throwaway PostgreSQL cluster on port 55433, without
# Docker. It never touches a PostgreSQL server already installed on the machine.
# Finds PostgreSQL with pg-bin.sh (PATH, /usr/lib/postgresql or C:\Program Files\PostgreSQL).
set -euo pipefail
cd "$(dirname "$0")"

source ./pg-bin.sh

TMP=$(mktemp -d)
trap 'pg_ctl -D "$TMP/data" -m fast -w stop >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT
initdb -D "$TMP/data" -U postgres -A trust -E UTF8 --locale=C >/dev/null
pg_ctl -D "$TMP/data" -o "$(pg_start_opts 55433 "$TMP")" -l "$TMP/log" -w start >/dev/null

PGHOST=localhost PGPORT=55433 PGUSER=postgres DB_DIR="$PWD" \
POS_PASSWORD=local-test REPORTING_PASSWORD=local-test \
  bash init/run-all.sh
