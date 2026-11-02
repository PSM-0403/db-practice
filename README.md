# DB 운영 실습 (PostgreSQL 16 / Docker / Ubuntu 24.04 WSL2)

DBA 업무(구축, 권한, 백업·복구, 실행계획·인덱스, 트랜잭션·락, 모니터링, 복제, 백업 자동화, PITR)를 직접 해 보고 결과를 기록한 저장소입니다.

DB 운영에 필요한 Linux 기본기는 [linux/](linux/README.md)에 따로 기록하고 있습니다.

## 결과 요약

| 실습 | 내용 | 결과 |
|---|---|---|
| 1. 구축 | 볼륨을 붙인 PostgreSQL 컨테이너, orders 100만 건 | 컨테이너 재생성 후에도 데이터 유지 |
| 2. 계정·권한 | 조회 전용 계정, REVOKE/GRANT | SELECT 허용, DELETE 차단 확인 |
| 3. 백업·복구 | pg_dump -Fc, DROP TABLE 사고 재현 | 21MB 백업 3.5초, 복구 3.6초, PK·권한 복구 |
| 4. 실행계획·인덱스 | EXPLAIN ANALYZE, 복합 인덱스, 인덱스 정리 | 37~51ms → 0.048ms, 인덱스 67MB → 51MB |
| 5. 트랜잭션·락 | 터미널 두 개로 동시 수정 재현 | 락 대기, 격리 수준 차이, 데드락 로그 확인 |
| 6. 모니터링 | 자원·크기 확인, 막힌 세션 종료, VACUUM, pg_stat_statements | 막고 있던 세션 찾아 종료, 죽은 행 10만 → 0, 느린 쿼리 1위 확인 |
| 7. 복제 | 주 서버 + 복제 서버, 장애 조치 | pg_basebackup으로 복제 서버 구성, 승격 후 쓰기 성공, 남은 슬롯 정리 |
| 8. 백업 자동화 | 백업 스크립트 + cron, 실패·보관 기간·복구 테스트 | 매일 새벽 3시 자동 백업, 실패 시 FAIL 기록, 자동 백업으로 100만 건 복구 확인 |
| 9. PITR | 베이스 백업 + WAL 보관으로 특정 시각 복구 | DELETE 직전 시각으로 복구, 1001건 되살림, 타임라인 1 → 2 |

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
| 06_monitoring.sql | 크기 조회, 막힌 세션 확인·종료, VACUUM, pg_stat_statements |
| 07_replication.sh | 네트워크, 복제 계정, pg_basebackup, 복제 확인, 승격, 정리 (순서표) |
| 08_backup.sh | 자동 백업 스크립트 (로그 기록, 실패 처리, 7일 보관). cron: `0 3 * * * /home/sumin/db-practice/08_backup.sh` |
| 09_pitr.sh | WAL 보관 설정, 베이스 백업, 실수 재현, 특정 시각 복구, 정리 (순서표, 5433 서버) |

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

## 6. 모니터링
- 서버·컨테이너 자원
  - df -h /: 1007G 중 3.6G 사용. 그런데 WSL 디스크는 C 드라이브 안의 파일이라 실제로 쓸 수 있는 건 C: 남은 용량(58G)까지
  - df -h 전체에서 /dev/sdb가 100%로 보였는데, WSL이 붙인 읽기 전용 도구 이미지라 문제없음 → 어느 위치가 찼는지부터 봐야 함
  - free -h: 전체 3.8Gi(WSL 4GB 제한), available 3.4Gi
  - docker stats: 쿼리가 없을 때 CPU 0.02%, 메모리 31.5MiB
- 크기: DB 125MB, orders 테이블 66MB + 인덱스 52MB = 117MB
- 막힌 세션 찾아서 끊기 (터미널 3개)
  - A가 트랜잭션을 열어 두고 커밋 안 함, B가 같은 행을 수정하다 멈춤
  - pg_stat_activity + pg_blocking_pids로 확인: A(pid 132)는 idle in transaction 2분째, B(pid 139)는 blocked_by {132}로 1분 20초째 대기
  - pg_terminate_backend(132)로 A를 끊으니 B가 바로 UPDATE 1
  - A는 쿼리를 실행 중인 게 아니라 트랜잭션만 열어 둔 상태라 pg_cancel_backend(쿼리 취소)로는 안 풀리고 세션을 끊어야 했음
