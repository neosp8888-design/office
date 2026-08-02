// 이 파일은 Codex와 Claude CLI JSONL을 공개 가능한 실시간 업무 이벤트로 변환한다.

import { isAbsolute, relative } from "node:path";

const MAX_REASONING_LENGTH = 6_000;

export function parseAgentEvent(line, backend, workdir = null) {
  let object;
  try {
    object = JSON.parse(line);
  } catch {
    return null;
  }
  if (!object || typeof object !== "object" || Array.isArray(object)) {
    return null;
  }

  return backend === "codex"
    ? parseCodexEvent(object, workdir)
    : parseClaudeEvent(object, workdir);
}

export function decodeAgentResponse(value) {
  const text = String(value ?? "").trim();
  const marker = "[NEED_INPUT]";
  if (!text.startsWith(marker)) {
    return { text, needsInput: false };
  }

  return {
    text: text.slice(marker.length).replace(/^\s+/, ""),
    needsInput: true,
  };
}

function parseCodexEvent(object, workdir) {
  const type = object.type;
  if (type === "thread.started") {
    return {
      sessionID: cleanText(object.thread_id),
    };
  }
  if (type === "turn.started") {
    return null;
  }
  if (type === "turn.completed") {
    const usage = normalizedUsage(object.usage, "codex");
    return usage ? { usage } : null;
  }
  if (type === "turn.failed") {
    return {
      failure:
        failureText(object.error) ??
        "Codex 작업이 완료되지 못했습니다.",
    };
  }
  if (type === "error") {
    return {
      warning:
        failureText(object.message) ??
        failureText(object.error),
    };
  }

  if (
    !["item.started", "item.updated", "item.completed"].includes(type) ||
    !object.item
  ) {
    return null;
  }

  const item = object.item;
  const eventKey = codexEventKey(item);
  switch (item.type) {
    case "reasoning": {
      const reasoningText = codexReasoningText(item);
      if (!reasoningText) {
        return null;
      }
      return {
        activity: {
          ...activity("thinking", reasoningText, {
            eventKey,
            status: codexActivityStatus(item, type),
          }),
          isCodexReasoning: true,
        },
      };
    }
    case "agent_message": {
      const text = cleanText(item.text);
      return text
        ? { agentMessage: text, agentMessageKey: eventKey }
        : null;
    }
    case "command_execution":
      return {
        activity: activity(
          "command",
          commandActivityText(item),
          {
            eventKey,
            status: codexActivityStatus(item, type),
          },
        ),
      };
    case "file_change":
      return {
        activity: activity(
          "tool",
          type === "item.completed"
            ? fileChangeActivityText(item.changes, null, workdir)
            : fileChangeRunningText(item.changes),
          {
            eventKey,
            status: codexActivityStatus(item, type),
          },
        ),
        fileChange: {
          eventKey,
          phase: type,
          changes: fileChangeMetadata(item.changes),
        },
      };
    case "mcp_tool_call":
      return {
        activity: activity(
          "tool",
          mcpActivityText(item),
          {
            eventKey,
            status: codexActivityStatus(item, type),
          },
        ),
      };
    case "collab_tool_call":
      return {
        activity: activity(
          "tool",
          collabActivityText(item),
          {
            eventKey,
            status: codexActivityStatus(item, type),
          },
        ),
      };
    case "web_search":
      return {
        activity: activity(
          "tool",
          webSearchActivityText(item),
          {
            eventKey,
            status: codexActivityStatus(item, type),
          },
        ),
      };
    case "error": {
      const text = cleanText(item.message ?? item.error);
      return text
        ? {
            activity: activity("tool", `오류 · ${text}`, {
              eventKey,
              status: "failed",
            }),
          }
        : null;
    }
    case "todo_list":
      return type !== "item.updated"
        ? {
            activity: activity(
              "thinking",
              todoActivityText(item),
              {
                eventKey,
                status: "completed",
              },
            ),
          }
        : null;
    default:
      return null;
  }
}

