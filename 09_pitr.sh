#!/usr/bin/env bash
# 9. PITR: 베이스 백업 + 보관한 WAL로 실수 직전 시각까지 복구
# 대상: apt로 직접 설치한 PostgreSQL 16 (포트 5433, linux/L1 참고)
# 한 번에 돌리는 스크립트가 아니라 순서표. psql 안에서 칠 SQL은 주석으로 적음

# 9-1. WAL 보관 켜기
sudo -u postgres mkdir -p /var/lib/postgresql/wal_archive
sudo -u postgres chmod 700 /var/lib/postgresql/wal_archive
sudo tee /etc/postgresql/16/main/conf.d/pitr.conf > /dev/null <<'EOF'
archive_mode = on
archive_command = 'test ! -f /var/lib/postgresql/wal_archive/%f && cp %p /var/lib/postgresql/wal_archive/%f'
EOF
sudo systemctl restart postgresql@16-main   # archive_mode는 재시작해야 적용
sudo -u postgres psql -p 5433 -c "SHOW archive_mode;"

# 9-2. 테스트 데이터와 베이스 백업
# sudo -u postgres psql -p 5433
#   CREATE DATABASE pitr;
#   \c pitr
#   CREATE TABLE accounts (id int PRIMARY KEY, owner text, balance int);
#   INSERT INTO accounts SELECT g, 'user_' || g, 10000 FROM generate_series(1, 1000) g;
sudo -u postgres pg_basebackup -p 5433 -D /var/lib/postgresql/16/base_backup -Fp -Xs -P

# 9-3. 실수 재현
# sudo -u postgres psql -p 5433 -d pitr
#   INSERT INTO accounts VALUES (1001, 'before_mistake', 5000);
#   SELECT now();              -- 이 시각을 기록 (복구 목표)
#   DELETE FROM accounts;      -- 실수
#   SELECT pg_switch_wal();    -- 쓰던 WAL을 마감해서 보관되게 함
sudo -u postgres psql -p 5433 -c "SELECT archived_count, last_archived_wal, failed_count FROM pg_stat_archiver;"

# 9-4. 복구
sudo systemctl stop postgresql@16-main
sudo mv /var/lib/postgresql/16/main /var/lib/postgresql/16/main_broken   # 지우지 않고 보존
sudo cp -a /var/lib/postgresql/16/base_backup /var/lib/postgresql/16/main  # -a: 소유자·권한 유지
sudo tee -a /etc/postgresql/16/main/conf.d/pitr.conf > /dev/null <<'EOF'
restore_command = 'cp /var/lib/postgresql/wal_archive/%f %p'
recovery_target_time = '2026-11-02 13:10:00.353171+09'
recovery_target_action = 'promote'
EOF
sudo -u postgres touch /var/lib/postgresql/16/main/recovery.signal
sudo systemctl start postgresql@16-main
sudo tail -15 /var/log/postgresql/postgresql-16-main.log   # recovery stopping before commit ...
sudo -u postgres psql -p 5433 -d pitr -c "SELECT count(*) FROM accounts;"   # 1001

# 9-5. 정리
sudo -u postgres psql -p 5433 -c "SELECT timeline_id FROM pg_control_checkpoint();"   # 2
sudo rm /etc/postgresql/16/main/conf.d/pitr.conf
sudo systemctl restart postgresql@16-main
sudo rm -rf /var/lib/postgresql/16/main_broken /var/lib/postgresql/16/base_backup /var/lib/postgresql/wal_archive
