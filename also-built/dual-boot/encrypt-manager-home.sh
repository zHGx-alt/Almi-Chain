#!/bin/bash
# Ubuntu side of the manager's PC: encrypts /home/manager with fscrypt (ext4), unlocked by
# the manager's login password through PAM.
# Usage: sudo bash encrypt-manager-home.sh [report-file]
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
who | grep -q '^manager ' && { echo "Log the manager's session out first"; exit 1; }
OUT=${1:-/root/fscrypt-home-manager.txt}   # report path (no secrets in it)
apt-get update -q && apt-get install -y -q fscrypt libpam-fscrypt
DEV=$(findmnt -no SOURCE -T /home); MNT=$(findmnt -no TARGET -T /home)
tune2fs -l "$DEV" | grep -q 'features:.*encrypt' || tune2fs -O encrypt "$DEV"
[ -e /etc/fscrypt.conf ] || fscrypt setup --quiet
[ -d "$MNT/.fscrypt" ] || fscrypt setup "$MNT" --quiet
if fscrypt status /home/manager 2>/dev/null | grep -q 'is encrypted'; then
  echo "/home/manager was already encrypted"
else
  mv /home/manager /home/manager.unencrypted
  install -d -o manager -g manager -m 700 /home/manager
  echo; echo ">>> Now type the manager's LOGIN password (from the password manager)"; echo
  if ! fscrypt encrypt /home/manager --user=manager --source=pam_passphrase; then
    rmdir /home/manager; mv /home/manager.unencrypted /home/manager
    echo "Not encrypted (wrong manager password?). /home/manager is left as it was."; exit 1
  fi
  cp -a /home/manager.unencrypted/. /home/manager/
  rm -rf /home/manager.unencrypted
fi
{ echo "# Manager's Ubuntu: /home/manager encrypted with fscrypt ($(date '+%F %H:%M'))"
  echo; echo '$ lsblk -f'; lsblk -f
  echo; echo "\$ tune2fs -l $DEV | grep features"; tune2fs -l "$DEV" | grep -i features
  echo; echo '$ fscrypt status /home/manager'; fscrypt status /home/manager
  echo; echo '$ grep fscrypt /etc/pam.d/common-*'; grep -H fscrypt /etc/pam.d/common-* || true
} > "$OUT"
echo; echo "DONE. Report in $OUT"