function parseClaudeEvent(object, workdir) {
  if (object.type === "system" && object.subtype === "init") {
    return {
      sessionID: cleanText(object.session_id),
    };
  }

  if (object.type === "stream_event") {
    const event = object.event ?? {};
    if (event.type === "message_start") {
      return {
        streamMessageID: cleanText(event.message?.id),
      };
    }
    if (
      event.type === "content_block_delta" &&
      event.delta?.type === "text_delta"
    ) {
      const delta = String(event.delta.text ?? "");
      return delta ? { responseDelta: delta } : null;
    }
    if (
      event.type === "content_block_start" &&
      event.content_block?.type === "thinking"
    ) {
      return {
        activity: activity("thinking", "추론 중", {
          eventKey: `block:${event.index ?? 0}`,
          messageScoped: true,
          status: "running",
        }),
      };
    }
    if (
      event.type === "content_block_start" &&
      event.content_block?.type === "tool_use"
    ) {
      return {
        activity: activity(
          "tool",
          claudeToolActivityText(event.content_block, workdir),
          {
            eventKey: claudeToolEventKey(event.content_block),
            status: "running",
          },
        ),
      };
    }
    return null;
  }

  if (object.type === "assistant") {
    const content = object.message?.content;
    if (!Array.isArray(content)) {
      return null;
    }
    const messageID = cleanText(object.message?.id);
    const activities = [];
    content.forEach((item, index) => {
      if (item.type === "thinking") {
        const text = reasoningText(item.thinking);
        if (text) {
          activities.push(
            activity("thinking", text, {
              eventKey: messageID
                ? `${messageID}:block:${index}`
                : null,
              status: "completed",
            }),
          );
        }
      } else if (item.type === "tool_use") {
        activities.push(
          activity("tool", claudeToolActivityText(item, workdir), {
            eventKey: claudeToolEventKey(item),
            status: "running",
          }),
        );
      }
    });
    const publicText = content
      .filter((item) => item.type === "text")
      .map((item) => String(item.text ?? ""))
      .join("");
    const result = {};
    if (activities.length > 0) {
      result.activities = activities;
    }
    if (publicText.trim()) {
      result.agentMessage = publicText.trim();
      result.agentMessageKey = messageID;
    }
    return Object.keys(result).length > 0 ? result : null;
  }

  if (object.type === "user") {
    const content = object.message?.content;
    if (!Array.isArray(content)) {
      return null;
    }
    const activities = content
      .filter((item) => item.type === "tool_result")
      .map((item) => activity("tool", "도구 완료", {
        eventKey: cleanText(item.tool_use_id),
        preserveText: true,
        status: item.is_error === true ? "failed" : "completed",
      }));
    return activities.length > 0 ? { activities } : null;
  }

  if (object.type === "result") {
    const sessionID = cleanText(object.session_id);
    const usage = normalizedUsage(object.usage, "claude", {
      reportedCostUsd: object.total_cost_usd,
    });
    if (object.is_error === true) {
      return {
        sessionID,
        usage,
        failure:
          cleanText(object.result) ??
          "Claude Code 작업이 완료되지 못했습니다.",
      };
    }
    return {
      sessionID,
      usage,
      responseText: cleanText(object.result),
    };
  }

  return null;
}

function activity(kind, text, options = {}) {
  return {
    kind,
    text,
    eventKey: options.eventKey ?? null,
    status: options.status ?? "completed",
    preserveText: options.preserveText === true,
    messageScoped: options.messageScoped === true,
  };
}

