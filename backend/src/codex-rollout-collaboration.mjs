// 이 파일은 Codex 롤아웃의 내부 협업 호출과 회신을 공개 가능한 활동으로 연결한다.

const MAX_PROMPT_LENGTH = 4_000;
const MAX_RESULT_LENGTH = 12_000;
const MAX_TRACKED_CALLS = 256;

const COLLABORATION_TOOLS = new Set([
  "spawn_agent",
  "send_message",
  "followup_task",
  "interrupt_agent",
  "wait_agent",
  "list_agents",
]);

export class CodexRolloutCollaborationTracker {
  constructor() {
    this.calls = new Map();
    this.agentsByPath = new Map();
  }

  consume(record) {
    const payload = record?.payload;
    if (!payload || typeof payload !== "object" || Array.isArray(payload)) {
      return [];
    }

    if (
      record.type === "response_item" &&
      payload.type === "function_call"
    ) {
      return this.consumeFunctionCall(payload);
    }
    if (
      record.type === "event_msg" &&
      payload.type === "sub_agent_activity"
    ) {
      return this.consumeAgentActivity(payload);
    }
    if (
      record.type === "response_item" &&
      payload.type === "function_call_output"
    ) {
      return this.consumeFunctionOutput(payload);
    }
    if (
      record.type === "response_item" &&
      payload.type === "agent_message"
    ) {
      return this.consumeAgentMessage(payload);
    }
    return [];
  }

  consumeFunctionCall(payload) {
    const name = cleanText(payload.name)?.replaceAll("-", "_").toLowerCase();
    if (
      !name ||
      (!COLLABORATION_TOOLS.has(name) && payload.namespace !== "collaboration")
    ) {
      return [];
    }
    const callID = cleanText(payload.call_id);
    if (!callID) {
      return [];
    }
    const argumentsObject = parsedObject(payload.arguments);
    this.calls.set(callID, {
      name,
      taskName: cleanText(argumentsObject?.task_name),
    });
    while (this.calls.size > MAX_TRACKED_CALLS) {
      this.calls.delete(this.calls.keys().next().value);
    }
    return [];
  }

  consumeAgentActivity(payload) {
    const callID = cleanText(payload.event_id);
    const call = callID ? this.calls.get(callID) : null;
    const path = cleanText(payload.agent_path);
    const threadID = cleanText(payload.agent_thread_id) ?? path;
    if (!path || !threadID) {
      return [];
    }

    const taskName = call?.taskName ?? pathLeaf(path);
    const agent = this.rememberAgent(path, threadID, taskName);
    const kind = cleanText(payload.kind)?.replaceAll("-", "_").toLowerCase();
    if (callID) {
      this.calls.delete(callID);
    }
    if (kind === "started") {
      return [collaborationActivity(agent, {
        action: "spawn",
        status: "running",
        agentStatus: "running",
      })];
    }
    if (kind === "interacted") {
      if (call?.name === "followup_task") {
        return [collaborationActivity(agent, {
          action: "follow_up",
          status: "running",
          agentStatus: "running",
          prompt: "추가 검토 요청",
        })];
      }
      // send_message 본문은 암호화되어 있어 화면 활동으로 만들지 않는다.
      return [];
    }
    if (kind === "interrupted") {
      return [collaborationActivity(agent, {
        action: "result",
        status: "failed",
        agentStatus: "interrupted",
        message: "협업 검토가 중단되었습니다.",
      })];
    }
    return [];
  }

  consumeFunctionOutput(payload) {
    const callID = cleanText(payload.call_id);
    const call = callID ? this.calls.get(callID) : null;
    if (callID) {
      this.calls.delete(callID);
    }
    if (
      call?.name === "spawn_agent" &&
      failedFunctionOutput(payload.output)
    ) {
      const threadID = `failed:${callID}`;
      const taskName = call.taskName ?? "검토자";
      const agent = this.rememberAgent(
        `/root/${taskName}`,
        threadID,
        taskName,
      );
      return [collaborationActivity(agent, {
        action: "spawn",
        status: "failed",
        agentStatus: "errored",
        message: "협업 검토를 시작하지 못했습니다.",
      })];
    }
    if (!call || call.name !== "list_agents") {
      return [];
    }
    const output = parsedObject(payload.output);
    const agents = Array.isArray(output?.agents) ? output.agents : [];
    return agents.flatMap((entry) => {
      const path = cleanText(entry?.agent_name);
      if (!path || path === "/root") {
        return [];
      }
      const completion = completedAgentStatus(entry?.agent_status);
      if (!completion) {
        return [];
      }
      const agent = this.agentsByPath.get(path) ??
        this.rememberAgent(path, path, pathLeaf(path));
      return [collaborationActivity(agent, {
        action: "result",
        status: completion.status,
        agentStatus: completion.agentStatus,
        message: completion.message,
      })];
    });
  }

