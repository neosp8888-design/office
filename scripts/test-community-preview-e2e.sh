#!/bin/bash
# 새 사용자의 DB 준비부터 백엔드 health와 첫 직원 업무 완료까지 실제로 잇는다.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
COMPOSE_PROJECT="officestra-community-preview-e2e"
BACKEND_PORT="4318"
POSTGRES_PORT="${OFFICESTRA_E2E_POSTGRES_PORT:-55429}"
DATABASE_URL="postgres://office:office-local@127.0.0.1:$POSTGRES_PORT/office"
TEMP_ROOT="$(mktemp -d)"
WORKSPACE="$TEMP_ROOT/user-project"
RUNTIME_CONFIG="$TEMP_ROOT/characters.json"
BACKEND_LOG="$TEMP_ROOT/backend.log"
FAKE_CLI="$TEMP_ROOT/bin/codex"
SYNCED_CLI="$TEMP_ROOT/synchronized-bin/codex"
STALE_CLI_MARKER="$TEMP_ROOT/stale-cli-used"
BACKEND_PID=""

cleanup() {
    if [[ -n "$BACKEND_PID" ]] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        kill "$BACKEND_PID" 2>/dev/null || true
        wait "$BACKEND_PID" 2>/dev/null || true
    fi
    docker compose \
        --project-name "$COMPOSE_PROJECT" \
        -f "$PROJECT_DIR/infra/compose.yaml" \
        down -v --remove-orphans >/dev/null 2>&1 || true
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

docker info >/dev/null
mkdir -p "$WORKSPACE" "$(dirname "$FAKE_CLI")"
cp "$PROJECT_DIR/scripts/fixtures/fake-codex-stale.sh" "$FAKE_CLI"
chmod 700 "$FAKE_CLI"
mkdir -p "$(dirname "$SYNCED_CLI")"
cp "$PROJECT_DIR/scripts/fixtures/fake-codex.sh" "$SYNCED_CLI"
chmod 700 "$SYNCED_CLI"
export OFFICESTRA_POSTGRES_PORT="$POSTGRES_PORT"

node --input-type=module \
    - "$PROJECT_DIR/Sources/OfficeCore/Resources/characters.json" \
    "$RUNTIME_CONFIG" "$WORKSPACE" \
    "$FAKE_CLI" \
    "$BACKEND_PORT" <<'NODE'
import { readFile, writeFile } from "node:fs/promises";

const [, , source, destination, workdir, executablePath, port] = process.argv;
const configuration = JSON.parse(await readFile(source, "utf8"));
configuration.workdir = workdir;
configuration.databaseBaseURL = `http://127.0.0.1:${port}`;
configuration.characters = configuration.characters.map((character) => ({
  ...character,
  backend: "codex",
  model: "gpt-5.6-terra",
  effort: "high",
  fastMode: false,
  permission: "workspace-write",
  executablePath,
}));
await writeFile(destination, `${JSON.stringify(configuration, null, 2)}\n`, {
  mode: 0o600,
});
NODE

docker compose \
    --project-name "$COMPOSE_PROJECT" \
    -f "$PROJECT_DIR/infra/compose.yaml" \
    up -d --wait --wait-timeout 120

(
    cd "$PROJECT_DIR/backend"
    DATABASE_URL="$DATABASE_URL" \
    OFFICE_BACKEND_PORT="$BACKEND_PORT" \
    OFFICE_WORKDIR="$WORKSPACE" \
    CHARACTER_CONFIG_PATH="$RUNTIME_CONFIG" \
    OFFICESTRA_RELEASE_ID="community-preview-e2e" \
    OFFICESTRA_STALE_CLI_MARKER="$STALE_CLI_MARKER" \
    OFFICE_SLACK_ENV_FILE="$TEMP_ROOT/no-slack.env" \
    SLACK_BOT_TOKEN="" \
    SLACK_APP_TOKEN="" \
    OFFICE_SLACK_ALLOWED_USER_IDS="" \
        node src/server.mjs >"$BACKEND_LOG" 2>&1
) &
BACKEND_PID="$!"

HEALTH_READY=""
for _ in $(seq 1 60); do
    if curl --fail --silent \
        "http://127.0.0.1:$BACKEND_PORT/health" \
        | node --input-type=module -e '
          let data = "";
          for await (const chunk of process.stdin) data += chunk;
          const health = JSON.parse(data);
          if (
            health.ok !== true ||
            health.database?.ok !== true ||
            health.releaseID !== "community-preview-e2e" ||
            health.activeTurnCount !== 0
          ) process.exit(1);
        ' 2>/dev/null; then
        HEALTH_READY="yes"
        break
    fi
    sleep 0.5
done

if [[ "$HEALTH_READY" != "yes" ]]; then
    cat "$BACKEND_LOG" >&2
    echo "Backend health did not reach the expected release, DB, and idle state." >&2
    exit 1
fi

curl --fail --silent "http://127.0.0.1:$BACKEND_PORT/health" \
    | node --input-type=module -e '
      let data = "";
      for await (const chunk of process.stdin) data += chunk;
      const health = JSON.parse(data);
      if (
        health.service !== "officestra-backend" ||
        health.ok !== true ||
        health.database?.ok !== true ||
        health.releaseID !== "community-preview-e2e" ||
        health.activeTurnCount !== 0
      ) process.exit(1);
    '

CLI_SYNC_PAYLOAD="$(SYNCED_CLI="$SYNCED_CLI" node -e '
  process.stdout.write(JSON.stringify({
    executables: { codex: process.env.SYNCED_CLI },
  }));
')"
CLI_SYNC_RESPONSE="$(curl --fail --silent \
    -X PUT "http://127.0.0.1:$BACKEND_PORT/api/runtime/cli-paths" \
    -H 'content-type: application/json' \
    --data "$CLI_SYNC_PAYLOAD")"
