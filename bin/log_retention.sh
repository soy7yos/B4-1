#!/bin/bash
LOG_DIR="${LOG_DIR:-/var/log/agent-app}"
ARCHIVE_DIR="${ARCHIVE_DIR:-/var/log/monitor/agent-app/archive}"

[ -d "$LOG_DIR" ] || { echo "[ERROR] log dir not found: $LOG_DIR" >&2; exit 1; }
# 아카이브 폴더가 없으면 만들어 보고, 못 만들거나 쓸 수 없으면(권한 부족) 아무것도 건드리지 않고 끝낸다
mkdir -p "$ARCHIVE_DIR" 2>/dev/null && [ -w "$ARCHIVE_DIR" ] ||
  { echo "[ERROR] archive dir missing or not writable: $ARCHIVE_DIR" >&2; exit 1; }

# -mtime은 일 단위로 잘라 세서 "정확히 7일"이 애매하므로 분 단위(-mmin)로 쓴다: 7일=10080분, 30일=43200분
# monitor.sh의 회전 파일(monitor.log.1~.9)은 이름이 *.log가 아니라서 같이 잡는다
zipped=0
while IFS= read -r -d '' f; do
  # gzip은 원본의 수정 시각을 .gz에 그대로 물려주므로 30일 삭제도 원본 기준으로 센다
  if gzip "$f" && mv "$f.gz" "$ARCHIVE_DIR/$(basename "$f")-$(date +%Y%m%d-%H%M%S).gz"; then
    echo "[INFO] archived: $f"
    zipped=$((zipped + 1))
  else
    echo "[WARNING] failed to archive: $f" >&2
  fi
done < <(find "$LOG_DIR" -maxdepth 1 -type f \( -name '*.log' -o -name '*.log.[0-9]' \) -mmin +10080 -print0)

deleted=0
while IFS= read -r -d '' f; do
  if rm -- "$f"; then
    echo "[INFO] deleted: $f"
    deleted=$((deleted + 1))
  else
    echo "[WARNING] failed to delete: $f" >&2
  fi
done < <(find "$ARCHIVE_DIR" -maxdepth 1 -type f -name '*.gz' -mmin +43200 -print0)

[ $((zipped + deleted)) -eq 0 ] && echo "[INFO] nothing to do (no log older than 7 days, no archive older than 30 days)"
echo "[INFO] done: $zipped compressed, $deleted deleted"