- 죽은 행과 VACUUM
  - 10만 건을 같은 값으로 UPDATE → n_dead_tup 100,009
  - VACUUM 후 n_dead_tup 0, 그런데 테이블 크기는 72MB 그대로 (6-2에서 66MB)
  - VACUUM은 죽은 행 자리를 다시 쓸 수 있게 표시만 하고 파일 크기는 안 줄임. 줄이려면 VACUUM FULL인데 그동안 테이블 전체가 잠김
  - 10만 건은 전체의 10%라 autovacuum 기본 기준(약 20%)에 못 미쳐서 직접 실행함
- 느린 쿼리 찾기
  - ALTER SYSTEM으로 shared_preload_libraries에 pg_stat_statements 추가 → 시작할 때만 읽는 설정이라 docker restart 후 CREATE EXTENSION
  - 쿼리 몇 개 실행 후 누적 시간 순으로 조회

| 쿼리 | 호출 | 1회 평균 |
|---|---|---|
| count(*) WHERE amount > $1 | 3 | 96.35ms |
| WHERE id = $1 | 2 | 0.57ms |
| WHERE customer_id = $1 ORDER BY created_at DESC | 1 | 0.87ms |

  - amount에는 인덱스가 없어서 매번 100만 건을 읽음. id = 1과 id = 2는 $1로 묶여 한 줄로 집계됨
  - customer_id 쿼리가 실습 4(0.048ms)보다 느린 건 재시작 직후라 데이터가 아직 메모리에 없었기 때문으로 보임
- 배운 점: 멈춘 쿼리는 막힌 쪽이 아니라 막고 있는 세션을 찾아야 풀린다. 끊으면 그 세션 작업은 취소되니까 실제로는 확인하고 끊어야 한다. 느린 쿼리는 pg_stat_statements로 찾고, 실습 4처럼 실행계획을 보고 인덱스를 정하면 된다.

## 7. 복제
- 구성: 주 서버 pg16 + 복제 서버 pg16-replica, Docker 네트워크 pgnet으로 연결
- 준비
  - wal_level = replica, max_wal_senders = 10은 기본값으로 이미 켜져 있었음
  - REPLICATION 권한만 있는 replicator 계정 생성
  - pg_hba.conf에 다른 컨테이너의 복제 접속이 허용돼 있지 않아서 `host replication replicator all scram-sha-256` 추가, pg_reload_conf()로 재시작 없이 적용
- 복제 서버 만들기
  - pg_basebackup으로 주 서버를 통째로 복사 (약 156MB). 실습 3의 pg_dump는 SQL 단위 논리 백업, 이건 파일 그대로 복사하는 물리 백업
  - -R 옵션으로 복제 서버 설정이 자동으로 들어가서, 켜자마자 로그에 entering standby mode, started streaming WAL from primary
- 복제 확인
  - 복제 서버에서 pg_is_in_recovery() = t
  - 주 서버 pg_stat_replication: state = streaming, sync_state = async
  - 주 서버에서 INSERT 한 행이 복제 서버에서 바로 조회됨
  - 복제 서버에서 INSERT → ERROR: cannot execute INSERT in a read-only transaction
- 장애 조치
  - 주 서버를 docker stop으로 끄니 복제 서버 로그에 주 서버 연결 실패가 반복됨
  - 복제 서버에서 pg_promote() → pg_is_in_recovery() = f, INSERT 성공. 이 서버가 새 주 서버가 됨
- 정리
  - 복제 서버를 지우고 원래 주 서버를 다시 켜니 슬롯 replica1이 active = f로 남아 있었음 (쌓인 WAL 176 bytes)
  - 받아 갈 서버가 없어도 슬롯이 있으면 주 서버는 WAL을 지우지 않음 → pg_drop_replication_slot('replica1')로 삭제
  - 주 서버의 repl_test에는 1, 2번 행만 있음. 승격된 복제 서버에서 넣은 3번은 그 서버와 같이 사라짐
  - replicator 계정, pg_hba.conf 복제 허용 줄, pgnet 네트워크는 다음 실습을 위해 남겨 둠
