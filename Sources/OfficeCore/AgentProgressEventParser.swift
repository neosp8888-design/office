// 이 파일은 직원 CLI JSONL 이벤트를 안전한 말풍선 진행 문구로 변환한다.

import Foundation

public enum AgentProgressEventParser {
    public static func message(
        fromJSONLine line: String,
        backend: AgentBackend
    ) -> String? {
        guard
            let data = line.data(using: .utf8),
            let value = try? JSONSerialization.jsonObject(with: data),
            let object = value as? [String: Any]
        else {
            return nil
        }

        switch backend {
        case .codex:
            return codexMessage(from: object)
        case .claude:
            return claudeMessage(from: object)
        case .antigravity:
            return antigravityMessage(from: object)
        }
    }

    private static func codexMessage(
        from object: [String: Any]
    ) -> String? {
        guard let eventType = object["type"] as? String else {
            return nil
        }
        if eventType == "turn.started" {
            return "요청서 정독 중 👀"
        }

        guard
            ["item.started", "item.updated", "item.completed"]
                .contains(eventType),
            let item = object["item"] as? [String: Any],
            let itemType = item["type"] as? String
        else {
            return nil
        }

        switch itemType {
        case "reasoning":
            if
                eventType != "item.started",
                let summary = reasoningText(
                    item["raw_reasoning"]
                        ?? item["rawReasoning"]
                        ?? item["raw_content"]
                        ?? item["rawContent"]
                        ?? item["content"]
                        ?? item["text"]
                        ?? item["summary"]
                )
            {
                return summary
            }
            return eventType == "item.started"
                ? "작전 짜는 중 🧠"
                : nil
        case "agent_message":
            guard eventType != "item.started" else {
                return nil
            }
            return concise(item["text"])
        case "command_execution":
            return commandMessage(item, eventType: eventType)
        case "file_change":
            return eventType == "item.completed"
                ? fileChangeMessage(item)
                : nil
        case "mcp_tool_call":
            return mcpMessage(item, eventType: eventType)
        case "collab_tool_call":
            return eventType == "item.completed"
                ? collabMessage(item)
                : nil
        case "web_search":
            return eventType == "item.started"
                ? webSearchMessage(item)
                : nil
        case "todo_list":
            return eventType == "item.started"
                ? todoMessage(item)
                : nil
        default:
            return nil
        }
    }

    private static func claudeMessage(
        from object: [String: Any]
    ) -> String? {
        if
            object["type"] as? String == "system",
            object["subtype"] as? String == "init"
        {
            return "업무 세팅 중 🧳"
        }

        guard
            object["type"] as? String == "assistant",
            let message = object["message"] as? [String: Any],
            let content = message["content"] as? [[String: Any]]
        else {
            return nil
        }

        let publicText = content.compactMap { item -> String? in
            guard item["type"] as? String == "text" else {
                return nil
            }
            return concise(item["text"])
        }
        .joined(separator: "\n")
        if !publicText.isEmpty {
            return concise(publicText)
        }
        if let tool = content.first(where: {
            $0["type"] as? String == "tool_use"
        }) {
            return claudeToolMessage(tool)
        }
        if let thinking = content.first(where: {
            $0["type"] as? String == "thinking"
        }), let text = reasoningText(thinking["thinking"]) {
            return text
        }
        return nil
    }

    private static func antigravityMessage(
        from object: [String: Any]
    ) -> String? {
        if object["event"] as? String == "init" {
            return "업무 세팅 중 🧳"
        }
        guard
            object["event"] as? String == "step_update",
            let update = object["step_update"] as? [String: Any]
        else {
            return nil
        }
        let stepType = cleanText(update["step_type"])
        if stepType == "agent_response" {
            return concise(update["text_delta"])
        }
        guard stepType == "tool" else {
            return nil
        }
        let info = update["tool_info"] as? [String: Any] ?? [:]
        let name = cleanText(update["tool_name"] ?? info["name"]) ?? "도구"
        let parameters = info["parameters"] as? [String: Any] ?? [:]
        if name == "run_command" {
            let command = safeCommand(
                parameters["CommandLine"]
                    ?? parameters["command_line"]
                    ?? parameters["command"]
            ) ?? "명령"
            return "실행 · \(command)"
        }
        if let path = cleanText(
            parameters["TargetFile"]
                ?? parameters["target_file"]
                ?? parameters["Path"]
                ?? parameters["path"]
        ) {
            return "도구 · \(name) · \(compactPath(path))"
        }
        return "도구 · \(name)"
    }

    private static func commandMessage(
        _ item: [String: Any],
        eventType: String
    ) -> String? {
        guard
            eventType == "item.started"
                || eventType == "item.updated"
                || eventType == "item.completed"
        else {
            return nil
        }
        let command = safeCommand(item["command"]) ?? "명령"
        guard eventType == "item.completed" else {
            return "실행 · \(command)"
        }

        guard let exitCode = integerValue(
            item["exit_code"] ?? item["exitCode"]
        ) else {
            let status = cleanText(item["status"])?.lowercased()
            if let status,
                ["failed", "error", "cancelled", "canceled"]
                    .contains(status)
            {
                return "실패 · \(command)"
            }
            return "완료 · \(command)"
        }
        return exitCode == 0
            ? "완료(0) · \(command)"
            : "실패(\(exitCode)) · \(command)"
    }

