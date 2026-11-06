# Linux 실습 (Ubuntu 24.04 WSL2)

DB 운영에 필요한 Linux 기본기를 PostgreSQL을 직접 다루면서 익히는 기록입니다. DB 실습(1~8)은 [상위 README](../README.md)에 있습니다.

## 결과 요약

| 실습 | 내용 | 결과 |
|---|---|---|
| L1. 직접 설치 | apt로 PostgreSQL 16 설치, systemctl, 파일 위치, 접속 인증 | Docker(5432)와 따로 5433에 설치, peer와 비밀번호 인증 차이 확인 |
| L2. 사용자·권한 | 사용자·그룹, rwx와 숫자 권한, 새 사용자로 막히는 곳 확인, 권한 장애 재현 | Linux 권한과 DB 권한 두 겹 확인, 데이터 폴더 777로 시작 거부 → 700으로 복구 |
| L3. 프로세스·자원 | ps, top, vmstat, CPU 부하, kill 신호 비교, kill -9 장애 재현 | 접속 하나 = 프로세스 하나 확인, kill -9 한 번에 전체 접속 끊김 → WAL 복구 약 0.3초, 커밋한 행만 남음 |
| L4. 디스크 | df, du, 큰 파일 찾기, 300MB 가상 디스크로 꽉 찬 상황 재현 | WAL을 못 써서 PANIC, 재시작도 실패 → 예비 파일 20MB 지워서 복구 |
| L5. 로그·텍스트 | grep, awk, sed, tail -f로 PostgreSQL 로그 분석 | ERROR 2건·FATAL 4건을 실습과 연결, kill -9 복구 시간 0.28초 계산, 세션 로그에서 칸이 밀리는 것 확인 |
| L6. 네트워크 | IP·포트 확인, nc 연결 테스트, 접속 실패 단계별 재현, 방화벽 차단 | refused, no pg_hba.conf entry, password failed, timed out을 직접 만들어서 구분 |

## L1. PostgreSQL 직접 설치
- Docker의 pg16이 5432를 쓰고 있는 상태(`ss -ltn`)에서 `sudo apt install -y postgresql` → 빈 포트를 골라 5433으로 설치됨
- `pg_lsclusters`: 버전 16, 클러스터 main, 포트 5433, 상태, 데이터·로그 위치가 한 줄에 나옴
- 서비스 관리
  - Docker 대신 systemd가 켜고 끔: `sudo systemctl stop/start postgresql@16-main`
  - stop 하니 상태 down, 5433 포트가 사라짐. start 하니 다시 online
  - `systemctl is-enabled`는 enabled-runtime → 상위 서비스 postgresql이 켜질 때 같이 켜짐. WSL을 켜면 자동으로 시작됨 (Docker pg16은 docker start를 해야 켜짐)
  - status 화면에 checkpointer, walwriter, autovacuum launcher 같은 프로세스가 보임. DB 실습 6, 7에서 로그로만 보던 것들
- 파일 위치: Docker에서는 설정 파일이 데이터 폴더 안에 있었는데, Ubuntu 설치판은 나눠져 있음

| 종류 | 위치 |
|---|---|
| 설정 | /etc/postgresql/16/main (postgresql.conf, pg_hba.conf) |
| 데이터 | /var/lib/postgresql/16/main (base, pg_wal, pg_replslot 등) |
| 로그 | /var/log/postgresql/postgresql-16-main.log |

- 권한
  - 데이터 폴더는 drwx------라 sudo 없이는 Permission denied
  - pg_hba.conf는 -rw-r-----로 다른 사용자가 못 읽음. postgresql.conf는 누구나 읽을 수 있음
- 로그와 설정에서 본 기본값
  - listen_addresses = localhost → 이 컴퓨터 안에서 오는 접속만 받음 (Docker pg16은 *)
  - 로그 시간이 KST. Docker pg16 로그는 UTC
