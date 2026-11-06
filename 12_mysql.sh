#!/bin/bash
# 12. MySQL 기초: 설치, 계정·권한, 100만 건, 실행계획·인덱스, mysqldump 백업·복구
# 비밀번호는 저장하지 않음. 실행 전에 read -s MYSQL_PW

# 12-1. 컨테이너 실행과 접속
docker run -d --name mysql8 \
  -e MYSQL_ROOT_PASSWORD="$MYSQL_PW" \
  -v mysqldata:/var/lib/mysql \
  -p 3306:3306 \
  mysql:8.0
docker logs --tail 3 mysql8                 # ready for connections, port: 3306 확인
docker exec -it mysql8 mysql -uroot -p

# 아래 SQL은 mysql> 안에서 실행
: <<'SQL'
SELECT VERSION();                           -- 8.0.46
SHOW DATABASES;
SHOW VARIABLES LIKE 'datadir';              -- /var/lib/mysql/
SHOW VARIABLES LIKE 'transaction_isolation'; -- REPEATABLE-READ
SELECT @@default_storage_engine;            -- InnoDB

-- 12-2. DB와 계정·권한
CREATE DATABASE practice CHARACTER SET utf8mb4;
USE practice;
CREATE TABLE perm_test (id INT PRIMARY KEY, name VARCHAR(20));
INSERT INTO perm_test VALUES (1, 'a'), (2, 'b');
CREATE USER 'readonly_user'@'%' IDENTIFIED BY '비밀번호';
GRANT SELECT ON practice.* TO 'readonly_user'@'%';
SHOW GRANTS FOR 'readonly_user'@'%';
SELECT user, host FROM mysql.user;
-- readonly_user로 접속: SELECT 성공, DELETE는 ERROR 1142

-- 12-3. 100만 건
CREATE TABLE orders (
  id BIGINT AUTO_INCREMENT PRIMARY KEY,
  customer_id INT NOT NULL,
  amount DECIMAL(10,2) NOT NULL,
  status VARCHAR(20) NOT NULL,
  created_at DATETIME NOT NULL
);
SET SESSION cte_max_recursion_depth = 1000000;
INSERT INTO orders (customer_id, amount, status, created_at)
WITH RECURSIVE seq (n) AS (
  SELECT 1
  UNION ALL
  SELECT n + 1 FROM seq WHERE n < 1000000
)
SELECT FLOOR(RAND() * 100000),
       ROUND(RAND() * 100000, 2),
       ELT(1 + FLOOR(RAND() * 3), 'paid', 'cancelled', 'refunded'),
       NOW() - INTERVAL FLOOR(RAND() * 31536000) SECOND
FROM seq;
ANALYZE TABLE orders;
SELECT table_name, table_rows,
       ROUND(data_length / 1024 / 1024) AS data_mb,
       ROUND(index_length / 1024 / 1024) AS index_mb
FROM information_schema.tables
WHERE table_schema = 'practice';            -- data 51MB, index 0MB

-- 12-4. 실행계획과 인덱스
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 12345 ORDER BY created_at DESC LIMIT 10\G  -- ALL, filesort, 545ms
CREATE INDEX idx_customer ON orders (customer_id);
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 12345 ORDER BY created_at DESC LIMIT 10\G  -- ref, filesort, 1.11ms
DROP INDEX idx_customer ON orders;
CREATE INDEX idx_customer_created ON orders (customer_id, created_at DESC);
EXPLAIN ANALYZE SELECT * FROM orders WHERE customer_id = 12345 ORDER BY created_at DESC LIMIT 10\G  -- ref, 정렬 없음, 1.08ms
SQL

# 12-5. mysqldump 백업·복구 (셸)
time docker exec -e MYSQL_PWD="$MYSQL_PW" mysql8 mysqldump -uroot --single-transaction practice > ~/mysql_practice.sql   # 2.3초, 54MB
grep -c "INSERT INTO" ~/mysql_practice.sql   # 56
docker exec -e MYSQL_PWD="$MYSQL_PW" mysql8 mysql -uroot -e "CREATE DATABASE practice_restore CHARACTER SET utf8mb4;"
time docker exec -i -e MYSQL_PWD="$MYSQL_PW" mysql8 mysql -uroot practice_restore < ~/mysql_practice.sql   # 20.6초
docker exec -e MYSQL_PWD="$MYSQL_PW" mysql8 mysql -uroot -e "SELECT count(*) FROM practice_restore.orders; SHOW INDEX FROM practice_restore.orders;"

# 정리
docker exec -e MYSQL_PWD="$MYSQL_PW" mysql8 mysql -uroot -e "DROP DATABASE practice_restore;"
rm ~/mysql_practice.sql