    private static func fileChangeMessage(
        _ item: [String: Any]
    ) -> String {
        let changes = item["changes"] as? [[String: Any]] ?? []
        let summaries = changes.compactMap { change -> String? in
            guard let path = cleanText(
                change["path"]
                    ?? change["file_path"]
                    ?? change["file"]
                    ?? change["move_path"]
            ) else {
                return nil
            }
            return "\(fileChangeLabel(change["kind"])) \(compactPath(path))"
        }
        guard !summaries.isEmpty else {
            return "파일 변경 완료"
        }
        let visible = summaries.prefix(3).joined(separator: ", ")
        let remainder = summaries.count - 3
        return "파일 · \(visible)"
            + (remainder > 0 ? " 외 \(remainder)개" : "")
    }

    private static func mcpMessage(
        _ item: [String: Any],
        eventType: String
    ) -> String? {
        guard
            eventType == "item.started"
                || eventType == "item.updated"
                || eventType == "item.completed"
        else {
            return nil
        }
        let server = cleanText(
            item["server"]
                ?? item["server_name"]
                ?? item["appName"]
                ?? item["app_name"]
        )
        let tool = cleanText(
            item["tool"]
                ?? item["name"]
                ?? item["actionName"]
                ?? item["action_name"]
        )
        let target = [server, tool].compactMap { $0 }.joined(separator: "/")
        let resolvedTarget = target.isEmpty ? "연결 도구" : target
        let status = cleanText(item["status"])?.lowercased()
        let failed = (
            status.map {
                ["failed", "error", "cancelled", "canceled"]
                    .contains($0)
            } ?? false
        ) || item["error"] != nil
        if eventType == "item.completed", failed {
            return "도구 실패 · \(resolvedTarget)"
        }
        return eventType == "item.completed"
            ? "도구 완료 · \(resolvedTarget)"
            : "도구 호출 · \(resolvedTarget)"
    }

    private static func collabMessage(
        _ item: [String: Any]
    ) -> String? {
        let tool = cleanText(
            item["tool"] ?? item["name"] ?? item["action"]
        )?.replacingOccurrences(of: "-", with: "_").lowercased()
            ?? "collaboration"
        if ["close_agent", "closeagent"].contains(tool) {
            return nil
        }
        if ["spawn_agent", "spawnagent"].contains(tool) {
            let prompt = cleanText(
                item["prompt"] ?? item["message"] ?? item["input"]
            )
            return prompt.map {
                "협업 요청 · \(shortened($0, limit: 220))"
            } ?? "협업 검토 시작"
        }
        if ["send_input", "sendinput"].contains(tool) {
            let prompt = cleanText(
                item["prompt"] ?? item["message"] ?? item["input"]
            )
            return prompt.map {
                "협업 추가 요청 · \(shortened($0, limit: 220))"
            } ?? "협업 추가 요청"
        }
        if tool == "wait" {
            let states = item["agents_states"] as? [String: Any]
                ?? item["agent_states"] as? [String: Any]
                ?? item["agentsStates"] as? [String: Any]
                ?? [:]
            var hasTerminalAgent = false
            for value in states.values {
                guard let state = value as? [String: Any] else {
                    continue
                }
                if let message = cleanText(
                    state["message"] ?? state["result"] ?? state["output"]
                ) {
                    return "협업 결과 · \(shortened(message, limit: 260))"
                }
                let status = cleanText(state["status"])?.lowercased()
                if let status,
                    [
                        "completed", "shutdown", "interrupted",
                        "errored", "not_found",
                    ].contains(status)
                {
                    hasTerminalAgent = true
                }
            }
            return hasTerminalAgent ? "협업 검토 완료" : nil
        }
        return "협업 · \(tool)"
    }

    private static func webSearchMessage(
        _ item: [String: Any]
    ) -> String {
        let action = item["action"] as? [String: Any] ?? [:]
        let detail = cleanText(
            item["query"]
                ?? action["query"]
                ?? action["pattern"]
                ?? action["url"]
        )
        return detail.map {
            "검색 · \(shortened($0, limit: 220))"
        } ?? "웹 검색"
    }

    private static func todoMessage(
        _ item: [String: Any]
    ) -> String {
        let entries = item["items"] as? [[String: Any]]
            ?? item["todos"] as? [[String: Any]]
            ?? []
        let pending = entries.first { entry in
            let completed = entry["completed"] as? Bool ?? false
            let status = cleanText(entry["status"])
            return !completed && status != "completed"
        }
        let text = pending.flatMap {
            cleanText($0["text"] ?? $0["step"] ?? $0["title"] ?? $0["content"])
        }
        if let text {
            return "계획 · \(shortened(text, limit: 220))"
        }
        return entries.isEmpty
            ? "작업 계획 정리"
            : "계획 · \(entries.count)단계"
    }

