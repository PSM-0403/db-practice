#!/usr/bin/env bash
# 3. 백업·복구: 테이블을 실수로 삭제한 상황을 재현하고 백업으로 복구
set -euo pipefail

BACKUP_DIR=~/db-practice/backup
mkdir -p "$BACKUP_DIR"

# 백업 (커스텀 포맷) → 컨테이너 밖으로 복사
time docker exec pg16 pg_dump -U postgres -d practice -Fc -f /tmp/practice.dump
docker cp pg16:/tmp/practice.dump "$BACKUP_DIR/practice.dump"
ls -lh "$BACKUP_DIR/practice.dump"   # 21MB

# 사고 재현
docker exec pg16 psql -U postgres -d practice -c "DROP TABLE orders;"

# 복구
docker cp "$BACKUP_DIR/practice.dump" pg16:/tmp/practice.dump
time docker exec pg16 pg_restore -U postgres -d practice --clean --if-exists /tmp/practice.dump

# 확인: 건수, 기본 키, 권한
docker exec pg16 psql -U postgres -d practice -c "SELECT count(*) FROM orders;"
docker exec pg16 psql -U postgres -d practice -c "\d orders"
docker exec pg16 psql -U postgres -d practice -c "\dp orders"