- 배운 점: 복제 서버는 주 서버의 WAL을 받아서 똑같이 다시 실행하는 방식이다. async라 주 서버가 갑자기 죽으면 마지막 변경이 복제 서버에 안 갔을 수 있다. 승격한 뒤 옛 주 서버를 그대로 켜면 주 서버가 두 대가 되니까, 옛 주 서버는 복제 서버로 다시 만들어야 한다. 복제 서버를 없앨 때는 슬롯도 같이 지워야 디스크가 안 찬다.
- 겪은 오류
  - docker exec pg16 뒤에 psql을 또 빠뜨림 (실습 2와 같은 실수)
  - 슬롯 삭제 때 replica1(숫자 1)을 replical(소문자 l)로 쳐서 does not exist → 이름은 조회 결과에서 보고 입력하기

## 8. 백업 자동화
- 08_backup.sh: pg_dump로 백업 → backup/auto/practice_날짜_시간.dump, 성공·실패를 backup.log에 한 줄씩 기록, 7일 지난 백업 삭제
- 직접 실행: 종료 코드 0, 21MB, 약 4초, 로그에 OK
- 실패 테스트: 컨테이너를 끄고 실행
  - 종료 코드 1, 로그에 Docker 에러 메시지(container is not running)와 FAIL
  - 실패한 백업 파일은 지워져서 빈 파일이 안 남음
- 보관 기간 테스트: touch -d '8 days ago'로 날짜를 바꾼 파일을 넣고 실행 → 그 파일만 지워지고 새 백업이 추가됨
- cron 등록
  - 먼저 `* * * * *`(1분마다)로 등록해서 1분 간격으로 OK가 쌓이는지 확인
  - 확인 중에 21MB가 아니라 6.6MB짜리 파일이 보였는데, 백업이 아직 쓰이는 중이었음. 몇 초 뒤 21MB로 끝나고 OK가 찍힘 → 백업이 끝났는지는 파일이 아니라 로그로 확인
  - cron이 만든 파일은 권한이 -rw-rw-r--로 직접 실행한 파일(-rw-r--r--)과 달랐음 (cron의 umask가 셸과 다름)
  - 확인 후 `0 3 * * *`(매일 새벽 3시)로 변경
  - WSL은 Ubuntu가 켜져 있을 때만 cron이 돌아서, 새벽에 노트북이 꺼져 있으면 백업이 안 됨. 실제 서버는 항상 켜져 있음
- 복구 테스트: 가장 최근 자동 백업을 새 DB practice_restore에 복구 → count = 1000000 확인 후 practice_restore 삭제. 운영 DB는 건드리지 않고 별도 DB에서 확인
- 배운 점: 자동 백업에서 제일 위험한 건 실패했는데 모르는 경우라, 실패도 꼭 기록하고 빈 파일은 지워야 한다. 오래된 백업을 안 지우면 디스크가 계속 찬다. 자동으로 만든 백업도 실제로 복구해 봐야 믿을 수 있다.
- 헷갈린 것: `ls -l`(소문자 L)과 `ls -1`(숫자 1), `tail -1`과 `tail -l`을 섞어 침. 실습 7의 슬롯 이름 replica1/replical도 같은 이유

## 9. PITR (특정 시각으로 복구)
- 대상: apt로 직접 설치한 PostgreSQL 16 (5433, [linux/L1](linux/README.md))
- 상황: 누가 DELETE FROM accounts를 실행함. 백업 시점이 아니라 지우기 직전 시각으로 되돌리고 싶음
- 원리: 베이스 백업(물리 백업)을 깔고, 그 뒤에 보관해 둔 WAL을 목표 시각까지만 다시 실행
- WAL 보관 켜기
  - conf.d/pitr.conf 파일을 새로 만들어 archive_mode = on, archive_command 설정 (원래 postgresql.conf는 안 건드림)
  - archive_mode는 재시작해야 적용됨
