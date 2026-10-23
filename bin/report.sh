#!/bin/bash
LOG="${MONITOR_LOG:-/var/log/agent-app/monitor.log}"

[ -r "$LOG" ] || { echo "[ERROR] cannot read log: $LOG" >&2; exit 1; }

# HEALTH_CHECK_FAILED 줄에는 수치가 없으므로 4번째 칸이 CPU:로 시작하는 정상 줄만 센다
# 줄 모양: [2026-02-25 13:58:01] PID:48291 CPU:10.2% MEM:3.2% DISK_USED:23%  (칸 = $1 $2 PID CPU MEM DISK)
awk '
function add(k, v, ts) {
  sum[k] += v
  if (!(k in max) || v > max[k]) { max[k] = v; maxat[k] = ts }
  if (!(k in min) || v < min[k]) { min[k] = v; minat[k] = ts }
}
$4 ~ /^CPU:/ {
  ts = substr($1, 2) " " substr($2, 1, 8)
  add("CPU", substr($4, 5) + 0, ts)
  add("MEM", substr($5, 5) + 0, ts)
  add("DISK", substr($6, 11) + 0, ts)
  n++
}
END {
  if (!n) { print "[WARNING] no samples in log"; exit 1 }
  print "====== STATISTICS REPORT ======"
  split("CPU MEM DISK", keys, " ")
  split("[CPU] [Memory] [Disk]", names, " ")
  for (i = 1; i <= 3; i++) {
    k = keys[i]
    print names[i]
    printf "Average : %.1f%%\n", sum[k] / n
    printf "Maximum : %.1f%% at %s\n", max[k], maxat[k]
    printf "Minimum : %.1f%% at %s\n", min[k], minat[k]
  }
  print "[Samples]"
  print "Data Points: " n " samples"
}' "$LOG"
