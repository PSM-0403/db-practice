-- 11. 설정 튜닝: work_mem, shared_buffers, log_min_duration_statement, random_page_cost
-- 접속: docker exec -it pg16 psql -U postgres -d practice
\pset pager off

-- 11-1. 현재 설정과 적용 방법 (context: postmaster = 재시작, sighup = 다시 읽기, user = 세션에서 변경)
SELECT name, setting, unit, context
FROM pg_settings
WHERE name IN ('shared_buffers', 'work_mem', 'maintenance_work_mem',
               'effective_cache_size', 'max_connections', 'max_wal_size',
               'checkpoint_timeout', 'random_page_cost')
ORDER BY name;

-- 11-2. work_mem과 정렬
SET max_parallel_workers_per_gather = 0;
EXPLAIN ANALYZE SELECT id, amount FROM orders ORDER BY amount;   -- 4MB: external merge Disk 26,256kB, 1,949.0ms
SET work_mem = '256MB';
EXPLAIN ANALYZE SELECT id, amount FROM orders ORDER BY amount;   -- 256MB: quicksort Memory 70,601kB, 1,189.3ms
RESET work_mem;

-- 임시 파일 누적량
SELECT datname, temp_files, pg_size_pretty(temp_bytes) AS temp_size
FROM pg_stat_database
WHERE datname = 'practice';

-- 11-3. shared_buffers (재시작 필요)
EXPLAIN (ANALYZE, BUFFERS) SELECT sum(amount) FROM orders;       -- 128MB: 두 번째도 read 10,239
ALTER SYSTEM SET shared_buffers = '512MB';
SELECT pg_reload_conf();
SHOW shared_buffers;                                             -- 아직 128MB
SELECT name, setting, pending_restart FROM pg_settings WHERE name = 'shared_buffers';   -- t
-- 셸: docker restart pg16
EXPLAIN (ANALYZE, BUFFERS) SELECT sum(amount) FROM orders;       -- 512MB 1차: read 10,368
EXPLAIN (ANALYZE, BUFFERS) SELECT sum(amount) FROM orders;       -- 512MB 2차: hit 10,368

-- 11-4. 되돌리기 + 재시작 없는 설정
ALTER SYSTEM RESET shared_buffers;
ALTER SYSTEM SET log_min_duration_statement = '200ms';
SELECT pg_reload_conf();
SELECT sum(amount) FROM orders;                                  -- 로그에 남음 (409.4ms)
SELECT id FROM orders WHERE id = 5;                              -- 안 남음
-- 셸: docker logs --tail 5 pg16
-- 셸: docker restart pg16

-- 11-5. random_page_cost와 실행계획 (각각 두 번 실행해서 두 번째 값 사용)
SET max_parallel_workers_per_gather = 0;
SET random_page_cost = 4;
EXPLAIN ANALYZE SELECT sum(amount) FROM orders WHERE customer_id < 50000;   -- Seq Scan, 339.4ms
SET random_page_cost = 1.1;
EXPLAIN ANALYZE SELECT sum(amount) FROM orders WHERE customer_id < 50000;   -- Index Scan, 629.0ms

-- 11-6. 정리 (ALTER SYSTEM RESET ALL은 pg_stat_statements 설정까지 지우므로 쓰지 않음)
RESET random_page_cost;
RESET max_parallel_workers_per_gather;
ALTER SYSTEM RESET log_min_duration_statement;
SELECT pg_reload_conf();
-- 셸: docker exec pg16 cat /var/lib/postgresql/data/postgresql.auto.conf
