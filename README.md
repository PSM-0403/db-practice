# DB 운영 실습 (PostgreSQL 16 / Docker / Ubuntu 24.04 WSL2)

DBA 업무(구축, 권한, 백업·복구, 실행계획·인덱스)를 직접 해 보고 결과를 기록한 저장소입니다.

## 결과 요약

| 실습 | 내용 | 결과 |
|---|---|---|
| 1. 구축 | 볼륨을 붙인 PostgreSQL 컨테이너, orders 100만 건 | 컨테이너 재생성 후에도 데이터 유지 |
| 2. 계정·권한 | 조회 전용 계정, REVOKE/GRANT | SELECT 허용, DELETE 차단 확인 |
| 3. 백업·복구 | pg_dump -Fc, DROP TABLE 사고 재현 | 21MB 백업 3.5초, 복구 3.6초, PK·권한 복구 |
| 4. 실행계획·인덱스 | EXPLAIN ANALYZE, 복합 인덱스, 인덱스 정리 | 37~51ms → 0.048ms, 인덱스 67MB → 51MB |

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
- 배운 점: 백업은 복구 테스트까지 해야 쓸 수 있는 백업이다. 백업 파일을 DB와 같은 곳에 두면 함께 사라질 수 있다.

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
- 배운 점: 인덱스 효과는 골라내는 비율에 달려 있다(7건 → 1,000배, 33만 건 → 4배). 복합 인덱스는 열 순서가 중요하다. 인덱스는 공간과 쓰기 비용이 들어서, 실행계획으로 실제 사용 여부를 확인하고 중복은 정리해야 한다.
- 예상과 달랐던 점: status 인덱스는 안 쓰일 거라 예상했지만 count(*)에서는 Index Only Scan(Heap Fetches 0)이 선택됨