function normalizedUsage(value, backend, options = {}) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  const cacheCreation = value.cache_creation &&
      typeof value.cache_creation === "object"
    ? value.cache_creation
    : {};
  const usage = {
    inputTokens: tokenCount(value.input_tokens),
    outputTokens: tokenCount(value.output_tokens),
    cachedInputTokens: tokenCount(
      backend === "codex"
        ? value.cached_input_tokens
        : value.cache_read_input_tokens,
    ),
    cacheWriteInputTokens: tokenCount(
      backend === "codex"
        ? value.cache_write_input_tokens
        : value.cache_creation_input_tokens,
    ),
    cacheWrite5mInputTokens: tokenCount(
      cacheCreation.ephemeral_5m_input_tokens,
    ),
    cacheWrite1hInputTokens: tokenCount(
      cacheCreation.ephemeral_1h_input_tokens,
    ),
    reasoningOutputTokens: tokenCount(value.reasoning_output_tokens),
    serviceTier: cleanText(value.service_tier),
    speed: cleanText(value.speed),
    inferenceGeo: cleanText(value.inference_geo),
    reportedCostUsd: nonnegativeNumber(options.reportedCostUsd),
  };
  const hasTokenOrCost = [
    usage.inputTokens,
    usage.outputTokens,
    usage.cachedInputTokens,
    usage.cacheWriteInputTokens,
    usage.cacheWrite5mInputTokens,
    usage.cacheWrite1hInputTokens,
    usage.reasoningOutputTokens,
    usage.reportedCostUsd,
  ].some((entry) => entry !== null);
  return hasTokenOrCost ? usage : null;
}

// Claude 세션 기록 한 줄에서 사용량을 읽는다. 중단으로 결과 이벤트를
// 받지 못한 턴의 사용량을 디스크에서 복구할 때 쓴다.
export function claudeSessionUsage(line) {
  let object;
  try {
    object = JSON.parse(line);
  } catch {
    return null;
  }
  if (!object || typeof object !== "object" || Array.isArray(object)) {
    return null;
  }
  return normalizedUsage(object.message?.usage, "claude");
}

function tokenCount(value) {
  const number = nonnegativeNumber(value);
  return number === null ? null : Math.trunc(number);
}

function nonnegativeNumber(value) {
  if (typeof value === "number" && Number.isFinite(value) && value >= 0) {
    return value;
  }
  if (typeof value === "string" && /^\d+(?:\.\d+)?$/.test(value)) {
    return Number(value);
  }
  return null;
}

function commandActivityText(item) {
  return safeCommand(item.command) ?? "명령";
}

function codexActivityStatus(item, eventType) {
  if (eventType !== "item.completed") {
    return "running";
  }
  const exitCode = numericValue(item.exit_code ?? item.exitCode);
  if (exitCode !== null) {
    return exitCode === 0 ? "completed" : "failed";
  }
  const status = cleanText(item.status)?.toLowerCase();
  return [
    "failed",
    "error",
    "cancelled",
    "canceled",
    "declined",
  ].includes(status) ||
      item.error
    ? "failed"
    : "completed";
}

export function fileChangeActivityText(
  changesValue,
  statistics = null,
  workdir = null,
) {
  const changes = Array.isArray(changesValue) ? changesValue : [];
  const summaries = changes
    .map((change) => {
      if (!change || typeof change !== "object") {
        return null;
      }
      const path = cleanText(
        change.path ??
          change.file_path ??
          change.file ??
          change.move_path,
      );
      if (!path) {
        return null;
      }
      return `${fileChangeLabel(change.kind)} ${compactPath(path, workdir)}`;
    })
    .filter(Boolean);
  if (summaries.length === 0) {
    return "파일 변경 완료";
  }

  const visible = summaries.slice(0, 40);
  const remainder = summaries.length - visible.length;
  return [
    `파일 ${summaries.length}개를 편집했습니다`,
    statistics
      ? `+${statistics.additions} -${statistics.deletions}`
      : null,
    ...visible,
    remainder > 0 ? `외 ${remainder}개` : null,
  ]
    .filter(Boolean)
    .join("\n");
}

function fileChangeRunningText(changesValue) {
  const changes = fileChangeMetadata(changesValue);
  if (changes.length === 0) {
    return "파일 변경을 적용하는 중";
  }
  return `파일 변경을 적용하는 중 · ${changes.length}개`;
}

function fileChangeMetadata(changesValue) {
  const changes = Array.isArray(changesValue) ? changesValue : [];
  return changes.flatMap((change) => {
    if (!change || typeof change !== "object") {
      return [];
    }
    const path = cleanText(
      change.path ??
        change.file_path ??
        change.file ??
        change.move_path,
    );
    return path ? [{ path, kind: cleanText(change.kind) }] : [];
  });
}

