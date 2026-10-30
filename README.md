# DB 운영 실습 (PostgreSQL 16 / Docker / Ubuntu 24.04 WSL2)

DBA 업무(구축, 권한, 백업·복구, 실행계획·인덱스, 트랜잭션·락)를 직접 해 보고 결과를 기록한 저장소입니다.

## 결과 요약

| 실습 | 내용 | 결과 |
|---|---|---|
| 1. 구축 | 볼륨을 붙인 PostgreSQL 컨테이너, orders 100만 건 | 컨테이너 재생성 후에도 데이터 유지 |
| 2. 계정·권한 | 조회 전용 계정, REVOKE/GRANT | SELECT 허용, DELETE 차단 확인 |
| 3. 백업·복구 | pg_dump -Fc, DROP TABLE 사고 재현 | 21MB 백업 3.5초, 복구 3.6초, PK·권한 복구 |
| 4. 실행계획·인덱스 | EXPLAIN ANALYZE, 복합 인덱스, 인덱스 정리 | 37~51ms → 0.048ms, 인덱스 67MB → 51MB |
| 5. 트랜잭션·락 | 터미널 두 개로 동시 수정 재현 | 락 대기, 격리 수준 차이, 데드락 로그 확인 |

## 환경

- Windows 11 + WSL2 Ubuntu 24.04 (메모리 4GB 제한)
- Docker Engine, postgres:16 이미지
- 데이터: generate_series로 만든 주문 데이터 100만 건

## 파일

| 파일 | 내용 |
|---|---|
| 00_run_container.sh | 볼륨 생성, 컨테이너 실행, DB 생성 |
| 01_setup.sql | 테이블 생성, 100만 건 입력 |
| 02_roles.sql | 조회 전용 계정, 권한 회수·부여 |
| 03_backup_restore.sh | 백업, 사고 재현, 복구, 확인 |
| 04_index.sql | 실행계획 비교, 인덱스 생성·정리 |
| 05_transaction_lock.sql | 트랜잭션, 락 대기, 격리 수준, 데드락 (두 세션 순서표) |

## 1. 구축
- 볼륨(pgdata)을 붙여 PostgreSQL 16 컨테이너 실행
- 실습 테이블 orders 100만 건 생성 (generate_series)
- 컨테이너를 삭제하고 다시 만들어도 count = 1000000 유지 → 데이터는 볼륨에 남음
- 반면 컨테이너 안 /tmp에 둔 백업 파일은 컨테이너 삭제와 함께 사라짐 → 백업은 DB와 다른 곳에 보관해야 함


## 2. 계정·권한
- 조회 전용 계정 readonly_user 생성 (CONNECT, USAGE, SELECT만 부여)
- readonly_user로 SELECT count(*) → 1000000 조회 성공
- readonly_user로 DELETE → ERROR: permission denied for table orders (삭제 차단 확인)
- REVOKE SELECT 후 조회도 permission denied → GRANT로 다시 부여
- 배운 점: 필요한 권한만 주는 최소 권한 원칙. 컨테이너 내부 접속은 pg_hba.conf 기본 설정(trust) 때문에 비밀번호 없이 접속됨 → 실제 서버는 외부 접속에 비밀번호 인증 필요
- 겪은 오류: docker exec 뒤에 psql을 빠뜨려 "executable file not found" → exec 뒤에는 실행할 프로그램이 와야 함


## 3. 백업·복구
- 상황: orders 테이블을 실수로 삭제(DROP TABLE)한 사고를 재현
- 백업: pg_dump 커스텀 포맷(-Fc), 100만 건 → 21MB, 3.537초
- 백업 파일은 docker cp로 컨테이너 밖(~/db-practice/backup)에 보관
- 복구: pg_restore --clean --if-exists, 3.578초
- 확인: count = 1000000, 기본 키(orders_pkey) 복구, readonly_user 조회 권한까지 복구
- 배운 점: 백업만 받아 두는 게 아니라 실제로 복구해 봐야 쓸 수 있는 백업인지 알 수 있다. 백업 파일을 DB와 같은 곳에 두면 같이 사라질 수 있다.

## 4. 실행계획·인덱스
- 상황: "특정 고객의 최근 주문 10건" 조회가 느리다는 가정 (orders 100만 건)
- 측정: EXPLAIN ANALYZE, 2~3회 실행해 값 확인

