// 이 파일은 공급자 계정 한도와 로컬 DB 사용 통계를 직접 합친다.

import { execFile, spawn } from "node:child_process";
import { readFile } from "node:fs/promises";
import { homedir } from "node:os";
import { resolve } from "node:path";
import { promisify } from "node:util";

const execFileAsync = promisify(execFile);
const fiveHourMinutes = 300;
const sevenDayMinutes = 10_080;

function finiteNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : null;
}

function remainingPercent(usedPercent) {
  const used = finiteNumber(usedPercent);
  if (used === null) return null;
  return Math.round(Math.min(100, Math.max(0, 100 - used)));
}

function normalizedPlan(value) {
  const plan = String(value ?? "").trim();
  if (!plan) return null;
  return plan
    .split(/[-_\s]+/)
    .filter(Boolean)
    .map((part) => part[0].toUpperCase() + part.slice(1))
    .join(" ");
}

function isoDate(value) {
  if (value == null) return null;
  const date = typeof value === "number"
    ? new Date(value * 1_000)
    : new Date(value);
  return Number.isNaN(date.getTime()) ? null : date.toISOString();
}

function codexWindow(window, expectedMinutes) {
  if (finiteNumber(window?.windowDurationMins) !== expectedMinutes) {
    return null;
  }
  return {
    remaining: remainingPercent(window.usedPercent),
    resetAt: isoDate(finiteNumber(window.resetsAt)),
  };
}

export function parseCodexRateLimits(result) {
  const rateLimits = result?.rateLimits ?? result ?? {};
  const windows = [rateLimits.primary, rateLimits.secondary]
    .filter(Boolean);
  const window = (minutes) => windows
    .map((entry) => codexWindow(entry, minutes))
    .find(Boolean) ?? null;
  return {
    fiveHour: window(fiveHourMinutes),
    weekly: window(sevenDayMinutes),
    plan: normalizedPlan(rateLimits.planType),
  };
}

function claudeWindow(window) {
  if (!window || typeof window !== "object") return null;
  return {
    remaining: remainingPercent(window.utilization),
    resetAt: isoDate(window.resets_at),
  };
}

export function parseClaudeRateLimits(payload, plan) {
  return {
    fiveHour: claudeWindow(payload?.five_hour),
    weekly: claudeWindow(payload?.seven_day),
    plan: normalizedPlan(plan),
  };
}

function safeError(error, fallback) {
  const message = error instanceof Error ? error.message : String(error ?? "");
  const normalized = message.trim();
  return normalized || fallback;
}

async function configuredCodexExecutable(pool) {
  const result = await pool.query(
    `
      SELECT config ->> 'executablePath' AS path
      FROM characters
      WHERE backend = 'codex'
        AND NULLIF(config ->> 'executablePath', '') IS NOT NULL
      ORDER BY updated_at DESC, id
      LIMIT 1
    `,
  );
  return String(result.rows?.[0]?.path ?? "").trim() || "codex";
}

export async function readCodexRateLimits({
  pool,
  timeoutMs = 8_000,
  spawnProcess = spawn,
}) {
  const executable = await configuredCodexExecutable(pool);
  const result = await new Promise((resolveResult, rejectResult) => {
    const child = spawnProcess(executable, ["app-server", "--stdio"], {
      stdio: ["pipe", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let settled = false;

    const finish = (error, value) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      child.kill();
      if (error) rejectResult(error);
      else resolveResult(value);
    };
    const timer = setTimeout(() => {
      finish(new Error("Codex 계정 한도 조회 시간이 초과됐습니다."));
    }, timeoutMs);
    timer.unref?.();

    child.on("error", () => {
      finish(new Error("Codex CLI를 실행할 수 없습니다."));
    });
    child.on("close", (code) => {
      if (!settled) {
        const detail = stderr.trim();
        finish(new Error(
          detail
            ? `Codex 계정 한도 조회가 실패했습니다: ${detail}`
            : `Codex 계정 한도 조회가 실패했습니다 (${code ?? "종료"}).`,
        ));
      }
    });
    child.stderr.setEncoding("utf8");
    child.stderr.on("data", (chunk) => {
      if (stderr.length < 2_048) stderr += chunk;
    });
    child.stdout.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      for (;;) {
        const newline = stdout.indexOf("\n");
        if (newline < 0) break;
        const line = stdout.slice(0, newline);
        stdout = stdout.slice(newline + 1);
        let message;
        try {
          message = JSON.parse(line);
        } catch {
          continue;
        }
        if (message.id !== 2) continue;
        if (message.error) {
          finish(new Error("Codex 계정 한도 응답이 실패했습니다."));
        } else {
          finish(null, message.result);
        }
      }
    });

    child.stdin.on("error", () => {
      finish(new Error("Codex CLI 요청을 전달할 수 없습니다."));
    });
    child.stdin.write(`${JSON.stringify({
      id: 1,
      method: "initialize",
      params: {
        clientInfo: { name: "officestra", version: "1" },
        capabilities: { experimentalApi: true },
      },
    })}\n`);
    child.stdin.write(`${JSON.stringify({
      method: "initialized",
      params: null,
    })}\n`);
    child.stdin.write(`${JSON.stringify({
      id: 2,
      method: "account/rateLimits/read",
      params: null,
    })}\n`);
  });
  return parseCodexRateLimits(result);
}