  consumeAgentMessage(payload) {
    const text = (Array.isArray(payload.content) ? payload.content : [])
      .filter((item) => item?.type === "input_text")
      .map((item) => cleanText(item.text))
      .filter(Boolean)
      .join("\n");
    const result = finalAnswerPayload(text);
    if (!result) {
      return [];
    }
    const path = result.sender ?? cleanText(payload.author);
    if (!path || path === "/root") {
      return [];
    }
    const agent = this.agentsByPath.get(path) ??
      this.rememberAgent(path, path, pathLeaf(path));
    return [collaborationActivity(agent, {
      action: "result",
      status: "completed",
      agentStatus: "completed",
      message: result.message,
    })];
  }

  rememberAgent(path, threadID, taskName) {
    const existing = this.agentsByPath.get(path);
    const label = readableTaskName(taskName ?? existing?.label ?? pathLeaf(path));
    const agent = {
      path,
      threadID: threadID ?? existing?.threadID ?? path,
      label,
      prompt: limitedText(label, MAX_PROMPT_LENGTH),
      eventKey: `collaboration:rollout:${threadID ?? existing?.threadID ?? path}`,
    };
    this.agentsByPath.set(path, agent);
    return agent;
  }
}

function collaborationActivity(agent, {
  action,
  status,
  agentStatus,
  prompt = agent.prompt,
  message = null,
  eventKey = agent.eventKey,
}) {
  const safePrompt = limitedText(prompt, MAX_PROMPT_LENGTH);
  const safeMessage = limitedText(message, MAX_RESULT_LENGTH);
  return {
    kind: "collaboration",
    text: safeMessage
      ? summaryText(safeMessage)
      : safePrompt ?? collaborationStatusText(status),
    eventKey,
    status,
    preserveText: false,
    messageScoped: false,
    collaboration: {
      action,
      agentThreadId: agent.threadID,
      agentLabel: agent.label,
      prompt: safePrompt,
      message: safeMessage,
      agentStatus,
    },
  };
}

function finalAnswerPayload(text) {
  if (!text || !/^Message Type:\s*FINAL_ANSWER\s*$/m.test(text)) {
    return null;
  }
  const marker = "\nPayload:\n";
  const markerIndex = text.indexOf(marker);
  if (markerIndex < 0) {
    return null;
  }
  const senderMatch = text.slice(0, markerIndex).match(/^Sender:\s*(.+)$/m);
  const message = limitedText(
    text.slice(markerIndex + marker.length),
    MAX_RESULT_LENGTH,
  );
  return message
    ? { sender: cleanText(senderMatch?.[1]), message }
    : null;
}

function completedAgentStatus(value) {
  if (!value || typeof value !== "object" || Array.isArray(value)) {
    return null;
  }
  for (const [key, status, agentStatus] of [
    ["completed", "completed", "completed"],
    ["failed", "failed", "errored"],
    ["errored", "failed", "errored"],
    ["interrupted", "failed", "interrupted"],
  ]) {
    const message = limitedText(value[key], MAX_RESULT_LENGTH);
    if (message) {
      return { status, agentStatus, message };
    }
  }
  return null;
}

function parsedObject(value) {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value;
  }
  if (typeof value !== "string") {
    return null;
  }
  try {
    const parsed = JSON.parse(value);
    return parsed && typeof parsed === "object" && !Array.isArray(parsed)
      ? parsed
      : null;
  } catch {
    return null;
  }
}

function failedFunctionOutput(value) {
  if (value && typeof value === "object" && !Array.isArray(value)) {
    return value.isError === true || Boolean(cleanText(value.error));
  }
  const text = cleanText(value);
  return Boolean(
    text && /already exists|\berror\b|\bfailed\b|\bunable\b|\bcannot\b/i.test(text),
  );
}

function pathLeaf(value) {
  return String(value ?? "").split("/").filter(Boolean).at(-1) ?? "검토자";
}

function readableTaskName(value) {
  return String(value ?? "")
    .replaceAll("_", " ")
    .replaceAll("-", " ")
    .replace(/\s+/g, " ")
    .trim() || "검토자";
}

function cleanText(value) {
  if (typeof value !== "string") {
    return null;
  }
  const text = value.trim();
  return text || null;
}

function limitedText(value, limit) {
  const text = cleanText(value)?.replaceAll("\r\n", "\n");
  if (!text) {
    return null;
  }
  return text.length <= limit ? text : `${text.slice(0, limit - 1)}…`;
}

function summaryText(value) {
  const text = String(value).replace(/\s+/g, " ").trim();
  return text.length <= 320 ? text : `${text.slice(0, 319)}…`;
}

function collaborationStatusText(status) {
  return status === "running"
    ? "협업 검토 중"
    : status === "failed"
    ? "협업 검토에 실패했습니다."
    : "협업 검토를 마쳤습니다.";
}
