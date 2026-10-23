#!/bin/bash
# cron(agent-admin)에서는 ~/.bashrc의 AGENT_* 변수가 없으므로 기본값을 둔다.
APP=agent-app-linux
PORT="${AGENT_PORT:-15034}"
LOG="${MONITOR_LOG:-/var/log/agent-app/monitor.log}"
MAX_BYTES=$((10 * 1024 * 1024))
KEEP=10

# cron(agent-admin)과 수동 실행(agent-dev)이 같은 로그를 이어 쓰도록 그룹 쓰기 권한(660)을 남긴다
umask 007

# logrotate 대신 스크립트 안에서 회전한다: 매분 실행이 곧 점검이라 10MB를 넘는 즉시 돌고 설정 파일이 따로 필요 없다
# 보관은 monitor.log + .1~.9 = 10개 (명세 "최대 10개 파일 유지"를 현재 파일 포함으로 읽음)
rotate_log() {
  [ "$(stat -c %s "$LOG" 2>/dev/null || echo 0)" -ge "$MAX_BYTES" ] || return 0
  rm -f "$LOG.$((KEEP - 1))"
  for ((i = KEEP - 2; i >= 1; i--)); do
    [ -f "$LOG.$i" ] && mv "$LOG.$i" "$LOG.$((i + 1))"
  done
  mv "$LOG" "$LOG.1"
}

# 쓰기 직전에 회전을 검사하므로 정상 종료와 Health Check 실패 종료 어디서 불러도 같다
log() { rotate_log; echo "[$(date '+%F %T')] $*" >> "$LOG"; }

echo "====== SYSTEM MONITOR RESULT ======"
echo
echo "[HEALTH CHECK]"

# 같은 이름 프로세스가 둘(PyInstaller 부모·자식)이라 -n으로 가장 늦게 뜬 자식(실제 앱)을 고른다
PID=$(pgrep -fn "$APP")
if [ -z "$PID" ]; then
  echo "Checking process '$APP'... [ERROR] not running"
  log "HEALTH_CHECK_FAILED process"
  exit 1
fi
echo "Checking process '$APP'... [OK] (PID: $PID)"

if ! ss -ltn "sport = :$PORT" | grep -q LISTEN; then
  echo "Checking port $PORT... [ERROR] not listening"
  log "HEALTH_CHECK_FAILED port"
  exit 1
fi
echo "Checking port $PORT... [OK]"

# sudo 없이 읽을 수 있는 설정 파일 값으로 판단한다(실제 적용 상태와 어긋날 수 있음)
echo
if grep -q '^ENABLED=yes' /etc/ufw/ufw.conf; then
  echo "[FIREWALL] ufw is enabled"
else
  echo "[WARNING] Firewall (ufw) is not enabled"
fi

# CPU: /proc/stat 누적 시간을 1초 간격으로 두 번 읽어 그 사이 idle이 아니었던 비율을 구한다
cpu_times() { awk '/^cpu /{print $2+$3+$4+$5+$6+$7+$8+$9, $5+$6}' /proc/stat; }
read -r T1 I1 < <(cpu_times)
sleep 1
read -r T2 I2 < <(cpu_times)
CPU=$(awk -v t=$((T2-T1)) -v i=$((I2-I1)) 'BEGIN{printf "%.1f", (t-i)*100/t}')
MEM=$(free | awk '/^Mem:/{printf "%.1f", ($2-$7)*100/$2}')
DISK=$(df --output=pcent / | tail -1 | tr -dc 0-9)

echo
echo "[RESOURCE MONITORING]"
echo "CPU Usage : ${CPU}%"
echo "MEM Usage : ${MEM}%"
echo "DISK Used : ${DISK}%"
echo

# Bash [ ]는 정수만 비교하므로 20.9 같은 소수는 awk로 비교한다
over() { awk -v v="$1" -v t="$2" 'BEGIN{exit !(v>t)}'; }
over "$CPU" 20 && echo "[WARNING] CPU threshold exceeded (${CPU}% > 20%)"
over "$MEM" 10 && echo "[WARNING] MEM threshold exceeded (${MEM}% > 10%)"
over "$DISK" 80 && echo "[WARNING] DISK_USED threshold exceeded (${DISK}% > 80%)"

log "PID:$PID CPU:${CPU}% MEM:${MEM}% DISK_USED:${DISK}%" && echo "[INFO] Log appended: $LOG"

# 마지막 && 줄이 거짓이면 종료 코드가 1이 되므로 경고는 종료가 아니라고 명시한다
exit 0
