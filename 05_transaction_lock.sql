-- 5. 트랜잭션·락: 두 세션(A창, B창)을 번갈아 실행
-- 접속: 터미널 두 개에서 각각 docker exec -it pg16 psql -U postgres -d practice
-- 한 번에 실행하는 스크립트가 아니라, 번호 순서대로 해당 창에 붙여 넣는 순서표

-- 5-1. 트랜잭션 기본 (A창)
SELECT id, amount FROM orders WHERE id = 1;
BEGIN;
UPDATE orders SET amount = 0 WHERE id = 1;
SELECT id, amount FROM orders WHERE id = 1;   -- 0
ROLLBACK;
SELECT id, amount FROM orders WHERE id = 1;   -- 원래 값으로 돌아옴

-- 5-2. 락 대기
-- ① A창
BEGIN;
UPDATE orders SET amount = amount + 1 WHERE id = 1;
-- ② B창: 같은 행 수정 → A가 끝날 때까지 멈춤
-- UPDATE orders SET amount = amount + 10 WHERE id = 1;
-- ③ A창: 누가 무엇을 기다리는지 확인 → B의 wait_event_type = Lock
SELECT pid, state, wait_event_type, wait_event, left(query, 50) AS query
FROM pg_stat_activity
WHERE datname = 'practice';
-- ④ A창
COMMIT;   -- B가 풀리면서 UPDATE 1, 최종 값은 처음보다 +11
-- 다른 행(id = 2)을 수정하면 B는 기다리지 않음 → 행 단위 락

-- 5-3. 격리 수준
-- READ COMMITTED (기본값)
-- A창
BEGIN;
SELECT id, amount FROM orders WHERE id = 3;
-- B창: UPDATE orders SET amount = amount + 100 WHERE id = 3;
SELECT id, amount FROM orders WHERE id = 3;   -- 100 늘어난 값 (반복 불가능한 읽기)
COMMIT;

-- REPEATABLE READ
-- A창
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT id, amount FROM orders WHERE id = 3;
-- B창: UPDATE orders SET amount = amount + 100 WHERE id = 3;
SELECT id, amount FROM orders WHERE id = 3;   -- 처음 값 그대로
COMMIT;
SELECT id, amount FROM orders WHERE id = 3;   -- 커밋 후에야 100 늘어난 값

-- REPEATABLE READ에서 다른 세션이 바꾼 행을 수정
-- A창
BEGIN ISOLATION LEVEL REPEATABLE READ;
SELECT id, amount FROM orders WHERE id = 3;
-- B창: UPDATE orders SET amount = amount + 100 WHERE id = 3;
UPDATE orders SET amount = amount + 1 WHERE id = 3;
-- ERROR: could not serialize access due to concurrent update
ROLLBACK;

-- 5-4. 데드락
-- ① A창
BEGIN;
UPDATE orders SET amount = amount + 1 WHERE id = 10;
-- ② B창
-- BEGIN;
-- UPDATE orders SET amount = amount + 1 WHERE id = 20;
-- ③ A창: B가 잡은 20번 요청 → 멈춤
UPDATE orders SET amount = amount + 1 WHERE id = 20;
-- ④ B창: A가 잡은 10번 요청 → 약 1초 뒤 한쪽에 ERROR: deadlock detected
-- UPDATE orders SET amount = amount + 1 WHERE id = 10;
-- ⑤ 에러 난 창은 ROLLBACK, 다른 창은 COMMIT
COMMIT;

-- 로그 확인 (Ubuntu 셸)
-- docker logs pg16 2>&1 | grep -A 5 deadlock