- 접속 인증 (pg_hba.conf는 위에서부터 처음 맞는 줄을 적용)
  - `sudo -u postgres psql -p 5433`: 소켓 접속 → `local all postgres peer` → Linux 사용자 이름이 같아서 비밀번호 없이 접속
  - `psql -h 127.0.0.1 -p 5433 -U postgres`: 네트워크 접속 → `host all all 127.0.0.1/32 scram-sha-256` → 비밀번호를 물어봄
  - Docker pg16은 컨테이너 안 접속이 trust(무조건 허용)였는데, Ubuntu 설치판은 처음부터 더 엄격함
- 배운 점: 같은 DB라도 어떤 길(소켓, 네트워크)로 들어오느냐에 따라 인증이 다르다. 비밀번호가 맞는데 접속이 안 되면 pg_hba.conf의 어느 줄에 걸리는지부터 봐야 한다.

## L2. 사용자·권한
- 나와 postgres

| | sumin | postgres |
|---|---|---|
| uid | 1000 (사람 계정은 1000부터) | 105 (설치할 때 생긴 시스템 계정) |
| 그룹 | sudo, docker 등 | postgres, ssl-cert |
| 홈 폴더 | /home/sumin | /var/lib/postgresql |

  - sudo 그룹이라 sudo를 쓸 수 있고, docker 그룹이라 sudo 없이 docker를 씀 (DB 실습 8에서 cron이 docker를 실행할 수 있던 이유)
- 권한 읽기: `rw-r-----`는 소유자 / 그룹 / 그 외 순서. r=4, w=2, x=1을 더해서 숫자로

| 대상 | 권한 | 숫자 |
|---|---|---|
| 데이터 폴더 | rwx------ | 700 (postgres만) |
| pg_hba.conf | rw-r----- | 640 (postgres 그룹은 읽기만) |
| postgresql.conf | rw-r--r-- | 644 (누구나 읽기) |

- cp와 cp -a
  - postgres 파일을 sudo cp로 복사하니 소유자가 root, 권한도 664 → 644로 바뀜. cp -a는 소유자·권한·시각이 원본 그대로
  - 새 파일은 만든 사용자가 주인이 되고, 권한은 그 사용자의 기본값(umask)을 따르기 때문. DB 실습 9에서 베이스 백업을 cp -a로 복사한 이유
- 새 사용자 dbuser로 확인 (useradd, 비밀번호 없이 sudo -u로만 사용)
  - postgresql.conf 읽기 됨 / pg_hba.conf, 데이터 폴더는 Permission denied
  - psql 접속은 role "dbuser" does not exist → Linux 사용자는 있어도 DB 계정이 없음
- 권한은 두 겹
  - createuser로 DB 계정을 만드니 접속은 되지만 permission denied for table accounts
  - GRANT SELECT 후에야 count = 1001 (DB 실습 9에서 복구한 데이터)
  - Linux 파일 권한과 DB 권한(접속, 테이블)은 따로 관리됨
- 그룹: dbuser를 postgres 그룹에 넣으니(usermod -aG) pg_hba.conf는 읽히고 데이터 폴더는 여전히 막힘 → 같은 그룹이라도 파일마다 다르게 열 수 있음. 확인 후 gpasswd -d로 다시 뺌
- 장애 재현
  - 데이터 폴더를 chmod 777로 바꾸고 재시작 → systemctl 실패, pg_lsclusters는 down
  - 로그: `FATAL: data directory ... has invalid permissions`, `DETAIL: Permissions should be u=rwx (0700) or u=rwx,g=rx (0750)`
  - chmod 700으로 되돌리고 start → online
  - systemctl은 실패했다는 것만 알려 주고, 원인은 DB 로그에 있었음
- 정리: REVOKE → dropuser → userdel -r 순서 (권한이 남아 있으면 DB 계정이 안 지워짐). userdel의 mail spool not found 메시지는 메일함이 원래 없어서 나온 것
- 배운 점: 권한을 열어 주는 게 해결책이 아닐 때가 있다. PostgreSQL은 데이터 폴더를 아무나 볼 수 있으면 아예 안 켜진다. usermod는 -a를 빼면 기존 그룹이 다 빠지니까 조심해야 한다.

