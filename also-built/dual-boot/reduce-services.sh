#!/bin/bash
# Ubuntu side of the manager's PC: disables the services an office PC does not need and
# writes a before/after report.
# Usage: sudo bash reduce-services.sh [report-file]
# Safe to repeat: services already disabled or missing are skipped.
set -euo pipefail
[ "$(id -u)" = 0 ] || { echo "Run with sudo"; exit 1; }
OUT=${1:-/root/reduced-services.txt}   # report path

# What goes and why. CUPS stays: the manager prints over USB.
declare -A REMOVE=(
  [cups-browsed.service]="finds network printers and adds them on its own; the manager's printer is on USB"
  [avahi-daemon.service]="announces the PC on the local network (mDNS); not needed in the office"
  [avahi-daemon.socket]="starts avahi-daemon on demand"
  [ModemManager.service]="manages 3G/4G modems; the PC has none"
  [whoopsie.service]="sends crash reports to Canonical"
  [kerneloops.service]="sends kernel crashes to Canonical"
  [apport.service]="collects crash reports to send them"
)

enabled_units() { systemctl list-unit-files --type=service --type=socket --state=enabled --no-legend | awk '{print $1}' | LC_ALL=C sort; }

BEFORE=$(enabled_units)
for u in "${!REMOVE[@]}"; do
  if systemctl cat "$u" >/dev/null 2>&1 && systemctl is-enabled "$u" 2>/dev/null | grep -qx enabled; then
    systemctl disable --now "$u" >/dev/null 2>&1 && echo "Disabled: $u (${REMOVE[$u]})"
  fi
done
AFTER=$(enabled_units)

{ echo "# Manager's Ubuntu: reduced services ($(date '+%F %H:%M'))"
  echo; echo "## Enabled services and sockets BEFORE ($(echo "$BEFORE" | grep -c .))"; echo "$BEFORE"
  echo; echo "## Enabled services and sockets AFTER ($(echo "$AFTER" | grep -c .))"; echo "$AFTER"
  echo; echo "## Removed in this run"; LC_ALL=C comm -23 <(echo "$BEFORE") <(echo "$AFTER") || true
  echo; echo "## Why each one"; for u in "${!REMOVE[@]}"; do echo "- $u: ${REMOVE[$u]}"; done
  echo; echo '$ ss -tulpn (listening ports afterwards)'; ss -tulpn
} > "$OUT"
echo; echo "DONE. Report in $OUT"
