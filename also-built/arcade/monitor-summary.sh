#!/bin/sh
# =============================================================================
# Almi-Chain · Summary of one or more CSV files from monitor.sh
#
# Usage:  sh monitor-summary.sh file1.csv [file2.csv ...]
# Prints one row per file (for example, before and after tuning) with
# averages and extremes. Needs awk (any Linux has it).
# =============================================================================

[ $# -ge 1 ] || { sed -n '2,8p' "$0" | sed 's/^# \{0,1\}//'; exit 1; }

printf '%-34s %8s %8s %8s %10s %13s %8s %9s\n' "file" "samples" "cpu_avg" "cpu_max" "mem_used" "mem_free_min" "temp_max" "proc_cpu"
for f in "$@"; do
    [ -r "$f" ] || { echo "Cannot read $f" >&2; continue; }
    awk -F, -v name="$(basename "$f")" '
        NR == 1 { next }
        {
            n++
            cpu += $3; if (n == 1 || $3 > cpumax) cpumax = $3
            mem += $6
            if (n == 1 || $7 < memfree) memfree = $7
            if ($9 != "" && (tn == 0 || $9 > tmax)) tmax = $9
            if ($9 != "") tn++
            pcpu += $10
        }
        END {
            if (n == 0) { printf "%-34s no data\n", name; exit }
            t = (tn > 0) ? sprintf("%.1f", tmax) : "n/a"
            printf "%-34s %8d %7.1f%% %7.1f%% %7.0f MB %10.0f MB %8s %8.1f%%\n", name, n, cpu/n, cpumax, mem/n, memfree, t, pcpu/n
        }' "$f"
done
