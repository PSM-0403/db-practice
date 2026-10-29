#!/usr/bin/env bash
# PostgreSQL 16 컨테이너 실행 (데이터는 pgdata 볼륨에 보관)
# 비밀번호는 저장소에 남기지 않도록 환경 변수로 받는다: PG_PASSWORD=... ./00_run_container.sh
set -euo pipefail

: "${PG_PASSWORD:?PG_PASSWORD 환경 변수를 지정하세요}"

docker volume create pgdata
docker run -d --name pg16 \
  -e POSTGRES_PASSWORD="$PG_PASSWORD" \
  -p 5432:5432 \
  -v pgdata:/var/lib/postgresql/data \
  postgres:16

# 실습용 DB 생성
sleep 5
docker exec pg16 psql -U postgres -c "CREATE DATABASE practice;"
