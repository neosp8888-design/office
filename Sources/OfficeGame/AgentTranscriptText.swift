// 이 파일은 Codex와 Claude 전사에서 공유하는 응답 본문 정리 규칙을 담는다.

import Foundation

enum AgentTranscriptText {
    /// 활동으로 승격된 공개 메시지를 누적 응답에서 제거해 중복 표시를 막는다.
    static func responseAfterRemovingPromotedMessages(
        _ response: String,
        promotedMessages: [String]
    ) -> String {
        var remaining = response
        var removedPrefixCount = 0
        for message in promotedMessages {
            if remaining == message {
                return ""
            }
            // 저장된 옛 턴에는 [OFFICE_SOURCES] 같은 기계 블록이 붙은 원문이
            // 메시지 활동으로 남아 있고, 응답에는 그 블록이 빠져 있다.
            // 이미 보여 준 메시지가 남은 응답을 통째로 품고 있으면
            // 같은 답을 다시 쓰지 않는다.
            if !remaining.isEmpty, message.hasPrefix(remaining) {
                return ""
            }

            let prefix = message + "\n\n"
            guard remaining.hasPrefix(prefix) else {
                break
            }
            remaining.removeFirst(prefix.count)
            removedPrefixCount += 1
        }
        if removedPrefixCount > 0 {
            return remaining
        }

        for startIndex in promotedMessages.indices.reversed() {
            let knownSuffix = promotedMessages[startIndex...]
                .joined(separator: "\n\n")
            if response == knownSuffix {
                return ""
            }
            let prefix = knownSuffix + "\n\n"
            if response.hasPrefix(prefix) {
                return String(response.dropFirst(prefix.count))
            }
        }
        return remaining
    }

    /// 남은 응답이 생성 이미지 미리보기뿐이면 직전 메시지에 이어 붙인다.
    static func isGeneratedImagePreviewSuffix(_ text: String) -> Bool {
        let blocks = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !blocks.isEmpty && blocks.allSatisfy { block in
            block.hasPrefix("[![생성 이미지 ")
                && block.contains("](<file:")
                && block.hasSuffix(")")
        }
    }
}
