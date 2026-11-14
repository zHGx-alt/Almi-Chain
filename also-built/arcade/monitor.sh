#!/bin/sh
# =============================================================================
# Almi-Chain · Resource monitor for the arcade machine
#
# Every few seconds it records CPU, memory, load, temperature and the emulator's
# own usage, and writes it to a CSV. POSIX sh (works under BusyBox too) and only
# /proc, /sys and basic commands: nothing to install.
#
# Usage:
#   sh monitor.sh [-i seconds] [-d seconds] [-l label] [-o folder] [-p process]
#
#   -i  interval between samples (default 5)
#   -d  total duration; 0 = until Ctrl+C (default 300)
#   -l  test label, for example "before" or "after" (default "test")
#   -o  output folder (default ./monitor)
#   -p  name of the emulator process to watch (default "mame")
#
# Output: <folder>/monitor_<label>_<date>-<time>.csv
# =============================================================================

INTERVAL=5
DURATION=300
LABEL=test
PROCESS=mame
OUTDIR=./monitor

usage() { sed -n '2,20p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

while getopts "i:d:l:o:p:h" opt; do
    case $opt in
        i) INTERVAL=$OPTARG ;;
        d) DURATION=$OPTARG ;;
        l) LABEL=$OPTARG ;;
        o) OUTDIR=$OPTARG ;;
        p) PROCESS=$OPTARG ;;
        *) usage ;;
    esac
done

# Validation: positive integers and a label without odd characters.
case $INTERVAL in ''|*[!0-9]*|0) echo "The interval (-i) must be an integer greater than 0." >&2; exit 1 ;; esac
case $DURATION in ''|*[!0-9]*)   echo "The duration (-d) must be an integer (0 = no limit)." >&2; exit 1 ;; esac
case $LABEL    in *[!A-Za-z0-9_-]*|'') echo "The label (-l) only accepts letters, digits, - and _." >&2; exit 1 ;; esac
case $PROCESS  in *[!A-Za-z0-9_.-]*|'') echo "The process (-p) only accepts letters, digits, . - and _." >&2; exit 1 ;; esac

mkdir -p "$OUTDIR" || { echo "Cannot create $OUTDIR" >&2; exit 1; }
FILE="$OUTDIR/monitor_${LABEL}_$(date +%Y%m%d-%H%M%S).csv"

# --- Readers -------------------------------------------------------------------

# Total CPU: leaves the accumulated jiffies in CPU_TOTAL and CPU_IDLE.
read_cpu() {
    read -r _ u n s i w irq sirq st _ < /proc/stat
    CPU_TOTAL=$((u + n + s + i + w + irq + sirq + st))
    CPU_IDLE=$((i + w))
}

# First PID whose name (comm) matches the watched process.
find_pid() {
    PID=
    for d in /proc/[0-9]*; do
        [ -r "$d/comm" ] || continue
        read -r c < "$d/comm" 2>/dev/null || continue
        if [ "$c" = "$PROCESS" ]; then PID=${d#/proc/}; return; fi
    done
}

# CPU (utime+stime) and resident memory of the process.
read_process() {
    PROC_JIFFIES=0; PROC_RSS_KB=0
    [ -n "$PID" ] && [ -r "/proc/$PID/stat" ] || return
    read -r line < "/proc/$PID/stat" 2>/dev/null || return
    rest=${line##*) }
    # shellcheck disable=SC2086
    set -- $rest
    PROC_JIFFIES=$((${12} + ${13}))
    while read -r k v _; do
        [ "$k" = "VmRSS:" ] && PROC_RSS_KB=$v && break
    done < "/proc/$PID/status" 2>/dev/null
}

read_memory() {
    MT=0; MA=0; MF=0; ST=0; SF=0
    while read -r k v _; do
        case $k in
            MemTotal:) MT=$v ;;
            MemFree:) MF=$v ;;
            MemAvailable:) MA=$v ;;
            SwapTotal:) ST=$v ;;
            SwapFree:) SF=$v ;;
        esac
    done < /proc/meminfo
    [ "$MA" -eq 0 ] && MA=$MF   # old kernels without MemAvailable
}

# Highest temperature across the thermal zones, in °C (empty if there are no sensors).
read_temperature() {
    TEMP=
    max=-1
    for z in /sys/class/thermal/thermal_zone*/temp; do
        [ -r "$z" ] || continue
        read -r t < "$z" 2>/dev/null || continue
        case $t in ''|*[!0-9-]*) continue ;; esac
        [ "$t" -gt "$max" ] && max=$t
    done
    [ "$max" -ge 0 ] && TEMP="$((max / 1000)).$(( (max % 1000) / 100 ))"
}

one_decimal() { # one_decimal <tenths>  ->  "12.3"
    echo "$(($1 / 10)).$(($1 % 10))"
}

# --- Main loop -----------------------------------------------------------------

STOP=0
trap 'STOP=1' INT TERM

echo "timestamp,seconds,cpu_pct,load_1min,mem_total_mb,mem_used_mb,mem_available_mb,swap_used_mb,temp_c,proc_cpu_pct,proc_rss_mb" > "$FILE"
echo "Writing to $FILE (every ${INTERVAL}s; watched process: $PROCESS). Ctrl+C to stop."

read_cpu; T0_TOTAL=$CPU_TOTAL; T0_IDLE=$CPU_IDLE
find_pid; read_process; P0=$PROC_JIFFIES
START=$(date +%s)
SAMPLES=0

while [ "$STOP" -eq 0 ]; do
    sleep "$INTERVAL" || break
    [ "$STOP" -eq 1 ] && break

    read_cpu
    DT=$((CPU_TOTAL - T0_TOTAL)); DI=$((CPU_IDLE - T0_IDLE))
    if [ "$DT" -gt 0 ]; then CPU10=$(( (1000 * (DT - DI)) / DT )); else CPU10=0; fi
    T0_TOTAL=$CPU_TOTAL; T0_IDLE=$CPU_IDLE

    find_pid; read_process
    DP=$((PROC_JIFFIES - P0)); [ "$DP" -lt 0 ] && DP=0   # the process restarted
    P0=$PROC_JIFFIES
    if [ "$DT" -gt 0 ]; then PCPU10=$(( (1000 * DP) / DT )); else PCPU10=0; fi

    read_memory; read_temperature
    read -r LOAD _ < /proc/loadavg

    NOW=$(date +%s)
    echo "$(date '+%Y-%m-%d %H:%M:%S'),$((NOW - START)),$(one_decimal $CPU10),$LOAD,$((MT / 1024)),$(((MT - MA) / 1024)),$((MA / 1024)),$(((ST - SF) / 1024)),$TEMP,$(one_decimal $PCPU10),$((PROC_RSS_KB / 1024))" >> "$FILE"
    SAMPLES=$((SAMPLES + 1))

    if [ "$DURATION" -gt 0 ] && [ $((NOW - START)) -ge "$DURATION" ]; then break; fi
done

echo "Finished: $SAMPLES samples in $FILE"
