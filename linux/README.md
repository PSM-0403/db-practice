# Linux 실습 (Ubuntu 24.04 WSL2)

DB 운영에 필요한 Linux 기본기를 PostgreSQL을 직접 다루면서 익히는 기록입니다. DB 실습(1~8)은 [상위 README](../README.md)에 있습니다.

## 결과 요약

| 실습 | 내용 | 결과 |
|---|---|---|
| L1. 직접 설치 | apt로 PostgreSQL 16 설치, systemctl, 파일 위치, 접속 인증 | Docker(5432)와 따로 5433에 설치, peer와 비밀번호 인증 차이 확인 |
| L2. 사용자·권한 | 사용자·그룹, rwx와 숫자 권한, 새 사용자로 막히는 곳 확인, 권한 장애 재현 | Linux 권한과 DB 권한 두 겹 확인, 데이터 폴더 777로 시작 거부 → 700으로 복구 |
| L3. 프로세스·자원 | ps, top, vmstat, CPU 부하, kill 신호 비교, kill -9 장애 재현 | 접속 하나 = 프로세스 하나 확인, kill -9 한 번에 전체 접속 끊김 → WAL 복구 약 0.3초, 커밋한 행만 남음 |

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
