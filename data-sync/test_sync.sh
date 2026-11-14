#!/usr/bin/env bash
# End-to-end test of sync_menu.py without Docker: a throwaway PostgreSQL cluster built
# by database/init/run-all.sh, plus the fake Odoo. Checks:
#   dry run changes nothing · first run links all 12 dishes · second run changes nothing ·
#   a price change updates exactly one product with VAT-included rounding · a new dish is created.
set -euo pipefail
cd "$(dirname "$0")/.."

source database/pg-bin.sh
PY=$(command -v python3 || command -v python)
PGPORT=55435 ODOO_PORT=18069 PASSWORD=local-test

TMP=$(mktemp -d)
cleanup() {
  if [[ -n ${ODOO_PID:-} ]]; then
    # On Windows (Git Bash) kill only stops the wrapper: stop the native process too.
    winpid=$(cat "/proc/$ODOO_PID/winpid" 2>/dev/null || true)
    kill "$ODOO_PID" 2>/dev/null || true
    [[ -n $winpid ]] && taskkill //F //PID "$winpid" >/dev/null 2>&1 || true
  fi
  pg_ctl -D "$TMP/data" -m fast -w stop >/dev/null 2>&1 || true
  rm -rf "$TMP"
}
trap cleanup EXIT
initdb -D "$TMP/data" -U postgres -A trust -E UTF8 --locale=C >/dev/null
pg_ctl -D "$TMP/data" -o "$(pg_start_opts $PGPORT "$TMP")" -l "$TMP/log" -w start >/dev/null
PGHOST=localhost PGPORT=$PGPORT PGUSER=postgres DB_DIR="$PWD/database" \
  POS_PASSWORD=$PASSWORD REPORTING_PASSWORD=$PASSWORD bash database/init/run-all.sh >/dev/null

FAKE_ODOO_PASSWORD=$PASSWORD FAKE_ODOO_PORT=$ODOO_PORT "$PY" data-sync/fake_odoo/fake_odoo.py >"$TMP/odoo.log" 2>&1 &
ODOO_PID=$!
for _ in $(seq 50); do grep -q fake_odoo "$TMP/odoo.log" && break; sleep 0.1; done
grep -q "port $ODOO_PORT" "$TMP/odoo.log" || { echo "FAILED fake Odoo did not start:" >&2; cat "$TMP/odoo.log" >&2; exit 1; }

export ODOO_URL=http://127.0.0.1:$ODOO_PORT ODOO_PASSWORD=$PASSWORD PGPASSWORD=$PASSWORD PYTHONIOENCODING=utf-8
export ALMI_PSQL="psql -X -h localhost -p $PGPORT -U reporting -d almi_chain"
admin() { psql -X -q -h localhost -p "$PGPORT" -U postgres -d almi_chain -c "$1" </dev/null >/dev/null; }

expect() {  # expect <label> <exact last line> [sync args...]
  local label=$1 want=$2; shift 2
  local got; got=$("$PY" data-sync/sync_menu.py "$@" 2>&1 | tail -1) || true   # a crash still reaches the FAILED line
  if [[ $got == "$want" ]]; then echo "OK    $label"; else echo "FAILED $label: got '$got', want '$want'" >&2; exit 1; fi
}

expect "dry run changes nothing"  "Sync (DRY RUN, nothing changed): 0 new, 12 updated, 0 unchanged." --dry-run
expect "first run links 12 dishes" "Sync: 0 new, 12 updated, 0 unchanged."
expect "second run changes nothing" "Sync: 0 new, 0 updated, 12 unchanged."
admin "UPDATE dish SET price = 2.00 WHERE dish_id = 1"
expect "price change updates one product" "Sync: 0 new, 1 updated, 11 unchanged."
price=$("$PY" - <<EOF
import xmlrpc.client
o = xmlrpc.client.ServerProxy("$ODOO_URL/xmlrpc/2/object")
ids = o.execute_kw("shop", 2, "$PASSWORD", "product.template", "search", [[["default_code", "=", "ALMI-1"]]], {})
print(o.execute_kw("shop", 2, "$PASSWORD", "product.template", "read", [ids, ["list_price"]], {})[0]["list_price"])
EOF
)
[[ $price == 2.2 ]] && echo "OK    price includes VAT (2.00 + 10 % = 2.2)" || { echo "FAILED list_price is $price, want 2.2" >&2; exit 1; }
admin "INSERT INTO dish (name, category, price, vat_rate) VALUES ('Idiazabal', 'starter', 9.09, 10)"
expect "new dish is created" "Sync: 1 new, 0 updated, 12 unchanged."
echo "Sync tests: all OK"