    private static func claudeToolMessage(
        _ tool: [String: Any]
    ) -> String {
        let name = cleanText(tool["name"]) ?? "도구"
        let input = tool["input"] as? [String: Any] ?? [:]
        let loweredName = name.lowercased()
        if ["bash", "shell", "terminal"].contains(loweredName) {
            if let command = safeCommand(input["command"]) {
                return "도구 · \(name) · \(command)"
            }
            return "도구 · \(name)"
        }

        if loweredName == "todowrite" {
            return todoMessage(input)
        }
        if loweredName == "task" {
            let detail = [
                cleanText(input["subagent_type"]),
                cleanText(input["description"]),
            ]
                .compactMap { $0 }
                .joined(separator: " · ")
            return detail.isEmpty
                ? "도구 · \(name)"
                : "도구 · \(name) · \(shortened(detail, limit: 180))"
        }

        if let path = cleanText(
            input["file_path"]
                ?? input["notebook_path"]
                ?? input["path"]
                ?? input["cwd"]
                ?? input["directory"]
        ) {
            return "도구 · \(name) · \(compactPath(path))"
        }
        if ["grep", "glob", "websearch"].contains(loweredName),
            let query = cleanText(input["pattern"] ?? input["query"])
        {
            return "도구 · \(name) · \(shortened(query, limit: 180))"
        }
        return "도구 · \(name)"
    }

    private static func safeCommand(_ value: Any?) -> String? {
        guard let source = cleanText(value) else {
            return nil
        }
        let command = source.replacingOccurrences(
            of: #"\s*\n\s*"#,
            with: " ↳ ",
            options: .regularExpression
        )
        if containsSensitiveCommandData(command) {
            return "\(commandProgram(command)) [민감 인자 숨김]"
        }
        return shortened(command, limit: 280)
    }

    private static func containsSensitiveCommandData(
        _ command: String
    ) -> Bool {
        let patterns = [
            #"(?:api[_-]?key|token|password|passwd|secret|authorization|cookie|bearer)"#,
            #"\b(?:sk|rk|pk)-[a-z0-9_-]{8,}"#,
            #"://[^/\s:@]+:[^@\s/]+@"#,
        ]
        return patterns.contains { pattern in
            command.range(
                of: pattern,
                options: [.regularExpression, .caseInsensitive]
            ) != nil
        }
    }

    private static func commandProgram(_ command: String) -> String {
        let assignmentPattern = #"^[A-Za-z_][A-Za-z0-9_]*="#
        return command.split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .first {
                $0.range(
                    of: assignmentPattern,
                    options: .regularExpression
                ) == nil
            } ?? "명령"
    }

    private static func compactPath(_ path: String) -> String {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        guard normalized.count > 96 else {
            return normalized
        }
        let components = normalized.split(separator: "/")
        guard components.count > 3 else {
            return "…" + String(normalized.suffix(92))
        }
        return "…/" + components.suffix(3).joined(separator: "/")
    }

    private static func fileChangeLabel(_ value: Any?) -> String {
        switch cleanText(value)?.lowercased() {
        case "add", "create":
            return "추가"
        case "delete", "remove":
            return "삭제"
        case "move", "rename":
            return "이동"
        default:
            return "수정"
        }
    }

    private static func integerValue(_ value: Any?) -> Int? {
        if let value = value as? Int {
            return value
        }
        if let value = value as? NSNumber {
            return value.intValue
        }
        if let value = value as? String {
            return Int(value)
        }
        return nil
    }

    private static func cleanText(_ value: Any?) -> String? {
        guard let value = value as? String else {
            return nil
        }
        let text = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func shortened(_ value: String, limit: Int) -> String {
        guard value.count > limit else {
            return value
        }
        return String(value.prefix(limit - 1)) + "…"
    }

    private static func reasoningText(_ value: Any?) -> String? {
        let source: String?
        if let value = value as? String {
            source = value
        } else if let values = value as? [Any] {
            let parts = values.compactMap(reasoningText)
            source = parts.isEmpty ? nil : parts.joined(separator: "\n")
        } else if let value = value as? [String: Any] {
            source = reasoningText(
                value["text"]
                    ?? value["content"]
                    ?? value["reasoning"]
                    ?? value["summary"]
            )
        } else {
            source = nil
        }
        guard let source else {
            return nil
        }
        let text = source.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !text.isEmpty else {
            return nil
        }
        return shortened(text, limit: 6_000)
    }

    private static func concise(_ value: Any?) -> String? {
        guard let text = value as? String else {
            return nil
        }
        let lines = text
            .replacingOccurrences(of: "\r\n", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            .filter { !$0.isEmpty }
        guard !lines.isEmpty else {
            return nil
        }

        let joined = lines.prefix(4).joined(separator: "\n")
        guard joined.count > 220 else {
            return joined
        }
        return String(joined.prefix(219)) + "…"
    }
}
