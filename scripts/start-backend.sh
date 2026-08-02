#!/bin/zsh
# 이 스크립트는 pgvector PostgreSQL을 시작하고 캐릭터 DB 백엔드를 실행한다.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$PROJECT_DIR"
docker compose -f infra/compose.yaml up -d

print "PostgreSQL 준비 상태를 확인합니다."
typeset -i postgres_wait_attempt=0
until docker compose -f infra/compose.yaml exec -T postgres \
    pg_isready -U office -d office >/dev/null 2>&1; do
    (( postgres_wait_attempt += 1 ))
    if (( postgres_wait_attempt >= 120 )); then
        print -u2 "PostgreSQL이 60초 안에 준비되지 않았습니다. 컨테이너 상태를 확인하세요."
        docker compose -f infra/compose.yaml ps >&2 || true
        exit 1
    fi
    sleep 0.5
done

npm --prefix backend install

exec npm --prefix backend start