function parsedClaudeCredential(raw) {
  const value = JSON.parse(raw);
  const oauth = value?.claudeAiOauth ?? value;
  const accessToken = String(oauth?.accessToken ?? "").trim();
  if (!accessToken) return null;
  const scopes = Array.isArray(oauth.scopes) ? oauth.scopes : [];
  if (scopes.length > 0 && !scopes.includes("user:profile")) {
    throw new Error("Claude 계정 한도 조회 권한(user:profile)이 없습니다.");
  }
  return {
    accessToken,
    plan: oauth.subscriptionType ?? oauth.rateLimitTier ?? null,
  };
}

async function readClaudeCredential() {
  const environmentToken = String(
    process.env.CLAUDE_CODE_OAUTH_TOKEN ?? "",
  ).trim();
  if (environmentToken) {
    return { accessToken: environmentToken, plan: null };
  }

  const credentialPath = resolve(
    process.env.CLAUDE_CONFIG_DIR ?? resolve(homedir(), ".claude"),
    ".credentials.json",
  );
  try {
    const credential = parsedClaudeCredential(
      await readFile(credentialPath, "utf8"),
    );
    if (credential) return credential;
  } catch (error) {
    if (error instanceof SyntaxError) {
      throw new Error("Claude 로그인 정보를 읽을 수 없습니다.");
    }
  }

  try {
    const { stdout } = await execFileAsync(
      "/usr/bin/security",
      ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
      {
        encoding: "utf8",
        maxBuffer: 1_048_576,
        timeout: 3_000,
        killSignal: "SIGTERM",
      },
    );
    const credential = parsedClaudeCredential(stdout);
    if (credential) return credential;
  } catch (error) {
    if (error instanceof SyntaxError) {
      throw new Error("Claude Keychain 로그인 정보를 읽을 수 없습니다.");
    }
  }
  throw new Error("Claude Code 로그인 정보를 찾을 수 없습니다.");
}

export async function readClaudeRateLimits({
  fetchImplementation = fetch,
  credentialReader = readClaudeCredential,
  timeoutMs = 8_000,
} = {}) {
  const credential = await credentialReader();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  timer.unref?.();
  try {
    const response = await fetchImplementation(
      "https://api.anthropic.com/api/oauth/usage",
      {
        method: "GET",
        headers: {
          authorization: `Bearer ${credential.accessToken}`,
          "anthropic-beta": "oauth-2025-04-20",
          "user-agent": "OFFICESTRA/1",
        },
        signal: controller.signal,
      },
    );
    if (!response.ok) {
      throw new Error(
        `Claude 계정 한도 조회가 실패했습니다 (HTTP ${response.status}).`,
      );
    }
    return parseClaudeRateLimits(await response.json(), credential.plan);
  } catch (error) {
    if (error?.name === "AbortError") {
      throw new Error("Claude 계정 한도 조회 시간이 초과됐습니다.");
    }
    throw error;
  } finally {
    clearTimeout(timer);
  }
}

function emptyActivity() {
  return {
    todayCostUSD: 0,
    recentTokens: 0,
    last30DaysCostUSD: 0,
    last30DaysTokens: 0,
  };
}

