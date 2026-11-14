#!/usr/bin/env bash
# Restore test of the Odoo backup, with a side-by-side comparison.
#
# Restores the latest snapshot into an ISOLATED environment, without touching production:
#   - throwaway PostgreSQL and Odoo on their own Docker network ("restore-test"), invisible to the
#     production Odoo (restoring into the production PostgreSQL would let production's job scheduler
#     connect to the copy as well)
#   - the test Odoo only listens on the server's 127.0.0.1:8070
# Compares what was restored with the original (Odoo and the chain's own database almi_chain), logs
# in to the restored Odoo, and deletes everything at the end.
#
# Usage:  sudo ./test-restore.sh [usb|raid|s3]  (default usb: the off-site copy;
#         s3 reads the keys from /root/.config/backup-odoo/s3.env, like backup-odoo.sh)
set -euo pipefail

SOURCE=${1:-usb}
export RESTIC_PASSWORD_FILE=/root/.config/backup-odoo/restic.pass
export RESTIC_CACHE_DIR=/var/cache/restic
COMPOSE=(docker compose -f /opt/odoo/docker-compose.yml)
TARGET=/srv/data/restore-test
NET=restore-test
PG=pg-restore-test
ODOO=odoo-restore-test

set -a; source /opt/odoo/.env; set +a
log() { printf '\n==> [%s] %s\n' "$(date +%T)" "$*"; }
# </dev/null: otherwise "docker compose exec" eats the stdin of the loop that reads the checks
sql_prod()    { "${COMPOSE[@]}" exec -T db psql -U "$POSTGRES_USER" -d "$ODOO_DB" -tAc "$1" </dev/null; }
sql_test()    { docker exec "$PG" psql -U "$POSTGRES_USER" -d "$ODOO_DB" -tAc "$1" </dev/null; }
sql_prod_db() { "${COMPOSE[@]}" exec -T db psql -U "$POSTGRES_USER" -d almi_chain -tAc "$1" </dev/null; }
sql_test_db() { docker exec "$PG" psql -U "$POSTGRES_USER" -d almi_chain -tAc "$1" </dev/null; }

cleanup() {
  docker rm -f "$ODOO" "$PG" >/dev/null 2>&1 || true
  docker network rm "$NET" >/dev/null 2>&1 || true
  rm -rf "$TARGET"
  if mountpoint -q /mnt/usb-backup; then umount /mnt/usb-backup; fi
}
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
cleanup   # in case something was left from a previous test
T0=$(date +%s)

log "1/6 Choosing the copy ($SOURCE)"
if [[ $SOURCE == usb ]]; then
  blkid -L BACKUP_USB >/dev/null || { echo "ERROR: plug in the BACKUP_USB disk" >&2; exit 1; }
  mount /mnt/usb-backup
  REPO=/mnt/usb-backup/restic
elif [[ $SOURCE == s3 ]]; then
  [[ -r /root/.config/backup-odoo/s3.env ]] || { echo "ERROR: /root/.config/backup-odoo/s3.env is missing" >&2; exit 1; }
  set -a; source /root/.config/backup-odoo/s3.env; set +a
  REPO=$S3_REPO
else
  REPO=/srv/data/restic
fi
restic -r "$REPO" snapshots --tag odoo --latest 1 --compact

log "2/6 Restoring the files of the latest snapshot"
install -d -m 700 "$TARGET"
restic -r "$REPO" restore latest --tag odoo --target "$TARGET" | tail -1
DUMP="$TARGET/srv/data/temp-backup/${ODOO_DB}.dump"
ATTACHMENTS="$TARGET/var/lib/docker/volumes/odoo_odoo-web-data/_data"
echo "  Dump: $(du -h "$DUMP" | cut -f1) · attachments: $(find "$ATTACHMENTS" -type f | wc -l) files · config: $(ls -A "$TARGET/opt/odoo" | tr '\n' ' ')"

log "3/6 Isolated PostgreSQL and database restore"
docker network create --internal "$NET" >/dev/null
docker run -d --name "$PG" --network "$NET" \
  -e POSTGRES_USER="$POSTGRES_USER" -e POSTGRES_PASSWORD="$POSTGRES_PASSWORD" -e POSTGRES_DB=postgres \
  postgres:17 >/dev/null
until docker exec "$PG" pg_isready -U "$POSTGRES_USER" -d postgres -q 2>/dev/null; do sleep 1; done
sleep 2
docker exec "$PG" createdb -U "$POSTGRES_USER" "$ODOO_DB"
docker exec -i "$PG" pg_restore -U "$POSTGRES_USER" -d "$ODOO_DB" --no-owner --exit-on-error < "$DUMP"
echo "  Database '$ODOO_DB' restored into the isolated PostgreSQL ($PG, internal network '$NET')"
DB_DUMP="$TARGET/srv/data/temp-backup/almi_chain.dump"
HAS_DB=0
if [[ -f $DB_DUMP ]]; then
  HAS_DB=1
  # Roles first (globals.sql): without app_role and read_role the grants are not restored.
  # The admin role already exists in the container: that error is expected and ignored.
  docker exec -i "$PG" psql -q -U "$POSTGRES_USER" -d postgres < "$TARGET/srv/data/temp-backup/globals.sql" >/dev/null 2>&1 || true
  docker exec "$PG" createdb -U "$POSTGRES_USER" almi_chain
  docker exec -i "$PG" pg_restore -U "$POSTGRES_USER" -d almi_chain --no-owner --exit-on-error < "$DB_DUMP"
  echo "  Database 'almi_chain' restored with its roles and grants"
fi