CLI_SYNC_RESPONSE="$CLI_SYNC_RESPONSE" node -e '
  const payload = JSON.parse(process.env.CLI_SYNC_RESPONSE);
  if (
    payload.ok !== true ||
    !Array.isArray(payload.updatedCharacterIds) ||
    !payload.updatedCharacterIds.includes("boss")
  ) process.exit(1);
'

JOB_RESPONSE="$(curl --fail --silent \
    -X POST "http://127.0.0.1:$BACKEND_PORT/api/agent-jobs" \
    -H 'content-type: application/json' \
    --data '{"characterId":"boss","prompt":"Complete the preview smoke test.","attachmentPaths":[]}')"
TURN_ID="$(JOB_RESPONSE="$JOB_RESPONSE" node -e '
  const payload = JSON.parse(process.env.JOB_RESPONSE);
  if (payload.status !== "running" || !payload.turnId) process.exit(1);
  process.stdout.write(payload.turnId);
')"

# macOS 기본 bash에서도 환경 크기와 quoting이 안정적이도록 별도 export한다.
export TURN_ID
COMPLETED=""
for _ in $(seq 1 60); do
    TURN_RESPONSE="$(curl --fail --silent \
        "http://127.0.0.1:$BACKEND_PORT/api/live-feed/$TURN_ID")"
    if TURN_RESPONSE="$TURN_RESPONSE" node -e '
      const turn = JSON.parse(process.env.TURN_RESPONSE).turn;
      if (turn.status !== "completed") process.exit(1);
      if (!turn.response.includes("Community preview first task completed.")) {
        process.exit(1);
      }
    ' 2>/dev/null; then
        COMPLETED="yes"
        break
    fi
    sleep 0.5
done

if [[ "$COMPLETED" != "yes" ]]; then
    cat "$BACKEND_LOG" >&2
    exit 1
fi

if [[ -e "$STALE_CLI_MARKER" ]]; then
    cat "$BACKEND_LOG" >&2
    echo "The first task used the stale CLI path after synchronization." >&2
    exit 1
fi

echo "Community Preview E2E passed: Docker DB, health, and first task."
