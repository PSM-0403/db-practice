-- 6. 모니터링: 자원, 크기, 막힌 세션, 죽은 행, 느린 쿼리
-- 접속: docker exec -it pg16 psql -U postgres -d practice

-- 6-1. 서버·컨테이너 자원 (Ubuntu 셸)
-- df -h /                         -- DB가 쓰는 디스크 사용량
-- free -h                         -- 메모리 (free보다 available을 봄)
-- docker stats --no-stream pg16   -- 컨테이너 CPU, 메모리

-- 6-2. DB·테이블 크기
SELECT pg_size_pretty(pg_database_size('practice')) AS db_size;

SELECT relname AS table_name,
       pg_size_pretty(pg_relation_size(relid))       AS table_size,
       pg_size_pretty(pg_indexes_size(relid))        AS index_size,
       pg_size_pretty(pg_total_relation_size(relid)) AS total_size
FROM pg_stat_user_tables
ORDER BY pg_total_relation_size(relid) DESC;

-- 6-3. 락을 잡고 안 놓는 세션 찾아서 끊기 (터미널 3개)
-- A창: SELECT pg_backend_pid(); BEGIN; UPDATE orders SET amount = amount + 1 WHERE id = 1;  (커밋 안 함)
-- B창: UPDATE orders SET amount = amount + 1 WHERE id = 1;  → 멈춤
-- C창: 누가 누구를 막는지 확인
SELECT pid,
       pg_blocking_pids(pid) AS blocked_by,
       state,
       now() - xact_start AS xact_age,
       left(query, 40) AS query
FROM pg_stat_activity
WHERE datname = 'practice' AND pid <> pg_backend_pid();
-- C창: 막고 있는 세션 종료 (pid는 위 결과에서 idle in transaction인 세션)
-- SELECT pg_terminate_backend(132);   → B가 풀리면서 UPDATE 1

-- 6-4. 죽은 행과 VACUUM
SELECT relname, n_live_tup, n_dead_tup, last_vacuum, last_autovacuum
FROM pg_stat_user_tables;
SELECT pg_size_pretty(pg_relation_size('orders'));

UPDATE orders SET amount = amount WHERE id <= 100000;   -- 값은 그대로지만 새 행 10만 개가 생김
SELECT relname, n_live_tup, n_dead_tup FROM pg_stat_user_tables;   -- n_dead_tup 약 10만

VACUUM (VERBOSE) orders;
SELECT relname, n_live_tup, n_dead_tup, last_vacuum FROM pg_stat_user_tables;   -- n_dead_tup 0
SELECT pg_size_pretty(pg_relation_size('orders'));   -- 크기는 줄지 않음

-- 6-5. 느린 쿼리 찾기 (pg_stat_statements)
ALTER SYSTEM SET shared_preload_libraries = 'pg_stat_statements';
-- 설정은 시작할 때만 읽어서 재시작 필요 (Ubuntu 셸): docker restart pg16
CREATE EXTENSION pg_stat_statements;
SELECT pg_stat_statements_reset();

SELECT count(*) FROM orders WHERE amount > 50000;
SELECT count(*) FROM orders WHERE amount > 50000;
SELECT count(*) FROM orders WHERE amount > 50000;
SELECT * FROM orders WHERE id = 1;
SELECT * FROM orders WHERE id = 2;
SELECT * FROM orders WHERE customer_id = 123 ORDER BY created_at DESC LIMIT 10;

SELECT calls,
       round(total_exec_time::numeric, 1) AS total_ms,
       round(mean_exec_time::numeric, 2)  AS mean_ms,
       rows,
       left(query, 60) AS query
FROM pg_stat_statements
ORDER BY total_exec_time DESC
LIMIT 5;
