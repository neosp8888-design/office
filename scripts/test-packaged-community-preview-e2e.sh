#!/bin/bash
# 완성된 앱/ZIP 안의 Node, 백엔드, Compose, 마이그레이션으로 첫 업무까지 검증한다.

set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARTIFACT="${1:-}"
COMPOSE_PROJECT="officestra-packaged-preview-e2e-$$"
BACKEND_PORT="${OFFICESTRA_PACKAGED_E2E_BACKEND_PORT:-4319}"
POSTGRES_PORT="${OFFICESTRA_PACKAGED_E2E_POSTGRES_PORT:-55430}"
DATABASE_URL="postgres://office:office-local@127.0.0.1:$POSTGRES_PORT/office"
TEMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/officestra-packaged-e2e.XXXXXX")"
BACKEND_PID=""

cleanup() {
    if [[ -n "$BACKEND_PID" ]] && kill -0 "$BACKEND_PID" 2>/dev/null; then
        kill "$BACKEND_PID" 2>/dev/null || true
        wait "$BACKEND_PID" 2>/dev/null || true
    fi
    if [[ -n "${COMPOSE_FILE:-}" && -f "$COMPOSE_FILE" ]]; then
        OFFICESTRA_POSTGRES_PORT="$POSTGRES_PORT" \
            docker compose \
                --project-name "$COMPOSE_PROJECT" \
                -f "$COMPOSE_FILE" \
                down -v --remove-orphans >/dev/null 2>&1 || true
    fi
    rm -rf "$TEMP_ROOT"
}
trap cleanup EXIT

if [[ -z "$ARTIFACT" || ! -e "$ARTIFACT" ]]; then
    printf '%s\n' "검증할 OFFICESTRA.app 또는 ZIP이 없습니다. $ARTIFACT" >&2
    exit 1
fi

# 이후 백엔드 디렉터리로 이동해도 번들 경로가 바뀌지 않도록 입력을 즉시 절대화한다.
ARTIFACT="$(cd "$(dirname "$ARTIFACT")" && pwd -P)/$(basename "$ARTIFACT")"

case "$ARTIFACT" in
    *.app)
        APP_PATH="$ARTIFACT"
        ;;
    *.zip)
        EXTRACT_DIR="$TEMP_ROOT/extracted"
        mkdir -p "$EXTRACT_DIR"
        /usr/bin/ditto -x -k "$ARTIFACT" "$EXTRACT_DIR"
        APP_PATH="$EXTRACT_DIR/OFFICESTRA.app"
        ;;
    *)
        printf '%s\n' "검증 형식은 .app 또는 .zip이어야 합니다. $ARTIFACT" >&2
        exit 1
        ;;
esac

RESOURCES="$APP_PATH/Contents/Resources"
RUNTIME="$RESOURCES/OFFICESTRARuntime"
PACKAGED_NODE="$RUNTIME/node/bin/node"
NODE_EXECUTABLE="${OFFICESTRA_PACKAGED_E2E_NODE_EXECUTABLE:-$PACKAGED_NODE}"
BACKEND_DIR="$RUNTIME/backend"
COMPOSE_FILE="$RUNTIME/infra/compose.yaml"
SOURCE_CONFIG="$RESOURCES/OfficeLLM_OfficeCore.bundle/characters.json"
RELEASE_ID="$(
    /usr/bin/python3 - "$APP_PATH/Contents/Info.plist" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as handle:
    value = plistlib.load(handle).get("OFFICESTRABackendReleaseID")
if not isinstance(value, str) or not value.strip():
    raise SystemExit("OFFICESTRABackendReleaseID is missing")
print(value)
PY
)"

for required_path in \
    "$NODE_EXECUTABLE" \
    "$BACKEND_DIR/src/server.mjs" \
    "$BACKEND_DIR/node_modules/pg/package.json" \
    "$BACKEND_DIR/node_modules/@huggingface/tokenizers/package.json" \
    "$BACKEND_DIR/node_modules/onnxruntime-node/bin/napi-v6/darwin/arm64/onnxruntime_binding.node" \
    "$COMPOSE_FILE" \
    "$RUNTIME/database/migrations/001_initial.sql" \
    "$SOURCE_CONFIG"; do
    if [[ ! -e "$required_path" ]]; then
        printf '%s\n' "패키지의 필수 런타임이 없습니다. $required_path" >&2
        exit 1
    fi
done

if [[ "$(uname -s)" == "Darwin" \
    && "${OFFICESTRA_PACKAGED_E2E_CROSS_PLATFORM:-0}" != "1" ]]; then
    /usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_PATH"
    /usr/bin/python3 \
        "$PROJECT_DIR/scripts/backend-release-id.py" \
        --verify \
        --verify-node-signature \
        "$APP_PATH" >/dev/null
elif [[ -z "${OFFICESTRA_PACKAGED_E2E_NODE_EXECUTABLE:-}" ]]; then
    printf '%s\n' \
        "macOS 밖에서는 OFFICESTRA_PACKAGED_E2E_NODE_EXECUTABLE이 필요합니다." >&2
    exit 1
fi
docker info >/dev/null

WORKSPACE="$TEMP_ROOT/chosen-user-project"
RUNTIME_CONFIG="$TEMP_ROOT/characters.json"
BACKEND_LOG="$TEMP_ROOT/backend.log"
FAKE_CLI="$TEMP_ROOT/bin/codex"
SYNCED_CLI="$TEMP_ROOT/synchronized-bin/codex"
STALE_CLI_MARKER="$TEMP_ROOT/stale-cli-used"
mkdir -p "$WORKSPACE" "$(dirname "$FAKE_CLI")"
cp "$PROJECT_DIR/scripts/fixtures/fake-codex-stale.sh" "$FAKE_CLI"
chmod 700 "$FAKE_CLI"
mkdir -p "$(dirname "$SYNCED_CLI")"
cp "$PROJECT_DIR/scripts/fixtures/fake-codex.sh" "$SYNCED_CLI"
chmod 700 "$SYNCED_CLI"