export async function readUsageActivity(pool, now = new Date()) {
  const dayStart = new Date(
    now.getFullYear(),
    now.getMonth(),
    now.getDate(),
  );
  const thirtyDaysAgo = new Date(now.getTime() - 30 * 86_400_000);
  const result = await pool.query(
    `
      WITH measured AS (
        SELECT
          COALESCE(NULLIF(turn_record.backend, ''), character.backend)
            AS provider,
          turn_record.started_at,
          COALESCE(usage.cost_usd, 0) AS cost_usd,
          CASE
            WHEN COALESCE(NULLIF(turn_record.backend, ''), character.backend)
              = 'claude'
            THEN
              COALESCE(usage.input_tokens, 0)
              + COALESCE(usage.output_tokens, 0)
              + COALESCE(usage.cached_input_tokens, 0)
              + COALESCE(usage.cache_write_input_tokens, 0)
            ELSE
              COALESCE(usage.input_tokens, 0)
              + COALESCE(usage.output_tokens, 0)
          END AS token_count
        FROM usage_records AS usage
        JOIN turns AS turn_record ON turn_record.id = usage.turn_id
        JOIN cli_sessions AS session
          ON session.id = turn_record.cli_session_id
        JOIN characters AS character
          ON character.id = session.character_id
        WHERE turn_record.started_at >= $2
      )
      SELECT
        provider,
        COALESCE(
          SUM(cost_usd) FILTER (WHERE started_at >= $1),
          0
        )::double precision AS "todayCostUSD",
        COALESCE(
          SUM(token_count) FILTER (WHERE started_at >= $1),
          0
        )::double precision AS "recentTokens",
        COALESCE(SUM(cost_usd), 0)::double precision
          AS "last30DaysCostUSD",
        COALESCE(SUM(token_count), 0)::double precision
          AS "last30DaysTokens"
      FROM measured
      GROUP BY provider
    `,
    [dayStart, thirtyDaysAgo],
  );
  const activity = {
    codex: emptyActivity(),
    claude: emptyActivity(),
  };
  for (const row of result.rows ?? []) {
    if (!Object.hasOwn(activity, row.provider)) continue;
    activity[row.provider] = {
      todayCostUSD: finiteNumber(row.todayCostUSD) ?? 0,
      recentTokens: Math.round(finiteNumber(row.recentTokens) ?? 0),
      last30DaysCostUSD: finiteNumber(row.last30DaysCostUSD) ?? 0,
      last30DaysTokens: Math.round(
        finiteNumber(row.last30DaysTokens) ?? 0,
      ),
    };
  }
  return activity;
}

function flattenedLimits(codex, claude, errors, fetchedAt) {
  return {
    codexFiveHour: codex?.fiveHour?.remaining ?? null,
    codexFiveHourResetAt: codex?.fiveHour?.resetAt ?? null,
    codexWeekly: codex?.weekly?.remaining ?? null,
    codexWeeklyResetAt: codex?.weekly?.resetAt ?? null,
    claudeFiveHour: claude?.fiveHour?.remaining ?? null,
    claudeFiveHourResetAt: claude?.fiveHour?.resetAt ?? null,
    claudeWeekly: claude?.weekly?.remaining ?? null,
    claudeWeeklyResetAt: claude?.weekly?.resetAt ?? null,
    codexPlan: codex?.plan ?? null,
    claudePlan: claude?.plan ?? null,
    codexLimitError: errors.codex,
    claudeLimitError: errors.claude,
    fetchedAt: fetchedAt.toISOString(),
  };
}

export function createUsageSummaryReader({
  pool,
  codexReader = () => readCodexRateLimits({ pool }),
  claudeReader = () => readClaudeRateLimits(),
  activityReader = (now) => readUsageActivity(pool, now),
  now = () => new Date(),
  cacheLifetimeMs = 30_000,
}) {
  let cachedLimits = null;
  let inFlightLimits = null;

  async function limits(force) {
    const current = now();
    if (
      !force &&
      cachedLimits &&
      current.getTime() - cachedLimits.cachedAt < cacheLifetimeMs
    ) {
      return cachedLimits.value;
    }
    if (inFlightLimits) return await inFlightLimits;

    inFlightLimits = (async () => {
      const [codexResult, claudeResult] = await Promise.allSettled([
        codexReader(),
        claudeReader(),
      ]);
      const fetchedAt = now();
      const value = flattenedLimits(
        codexResult.status === "fulfilled" ? codexResult.value : null,
        claudeResult.status === "fulfilled" ? claudeResult.value : null,
        {
          codex: codexResult.status === "rejected"
            ? safeError(codexResult.reason, "Codex 한도를 확인할 수 없습니다.")
            : null,
          claude: claudeResult.status === "rejected"
            ? safeError(
              claudeResult.reason,
              "Claude 한도를 확인할 수 없습니다.",
            )
            : null,
        },
        fetchedAt,
      );
      cachedLimits = { cachedAt: fetchedAt.getTime(), value };
      return value;
    })();
    try {
      return await inFlightLimits;
    } finally {
      inFlightLimits = null;
    }
  }

  return async function usageSummary({ force = false } = {}) {
    const current = now();
    const [limitSnapshot, activity] = await Promise.all([
      limits(force),
      activityReader(current),
    ]);
    return {
      ...limitSnapshot,
      codexActivity: activity.codex,
      claudeActivity: activity.claude,
    };
  };
}
