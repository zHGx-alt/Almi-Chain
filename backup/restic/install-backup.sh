#!/usr/bin/env bash
# Installs Odoo's 3-2-1 backup: restic, encryption password, repositories, USB disk and daily timer.
#
# Usage:  sudo ./install-backup.sh [/dev/sdX]
#   /dev/sdX (optional): a NEW, EMPTY external USB disk to prepare (formatted with the label BACKUP_USB).
#   Idempotent: whatever already exists (password, repository, prepared USB) is left alone.
set -euo pipefail

SOURCE="$(cd "$(dirname "$0")" && pwd)"
PASS=/root/.config/backup-odoo/restic.pass
RAID_REPO=/srv/data/restic

log() { printf '\n==> %s\n' "$*"; }
[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
mountpoint -q /srv/data || { echo "ERROR: the RAID is not mounted at /srv/data (run create-raid1.sh)" >&2; exit 1; }

log "1/5 Installing restic"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq restic >/dev/null
restic version

log "2/5 Encryption password"
if [[ ! -f $PASS ]]; then
  install -d -m 700 "$(dirname "$PASS")"
  (umask 077; openssl rand -base64 32 > "$PASS")
  echo "  Created at $PASS (mode 600)."
  echo "  WARNING: ALSO STORE IT OUTSIDE THE SERVER (the manager's password manager): without it the backups CANNOT be restored."
else
  echo "  Already exists: kept"
fi

log "3/5 Repository on the RAID"
if [[ -f $RAID_REPO/config ]]; then
  echo "  Already exists"
else
  install -d -m 700 "$RAID_REPO"
  restic -r "$RAID_REPO" init --password-file "$PASS"
fi

log "4/5 External USB disk"
install -d -m 700 /mnt/usb-backup
grep -q "LABEL=BACKUP_USB" /etc/fstab || \
  echo "LABEL=BACKUP_USB  /mnt/usb-backup  ext4  noauto,nofail  0  0" >> /etc/fstab
systemctl daemon-reload
if [[ -n ${1:-} ]]; then
  USB=$1
  SYSTEM_DISK=/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")
  [[ -b $USB && $USB != "$SYSTEM_DISK" ]] || { echo "ERROR: $USB cannot be used" >&2; exit 1; }
  if [[ $(blkid -s LABEL -o value "$USB" 2>/dev/null) == BACKUP_USB ]]; then
    echo "  $USB is already prepared"
  elif [[ $(lsblk -no NAME "$USB" | wc -l) -gt 1 || -n $(blkid -p "$USB" 2>/dev/null) ]]; then
    echo "ERROR: $USB has data. Not formatted." >&2; exit 1
  else
    mkfs.ext4 -q -L BACKUP_USB "$USB"
    echo "  $USB formatted with the label BACKUP_USB"
  fi
else
  echo "  (no disk given: any connected disk labelled BACKUP_USB will be used)"
fi

log "5/5 Script, failure alert and daily timer (02:30)"
install -m 750 "$SOURCE/backup-odoo.sh" /usr/local/sbin/backup-odoo.sh
install -m 750 "$SOURCE/backup-failure-alert.sh" /usr/local/sbin/backup-failure-alert.sh
[[ -f /etc/default/backup-odoo ]] || printf '# Email to alert if the backup fails (needs an MTA and the mail command)\n#ALERT_EMAIL=manager@example.com\n' > /etc/default/backup-odoo
cat > /etc/systemd/system/backup-odoo-failure.service <<'EOF'
[Unit]
Description=Odoo backup failure alert

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/backup-failure-alert.sh
EOF
cat > /etc/systemd/system/backup-odoo.service <<'EOF'
[Unit]
Description=Encrypted 3-2-1 backup of Odoo
After=docker.service srv-data.mount
Requires=docker.service
OnFailure=backup-odoo-failure.service

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/backup-odoo.sh
Nice=10
IOSchedulingClass=idle
EOF
cat > /etc/systemd/system/backup-odoo.timer <<'EOF'
[Unit]
Description=Daily Odoo backup

[Timer]
OnCalendar=*-*-* 02:30:00
RandomizedDelaySec=10min
# If the server was off at that time, the backup runs when it is switched on
Persistent=true

[Install]
WantedBy=timers.target
EOF
systemctl daemon-reload
systemctl enable --now backup-odoo.timer
systemctl list-timers backup-odoo.timer --no-pager