## L3. 프로세스·자원
- 프로세스 구조
  - 대표 프로세스(postmaster) 283의 부모는 1(systemd), checkpointer·walwriter 등의 부모는 전부 283
  - psql로 접속하니 프로세스가 하나 늘어남. `pg_backend_pid()` 값(912)과 OS의 PID가 같음 → 접속 하나 = 프로세스 하나
- 쉴 때와 CPU 부하 때 비교 (PL/pgSQL 반복문으로 CPU만 쓰는 쿼리)

| 항목 | 쉴 때 | 부하 중 |
|---|---|---|
| top %Cpu us | 2.2 | 26.9 (코어 4개 중 1개) |
| top wa | 0.0 | 0.0 (디스크를 안 쓰는 쿼리) |
| 프로세스 912 %CPU | - | 83.3 |
| vmstat r | 0 | 1~3 |

  - us가 높으면 CPU를 쓰는 중, wa가 높으면 디스크를 기다리는 중
  - top에서 찾은 PID로 pg_stat_activity를 보면 어떤 쿼리인지 알 수 있음
  - pg_stat_activity의 query는 state가 active면 실행 중인 쿼리, idle이면 마지막에 실행했던 쿼리. 처음에 쿼리가 끝난 뒤 조회해서 idle로 나옴
- kill 신호 비교

| SQL | Linux | 결과 |
|---|---|---|
| pg_cancel_backend(pid) | kill -INT pid | ERROR, 쿼리만 취소되고 접속 유지 (번호 그대로 912) |
| pg_terminate_backend(pid) | kill -TERM pid | FATAL, 세션 종료. psql이 다시 접속하니 번호가 1026으로 바뀜 |

- kill -9 장애 재현
  - C창에서 2000번 행은 커밋, 2001번 행은 커밋 안 한 상태로 두고, 상관없는 접속 1026에 `sudo kill -9`
  - 로그: `server process (PID 1026) was terminated by signal 9` → `terminating any other active server processes` → `automatic recovery in progress` → `redo starts` → `redo done` → `ready to accept connections`
  - C창도 끊김: `terminating connection because of crash of another server process`. 프로세스들이 공유 메모리를 같이 쓰는데 하나가 정리 없이 죽으면 메모리가 망가졌을 수 있어서 전부 끊음
  - 복구는 약 0.3초 (WAL 8kB). 로그의 `invalid record length ... got 0`은 에러가 아니라 WAL 끝에 도착했다는 뜻
  - 복구 후 2000번은 있고 2001번은 없음 → 커밋된 건 WAL로 살아나고, 커밋 안 한 건 사라짐
- 배운 점: 쿼리가 안 끝나면 pg_cancel_backend, 그다음 pg_terminate_backend 순서로 쓴다. kill -9는 그 접속 하나가 아니라 DB 전체 접속을 끊는다. 복구가 금방 끝난 건 변경이 적어서고, 변경이 많은 서버면 그동안 서비스가 멈춘다.
- 헷갈린 것: `ps aux --sort=%mem`은 작은 순서라 `-%mem`으로 써야 큰 순서. 20억 번 반복문이 예상보다 빨리 끝나서 처음엔 무한 반복으로 바꿔서 다시 함

## L4. 디스크
- 현황 보기
  - `df`는 디스크 전체, `du`는 폴더별 용량. df로 찼는지 보고 du로 범인을 찾음
  - main 클러스터: pg_wal 49M, base 30M → 변경이 많으면 WAL이 데이터보다 커질 수 있음
  - `find`로 20MB 넘는 파일을 찾으니 DB 실습 3에서 컨테이너 안 /tmp에 받은 practice.dump가 아직 남아 있었음 (Docker 이미지·컨테이너도 /var/lib/containerd에서 공간을 차지)
- 작은 디스크 만들기: 진짜 디스크를 채우면 다른 실습까지 망가져서 300MB 파일을 디스크로 사용
  - fallocate → mkfs.ext4 → mount -o loop 순서. 쓸 수 있는 공간은 244MB (파일 시스템 정보와 root 예약 공간 때문에 300MB보다 작음)
  - pg_createcluster로 클러스터 small(5434)을 만듦. 빈 DB인데도 약 39MB 사용
  - 예비 파일 ballast 20MB를 미리 만들어 둠
