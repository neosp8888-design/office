// 이 파일은 Codex와 Claude의 JSONL 이벤트를 안전한 말풍선 진행 문구로 변환한다.

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
                let summary = concise(item["text"])
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
            return eventType == "item.started"
                ? "터미널 출동 🧰"
                : eventType == "item.completed"
                ? "결과 까보는 중 🔎"
                : nil
        case "file_change":
            return eventType == "item.completed"
                ? "수정본 반영 중 ✍️"
                : nil
        case "mcp_tool_call":
            return eventType == "item.started"
                ? "도구 콜하는 중 📡"
                : eventType == "item.completed"
                ? "도구 결과 체크 중 👀"
                : nil
        case "collab_tool_call":
            return eventType == "item.started"
                ? "동료 찬스 소환 중 🤝"
                : nil
        case "web_search":
            return eventType == "item.started"
                ? "자료 서치 중 🔍"
                : nil
        case "todo_list":
            return eventType == "item.started"
                ? "할 일 우선순위 픽 중 📌"
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
        if content.contains(where: { $0["type"] as? String == "tool_use" }) {
            return "도구로 뚝딱 처리 중 🛠️"
        }
        if content.contains(where: { $0["type"] as? String == "thinking" }) {
            return "각 잡고 분석 중 🧠"
        }
        return nil
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
