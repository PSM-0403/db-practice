-- 1. 구축: 실습 테이블 orders 100만 건 생성
-- 실행: docker exec -i pg16 psql -U postgres -d practice < 01_setup.sql

CREATE TABLE orders (
    id          bigserial PRIMARY KEY,
    customer_id int,
    amount      numeric(10,2),
    status      text,
    created_at  timestamptz
);

INSERT INTO orders (customer_id, amount, status, created_at)
SELECT (random() * 100000)::int,
       round((random() * 100000)::numeric, 2),
       (ARRAY['paid', 'cancelled', 'refunded'])[1 + floor(random() * 3)::int],
       now() - random() * interval '365 days'
FROM generate_series(1, 1000000);

-- 통계 갱신 후 건수 확인
ANALYZE orders;
SELECT count(*) FROM orders;  -- 1000000

-- 볼륨 확인: 컨테이너를 지우고(docker rm -f pg16) 같은 볼륨으로 다시 실행해도 count = 1000000
