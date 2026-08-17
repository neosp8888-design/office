// 이 파일은 CLI 에이전트의 일반 응답과 사용자 확인 질문을 공통 형식으로 구분한다.

import Foundation

public struct AgentResponseEnvelope: Equatable, Sendable {
    public let text: String
    public let needsInput: Bool

    public init(text: String, needsInput: Bool) {
        self.text = text
        self.needsInput = needsInput
    }
}

public enum AgentResponseProtocol {
    public static let inputMarker = "[NEED_INPUT]"

    public static func decode(_ text: String) -> AgentResponseEnvelope {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        guard
            let markerIndex = lines.firstIndex(where: {
                !$0.trimmingCharacters(in: .whitespaces).isEmpty
            }),
            lines[markerIndex].trimmingCharacters(in: .whitespaces)
                == inputMarker,
            markerIndex + 1 < lines.endIndex
        else {
            return AgentResponseEnvelope(text: text, needsInput: false)
        }

        let question = lines[(markerIndex + 1)...]
            .joined(separator: "\n")
        guard !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            return AgentResponseEnvelope(text: text, needsInput: false)
        }
        return AgentResponseEnvelope(text: question, needsInput: true)
    }
}