# 설치 마법사가 선택한 폴더와 탐지한 CLI를 기록하는 것과 같은 설정을 만든다.
"$NODE_EXECUTABLE" --input-type=module \
    - "$SOURCE_CONFIG" "$RUNTIME_CONFIG" "$WORKSPACE" \
    "$FAKE_CLI" "$BACKEND_PORT" <<'NODE'
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

OFFICESTRA_POSTGRES_PORT="$POSTGRES_PORT" \
    docker compose \
        --project-name "$COMPOSE_PROJECT" \
        -f "$COMPOSE_FILE" \
        up -d --wait --wait-timeout 120

(
    cd "$BACKEND_DIR"
    DATABASE_URL="$DATABASE_URL" \
    OFFICE_BACKEND_PORT="$BACKEND_PORT" \
    OFFICE_WORKDIR="$WORKSPACE" \
    CHARACTER_CONFIG_PATH="$RUNTIME_CONFIG" \
    OFFICESTRA_RELEASE_ID="$RELEASE_ID" \
    OFFICESTRA_STALE_CLI_MARKER="$STALE_CLI_MARKER" \
    OFFICE_SLACK_ENV_FILE="$TEMP_ROOT/no-slack.env" \
    SLACK_BOT_TOKEN="" \
    SLACK_APP_TOKEN="" \
    OFFICE_SLACK_ALLOWED_USER_IDS="" \
        "$NODE_EXECUTABLE" src/server.mjs >"$BACKEND_LOG" 2>&1
) &
BACKEND_PID="$!"

HEALTH_READY=""
for _ in $(seq 1 60); do
    if curl --fail --silent \
        "http://127.0.0.1:$BACKEND_PORT/health" \
        | EXPECTED_RELEASE_ID="$RELEASE_ID" \
            "$NODE_EXECUTABLE" --input-type=module -e '
              let data = "";
              for await (const chunk of process.stdin) data += chunk;
              const health = JSON.parse(data);
              if (
                health.service !== "officestra-backend" ||
                health.ok !== true ||
                health.database?.ok !== true ||
                health.releaseID !== process.env.EXPECTED_RELEASE_ID ||
                health.acceptingJobs !== true ||
                health.activeTurnCount !== 0 ||
                health.idle !== true
              ) process.exit(1);
            ' 2>/dev/null; then
        HEALTH_READY="yes"
        break
    fi
    sleep 0.5
done

if [[ "$HEALTH_READY" != "yes" ]]; then
    cat "$BACKEND_LOG" >&2
    printf '%s\n' \
        "패키지 백엔드가 예상 릴리스·DB·유휴 상태에 도달하지 못했습니다." >&2
    exit 1
fi

# 동일 릴리스 백엔드가 이미 떠 있는 경우에도 설치 도우미가 새로 찾은
# CLI 경로가 다음 업무 전에 실제 DB 설정으로 반영되는지 검증한다.
CLI_SYNC_PAYLOAD="$(SYNCED_CLI="$SYNCED_CLI" "$NODE_EXECUTABLE" -e '
  process.stdout.write(JSON.stringify({
    executables: { codex: process.env.SYNCED_CLI },
  }));
')"
CLI_SYNC_RESPONSE="$(curl --fail --silent \
    -X PUT "http://127.0.0.1:$BACKEND_PORT/api/runtime/cli-paths" \
    -H 'content-type: application/json' \
    --data "$CLI_SYNC_PAYLOAD")"
CLI_SYNC_RESPONSE="$CLI_SYNC_RESPONSE" "$NODE_EXECUTABLE" -e '
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
    --data '{"characterId":"boss","prompt":"Complete the packaged preview smoke test.","attachmentPaths":[]}')"
TURN_ID="$(JOB_RESPONSE="$JOB_RESPONSE" "$NODE_EXECUTABLE" -e '
  const payload = JSON.parse(process.env.JOB_RESPONSE);
  if (payload.status !== "running" || !payload.turnId) process.exit(1);
  process.stdout.write(payload.turnId);
')"

COMPLETED=""
for _ in $(seq 1 60); do
    TURN_RESPONSE="$(curl --fail --silent \
        "http://127.0.0.1:$BACKEND_PORT/api/live-feed/$TURN_ID")"
    if TURN_RESPONSE="$TURN_RESPONSE" "$NODE_EXECUTABLE" -e '
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
    printf '%s\n' "패키지 런타임의 첫 업무가 완료되지 않았습니다." >&2
    exit 1
fi

if [[ -e "$STALE_CLI_MARKER" ]]; then
    cat "$BACKEND_LOG" >&2
    printf '%s\n' \
        "CLI 경로 동기화 뒤에도 이전 실행 파일이 사용됐습니다." >&2
    exit 1
fi

if [[ -z "${OFFICESTRA_PACKAGED_E2E_NODE_EXECUTABLE:-}" ]]; then
    NODE_DESCRIPTION="bundled Node"
else
    NODE_DESCRIPTION="host Node with packaged backend"
fi
printf '%s\n' \
    "Packaged Community Preview E2E passed: app layout, $NODE_DESCRIPTION, Docker DB, migrations, and first task."