| 단계 | 실행 방법 | Sort | Execution Time |
|---|---|---|---|
| 인덱스 없음 | Parallel Seq Scan (약 100만 건 읽고 7건 남김) | 있음 | 37~51ms |
| customer_id 인덱스 | Bitmap Index Scan | 있음 | 0.233ms |
| (customer_id, created_at DESC) 복합 인덱스 | Index Scan | 없음 | 0.048ms |

- 복합 인덱스로 약 800~1,000배 개선. 인덱스가 이미 고객별 최신순으로 정렬돼 있어 Sort 단계가 사라짐
- 값 종류가 적은 status 인덱스
  - count(*): Index Only Scan 20.3ms vs 인덱스 끈 Seq Scan 81.0ms (약 4배)
  - sum(amount): 인덱스가 있어도 Parallel Seq Scan 선택 (101ms). 33만 건을 읽어야 해서 테이블 전체 읽기가 더 빠르다고 판단
- 인덱스 비용: 테이블 66MB인데 인덱스 4개 합계 약 67MB
- 정리: 복합 인덱스와 중복인 customer_id 단일 인덱스, 효과가 적은 status 인덱스 삭제 → 인덱스 51MB
  - 삭제 후 customer_id 조회는 복합 인덱스로 처리 (0.119ms)
- 배운 점: 같은 인덱스라도 몇 건을 골라내느냐에 따라 효과가 크게 달랐다(7건은 약 1,000배, 33만 건은 약 4배). 인덱스도 공간을 차지하고 쓰기를 느리게 해서, 실행계획으로 실제로 쓰이는지 보고 겹치는 건 지웠다.
- 예상과 달랐던 점: status 인덱스는 안 쓰일 거라 예상했지만 count(*)에서는 Index Only Scan(Heap Fetches 0)이 선택됨

## 5. 트랜잭션·락
- 방법: 터미널 두 개(A창, B창)로 각각 psql에 접속해서 번갈아 실행
- 트랜잭션 기본: BEGIN 후 amount를 0으로 바꿨다가 ROLLBACK → 원래 값으로 돌아옴
- 락 대기
  - A가 id = 1을 수정하고 커밋하지 않은 상태에서 B가 같은 행을 수정하면 B가 멈춤
  - pg_stat_activity에서 B의 wait_event_type = Lock 확인
  - A가 COMMIT하니 B가 진행됨. 최종 값은 처음보다 +11 → A의 +1과 B의 +10이 둘 다 반영됨
  - B가 다른 행(id = 2)을 수정할 때는 기다리지 않음 → 락이 행 단위로 걸림
- 격리 수준

| 격리 수준 | A가 조회하는 중에 B가 id = 3을 +100 하고 커밋 |
|---|---|
| READ COMMITTED (기본값) | A가 다시 조회하면 바로 +100 된 값이 보임 |
| REPEATABLE READ | A가 커밋하기 전까지는 처음 값 그대로, 커밋 후 조회해야 +100 된 값이 보임 |
| REPEATABLE READ에서 A도 같은 행 수정 | ERROR: could not serialize access due to concurrent update → ROLLBACK 하고 다시 해야 함 |

- 데드락
  - A는 10번 → 20번, B는 20번 → 10번 순서로 수정해서 서로 상대가 잡은 행을 기다리게 함
  - 1초쯤 뒤 B에 ERROR: deadlock detected가 나고 A는 진행됨 (deadlock_timeout 기본값 1초)
  - docker logs로 서버 로그를 보니 서로 기다린 프로세스 번호와 각자 실행하던 쿼리(id = 10, id = 20)가 남아 있음
- 배운 점: 트랜잭션을 커밋하지 않고 두면 그동안 다른 창은 계속 기다려야 했다. 데드락은 두 창이 수정 순서를 반대로 해서 생긴 거라, 같은 순서로 수정하면 생기지 않는다.
- 겪은 오류: 데드락 재현 중 A창에서 + 대신 _를 쳐서 syntax error가 남 → 트랜잭션이 통째로 실패(practice=!#)하면서 잡고 있던 락도 풀려 데드락이 안 생김. 서버 로그를 보고 원인을 알았고, ROLLBACK 후 다시 실행
