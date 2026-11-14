#!/usr/bin/env bash
# Arcade machine tuning (run after install-arcade.sh).
#
# Goal: MAME gets the machine to itself. Background jobs that can stutter mid-game are removed
# and disk and RAM are freed. Security is untouched: AppArmor and SSH stay on and automatic
# security updates are kept, at 05:00.
#
# Usage:  sudo ./optimize-arcade.sh        (idempotent)
set -euo pipefail

log() { printf '\n==> %s\n' "$*"; }

[[ $EUID -eq 0 ]] || { echo "Run the script with sudo: sudo $0" >&2; exit 1; }

log "1/7 Disabling scheduled jobs an arcade machine does not need"
# man-db: rebuilds the man page index.
# e2scrub_all / e2scrub_reap: only useful for LVM volumes, and there is no LVM here.
# dpkg-db-backup: daily copy of the package database.
# apt-daily and apt-daily-upgrade are NOT removed: they move outside opening hours (step 2).
for unit in man-db.timer e2scrub_all.timer dpkg-db-backup.timer e2scrub_reap.service; do
  systemctl disable --now "$unit" 2>/dev/null && echo "  disabled: $unit" || echo "  (does not exist: $unit)"
done

log "2/7 Automatic security updates at 05:00, with the restaurant closed"
# Secure by default: the machine is on the customers' Wi-Fi and cannot go unpatched.
# Downloads and installs cause stutter, so they run at dawn and not during games.
# If it is off at that time, Persistent=true runs them at boot (a few minutes, before opening).
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq unattended-upgrades >/dev/null
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF
for t in apt-daily:04:30 apt-daily-upgrade:05:00; do
  mkdir -p "/etc/systemd/system/${t%%:*}.timer.d"
  cat > "/etc/systemd/system/${t%%:*}.timer.d/90-arcade.conf" <<EOF
[Timer]
OnCalendar=
OnCalendar=*-*-* ${t#*:}
RandomizedDelaySec=0
Persistent=true
EOF
done
systemctl daemon-reload
systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
echo "  apt-daily at 04:30 and apt-daily-upgrade (unattended-upgrades) at 05:00"

log "3/7 Disabling cron (its daily jobs are already handled by systemd timers)"
systemctl disable --now cron.service 2>/dev/null && echo "  disabled: cron.service" || true

log "4/7 Memory: keep MAME out of swap"
cat > /etc/sysctl.d/90-arcade.conf <<'EOF'
# Arcade machine: only use swap when RAM is almost full (default 60)
vm.swappiness = 10
EOF
sysctl -q --system
echo "  vm.swappiness = $(cat /proc/sys/vm/swappiness)"

log "5/7 Capping log size"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/90-arcade.conf <<'EOF'
[Journal]
SystemMaxUse=50M
EOF
systemctl restart systemd-journald
journalctl --vacuum-size=50M -q || true

log "6/7 CPU at full performance (physical machines with cpufreq only)"
if [[ -d /sys/devices/system/cpu/cpu0/cpufreq ]]; then
  cat > /etc/systemd/system/cpu-performance.service <<'EOF'
[Unit]
Description=CPU governor in performance mode (arcade machine)

[Service]
Type=oneshot
ExecStart=/bin/sh -c 'for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do echo performance > "$g"; done'

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now cpu-performance.service
  echo "  governor: $(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor)"
else
  echo "  No cpufreq (virtual machine): skipped."
fi

log "7/7 Freeing disk (unused packages and kernels, apt cache)"
DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -qq
apt-get clean

log "Summary"
echo "Running services: $(systemctl list-units --type=service --state=running --no-legend | wc -l)"
echo "Active timers:    $(systemctl list-timers --no-legend | wc -l)"
echo "Disk used:        $(df -h / | awk 'NR==2{print $3}')"
echo
echo "Done. Reboot to measure the result:  sudo reboot"
