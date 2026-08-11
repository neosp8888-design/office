#!/bin/zsh

set -euo pipefail

deploy_label="com.neo.officestra-deploy-5e2cc1e"
deploy_target="gui/501/$deploy_label"
deploy_script="/Users/neo/.officestra/worktrees/03ffd78858a8/right-woman-3a7e5a25-b4a6-4c9f-ae3f-431f3ff931f3/.officestra-deploy-5e2cc1e.sh"
deploy_plist="/Users/neo/.officestra/worktrees/03ffd78858a8/right-woman-3a7e5a25-b4a6-4c9f-ae3f-431f3ff931f3/.officestra-deploy-5e2cc1e.plist"
health_url="http://127.0.0.1:4317/health"
drain_url="http://127.0.0.1:4317/api/maintenance/drain"
backend_label="com.neo.office-backend-4317"
backend_target="gui/501/$backend_label"
old_backend_pid="4216"
expected_release="84892a3a46f79cefc92cec1b06e813384e36d6effd7e3592b5afeb149bda06c0"
app_pid="70666"
deploy_succeeded=0

cancel_drain_on_failure() {
    local exit_status=$?
    if (( deploy_succeeded == 0 )); then
        /usr/bin/curl -fsS -X DELETE \
            -H "Content-Type: application/json" \
            -d "{}" \
            "$drain_url" >/dev/null 2>&1 || true
        echo "failed_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ) status=$exit_status"
    fi
}
trap cancel_drain_on_failure EXIT

echo "started_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ)"
drain_json="$(/usr/bin/curl -fsS -X POST \
    -H "Content-Type: application/json" \
    -d "{}" \
    "$drain_url")"
drain_ok="$(printf "%s" "$drain_json" \
    | /usr/bin/plutil -extract ok raw -o - -)"
draining="$(printf "%s" "$drain_json" \
    | /usr/bin/plutil -extract draining raw -o - -)"
accepting_jobs="$(printf "%s" "$drain_json" \
    | /usr/bin/plutil -extract acceptingJobs raw -o - -)"
if [[ "$drain_ok" != "true" || "$draining" != "true" \
      || "$accepting_jobs" != "false" ]]; then
    echo "drain_rejected=$drain_json"
    exit 1
fi

drained=0
for attempt in {1..2400}; do
    health_json="$(/usr/bin/curl -fsS --max-time 2 \
        "$health_url" 2>/dev/null || true)"
    if [[ -n "$health_json" ]]; then
        health_pid="$(printf "%s" "$health_json" \
            | /usr/bin/plutil -extract pid raw -o - - 2>/dev/null || true)"
        active_count="$(printf "%s" "$health_json" \
            | /usr/bin/plutil -extract activeTurnCount raw -o - - \
                2>/dev/null || true)"
        drain_state="$(printf "%s" "$health_json" \
            | /usr/bin/plutil -extract draining raw -o - - \
                2>/dev/null || true)"
        if [[ "$health_pid" == "$old_backend_pid" \
              && "$active_count" == "0" \
              && "$drain_state" == "true" ]]; then
            drained=1
            break
        fi
    fi
    /bin/sleep 0.25
done
if [[ "$drained" != "1" ]]; then
    echo "drain_timeout"
    exit 1
fi

job_output="$(/bin/launchctl print "$backend_target")"
job_pid="$(printf "%s\n" "$job_output" \
    | /usr/bin/sed -n \
        "s/^[[:space:]]*pid = \\([0-9][0-9]*\\)[[:space:]]*$/\\1/p" \
    | /usr/bin/head -n 1)"
listener_pids="$(/usr/sbin/lsof -nP -t -iTCP:4317 -sTCP:LISTEN \
    2>/dev/null | /usr/bin/sort -u | /usr/bin/paste -sd, -)"
if [[ "$job_pid" != "$old_backend_pid" \
      || "$listener_pids" != "$old_backend_pid" ]]; then
    echo "ownership_mismatch job_pid=$job_pid listeners=$listener_pids"
    exit 1
fi