log "4/6 Compare: production vs restored"
printf '  %-38s %-34s %-34s %s\n' "Item" "Production" "Restored" ""
FAILURES=0
compare() {
  local name=$1 a=$2 b=$3 mark
  if [[ $a == "$b" ]]; then mark="OK"; else mark="DIFFERENT"; FAILURES=$((FAILURES+1)); fi
  printf '  %-38s %-34s %-34s %s\n' "$name" "$a" "$b" "$mark"
}
while IFS='|' read -r name sql; do
  compare "$name" "$(sql_prod "$sql")" "$(sql_test "$sql")"
done <<'EOF'
Customers and contacts|SELECT count(*) FROM res_partner
Products|SELECT count(*) FROM product_template
Sales orders|SELECT count(*) FROM sale_order
Posted invoices|SELECT count(*) FROM account_move WHERE move_type='out_invoice' AND state='posted'
Total invoiced (EUR)|SELECT coalesce(sum(amount_total),0) FROM account_move WHERE move_type='out_invoice' AND state='posted'
Last invoice|SELECT max(name) FROM account_move WHERE move_type='out_invoice' AND state='posted'
Journal items|SELECT count(*) FROM account_move_line
Points of sale|SELECT string_agg(name, ',' ORDER BY id) FROM pos_config
Active users|SELECT string_agg(login, ',' ORDER BY id) FROM res_users WHERE active
EOF
ORIG_FS="/var/lib/docker/volumes/odoo_odoo-web-data/_data/filestore/$ODOO_DB"
REST_FS="$ATTACHMENTS/filestore/$ODOO_DB"
folder_hash() { (cd "$1" && find . -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-16); }
compare "Attachments: file count" "$(find "$ORIG_FS" -type f | wc -l)" "$(find "$REST_FS" -type f | wc -l)"
compare "Attachments: content hash" "$(folder_hash "$ORIG_FS")" "$(folder_hash "$REST_FS")"
if [[ $HAS_DB -eq 1 ]]; then
  while IFS='|' read -r name sql; do
    compare "$name" "$(sql_prod_db "$sql")" "$(sql_test_db "$sql")"
  done <<'EOF'
almi_chain: tables|SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'
almi_chain: rows per table (hash)|SELECT md5(string_agg(relname || '=' || n, ',' ORDER BY relname)) FROM (SELECT relname, (xpath('/row/c/text()', query_to_xml('SELECT count(*) AS c FROM public.' || quote_ident(relname), false, true, '')))[1]::text AS n FROM pg_stat_user_tables) t
almi_chain: customers|SELECT count(*) FROM customer
almi_chain: dishes on the menu|SELECT count(*) FROM dish
almi_chain: invoices|SELECT count(*) FROM invoice
almi_chain: invoice lines total (EUR)|SELECT coalesce(sum(quantity * unit_price),0) FROM invoice_line
almi_chain: grants of app_role/read_role|SELECT count(*) FROM information_schema.role_table_grants WHERE grantee IN ('app_role','read_role')
EOF
else
  echo "  (the copy has no almi_chain: the chain's database is not compared)"
fi
for f in docker-compose.yml .env config/odoo.conf; do
  compare "Config: $f" "$(sha256sum < "/opt/odoo/$f" | cut -c1-16)" "$(sha256sum < "$TARGET/opt/odoo/$f" | cut -c1-16)"
done

log "5/6 Starting a test Odoo on the restored data and logging in"
install -d "$TARGET/odoo-data/filestore"
cp -a "$REST_FS" "$TARGET/odoo-data/filestore/$ODOO_DB"
chown -R 100:101 "$TARGET/odoo-data"
# The "restore-test" network is internal (no way out). To publish 127.0.0.1:8070 it also joins the bridge network.
# No scheduled jobs (--max-cron-threads=0): the copy sends no emails and does nothing on its own.
docker create --name "$ODOO" --network "$NET" -p 127.0.0.1:8070:8069 \
  -v "$TARGET/odoo-data:/var/lib/odoo" \
  -e HOST="$PG" -e USER="$POSTGRES_USER" -e PASSWORD="$POSTGRES_PASSWORD" \
  "odoo:${ODOO_VERSION}" -- --db-filter="^${ODOO_DB}\$" -d "$ODOO_DB" --no-database-list --max-cron-threads=0 >/dev/null
docker network connect bridge "$ODOO"
docker start "$ODOO" >/dev/null
for _ in $(seq 1 60); do curl -fs -o /dev/null http://127.0.0.1:8070/web/login && break; sleep 2; done
HTTP=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8070/web/login)
LOGIN=$(curl -s -H 'Content-Type: application/json' http://127.0.0.1:8070/jsonrpc \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":{\"service\":\"common\",\"method\":\"login\",\"args\":[\"$ODOO_DB\",\"admin\",\"$ODOO_ADMIN_PASSWORD\"]}}" \
  | grep -o '"result": *[0-9a-z]*' | grep -o '[0-9a-z]*$' || true)
compare "Restored Odoo: /web/login" "200" "$HTTP"
compare "Restored Odoo: admin login (uid)" "2" "$LOGIN"
echo "  Connections to production PostgreSQL from outside production: $(sql_prod "SELECT count(*) FROM pg_stat_activity WHERE datname<>'$ODOO_DB' AND datname IS NOT NULL AND datname<>'postgres'")"

log "6/6 Result"
echo "  Total recovery time (measured RTO): $(( $(date +%s) - T0 )) s"
echo "  Age of the restored copy (RPO): $(( ( $(date +%s) - $(stat -c %Y "$DUMP") ) / 60 )) min"
if [[ $FAILURES -eq 0 ]]; then
  echo "  RESTORE OK: everything matches and the restored Odoo works"
else
  echo "  $FAILURES checks failed"; exit 1
fi
echo "  (cleaning up: the throwaway PostgreSQL and Odoo, their network and the restored files are deleted)"