- 꽉 채우기: 1KB 행 5만 건 INSERT (테이블 약 50MB + WAL)
  - 첫 번째 INSERT는 성공, 두 번째에서 `PANIC: could not write to file "pg_wal/xlogtemp.1777": No space left on device`
  - 전체 접속이 끊기고 복구를 시도했지만 복구도 WAL을 써야 해서 `FATAL: could not write to file ...`, `shutting down due to startup process failure` → 상태 down
- 복구
  - pg_wal을 지우면 안 됨. 커밋됐지만 테이블 파일에 아직 반영 안 된 변경이 들어 있어서 데이터가 깨지거나 안 켜질 수 있음
  - 예비 파일을 지우니 남은 공간 3.3M → 24M, start 하니 redo로 약 90MB를 0.7초에 재실행하고 online
  - 로그의 `HINT: ... some data is corrupted`는 복구가 중간에 끊긴 적이 있으면 나오는 안내. 그래도 데이터를 확인함 → count = 50000 (첫 번째 INSERT만 남고, 커밋 전에 실패한 두 번째는 사라짐)
  - TRUNCATE와 CHECKPOINT 후 base 22M, 사용량 56%. pg_wal은 113M로 남음 (재사용하려고 남겨 둔 파일로 보임. 직접 지우지 않음)
- 정리: pg_dropcluster → umount → rmdir → 이미지 파일 삭제
- 배운 점: 테이블보다 WAL이 먼저 막히면 명령 하나가 아니라 서버 전체가 멈추고, 공간이 없으면 재시작도 안 된다. 그래서 디스크 사용량은 차기 전에 봐야 한다. 공간이 부족해도 pg_wal은 직접 지우지 않고, 다른 공간을 비운 뒤 PostgreSQL이 정리하게 한다.
- 겪은 오류
  - `sudo du -sh 폴더/*`가 No such file or directory → `*`은 sudo가 아니라 지금 셸(sumin)이 먼저 푸는데 700 폴더라 못 풀어서 글자 그대로 넘어감. `sudo bash -c '...'`로 해결
  - `find /var/lib/home`으로 붙여 쳐서 결과가 비어 있었는데 `2>/dev/null` 때문에 에러도 안 보임

## L5. 로그·텍스트
- 대상: main 클러스터 로그 183줄, 22KB. 권한이 640(postgres:adm)이라 sudo가 필요해서 홈 폴더에 복사본을 만들어 연습
- 로그 형식: `날짜 시각 KST [PID] 수준: 내용`. 접속 세션의 로그는 PID 뒤에 `사용자@DB`가 들어감
- grep으로 찾기
  - ERROR 2, FATAL 4, PANIC 0. L4의 PANIC은 small 클러스터 로그에 있었음
  - 나온 내용이 실습과 맞음: L2의 role 없음·permission denied·invalid permissions, L3의 cancel·terminate
  - `grep -n "signal 9"`로 146번째 줄을 찾고, `grep -A 6`으로 뒤에 이어지는 복구 과정을 봄
  - checkpoint 포함 49줄 + 제외 134줄 = 183줄. 나눠서 세고 전체와 맞춰 보면 필터를 검증할 수 있음
- awk로 집계
  - 날짜별: 11-01 26줄, 11-02 101줄, 11-04 44줄, 11-05 7줄. 합계 178줄, 나머지 5줄은 2026으로 시작하지 않는 cp, pg_ctl 메시지
  - `$5`로 수준을 세니 FATAL이 1개만 나옴. 접속 세션 로그는 `dbuser@pitr`가 `$5`에 들어가서 수준이 `$6`으로 밀림
  - 수준은 `grep -oE`로 다시 셈: LOG 165, FATAL 4, STATEMENT 3, ERROR 2, DETAIL 2. 패턴에 안 넣은 CONTEXT 2줄을 더하면 178줄
  - 체크포인트 24번, 쓴 버퍼 합계 1,106, 최대 930(11-02 12:35). 930 버퍼는 쓰기에 93.56초 걸림 (체크포인트는 쓰기를 시간에 나눠서 함)
