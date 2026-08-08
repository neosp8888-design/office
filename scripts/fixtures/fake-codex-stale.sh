#!/bin/sh
# CLI 경로 동기화 E2E에서 이 이전 경로가 호출되면 흔적을 남긴다.
set -eu

if [ -n "${OFFICESTRA_STALE_CLI_MARKER:-}" ]; then
    printf '%s\n' "stale CLI path invoked" > "$OFFICESTRA_STALE_CLI_MARKER"
fi

printf '%s\n' '{"type":"thread.started","thread_id":"community-preview-e2e-stale-session"}'
printf '%s\n' '{"type":"item.completed","item":{"id":"message-stale","type":"agent_message","text":"Community preview first task completed."}}'
printf '%s\n' '{"type":"turn.completed","usage":{"input_tokens":10,"cached_input_tokens":0,"cache_write_input_tokens":0,"output_tokens":8,"reasoning_output_tokens":0}}'
