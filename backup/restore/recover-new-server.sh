#!/usr/bin/env bash
# Rebuilds the server on a NEW machine from the USB backup disk (real RTO).
#
# The disaster plan as a script: the server is lost, there is a freshly installed machine
# (network-security/hardening/server-preseed.cfg) and the BACKUP_USB disk is plugged in.
# No Docker, no images, no /opt/odoo: everything comes from the backup.
#
# Usage:  sudo ./recover-new-server.sh PASSWORD_FILE
#   PASSWORD_FILE: the restic password taken from the password manager and pasted into a
#   temporary file (mode 600). The script copies it to /root/.config/backup-odoo/restic.pass, where
#   the nightly backup expects it, and deletes the temporary file.
#
# When it finishes, Odoo runs on the backed-up data (HTTPS if the backup includes the proxy) and
# the total time is printed. The real stopwatch starts earlier: when the machine is created.
set -euo pipefail

PASS_TEMP=${1:?Usage: sudo $0 PASSWORD_FILE (the restic password, from the password manager)}
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
[[ -r $PASS_TEMP ]] || { echo "Cannot read $PASS_TEMP" >&2; exit 1; }

export RESTIC_PASSWORD_FILE=/root/.config/backup-odoo/restic.pass
export RESTIC_CACHE_DIR=/var/cache/restic
RESTORED=/srv/restored
T0=$(date +%s)
log() { printf '\n==> [%s] (+%ss) %s\n' "$(date +%T)" "$(( $(date +%s) - T0 ))" "$*"; }

log "1/7 Tools: restic, Docker and Compose"
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq restic docker.io docker-compose curl >/dev/null
docker compose version

log "2/7 restic password and USB disk"
install -d -m 700 /root/.config/backup-odoo
install -m 600 "$PASS_TEMP" "$RESTIC_PASSWORD_FILE"
shred -u "$PASS_TEMP" 2>/dev/null || rm -f "$PASS_TEMP"
DISK=$(blkid -L BACKUP_USB) || { echo "ERROR: plug in the BACKUP_USB disk" >&2; exit 1; }
install -d /mnt/usb-backup
mountpoint -q /mnt/usb-backup || mount -o ro "$DISK" /mnt/usb-backup
# --no-lock: the USB is mounted read-only so the backup is never touched, and restic cannot leave its lock on it
restic -r /mnt/usb-backup/restic snapshots --no-lock --tag odoo --latest 1 --compact

log "3/7 Restoring the latest snapshot"
install -d -m 700 "$RESTORED"
restic -r /mnt/usb-backup/restic restore --no-lock latest --tag odoo --target "$RESTORED" | tail -1
TEMP="$RESTORED/srv/data/temp-backup"
ATTACHMENTS=$(find "$RESTORED" -path '*/volumes/odoo_odoo-web-data/_data' -type d | head -1)
[[ -n $ATTACHMENTS ]] || { echo "ERROR: the backup has no Odoo attachments" >&2; exit 1; }
cp -a "$RESTORED/opt/odoo" /opt/odoo
cd /opt/odoo
set -a; source .env; set +a
echo "  /opt/odoo: $(ls -A | tr '\n' ' ')"

log "4/7 PostgreSQL and databases (${ODOO_DB} and almi_chain)"
docker compose up -d db
until docker compose exec -T db pg_isready -U "$POSTGRES_USER" -d postgres -q 2>/dev/null; do sleep 1; done
sleep 2
# Roles (app_role, read_role...). The admin role already exists: that error is expected.
docker compose exec -T db psql -q -U "$POSTGRES_USER" -d postgres < "$TEMP/globals.sql" >/dev/null 2>&1 || true
docker compose exec -T db createdb -U "$POSTGRES_USER" "$ODOO_DB"
docker compose exec -T db pg_restore -U "$POSTGRES_USER" -d "$ODOO_DB" --no-owner --exit-on-error < "$TEMP/${ODOO_DB}.dump"
if [[ -f $TEMP/almi_chain.dump ]]; then
  docker compose exec -T db createdb -U "$POSTGRES_USER" almi_chain
  docker compose exec -T db pg_restore -U "$POSTGRES_USER" -d almi_chain --no-owner --exit-on-error < "$TEMP/almi_chain.dump"
fi

log "5/7 Odoo attachments (filestore)"
docker volume create odoo_odoo-web-data >/dev/null
VOL=$(docker volume inspect -f '{{.Mountpoint}}' odoo_odoo-web-data)
cp -a "$ATTACHMENTS/." "$VOL/"
chown -R 100:101 "$VOL"
echo "  $(find "$VOL/filestore/$ODOO_DB" -type f | wc -l) files"

log "6/7 Starting Odoo (and the HTTPS proxy if the backup has it)"
docker compose up -d
docker compose ps --format '  {{.Name}} {{.Image}} {{.Status}}'
for _ in $(seq 1 90); do curl -fs -o /dev/null http://127.0.0.1:8069/web/login && break; sleep 2; done

log "7/7 Checks"
sql() { docker compose exec -T db psql -U "$POSTGRES_USER" -d "$1" -tAc "$2" </dev/null; }
HTTP=$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8069/web/login)
HTTPS=$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/web/login || true)
LOGIN=$(curl -s -H 'Content-Type: application/json' http://127.0.0.1:8069/jsonrpc \
  -d "{\"jsonrpc\":\"2.0\",\"method\":\"call\",\"params\":{\"service\":\"common\",\"method\":\"login\",\"args\":[\"$ODOO_DB\",\"admin\",\"$ODOO_ADMIN_PASSWORD\"]}}" \
  | grep -o '"result": *[0-9a-z]*' | grep -o '[0-9a-z]*$' || true)
echo "  Odoo /web/login over HTTP (server only): $HTTP"
echo "  Odoo /web/login over HTTPS (proxy): ${HTTPS:-no proxy}"
echo "  admin login (uid): ${LOGIN:-FAILS}"
echo "  Points of sale: $(sql "$ODOO_DB" "SELECT string_agg(name, ', ' ORDER BY id) FROM pos_config")"
echo "  Active cashiers: $(sql "$ODOO_DB" "SELECT string_agg(login, ', ' ORDER BY id) FROM res_users WHERE active AND login LIKE 'cashier%'")"
echo "  Last POS sale: $(sql "$ODOO_DB" "SELECT name || ' · ' || date_order || ' · ' || amount_total || ' EUR' FROM pos_order ORDER BY id DESC LIMIT 1")"
echo "  POS sales: $(sql "$ODOO_DB" "SELECT count(*) FROM pos_order") · customers: $(sql "$ODOO_DB" "SELECT count(*) FROM res_partner") · products: $(sql "$ODOO_DB" "SELECT count(*) FROM product_template")"
if [[ -f $TEMP/almi_chain.dump ]]; then
  echo "  almi_chain: $(sql almi_chain "SELECT count(*) FROM information_schema.tables WHERE table_schema='public' AND table_type='BASE TABLE'") tables, $(sql almi_chain "SELECT count(*) FROM invoice") invoices"
fi
echo "  Age of the backup (RPO): $(( ( $(date +%s) - $(stat -c %Y "$TEMP/${ODOO_DB}.dump") ) / 3600 )) h"
umount /mnt/usb-backup
echo
echo "  Time for this script: $(( $(date +%s) - T0 )) s"
[[ $HTTP == 200 && $LOGIN == 2 ]] || { echo "  Odoo does not answer or does not let admin in"; exit 1; }
echo "  Server recovered. Still to do: the nightly backup (../restic/install-backup.sh) and the firewall."
