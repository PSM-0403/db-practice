-- 10. 운영 중 스키마 변경: 컬럼 추가, 락 대기 줄, lock_timeout, CREATE INDEX CONCURRENTLY
-- 접속: docker exec -it pg16 psql -U postgres -d practice (10-2, 10-3은 창 3개)

-- 10-1. 컬럼 추가 세 가지
\timing on
ALTER TABLE orders ADD COLUMN memo text;                     -- 22.7ms: 정의만 바꿈
ALTER TABLE orders ADD COLUMN channel text DEFAULT 'web';    -- 17.1ms: 고정 기본값은 따로 기록만
ALTER TABLE orders ADD COLUMN rnd float DEFAULT random();    -- 2,174ms: 행마다 값이 달라 100만 행을 다시 씀

-- 10-2. 락 대기 줄
-- A창: BEGIN; SELECT count(*) FROM orders WHERE id < 10;     (커밋 안 함)
-- B창: ALTER TABLE orders ADD COLUMN flag boolean;            → A를 기다림
-- C창: SELECT * FROM orders WHERE id = 5;                     → B 뒤에 줄을 섬
-- A창에서 확인
SELECT pid, pg_blocking_pids(pid) AS blocked_by, state, wait_event_type, left(query, 45) AS query
FROM pg_stat_activity
WHERE datname = 'practice' AND pid <> pg_backend_pid();
-- B창 Ctrl + C → C가 바로 풀림

-- lock_timeout: 오래 기다리지 않고 포기
-- B창
SET lock_timeout = '3s';
ALTER TABLE orders ADD COLUMN flag boolean;   -- A가 열려 있으면 3초 뒤 ERROR: canceling statement due to lock timeout
-- A창: COMMIT; 후 B창에서 다시 실행하면 바로 성공
RESET lock_timeout;

-- 10-3. 인덱스: 일반 vs CONCURRENTLY
-- A창: BEGIN; UPDATE orders SET amount = amount WHERE id = 1;
-- B창: CREATE INDEX idx_orders_amount ON orders (amount);     → A를 기다림
-- C창: UPDATE orders SET amount = amount WHERE id = 2;        → B 뒤에서 멈춤 (B 취소하니 풀림)
-- B창: CREATE INDEX CONCURRENTLY idx_orders_amount ON orders (amount);   → A가 끝나기는 기다림
-- C창: UPDATE orders SET amount = amount WHERE id = 3;        → 바로 UPDATE 1
-- A창: COMMIT; → B의 인덱스 생성 완료
SELECT pg_size_pretty(pg_relation_size('idx_orders_amount'));   -- 29MB

-- 인덱스가 생겨도 쓰이는지는 조건에 따라 다름
EXPLAIN ANALYZE SELECT count(*) FROM orders WHERE amount > 50000;   -- 절반: Parallel Seq Scan
EXPLAIN ANALYZE SELECT count(*) FROM orders WHERE amount > 99000;   -- 약 1%: Bitmap Index Scan

-- 10-4. 정리
DROP INDEX idx_orders_amount;
ALTER TABLE orders DROP COLUMN memo, DROP COLUMN channel, DROP COLUMN rnd, DROP COLUMN flag;
