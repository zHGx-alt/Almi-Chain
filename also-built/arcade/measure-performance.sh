#!/usr/bin/env bash
# Takes ONE performance sample of the arcade machine and appends it to a CSV.
# Run right after booting (on tty2 or over SSH), once per reboot:
#   sudo ./measure-performance.sh before            # boot, RAM, processes...
#   sudo ./measure-performance.sh before --bench    # plus a MAME benchmark (~2 min)
set -euo pipefail
export LC_ALL=C   # decimal points (a Spanish locale's comma would break the CSV)

LABEL="${1:?Usage: sudo $0 <label> [--bench]}"
CSV="${CSV:-/root/performance.csv}"
MAME=/usr/games/mame
ROMS=/home/arcade/roms
BENCH_SECONDS=30

[[ $EUID -eq 0 ]] || { echo "Run with sudo" >&2; exit 1; }

# Wait until MAME is open and let the system settle
for _ in $(seq 1 60); do pgrep -u arcade -x mame >/dev/null && break; sleep 1; done
MAME_PID=$(pgrep -u arcade -x mame | head -1) || { echo "MAME is not running" >&2; exit 1; }
sleep 20

# Boot times (systemd-analyze may take a few seconds to have them)
until systemd-analyze >/dev/null 2>&1; do sleep 1; done
LINE=$(systemd-analyze | head -1)
T_KERNEL=$(grep -oP '[\d.]+(?=s \(kernel\))' <<<"$LINE")
T_USER=$(grep -oP '[\d.]+(?=s \(userspace\))' <<<"$LINE")
T_TOTAL=$(grep -oP '(?<== )[\d.]+(?=s)' <<<"$LINE")

# Second (since the kernel started) at which MAME opened
TICKS=$(awk '{print $22}' "/proc/${MAME_PID}/stat")
T_MAME=$(awk -v t="$TICKS" -v hz="$(getconf CLK_TCK)" 'BEGIN{printf "%.2f", t/hz}')

RAM_USED=$(free -m | awk '/^Mem:/{print $3}')
MAME_RSS=$(( $(ps -o rss= -p "$MAME_PID") / 1024 ))
PROCESSES=$(ps -e --no-headers | wc -l)
SERVICES=$(systemctl list-units --type=service --state=running --no-legend | wc -l)
TIMERS=$(systemctl list-timers --no-legend | wc -l)
DISK_MB=$(df -m / | awk 'NR==2{print $3}')

bench() {   # average speed (%) of a game with -bench; 100 % = real speed
  (cd /tmp && sudo -u arcade "$MAME" -rompath "$ROMS" -bench "$BENCH_SECONDS" "$1" 2>/dev/null) \
    | grep -oP '(?<=Average speed: )[\d.]+'
}
B_GRIDLEE=""; B_ROBBY=""
if [[ "${2:-}" == "--bench" ]]; then
  B_GRIDLEE=$(bench gridlee)
  B_ROBBY=$(bench robby)
fi

[[ -f "$CSV" ]] || echo "label,date,kernel_s,userspace_s,total_s,mame_open_s,ram_used_mb,mame_rss_mb,processes,services,timers,disk_mb,bench_gridlee_pct,bench_robby_pct" > "$CSV"
ROW="$LABEL,$(date '+%F %T'),$T_KERNEL,$T_USER,$T_TOTAL,$T_MAME,$RAM_USED,$MAME_RSS,$PROCESSES,$SERVICES,$TIMERS,$DISK_MB,$B_GRIDLEE,$B_ROBBY"
echo "$ROW" >> "$CSV"
echo "$ROW"
