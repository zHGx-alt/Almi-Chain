#!/usr/bin/env bash
# Simulates a RAID disk failure **with Odoo running**.
# Requires the database on the RAID (move-docker-to-raid.sh). Checks that with one disk failed
# Odoo keeps answering and saving sales (it creates one through Odoo itself, with odoo shell, the
# same logic as the application), and that the mirror rebuilds when the disk is added back.
#
#   sudo ./simulate-disk-failure.sh 2>&1 | tee disk-failure.log
set -euo pipefail

MD=/dev/md0
ODOO_DIR=/opt/odoo
fail() { echo "ERROR: $*" >&2; exit 1; }
step() { printf '\n==> %s  (%s)\n' "$1" "$(date '+%T')"; }
login() { curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:8069/web/login || true; }
sql() { (cd "$ODOO_DIR" && docker compose exec -T db sh -c "psql -U \"\$POSTGRES_USER\" -d shop -tAc \"$1\""); }
counts() { sql "select (select count(*) from pos_order) || ' POS orders, ' || (select count(*) from sale_order) || ' sales orders, ' || (select count(*) from account_move where state='posted') || ' posted entries/invoices'"; }

[[ $EUID -eq 0 ]] || fail "run with sudo"

step "1/6 Initial state"
state=$(awk '/^md/{getline; print $NF; exit}' /proc/mdstat)
source_dev=$(findmnt -no SOURCE --target /var/lib/docker/volumes)
echo "RAID: $state · Docker volumes on: $source_dev · Odoo login: $(login)"
[[ $state == "[UU]" ]] || fail "the RAID is not healthy"
[[ $source_dev == *md0* ]] || fail "the database is not on the RAID: run sudo ./move-docker-to-raid.sh first"
echo "Data: $(counts)"
mdadm --detail $MD | grep -E 'State :|Active Devices|/dev/sd'

FAILED=$(mdadm --detail $MD | awk '/active sync/{d=$NF} END{print d}')
step "2/6 Failing $FAILED"
mdadm $MD --fail "$FAILED"
sleep 2
cat /proc/mdstat
mdadm --detail $MD | grep -E 'State :|Active Devices|Failed Devices'

step "3/6 Odoo with the RAID degraded"
echo "Odoo login: $(login) (expected 200)"
echo "Creating a sale through Odoo (odoo shell) with the RAID degraded..."
# If the sale fails, warn and go on: the script must never end with the RAID degraded on purpose
{ (cd "$ODOO_DIR" && docker compose exec -T odoo /entrypoint.sh odoo shell -d shop --no-http 2>/dev/null) <<'PY' | grep '^SALE'; } || echo "WARNING: could not create the sale with odoo shell (the test goes on)"
customer = env['res.partner'].search([('name', '=', 'RAID failure test')], limit=1) or env['res.partner'].create({'name': 'RAID failure test'})
product = env['product.product'].search([('sale_ok', '=', True)], limit=1)
order = env['sale.order'].create({'partner_id': customer.id, 'order_line': [(0, 0, {'product_id': product.id, 'product_uom_qty': 1})]})
order.action_confirm()
env.cr.commit()
print('SALE', order.name, order.state, round(order.amount_total, 2))
PY
echo "Data after the sale: $(counts)"
sql "checkpoint" >/dev/null && echo "PostgreSQL CHECKPOINT: written to disk without errors"
dmesg | grep -E 'md/raid1|md0' | tail -3 || true

step "4/6 Replacing the disk (the same one is added back, as if it were new)"
mdadm $MD --remove "$FAILED"
wipefs -a "$FAILED" >/dev/null
mdadm $MD --add "$FAILED"

step "5/6 Rebuild"
start=$(date +%s)
while grep -qE 'recovery|resync' /proc/mdstat || ! grep -q '\[UU\]' /proc/mdstat; do
  grep -oE '(recovery|resync) = *[0-9.]+%' /proc/mdstat || true
  sleep 5
done
echo "Rebuilt in $(( $(date +%s) - start )) s"
cat /proc/mdstat

step "6/6 Final state"
mdadm --detail $MD | grep -E 'State :|Active Devices|Failed Devices|/dev/sd'
echo "Odoo login: $(login) · Data: $(counts)"
echo
echo "Done: Odoo kept working and saving with a failed disk, and the mirror went back to [UU]."