/bin/launchctl bootout "$backend_target"
absent_samples=0
for attempt in {1..100}; do
    if ! /bin/launchctl print "$backend_target" >/dev/null 2>&1 \
       && ! /usr/sbin/lsof -nP -t -iTCP:4317 -sTCP:LISTEN \
            >/dev/null 2>&1; then
        absent_samples=$((absent_samples + 1))
    else
        absent_samples=0
    fi
    if (( absent_samples >= 3 )); then
        break
    fi
    /bin/sleep 0.1
done
if (( absent_samples < 3 )); then
    echo "backend_stop_not_confirmed"
    exit 1
fi

backend_command="umask 077; mkdir -p '/Users/neo/Library/Application Support/OFFICESTRA/logs'; export PATH='/Users/neo/office/dist/OFFICESTRA.app/Contents/Resources/OFFICESTRARuntime/node/bin:/Users/neo/.nvm/versions/node/v24.14.0/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin'; export OFFICE_WORKDIR='/Users/neo/office'; export OFFICESTRA_RELEASE_ID='$expected_release'; export CHARACTER_CONFIG_PATH='/Users/neo/Library/Application Support/OFFICESTRA/runtime/characters.json'; cd '/Users/neo/office/dist/OFFICESTRA.app/Contents/Resources/OFFICESTRARuntime/backend'; exec '/Users/neo/office/dist/OFFICESTRA.app/Contents/Resources/OFFICESTRARuntime/node/bin/node' src/server.mjs >> '/Users/neo/Library/Application Support/OFFICESTRA/logs/backend.out.log' 2>> '/Users/neo/Library/Application Support/OFFICESTRA/logs/backend.err.log'"
/bin/launchctl submit -l "$backend_label" -- \
    /bin/zsh -lc "$backend_command"

ready=0
new_backend_pid=""
for attempt in {1..160}; do
    health_json="$(/usr/bin/curl -fsS --max-time 2 \
        "$health_url" 2>/dev/null || true)"
    if [[ -n "$health_json" ]]; then
        release_id="$(printf "%s" "$health_json" \
            | /usr/bin/plutil -extract releaseID raw -o - - \
                2>/dev/null || true)"
        new_backend_pid="$(printf "%s" "$health_json" \
            | /usr/bin/plutil -extract pid raw -o - - \
                2>/dev/null || true)"
        service="$(printf "%s" "$health_json" \
            | /usr/bin/plutil -extract service raw -o - - \
                2>/dev/null || true)"
        if [[ "$release_id" == "$expected_release" \
              && "$service" == "officestra-backend" \
              && "$new_backend_pid" != "$old_backend_pid" ]]; then
            ready=1
            break
        fi
    fi
    /bin/sleep 0.25
done
if [[ "$ready" != "1" ]]; then
    echo "new_backend_not_ready"
    exit 1
fi

listener_pid="$(/usr/sbin/lsof -nP -t -iTCP:4317 -sTCP:LISTEN \
    2>/dev/null | /usr/bin/sort -u | /usr/bin/paste -sd, -)"
if [[ "$listener_pid" != "$new_backend_pid" ]]; then
    echo "new_listener_mismatch new_pid=$new_backend_pid listener=$listener_pid"
    exit 1
fi
/usr/bin/curl -fsS --max-time 45 \
    "http://127.0.0.1:4317/api/usage-summary" >/dev/null

app_connections=0
for attempt in {1..80}; do
    app_connections="$(/usr/sbin/lsof -nP -a -p "$app_pid" \
        -iTCP:4317 -sTCP:ESTABLISHED 2>/dev/null \
        | /usr/bin/tail -n +2 | /usr/bin/wc -l | /usr/bin/tr -d " ")"
    if (( app_connections >= 1 )); then
        break
    fi
    /bin/sleep 0.25
done

deploy_succeeded=1
echo "completed_at=$(/bin/date -u +%Y-%m-%dT%H:%M:%SZ) new_pid=$new_backend_pid listener=$listener_pid app_connections=$app_connections release_id=$expected_release"
/bin/rm -f "$deploy_script" "$deploy_plist"
/bin/launchctl bootout "$deploy_target" >/dev/null 2>&1 || true