function mcpActivityText(item) {
  const server = cleanText(
    item.server ?? item.server_name ?? item.appName ?? item.app_name,
  );
  const tool = cleanText(
    item.tool ?? item.name ?? item.actionName ?? item.action_name,
  );
  const target = [server, tool].filter(Boolean).join("/") || "연결 도구";
  return target;
}

function collabActivityText(item) {
  const tool = cleanText(item.tool ?? item.name ?? item.action) ?? "협업";
  const target = cleanText(
    item.receiver_agent_nickname ??
      item.receiver_agent ??
      item.agent_name ??
      item.agent,
  );
  return target
    ? `협업 · ${tool} → ${target}`
    : `협업 · ${tool}`;
}

function webSearchActivityText(item) {
  const action = item.action && typeof item.action === "object"
    ? item.action
    : {};
  const detail = cleanText(
    item.query ?? action.query ?? action.pattern ?? action.url,
  );
  return detail
    ? `검색 · ${safePublicText(detail, 220)}`
    : "웹 검색";
}

function todoActivityText(item) {
  const entries = Array.isArray(item.items)
    ? item.items
    : Array.isArray(item.todos)
    ? item.todos
    : [];
  const pending = entries.find((entry) => {
    if (!entry || typeof entry !== "object") {
      return false;
    }
    return entry.completed !== true && entry.status !== "completed";
  });
  const text = pending && typeof pending === "object"
    ? cleanText(pending.text ?? pending.step ?? pending.title)
    : null;
  return text
    ? `계획 · ${safePublicText(text, 220)}`
    : entries.length > 0
    ? `계획 · ${entries.length}단계`
    : "작업 계획 정리";
}

function claudeToolActivityText(tool, workdir) {
  if (!tool || typeof tool !== "object") {
    return "도구 호출";
  }
  const name = cleanText(tool.name) ?? "도구";
  const input = tool.input && typeof tool.input === "object"
    ? tool.input
    : {};
  const loweredName = name.toLowerCase();
  if (["bash", "shell", "terminal"].includes(loweredName)) {
    const command = safeCommand(input.command);
    return command ? `도구 · ${name} · ${command}` : `도구 · ${name}`;
  }
  if (loweredName === "todowrite") {
    return claudePlanActivityText(name, input);
  }
  if (loweredName === "task") {
    const detail = [
      cleanText(input.subagent_type ?? input.subagentType),
      cleanText(input.description),
    ]
      .filter(Boolean)
      .join(" · ");
    return detail
      ? `도구 · ${name} · ${safePublicText(detail, 180)}`
      : `도구 · ${name}`;
  }

  const path = cleanText(
    input.file_path ??
      input.notebook_path ??
      input.path ??
      input.cwd ??
      input.directory,
  );
  if (path) {
    return `도구 · ${name} · ${compactPath(path, workdir)}`;
  }
  if (["grep", "glob", "websearch"].includes(loweredName)) {
    const query = cleanText(input.pattern ?? input.query);
    if (query) {
      return `도구 · ${name} · ${safePublicText(query, 180)}`;
    }
  }
  return `도구 · ${name}`;
}

function claudePlanActivityText(name, input) {
  const entries = Array.isArray(input.todos)
    ? input.todos
    : Array.isArray(input.items)
    ? input.items
    : [];
  const steps = entries.flatMap((entry) => {
    if (!entry || typeof entry !== "object") {
      return [];
    }
    const text = cleanText(entry.content ?? entry.text ?? entry.title);
    if (!text) {
      return [];
    }
    const status = cleanText(entry.status)?.toLowerCase();
    const done = entry.completed === true || status === "completed";
    const marker = done ? "x" : status === "in_progress" ? "~" : " ";
    return [`[${marker}] ${safePublicText(text, 160)}`];
  });
  if (steps.length === 0) {
    return `도구 · ${name}`;
  }

  const done = steps.filter((step) => step.startsWith("[x]")).length;
  const visible = steps.slice(0, 12);
  const remainder = steps.length - visible.length;
  return [
    `도구 · ${name} · ${done}/${steps.length}단계`,
    ...visible,
    remainder > 0 ? `외 ${remainder}개` : null,
  ]
    .filter(Boolean)
    .join("\n");
}

function codexEventKey(item) {
  return cleanText(item.id ?? item.item_id ?? item.itemId);
}

