#!/usr/bin/env bash
# 7. 복제: 주 서버(pg16) 1대 + 복제 서버(pg16-replica) 1대, 장애 조치, 정리
# 한 번에 돌리는 스크립트가 아니라 순서표. psql 안에서 칠 SQL은 주석으로 적음

# 7-1. 두 컨테이너가 이름으로 서로 찾을 수 있게 네트워크 생성
docker network create pgnet
docker network connect pgnet pg16

# 7-2. 주 서버 준비
read -s -p "replicator 비밀번호: " REPL_PASS; echo
docker exec pg16 psql -U postgres -c "CREATE ROLE replicator WITH REPLICATION LOGIN PASSWORD '$REPL_PASS';"
# 다른 컨테이너에서 오는 복제 접속 허용
docker exec pg16 bash -c 'echo "host replication replicator all scram-sha-256" >> "$PGDATA/pg_hba.conf"'
docker exec pg16 psql -U postgres -c "SELECT pg_reload_conf();"
docker exec pg16 psql -U postgres -c "SELECT type, database, user_name, auth_method FROM pg_hba_file_rules;"

# 7-3. 복제 서버 만들기: 주 서버를 통째로 복사(물리 백업) 후 실행
docker volume create pgreplica
docker run --rm --network pgnet \
  -v pgreplica:/var/lib/postgresql/data \
  -e PGPASSWORD="$REPL_PASS" \
  postgres:16 \
  pg_basebackup -h pg16 -U replicator -D /var/lib/postgresql/data -Fp -Xs -P -R -C -S replica1
docker run -d --name pg16-replica --network pgnet \
  -v pgreplica:/var/lib/postgresql/data \
  postgres:16
docker logs pg16-replica 2>&1 | tail -5   # entering standby mode, started streaming WAL from primary

# 7-4. 복제 확인
# 복제 서버: docker exec -it pg16-replica psql -U postgres -d practice
#   SELECT pg_is_in_recovery();                     -- t
# 주 서버: docker exec -it pg16 psql -U postgres -d practice
#   SELECT client_addr, state, sync_state, replay_lag FROM pg_stat_replication;   -- streaming, async
#   SELECT slot_name, active FROM pg_replication_slots;                           -- replica1, t
#   CREATE TABLE repl_test (id int, note text, created_at timestamptz DEFAULT now());
#   INSERT INTO repl_test (id, note) VALUES (1, 'primary에서 입력');
# 복제 서버:
#   SELECT * FROM repl_test;                        -- 1번 행 보임
#   INSERT INTO repl_test (id, note) VALUES (2, 'replica에서 입력');
#   -- ERROR: cannot execute INSERT in a read-only transaction

# 7-5. 장애 조치
# 주 서버: INSERT INTO repl_test (id, note) VALUES (2, '장애 직전 primary에서 입력');
docker stop pg16
docker logs pg16-replica 2>&1 | tail -3   # 주 서버 연결 실패
# 복제 서버:
#   SELECT pg_promote();
#   SELECT pg_is_in_recovery();                     -- f, 이제 주 서버
#   INSERT INTO repl_test (id, note) VALUES (3, '승격 후 replica에서 입력');   -- 성공

# 7-6. 정리: 복제 서버 삭제 후 원래 주 서버로 복귀
docker rm -f pg16-replica
docker volume rm pgreplica
docker start pg16
# 주 서버:
#   SELECT slot_name, active,
#          pg_size_pretty(pg_wal_lsn_diff(pg_current_wal_lsn(), restart_lsn)) AS retained_wal
#   FROM pg_replication_slots;                      -- replica1, f → 받는 서버가 없어도 WAL을 계속 쌓아 둠
#   SELECT pg_drop_replication_slot('replica1');
#   SELECT * FROM repl_test;                        -- 1, 2번만 있음 (3번은 지운 복제 서버에만 있었음)
#   DROP TABLE repl_test;