- sed로 자르고 바꾸기
  - `/signal 9/,/ready to accept/` 구간을 뽑으니 13:43:39.391 → 13:43:39.672, 복구까지 약 0.28초
  - `s/[a-z]+@[a-z0-9]+/USER@DB/`로 사용자 정보를 화면에서만 가림. -i가 없으면 파일은 안 바뀜
- tail -f: 다른 창에서 없는 테이블을 조회하니 ERROR와 STATEMENT가 바로 나타남 (14:31:03, relation "no_such_table" does not exist)
- 배운 점: 장애가 나면 FATAL, PANIC부터 찾고 앞뒤 줄을 시각순으로 본다. 칸 번호로 집계하기 전에 형식이 일정한지 확인한다. 한 번 나눠서 세면 합계가 맞는지 검산한다.
- 겪은 오류: `wc -1`로 쳐서 invalid option (소문자 L이 맞음)

## L6. 네트워크
- 장치와 포트
  - lo 127.0.0.1, eth0 172.26.98.10, docker0 172.17.0.1, br-f7fe... 172.18.0.1(pgnet으로 보임), veth는 컨테이너와 연결
  - 5433은 127.0.0.1(apt 설치판, 이 안에서만), 5432·3306은 0.0.0.0(docker-proxy, 모든 장치에서)
  - docker ps의 33060/tcp는 `->`가 없어서 컨테이너 안에만 열려 있음
  - `-p 3306:3306`은 0.0.0.0으로 열림. 운영 서버면 외부 노출 위험
- nc 연결 테스트
  - 127.0.0.1:5433 성공, 172.26.98.10:5433 거부, 172.26.98.10:5432 성공, 127.0.0.1:5999 거부
- 접속 실패 단계별 재현 (5433)

| 단계 | 한 일 | 에러 | 볼 곳 |
|---|---|---|---|
| 포트 | listen_addresses = localhost 상태 | `Connection refused` | 서버 기동, listen_addresses, 포트 |
| 접속 규칙 | listen_addresses = '*' + 재시작 | `no pg_hba.conf entry` | pg_hba.conf |
| 인증 | 172.26.98.10/32 scram 줄 추가 + reload | `password authentication failed` | 계정, 비밀번호 |
| 방화벽 | iptables INPUT DROP | `timed out` (3초 대기) | 방화벽, 경로 |

  - listen_addresses는 재시작 필요, pg_hba.conf는 reload로 적용. 수정 후 pg_hba_file_rules의 error 칸으로 문법 확인 (133번째 줄)
  - FATAL이 두 줄인 건 psql이 SSL로 먼저 시도하고 암호화 없이 다시 시도해서. 로그 PID도 2677, 2678로 다름
  - refused는 바로 나오고, DROP은 응답이 없어서 끝까지 기다림
- 실제 연결: nettest로 접속해 두고 비교. `ss -tn`의 포트와 pg_stat_activity의 client_port가 46592로 같음
  - 서버 쪽은 5433, 접속한 쪽은 임시 포트. 같은 서버 안에서 접속해서 ESTAB 줄이 두 줄 보임
- 정리: nettest 삭제, pg_hba.conf 복원, listen_addresses RESET 후 재시작, iptables 규칙 삭제. 172.26.98.10:5433 다시 거부되는 것까지 확인
- 배운 점: 접속이 안 되면 에러 메시지로 어느 단계에서 막혔는지부터 구분한다. refused는 포트와 listen_addresses, no pg_hba.conf entry는 접속 규칙, password failed는 계정, timeout은 방화벽이나 경로를 먼저 본다. 방화벽 규칙과 접속 설정은 범위를 좁게 열고 끝나면 되돌린다.
- 헷갈린 것: `sudo -u`만 치고 Tab을 누르면 사용자 목록이 나옴. 큰따옴표를 닫기 전에 Enter를 치면 `>`가 나오고 입력을 계속 기다림

