-- 2. 계정·권한: 조회 전용 계정
-- 실행: docker exec -i pg16 psql -U postgres -d practice -v ro_pass="'비밀번호'" < 02_roles.sql

CREATE ROLE readonly_user LOGIN PASSWORD :ro_pass;
GRANT CONNECT ON DATABASE practice TO readonly_user;
GRANT USAGE ON SCHEMA public TO readonly_user;
GRANT SELECT ON ALL TABLES IN SCHEMA public TO readonly_user;

-- 확인 (psql -U readonly_user -d practice 로 접속해서 실행)
-- SELECT count(*) FROM orders;          -- 1000000
-- DELETE FROM orders WHERE id = 1;      -- ERROR: permission denied for table orders

-- 권한 회수 후 다시 부여
REVOKE SELECT ON orders FROM readonly_user;
-- readonly_user로 SELECT → ERROR: permission denied for table orders
GRANT SELECT ON orders TO readonly_user;
