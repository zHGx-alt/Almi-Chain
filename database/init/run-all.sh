#!/usr/bin/env bash
# Builds the almi_chain database and runs every test. Any failure stops with exit 1.
#
# In Docker it runs once from /docker-entrypoint-initdb.d (see docker-compose.yml),
# with the SQL files mounted at /database. Locally, database/test-local.sh calls it
# with DB_DIR and the PG* variables pointing at a throwaway cluster.
#
# Environment:
#   DB_DIR              folder with schema/, tests/, seed/, queries/  (default /database)
#   POS_PASSWORD        password for the pos_app account               (required)
#   REPORTING_PASSWORD  password for the reporting account             (required)
#   PGUSER / PGHOST / PGPORT  as usual for psql (default user: $POSTGRES_USER or postgres)
set -euo pipefail

DB_DIR=${DB_DIR:-/database}
ADMIN=${PGUSER:-${POSTGRES_USER:-postgres}}
: "${POS_PASSWORD:?POS_PASSWORD is not set}"
: "${REPORTING_PASSWORD:?REPORTING_PASSWORD is not set}"
# The SQL files are UTF-8; without this, psql on Windows reads them in the console
# code page and stores "Caña" as "CaÃ±a".
export PGCLIENTENCODING=UTF8

run() { psql -X -q -v ON_ERROR_STOP=1 "$@" </dev/null; }
fail() { echo "FAILED: $*" >&2; exit 1; }

# Counts the lines of a test file's output that start with "OK" after psql's prefix.
count_ok() { grep -c -E '(^|NOTICE: +)OK ' || true; }

run -U "$ADMIN" -d postgres -c "CREATE DATABASE almi_chain"

for f in schema/01-tables schema/02-rules schema/03-roles; do
  run -U "$ADMIN" -d almi_chain -f "$DB_DIR/$f.sql" >/dev/null || fail "$f.sql"
done
echo "Schema, rules and roles created."

out=$(run -U "$ADMIN" -d almi_chain -f "$DB_DIR/tests/05-constraint-tests.sql" 2>&1) || { echo "$out" >&2; fail "05-constraint-tests.sql"; }
n=$(echo "$out" | count_ok)
[[ $n -eq 49 ]] || { echo "$out" >&2; fail "constraint tests: $n/49 OK"; }
echo "Constraint tests: 49/49 OK"

run -U "$ADMIN" -d almi_chain -f "$DB_DIR/seed/06-sample-data.sql" >/dev/null || fail "06-sample-data.sql"
n=$(run -U "$ADMIN" -d almi_chain -tA -c "SELECT count(*) FROM invoice")
[[ $n -eq 8 ]] || fail "sample data: $n invoices, expected 8"
echo "Sample data loaded: 8 invoices."

run -U "$ADMIN" -d almi_chain -f "$DB_DIR/queries/07-queries.sql" >/dev/null || fail "07-queries.sql"
echo "Queries: 15 run without errors."

run -U "$ADMIN" -d almi_chain -v pos_password="$POS_PASSWORD" \
    -v reporting_password="$REPORTING_PASSWORD" -f "$DB_DIR/schema/08-users.sql" >/dev/null || fail "08-users.sql"

for account in pos_app reporting; do
  if [[ $account == pos_app ]]; then pw=$POS_PASSWORD; else pw=$REPORTING_PASSWORD; fi
  out=$(PGPASSWORD=$pw run -U "$account" -d almi_chain -v account="$account" \
        -f "$DB_DIR/tests/09-user-tests.sql" 2>&1) || { echo "$out" >&2; fail "09-user-tests.sql as $account"; }
  n=$(echo "$out" | count_ok)
  [[ $n -eq 9 ]] || { echo "$out" >&2; fail "user tests as $account: $n/9 OK"; }
done

echo "Database ready: 49/49 constraint tests, 9/9 + 9/9 user tests"
