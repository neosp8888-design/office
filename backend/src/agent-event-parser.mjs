// 이 파일은 Codex와 Claude CLI JSONL을 공개 가능한 실시간 업무 이벤트로 변환한다.

const MAX_ACTIVITY_LENGTH = 800;

export function parseAgentEvent(line, backend) {
  let object;
  try {
    object = JSON.parse(line);
  } catch {
    return null;
  }

  return backend === "codex"
    ? parseCodexEvent(object)
    : parseClaudeEvent(object);
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

function parseCodexEvent(object) {
  const type = object.type;
  if (type === "thread.started") {
    return {
      sessionID: cleanText(object.thread_id),
      activity: activity("thinking", "업무 환경을 준비하는 중..."),
    };
  }
  if (type === "turn.started") {
    return {
      activity: activity("thinking", "업무 내용을 살펴보는 중..."),
    };
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
  switch (item.type) {
    case "reasoning": {
      const summary = type === "item.started"
        ? "해결 방법을 검토하는 중..."
        : concise(item.text);
      return summary
        ? { activity: activity("thinking", summary) }
        : null;
    }
    case "agent_message": {
      const text = cleanText(item.text);
      return text ? { responseText: text } : null;
    }
    case "command_execution":
      return {
        activity: activity(
          "command",
          type === "item.completed"
            ? "명령 결과를 확인했습니다."
            : "명령을 실행하는 중...",
        ),
      };
    case "file_change":
      return type === "item.completed"
        ? { activity: activity("tool", "파일 변경을 반영했습니다.") }
        : null;
    case "mcp_tool_call":
      return {
        activity: activity(
          "tool",
          type === "item.completed"
            ? "연결된 도구의 결과를 확인했습니다."
            : "연결된 도구를 사용하는 중...",
        ),
      };
    case "collab_tool_call":
      return type === "item.started"
        ? { activity: activity("tool", "동료 에이전트와 협업하는 중...") }
        : null;
    case "web_search":
      return type === "item.started"
        ? { activity: activity("tool", "필요한 자료를 검색하는 중...") }
        : null;
    case "todo_list":
      return type === "item.started"
        ? { activity: activity("thinking", "작업 순서를 정리하는 중...") }
        : null;
    default:
      return null;
  }
}

function parseClaudeEvent(object) {
  if (object.type === "system" && object.subtype === "init") {
    return {
      sessionID: cleanText(object.session_id),
      activity: activity("thinking", "업무 환경을 준비하는 중..."),
    };
  }

  if (object.type === "stream_event") {
    const event = object.event ?? {};
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
        activity: activity("thinking", "문제를 분석하는 중..."),
      };
    }
    if (
      event.type === "content_block_start" &&
      event.content_block?.type === "tool_use"
    ) {
      return {
        activity: activity("tool", "도구를 사용해 업무를 처리하는 중..."),
      };
    }
    return null;
  }

  if (object.type === "assistant") {
    const content = object.message?.content;
    if (!Array.isArray(content)) {
      return null;
    }
    const publicText = content
      .filter((item) => item.type === "text")
      .map((item) => String(item.text ?? ""))
      .join("");
    if (publicText.trim()) {
      return { responseText: publicText.trim() };
    }
    if (content.some((item) => item.type === "tool_use")) {
      return {
        activity: activity("tool", "도구를 사용해 업무를 처리하는 중..."),
      };
    }
    if (content.some((item) => item.type === "thinking")) {
      return {
        activity: activity("thinking", "문제를 분석하는 중..."),
      };
    }
    return null;
  }

  if (object.type === "result") {
    const sessionID = cleanText(object.session_id);
    if (object.is_error === true) {
      return {
        sessionID,
        failure:
          cleanText(object.result) ??
          "Claude Code 작업이 완료되지 못했습니다.",
      };
    }
    return {
      sessionID,
      responseText: cleanText(object.result),
    };
  }

  return null;
}

function activity(kind, text) {
  return { kind, text };
}

function concise(value) {
  const lines = String(value ?? "")
    .replaceAll("\r\n", "\n")
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
  if (lines.length === 0) {
    return null;
  }

  const joined = lines.slice(0, 6).join("\n");
  return joined.length <= MAX_ACTIVITY_LENGTH
    ? joined
    : `${joined.slice(0, MAX_ACTIVITY_LENGTH - 1)}…`;
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