## 명령어 노트

| 명령 | 하는 일 | 실습 |
|---|---|---|
| `mkdir -p 경로` | 폴더 만들기. 중간 폴더까지 한 번에, 이미 있어도 에러 없음 | L1 |
| `ss -ltn` | 접속을 기다리는 포트 목록 (l: listen, t: tcp, n: 숫자로) | L1 |
| `sudo 명령` | 관리자 권한으로 실행 | L1 |
| `sudo -u 사용자 명령` | 다른 사용자로 실행 | L1 |
| `apt update` / `apt install -y 패키지` | 패키지 목록 새로 고침 / 설치 | L1 |
| `systemctl status / start / stop 서비스` | 서비스 상태 확인, 시작, 중지 | L1 |
| `systemctl is-enabled 서비스` | 부팅할 때 자동 시작하는지 | L1 |
| `ps -ef` | 실행 중인 모든 프로세스 | L1 |
| `ls -l` | 파일 목록을 권한, 소유자, 크기와 함께 (소문자 L) | L1 |
| `tail -5 파일` | 파일 마지막 5줄 | L1 |
| `grep -v '^#' 파일 \| grep -v '^$'` | 주석 줄과 빈 줄 빼고 보기 | L1 |
| `pg_lsclusters` | PostgreSQL 클러스터 목록 (Ubuntu 설치판) | L1 |
| `ls -ld 폴더` | 폴더 안 내용이 아니라 폴더 자체의 권한·소유자 | 9 |
| `chmod 700 경로` | 소유자만 읽기·쓰기·실행 | 9 |
| `sudo tee 파일 > /dev/null <<'EOF' ... EOF` | 여러 줄을 관리자 권한으로 파일에 쓰기 | 9 |
| `sudo tee -a 파일` | 덮어쓰지 않고 파일 뒤에 덧붙이기 | 9 |
| `systemctl restart 서비스` | 서비스 재시작 | 9 |
| `mv 원래이름 새이름` | 이름 바꾸기·옮기기 (지우지 않고 보존할 때) | 9 |
| `cp -a 원본 대상` | 소유자·권한·시각까지 그대로 복사 | 9 |
| `touch 파일` | 빈 파일 만들기 (있으면 시각만 갱신) | 9 |
| `du -sh 경로` | 폴더가 차지하는 용량 | 9 |
| `rm -rf 경로` | 폴더째 삭제. 되돌릴 수 없으니 경로 확인 후 실행 | 9 |
| Tab | 경로·파일 이름 자동 완성. 후보가 여러 개면 목록 표시 | 9 |
| `whoami` / `id` / `id 사용자` | 내 이름 / uid·gid·그룹 / 다른 사용자 정보 | L2 |
| `getent passwd 사용자` | 사용자 정보 한 줄 (홈 폴더, 셸) | L2 |
| `useradd -m -s /bin/bash 이름` | 사용자 만들기 (-m 홈 폴더, -s 셸) | L2 |
| `userdel -r 이름` | 사용자 삭제 (-r 홈 폴더까지) | L2 |
| `usermod -aG 그룹 사용자` | 그룹에 추가. -a를 빼면 기존 그룹이 다 빠짐 | L2 |
| `gpasswd -d 사용자 그룹` | 그룹에서 빼기 | L2 |
| `head -3 파일` | 파일 앞 3줄 | L2 |
| `chmod 숫자 경로` | 권한 바꾸기 (700, 640, 644, 755) | L2 |
| `createuser` / `dropuser` | PostgreSQL 계정 만들기 / 삭제 (셸 명령) | L2 |
| `ps -o pid,ppid,user,cmd -u 사용자` | 그 사용자의 프로세스를 원하는 칸만 | L3 |
| `ps aux --sort=-%mem \| head -5` | 메모리를 많이 쓰는 순서로 (`-`가 큰 순서) | L3 |
| `top` / `top -b -n 1 \| head -12` | 프로세스·CPU·메모리 실시간 (q로 종료) / 한 번만 찍기 | L3 |
| `vmstat 1 5` | 1초 간격 5번. r, free, si/so, us/sy/id/wa. 첫 줄은 부팅 후 평균 | L3 |
| `free -h` | 메모리. free보다 available을 봄 | L3 |
| `kill -INT pid` | 쿼리 취소 (pg_cancel_backend와 같음) | L3 |
| `kill -TERM pid` | 세션 종료 (pg_terminate_backend와 같음) | L3 |
| `kill -9 pid` | 정리 없이 강제 종료. PostgreSQL에는 쓰지 않기 | L3 |
| `lsblk` | 디스크 목록과 연결 위치 | L4 |
| `df -h 경로` / `df -i 경로` | 디스크 용량 / inode(파일 개수) 사용량 | L4 |
| `sudo bash -c 'du -sh 폴더/* \| sort -h'` | 권한 막힌 폴더의 하위 폴더별 용량 | L4 |
| `find 경로 -xdev -type f -size +20M` | 큰 파일 찾기 (-xdev: 다른 디스크로 안 넘어감) | L4 |
| `2>/dev/null` | 에러 메시지 버리기. 실패를 숨기니 주의 | L4 |
| `fallocate -l 300M 파일` | 그 크기의 파일 만들기 | L4 |
| `mkfs.ext4` / `mount -o loop 파일 폴더` / `umount 폴더` | 포맷 / 연결 / 연결 해제 | L4 |
| `rmdir 폴더` | 빈 폴더 삭제 | L4 |
| `pg_createcluster 16 이름 -d 경로 -p 포트 --start` | 클러스터 새로 만들기 (Ubuntu 설치판) | L4 |
| `pg_dropcluster 16 이름 --stop` | 클러스터 중지하고 삭제 | L4 |
| `wc -l 파일` | 줄 수 세기 | L5 |
| `grep -c 단어 파일` | 찾은 줄 수 | L5 |
| `grep -E "A\|B" 파일` | A 또는 B | L5 |
| `grep -n` / `-v` / `-o` | 줄 번호 표시 / 없는 줄 / 찾은 부분만 | L5 |
| `grep -A 6` / `-B 6` | 찾은 줄의 뒤 6줄 / 앞 6줄도 출력 | L5 |
| `cut -c 1-110` | 각 줄의 1~110번째 글자 | L5 |
| `awk '{print $1, $5}' 파일` | 공백으로 나눈 칸 출력 | L5 |
| `awk '/^2026/ {...}'` | 2026으로 시작하는 줄만 처리 | L5 |
| `awk '{sum += $9} END {print sum}'` | 칸의 합계 | L5 |
| `sort \| uniq -c \| sort -rn` | 값별 개수를 많은 순서로 | L5 |
| `sed -n '146,148p'` / `sed -n '/A/,/B/p'` | 줄 범위 / A부터 B까지 출력 | L5 |
| `sed -E 's/찾기/바꾸기/'` | 찾아 바꿔서 출력 (-i가 있으면 파일을 고침) | L5 |
| `tail -f 파일` | 추가되는 내용을 계속 출력. Ctrl + C로 종료 | L5 |
| `ip -br addr` | 네트워크 장치와 IP | L6 |
| `ip route` | 패킷을 보내는 경로. default는 모르는 주소가 가는 곳 | L6 |
| `getent hosts 이름` | DNS로 찾은 주소 | L6 |
| `sudo ss -ltnp` | 듣고 있는 TCP 포트와 프로세스 | L6 |
| `ss -tn` | 맺어진 TCP 연결 (ESTAB) | L6 |
| `nc -zv -w 2 주소 포트` | 포트까지 연결되는지 테스트 | L6 |
| `pg_isready -h 주소 -p 포트` | PostgreSQL이 접속을 받는지 확인 | L6 |
| `sudo iptables -I INPUT -p tcp --dport 포트 -j DROP` | 그 포트로 오는 패킷 버리기 | L6 |
| `sudo iptables -D INPUT -p tcp --dport 포트 -j DROP` | 위 규칙 삭제 | L6 |
| `sudo iptables -L INPUT -n --line-numbers` | 방화벽 규칙 보기 | L6 |
