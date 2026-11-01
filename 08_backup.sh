#!/usr/bin/env bash
# 8. 자동 백업: pg_dump로 백업하고 7일 지난 백업은 삭제
set -uo pipefail

BACKUP_DIR="$HOME/db-practice/backup/auto"
LOG="$BACKUP_DIR/backup.log"
KEEP_DAYS=7
FILE="$BACKUP_DIR/practice_$(date +%Y%m%d_%H%M%S).dump"

mkdir -p "$BACKUP_DIR"

if docker exec pg16 pg_dump -U postgres -d practice -Fc > "$FILE" 2>>"$LOG" && [ -s "$FILE" ]; then
  echo "$(date '+%F %T') OK   $(basename "$FILE") $(du -h "$FILE" | cut -f1)" >> "$LOG"
else
  echo "$(date '+%F %T') FAIL $(basename "$FILE")" >> "$LOG"
  rm -f "$FILE"
  exit 1
fi

find "$BACKUP_DIR" -name 'practice_*.dump' -mtime +"$KEEP_DAYS" -delete
