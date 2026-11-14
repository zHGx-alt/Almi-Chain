#!/usr/bin/env bash
# Moves the live data (PostgreSQL and Odoo attachments) onto the RAID 1, so the database
# lives on a redundant device.
#
# Only Docker's VOLUMES move (/var/lib/docker/volumes: the database and the attachments), not
# all of /var/lib/docker: images take several GB, can be pulled again, and do not fit on a 5 GB RAID.
#
#   1. Checks that the RAID is mounted at /srv/data, healthy ([UU]) and has room for the volumes.
#   2. Takes a backup right before (backup-odoo).
#   3. Stops Odoo and Docker and copies the volumes to /srv/data/docker-volumes.
#   4. Bind-mounts that folder over /var/lib/docker/volumes (in /etc/fstab, requiring the RAID) and
#      makes Docker always start AFTER that mount: without the RAID, Odoo never starts on an empty database.
#   5. Starts everything and checks: volumes on md0, containers up and Odoo's login page returning 200.
#   The old volumes stay in /var/lib/docker/volumes.old (not deleted): remove them by hand later.
#
# Usage:  sudo ./move-docker-to-raid.sh        (if already moved, it only checks)
set -euo pipefail

RAID=/srv/data
VOLUMES=/var/lib/docker/volumes
NEW=$RAID/docker-volumes
ODOO_DIR=/opt/odoo
log() { printf '\n==> %s\n' "$*"; }
fail() { echo "ERROR: $*" >&2; exit 1; }
on_raid() { [[ $(findmnt -no SOURCE --target "$VOLUMES" 2>/dev/null) == *md0* ]]; }

[[ $EUID -eq 0 ]] || fail "run the script with sudo: sudo $0"

log "1/5 Checks"
mountpoint -q "$RAID" || fail "$RAID is not mounted (run create-raid1.sh)"
state=$(awk '/^md/{getline; print $NF; exit}' /proc/mdstat)
[[ $state == "[UU]" ]] || fail "the RAID is not healthy ($state): repair it first"
echo "  RAID $state mounted at $RAID"
if on_raid; then
  echo "  The volumes are already on the RAID: nothing to move."
else
  used=$(du -sm "$VOLUMES" | cut -f1)
  free=$(df -m --output=avail "$RAID" | tail -1 | tr -d ' ')
  echo "  Docker volumes: ${used} MB · free on the RAID: ${free} MB"
  (( free > used * 2 )) || fail "not enough room on the RAID (twice the size of the volumes is needed)"

  log "2/5 Backup before the change"
  if systemctl list-unit-files backup-odoo.service >/dev/null 2>&1; then
    systemctl start backup-odoo.service && echo "  Backup done (journalctl -u backup-odoo)"
  else
    echo "  WARNING: backup-odoo is not installed: going on without a backup"
  fi

  log "3/5 Stopping Odoo and Docker and copying the volumes"
  (cd "$ODOO_DIR" && docker compose down)
  systemctl stop docker.socket docker.service
  command -v rsync >/dev/null || DEBIAN_FRONTEND=noninteractive apt-get install -y -qq rsync >/dev/null
  install -d -m 701 "$NEW"
  rsync -aHAX --info=progress2 "$VOLUMES/" "$NEW/"
  mv "$VOLUMES" "$VOLUMES.old"
  install -d -m 701 "$VOLUMES"
  echo "  Copied. The old volumes stay in $VOLUMES.old"

  log "4/5 Mounting on the RAID"
  grep -q " $VOLUMES " /etc/fstab || \
    echo "$NEW  $VOLUMES  none  bind,x-systemd.requires-mounts-for=$RAID  0  0" >> /etc/fstab
  systemctl daemon-reload
  mount "$VOLUMES"
fi

# Docker starts after the RAID and the volumes mount (and does not start without them)
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/90-raid.conf <<EOF
[Unit]
RequiresMountsFor=$RAID $VOLUMES
EOF
systemctl daemon-reload
systemctl start docker.service
(cd "$ODOO_DIR" && docker compose up -d)

log "5/5 Check"
sleep 15
findmnt --target "$VOLUMES" -o TARGET,SOURCE,FSTYPE
docker volume inspect -f '  {{.Name}}: {{.Mountpoint}}' odoo_odoo-db-data odoo_odoo-web-data
(cd "$ODOO_DIR" && docker compose ps --format '  {{.Service}}: {{.Status}}')
code=$(curl -sk -o /dev/null -w '%{http_code}' http://127.0.0.1:8069/web/login || true)
echo "  Odoo login: $code (expected 200)"
on_raid && [[ $code == 200 ]] || fail "something went wrong: check the output"
echo
echo "Done: the database and the attachments are on the RAID."
echo "Next: sudo ./simulate-disk-failure.sh and, once everything has run fine for a few days,"
echo "delete $VOLUMES.old."