- 데이터와 백업: accounts 1000건 → pg_basebackup으로 베이스 백업 (약 30MB). 보관 폴더에 WAL 01, 02와 백업 위치 기록 파일(.backup)이 생김
- 실수 재현
  - 1001번 행 INSERT (13:09:46 커밋) → now()로 시각 기록 13:10:00.353171+09 → DELETE (13:10:43 커밋) → 0건
  - pg_switch_wal()로 쓰던 WAL을 마감하니 WAL 03이 보관됨. pg_stat_archiver의 failed_count = 0 확인 (실패가 있으면 WAL이 빠져서 복구 불가)
- 복구
  - 서버 정지 → 데이터 폴더 main을 main_broken으로 이름만 바꿔 보존 → 베이스 백업을 cp -a로 복사 (그냥 cp면 소유자가 root가 돼서 안 켜짐)
  - pitr.conf에 restore_command, recovery_target_time, recovery_target_action = 'promote' 추가 + recovery.signal 파일 생성
  - 시작하니 로그에 `recovery stopping before commit of transaction 746, time 13:10:43` → DELETE 커밋 직전에서 멈춤
  - count = 1001, 1001번 행도 살아남. 베이스 백업에는 1000건뿐이었으니 1001번은 WAL을 다시 실행해서 되살아난 것
- 타임라인
  - 복구 후 timeline_id가 1 → 2로 바뀌고 보관 폴더에 00000002.history가 생김
  - 복구한 뒤부터는 원래 WAL(DELETE가 들어 있음)과 다른 갈래라서 번호로 구분함
  - 로그의 `cp: cannot stat ... .history`는 이전 갈래 기록을 찾다가 없어서 나온 것으로, 처음 복구할 때는 정상
- 정리: pitr.conf 삭제 후 재시작 (archive_mode = off), main_broken 63MB·base_backup 46MB·wal_archive 81MB 삭제
- 배운 점: pg_dump(논리 백업)는 백업한 순간으로만 돌아갈 수 있고, 특정 시각으로 돌리려면 물리 백업과 WAL 보관이 같이 있어야 한다. WAL이 하나라도 빠지면 그 뒤로는 복구가 안 되니까 보관 실패를 꼭 확인해야 한다. 복구할 때는 망가진 데이터도 바로 지우지 않고 남겨 둔다.
- 겪은 오류: 보관 폴더 경로를 /var가 아니라 /val로 쳐서 No such file or directory → 경로는 Tab 자동 완성으로 입력

## 정리: 자주 쓴 명령어

| 하는 일 | 명령 | 실습 |
|---|---|---|
| DB 접속 | `docker exec -it pg16 psql -U postgres -d practice` | 전체 |
| 백업 | `pg_dump -U postgres -d practice -Fc -f /tmp/practice.dump` | 3 |
| 백업 파일 꺼내기 | `docker cp pg16:/tmp/practice.dump ~/db-practice/backup/` | 3 |
| 복구 | `pg_restore -U postgres -d practice --clean --if-exists /tmp/practice.dump` | 3 |
| 실행계획 | `EXPLAIN ANALYZE 쿼리` | 4 |
| 접속·대기 확인 | `pg_stat_activity`, `pg_blocking_pids(pid)` | 5, 6 |
| 쿼리만 취소 / 세션 종료 | `pg_cancel_backend(pid)` / `pg_terminate_backend(pid)` | 6 |
| 죽은 행 확인 | `pg_stat_user_tables`의 `n_dead_tup` | 6 |
| 죽은 행 정리 | `VACUUM (VERBOSE) orders` | 6 |
| 느린 쿼리 순위 | `pg_stat_statements` (total_exec_time 순) | 6 |
| 서버 로그 | `docker logs pg16 2>&1 \| grep -A 5 deadlock` | 5 |
| 서버 자원 | `df -h /`, `free -h`, `docker stats --no-stream pg16` | 6 |
| 복제 서버 만들기 | `pg_basebackup -h pg16 -U replicator -D 경로 -Xs -P -R -C -S replica1` | 7 |
| 복제 상태 | `pg_stat_replication`, `pg_replication_slots`, `pg_is_in_recovery()` | 7 |
| 복제 서버 승격 | `pg_promote()` | 7 |
| 슬롯 삭제 | `pg_drop_replication_slot('replica1')` | 7 |
| 접속 규칙 다시 읽기 | `pg_reload_conf()` / 확인은 `pg_hba_file_rules` | 7 |
| 예약 실행 등록·확인 | `crontab -e` / `crontab -l` | 8 |
| 직전 명령 성공 여부 | `echo $?` (0 성공, 1 이상 실패) | 8 |
| 오래된 파일 삭제 | `find 경로 -name '*.dump' -mtime +7 -delete` | 8 |
| 최신 파일 고르기 | `ls -t 경로/*.dump \| head -1` | 8 |
| 별도 DB에 복구 확인 | `createdb` → `pg_restore -d 새DB < 파일` → `count(*)` → `dropdb` | 8 |
| WAL 강제 마감 | `SELECT pg_switch_wal();` | 9 |
| WAL 보관 상태 | `pg_stat_archiver` (failed_count) | 9 |
| 타임라인 확인 | `SELECT timeline_id FROM pg_control_checkpoint();` | 9 |

