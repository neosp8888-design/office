#!/bin/zsh
# 이 스크립트는 pgvector PostgreSQL을 시작하고 캐릭터 DB 백엔드를 실행한다.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cd "$PROJECT_DIR"
docker compose -f infra/compose.yaml up -d

if [[ ! -d "$PROJECT_DIR/backend/node_modules" ]]; then
    npm --prefix backend install
fi

exec npm --prefix backend start
