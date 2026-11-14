#!/usr/bin/env bash
# Encrypted 3-2-1 backup of Odoo (run every night by backup-odoo.timer)
#
#   Copy 1: the live data (PostgreSQL: Odoo's and almi_chain's databases + Odoo attachments + config)
#   Copy 2: restic repository on the RAID 1            -> /srv/data/restic
#   Copy 3: restic repository on the external USB disk -> /mnt/usb-backup/restic (if plugged in)
#   Copy 3b (optional): restic repository on AWS S3, if /root/.config/backup-odoo/s3.env exists (see s3.env.example)
#
# restic encrypts with AES-256 and deduplicates: each daily snapshot only stores what changed.
set -euo pipefail

export RESTIC_PASSWORD_FILE=/root/.config/backup-odoo/restic.pass
export RESTIC_CACHE_DIR=/var/cache/restic   # under systemd there is no $HOME: without this restic runs uncached
RAID_REPO=/srv/data/restic
USB_REPO=/mnt/usb-backup/restic
USB_LABEL=BACKUP_USB
COMPOSE=/opt/odoo/docker-compose.yml
STATE=/var/lib/backup-odoo           # date of the last USB copy
MAX_DAYS_WITHOUT_USB=7               # the USB disk is swapped off-site every Monday
TEMP=/srv/data/temp-backup
RETENTION=(--keep-daily 7 --keep-weekly 4 --keep-monthly 6)
S3_ENV=/root/.config/backup-odoo/s3.env   # S3_REPO and the keys of an IAM user limited to the bucket (outside Git)

log() { echo "[backup-odoo] $*"; }

set -a; source /opt/odoo/.env; set +a
mountpoint -q /srv/data || { log "ERROR: the RAID /srv/data is not mounted"; exit 1; }
# Real path of the attachments volume: still right after Docker's data moves to the RAID
ATTACHMENTS_VOLUME=$(docker volume inspect -f '{{.Mountpoint}}' odoo_odoo-web-data)

# 1. Consistent database dump (pg_dump custom format: compressed and restorable with pg_restore)
install -d -m 700 "$TEMP"
log "Dumping the ${ODOO_DB} database"
docker compose -f "$COMPOSE" exec -T db pg_dump -U "$POSTGRES_USER" -Fc "$ODOO_DB" > "$TEMP/${ODOO_DB}.dump"
docker compose -f "$COMPOSE" exec -T db pg_dumpall -U "$POSTGRES_USER" --globals-only > "$TEMP/globals.sql"
log "Dump: $(du -h "$TEMP/${ODOO_DB}.dump" | cut -f1)"
# The chain's own database (almi_chain), if it lives in the same PostgreSQL
if docker compose -f "$COMPOSE" exec -T db psql -U "$POSTGRES_USER" -d postgres -tAc \
     "SELECT 1 FROM pg_database WHERE datname = 'almi_chain'" | grep -q 1; then
  docker compose -f "$COMPOSE" exec -T db pg_dump -U "$POSTGRES_USER" -Fc almi_chain > "$TEMP/almi_chain.dump"
  log "almi_chain dump: $(du -h "$TEMP/almi_chain.dump" | cut -f1)"
fi

# 2. Copy on the RAID
log "Copy 2/3 -> RAID ($RAID_REPO)"
restic -r "$RAID_REPO" backup --tag odoo --host erp-server \
  "$TEMP" "$ATTACHMENTS_VOLUME" /opt/odoo
restic -r "$RAID_REPO" forget --tag odoo "${RETENTION[@]}" --prune
restic -r "$RAID_REPO" check

# 3. Copy on the external USB disk (if plugged in)
USB_DEVICE=$(blkid -L "$USB_LABEL" 2>/dev/null || true)
if [[ -n $USB_DEVICE ]]; then
  mountpoint -q /mnt/usb-backup || mount /mnt/usb-backup
  if [[ ! -f $USB_REPO/config ]]; then
    restic -r "$USB_REPO" init --from-repo "$RAID_REPO" --from-password-file "$RESTIC_PASSWORD_FILE" --copy-chunker-params
  fi
  log "Copy 3/3 -> external USB ($USB_DEVICE)"
  restic -r "$USB_REPO" copy --from-repo "$RAID_REPO" --from-password-file "$RESTIC_PASSWORD_FILE" --tag odoo
  restic -r "$USB_REPO" forget --tag odoo "${RETENTION[@]}" --prune
  restic -r "$USB_REPO" check
  sync; umount /mnt/usb-backup   # unmounted: it can be unplugged and taken off-site
  install -d -m 700 "$STATE"; date +%s > "$STATE/last-usb-copy"
  log "USB unmounted: safe to remove"
else
  log "WARNING: external USB not connected -> today there is only the RAID copy (3-2-1 not met)"
fi

# 3b. Copy on AWS S3 (optional): off-site every day, without relying on someone taking the USB home
S3_COPY_TODAY=0
if [[ -r $S3_ENV ]]; then
  set -a; source "$S3_ENV"; set +a
  if ! restic -r "$S3_REPO" cat config >/dev/null 2>&1; then
    log "Creating the S3 repository ($S3_REPO)"
    restic -r "$S3_REPO" init --from-repo "$RAID_REPO" --from-password-file "$RESTIC_PASSWORD_FILE" --copy-chunker-params
  fi
  log "Copy 3b -> AWS S3 ($S3_REPO)"
  restic -r "$S3_REPO" copy --from-repo "$RAID_REPO" --from-password-file "$RESTIC_PASSWORD_FILE" --tag odoo
  restic -r "$S3_REPO" forget --tag odoo "${RETENTION[@]}" --prune
  restic -r "$S3_REPO" check
  install -d -m 700 "$STATE"; date +%s > "$STATE/last-s3-copy"
  S3_COPY_TODAY=1
fi

rm -rf "$TEMP"
log "Snapshots on the RAID:"
restic -r "$RAID_REPO" snapshots --tag odoo --compact

# Alert when the off-site copy is too old: the service exits with an error, shows up in
# "systemctl --failed", and OnFailure= runs backup-failure-alert.sh. A copy on S3 today
# counts as off-site even if the USB did not come back.
last=$(cat "$STATE/last-usb-copy" 2>/dev/null || echo 0)
days=$(( ($(date +%s) - last) / 86400 ))
if (( days > MAX_DAYS_WITHOUT_USB && S3_COPY_TODAY == 0 )); then
  log "ERROR: the last USB copy is $days days old (maximum $MAX_DAYS_WITHOUT_USB): bring the USB disk back"
  exit 2
fi
log "Backup finished successfully"