psql 프롬프트로 지금 상태를 알 수 있다.

| 프롬프트 | 뜻 |
|---|---|
| `practice=#` | 명령 기다리는 중 |
| `practice-#` | SQL이 안 끝남 (`;` 빠짐). Ctrl + C로 취소 |
| `practice=*#` | 트랜잭션 진행 중 (COMMIT이나 ROLLBACK 전) |
| `practice=!#` | 트랜잭션 안에서 에러 남. ROLLBACK 해야 다음 명령 가능 |

## 정리: 개념과 실습에서 본 것

| 개념 | 실습에서 본 것 | 실습 |
|---|---|---|
| 최소 권한 | 조회 전용 계정은 SELECT만 되고 DELETE는 permission denied | 2 |
| 백업과 복구 테스트 | pg_dump로 받은 백업으로 실제 복구해서 건수·PK·권한까지 확인 | 3 |
| 인덱스 효과 | 7건 골라낼 때 약 1,000배, 33만 건 골라낼 때 약 4배 | 4 |
| 트랜잭션 | BEGIN 후 ROLLBACK 하면 바꾼 값이 원래대로 돌아옴 | 5 |
| 행 단위 락 | 같은 행은 기다리고, 다른 행은 안 기다림 | 5 |
| 격리 수준 | READ COMMITTED는 남이 커밋한 값이 바로 보이고, REPEATABLE READ는 내 트랜잭션이 끝날 때까지 안 보임 | 5 |
| 데드락 | 두 창이 수정 순서를 반대로 하면 1초쯤 뒤 한쪽이 취소됨 | 5 |
| 막힌 세션 | idle in transaction 세션이 락을 잡고 있어서, 그 세션을 끊으니 대기가 풀림 | 6 |
| 죽은 행 | UPDATE 하면 옛 행이 남고, VACUUM이 치워도 파일 크기는 안 줄어듦 | 6 |
| 느린 쿼리 찾기 | pg_stat_statements에서 인덱스 없는 쿼리가 1회 평균 96ms로 1위 | 6 |
| WAL과 복제 | 복제 서버는 주 서버의 WAL을 받아서 다시 실행함. 로그에 started streaming WAL from primary | 7 |
| async 복제 | 주 서버는 복제 서버가 받았는지 안 기다림. 빠르지만 갑자기 죽으면 마지막 변경을 잃을 수 있음 | 7 |
| 장애 조치 | 주 서버를 끄고 pg_promote()로 복제 서버를 새 주 서버로 올림 | 7 |
| 복제 슬롯 | 받는 서버가 없어도 WAL을 계속 남겨서, 안 쓰는 슬롯은 지워야 함 | 7 |
| 백업 자동화 | 실패도 로그에 남기고 빈 파일은 지움. 오래된 백업은 지움. 자동 백업도 별도 DB에 복구해서 확인 | 8 |
| PITR | 베이스 백업 + WAL을 목표 시각까지만 다시 실행. DELETE 직전에서 멈추고 1001건 복구 | 9 |
| 타임라인 | 복구 후 다른 갈래가 되어 번호가 2로 바뀌고 .history 파일이 생김 | 9 |
