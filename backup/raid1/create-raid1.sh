#!/usr/bin/env bash
# Creates a software RAID 1 (mirror) with mdadm and mounts it at /srv/data.
#
# Usage:  sudo ./create-raid1.sh /dev/sdX /dev/sdY
# SAFETY: it only goes on if both disks are completely empty (no partitions, no file system)
# and neither is the system disk. If the RAID already exists, it does nothing.
set -euo pipefail

MD=/dev/md0
MOUNT=/srv/data

[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }
[[ $# -eq 2 ]] || { echo "Usage: sudo $0 /dev/sdX /dev/sdY" >&2; exit 1; }
DISK1=$1; DISK2=$2

log() { printf '\n==> %s\n' "$*"; }

log "1/5 Installing mdadm"
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq mdadm >/dev/null
mdadm --version

if [[ -e $MD ]] && mdadm --detail "$MD" >/dev/null 2>&1; then
  echo "RAID $MD already exists:"; mdadm --detail "$MD"; exit 0
fi

log "2/5 Checking that the disks are empty"
SYSTEM_DISK=/dev/$(lsblk -no PKNAME "$(findmnt -no SOURCE /)")
for d in "$DISK1" "$DISK2"; do
  [[ -b $d ]] || { echo "ERROR: $d does not exist" >&2; exit 1; }
  [[ $d != "$SYSTEM_DISK" ]] || { echo "ERROR: $d is the system disk" >&2; exit 1; }
  if [[ $(lsblk -no NAME "$d" | wc -l) -gt 1 ]] || [[ -n $(blkid -p "$d" 2>/dev/null) ]]; then
    echo "ERROR: $d has partitions or data. Not touched." >&2; exit 1
  fi
  echo "  $d: empty ($(lsblk -dno SIZE "$d"))"
done

log "3/5 Creating RAID 1 on $MD"
mdadm --create "$MD" --level=1 --raid-devices=2 --metadata=1.2 --name=data --run "$DISK1" "$DISK2"

log "4/5 ext4 file system, mounted at $MOUNT"
mkfs.ext4 -q -L data "$MD"
mkdir -p "$MOUNT"
UUID=$(blkid -s UUID -o value "$MD")
grep -q "$UUID" /etc/fstab || echo "UUID=$UUID  $MOUNT  ext4  defaults,nofail  0  2" >> /etc/fstab
systemctl daemon-reload
mount "$MOUNT"

log "5/5 Making the RAID persistent and monitored"
# Assembled automatically at boot
mdadm --detail --scan | grep -q "$MD" && { grep -q "name=.*data" /etc/mdadm/mdadm.conf || mdadm --detail --scan >> /etc/mdadm/mdadm.conf; }
sed -i 's/^#\?MAILADDR.*/MAILADDR root/' /etc/mdadm/mdadm.conf
update-initramfs -u >/dev/null 2>&1
# Alerts when a disk fails (mdmonitor writes to the journal and to root's mail)
systemctl enable --now mdmonitor.service >/dev/null 2>&1 || true

echo
cat /proc/mdstat
df -h "$MOUNT"
