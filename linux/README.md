# Linux 실습 (Ubuntu 24.04 WSL2)

DB 운영에 필요한 Linux 기본기를 PostgreSQL을 직접 다루면서 익히는 기록입니다. DB 실습(1~8)은 [상위 README](../README.md)에 있습니다.

## 결과 요약

| 실습 | 내용 | 결과 |
|---|---|---|
| L1. 직접 설치 | apt로 PostgreSQL 16 설치, systemctl, 파일 위치, 접속 인증 | Docker(5432)와 따로 5433에 설치, peer와 비밀번호 인증 차이 확인 |

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