function claudeToolEventKey(tool) {
  return cleanText(tool?.id ?? tool?.tool_use_id);
}

function codexReasoningText(item) {
  const raw = nestedReasoningText(
    item.raw_reasoning ??
      item.rawReasoning ??
      item.raw_content ??
      item.rawContent ??
      item.content,
  );
  return reasoningText(raw) ??
    reasoningText(item.text) ??
    reasoningText(item.summary);
}

function nestedReasoningText(value) {
  if (typeof value === "string") {
    return value;
  }
  if (Array.isArray(value)) {
    return value
      .map((entry) => nestedReasoningText(entry))
      .filter(Boolean)
      .join("\n");
  }
  if (!value || typeof value !== "object") {
    return null;
  }
  return nestedReasoningText(
    value.text ?? value.content ?? value.reasoning ?? value.summary,
  );
}

function reasoningText(value) {
  const text = cleanText(value);
  if (!text) {
    return null;
  }
  return text.length <= MAX_REASONING_LENGTH
    ? text
    : `${text.slice(0, MAX_REASONING_LENGTH - 1)}…`;
}

function safeCommand(value) {
  const source = cleanText(value);
  if (!source) {
    return null;
  }
  const command = source.replace(/\s*\n\s*/g, " ↳ ");
  if (containsSensitiveCommandData(command)) {
    return `${commandProgram(command)} [민감 인자 숨김]`;
  }
  return safePublicText(command, 280);
}

function containsSensitiveCommandData(command) {
  return /(?:api[_-]?key|token|password|passwd|secret|authorization|cookie|bearer)/i
    .test(command) ||
    /\b(?:sk|rk|pk)-[a-z0-9_-]{8,}/i.test(command) ||
    /:\/\/[^/\s:@]+:[^@\s/]+@/.test(command);
}

function commandProgram(command) {
  const tokens = command.trim().split(/\s+/);
  const token = tokens.find((candidate) => !/^[A-Za-z_][A-Za-z0-9_]*=/.test(candidate));
  return cleanText(token) ?? "명령";
}

function safePublicText(value, limit) {
  const source = String(value ?? "")
    .replaceAll("\r\n", "\n")
    .replace(/\s*\n\s*/g, " ↳ ")
    .trim();
  if (source.length <= limit) {
    return source;
  }
  return `${source.slice(0, limit - 1)}…`;
}

function compactPath(value, workdir = null) {
  const source = String(value);
  const base = String(workdir ?? "");
  const relativePath = base
    ? isAbsolute(source) ? relative(base, source) : source
    : null;
  const normalizedRelativePath = relativePath?.replaceAll("\\", "/");
  if (
    normalizedRelativePath &&
    normalizedRelativePath !== ".." &&
    !normalizedRelativePath.startsWith("../") &&
    !isAbsolute(relativePath)
  ) {
    return normalizedRelativePath;
  }

  const path = source.replaceAll("\\", "/");
  if (path.length <= 96) {
    return path;
  }
  const components = path.split("/").filter(Boolean);
  return components.length > 3
    ? `…/${components.slice(-3).join("/")}`
    : `…${path.slice(-92)}`;
}

function fileChangeLabel(value) {
  switch (cleanText(value)?.toLowerCase()) {
    case "add":
    case "create":
      return "추가";
    case "delete":
    case "remove":
      return "삭제";
    case "move":
    case "rename":
      return "이동";
    default:
      return "수정";
  }
}

function numericValue(value) {
  if (typeof value === "number" && Number.isFinite(value)) {
    return value;
  }
  if (typeof value === "string" && /^-?\d+$/.test(value)) {
    return Number(value);
  }
  return null;
}

function cleanText(value) {
  const text = typeof value === "string" ? value.trim() : "";
  return text || null;
}

function failureText(value) {
  if (typeof value === "string") {
    return cleanText(value);
  }
  if (!value || typeof value !== "object") {
    return null;
  }

  const parts = ["message", "detail", "code", "type", "error"]
    .map((key) => failureText(value[key]))
    .filter(Boolean);
  return [...new Set(parts)].join("\n") || null;
}
