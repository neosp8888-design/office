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

    public static let instruction = """
    사용자 판단이 반드시 필요해 더 진행할 수 없을 때만 최종 응답을 정확히 다음 형식으로 작성한다.
    [NEED_INPUT]
    사용자에게 보여줄 질문 원문
    표식 다음에는 질문과 판단에 필요한 선택지만 작성한다. 사용자 확인 없이 할 수 있는 작업은 먼저 진행한다.
    """

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
