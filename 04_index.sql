-- 4. 실행계획·인덱스: "특정 고객의 최근 주문 10건" 조회 개선
-- 실행: docker exec -it pg16 psql -U postgres -d practice  후 단계별로 실행 (각 쿼리 2~3회)

-- (1) 인덱스 없음: Parallel Seq Scan + Sort, 37~51ms
EXPLAIN ANALYZE
SELECT * FROM orders WHERE customer_id = 12345 ORDER BY created_at DESC LIMIT 10;

-- (2) customer_id 단일 인덱스: Bitmap Index Scan + Sort, 0.233ms
CREATE INDEX idx_orders_customer ON orders (customer_id);
EXPLAIN ANALYZE
SELECT * FROM orders WHERE customer_id = 12345 ORDER BY created_at DESC LIMIT 10;

-- (3) 복합 인덱스: Index Scan, Sort 없음, 0.048ms
CREATE INDEX idx_orders_customer_created ON orders (customer_id, created_at DESC);
EXPLAIN ANALYZE
SELECT * FROM orders WHERE customer_id = 12345 ORDER BY created_at DESC LIMIT 10;

-- (4) 값 종류가 적은 status 인덱스
CREATE INDEX idx_orders_status ON orders (status);

-- count(*): Index Only Scan 20.3ms
EXPLAIN ANALYZE SELECT count(*) FROM orders WHERE status = 'paid';

-- 인덱스를 끄고 비교: Seq Scan 81.0ms
SET enable_indexscan = off;
SET enable_indexonlyscan = off;
SET enable_bitmapscan = off;
EXPLAIN ANALYZE SELECT count(*) FROM orders WHERE status = 'paid';
RESET enable_indexscan;
RESET enable_indexonlyscan;
RESET enable_bitmapscan;

-- sum(amount): 인덱스가 있어도 Parallel Seq Scan, 101ms
EXPLAIN ANALYZE SELECT sum(amount) FROM orders WHERE status = 'paid';

-- (5) 인덱스 비용 확인: 테이블 66MB, 인덱스 합계 약 67MB
SELECT pg_size_pretty(pg_relation_size('orders')) AS table_size,
       pg_size_pretty(pg_indexes_size('orders'))  AS index_size;

SELECT indexrelname, pg_size_pretty(pg_relation_size(indexrelid)) AS size
FROM pg_stat_user_indexes
WHERE relname = 'orders';

-- (6) 정리: 복합 인덱스와 겹치는 단일 인덱스, 효과가 적은 status 인덱스 삭제 → 51MB
DROP INDEX idx_orders_customer;
DROP INDEX idx_orders_status;
SELECT pg_size_pretty(pg_indexes_size('orders')) AS index_size;

-- 삭제 후 customer_id 조건 조회는 복합 인덱스로 처리 (0.119ms)
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 12345;
