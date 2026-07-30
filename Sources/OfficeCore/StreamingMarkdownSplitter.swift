// 이 파일은 스트리밍 중인 Markdown을 확정 구간, 작성 중 블록, 미완성 줄로 나눈다.

import Foundation

public struct StreamingMarkdownSegments: Equatable, Sendable {
    /// 빈 줄로 끝나 더 바뀌지 않는 앞부분. 한 번 렌더링하면 다시 파싱하지 않는다.
    public let settledMarkdown: String
    /// 지금 작성 중인 블록을 추측 마감한 Markdown. 줄이 늘 때만 바뀐다.
    public let activeMarkdown: String
    /// 개행이 아직 오지 않은 마지막 조각. 평문으로 타자 출력한다.
    public let openLine: String

    public init(
        settledMarkdown: String,
        activeMarkdown: String,
        openLine: String
    ) {
        self.settledMarkdown = settledMarkdown
        self.activeMarkdown = activeMarkdown
        self.openLine = openLine
    }
}

public enum StreamingMarkdownSplitter {
    public static func split(_ source: String) -> StreamingMarkdownSegments {
        let (completedText, openLine) = separateOpenLine(source)
        let lines = completedText.isEmpty
            ? []
            : completedText.components(separatedBy: "\n")
        let settledLineCount = settledLineCount(of: lines)

        let settled = lines.prefix(settledLineCount)
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let activeLines = Array(lines.dropFirst(settledLineCount))

        return StreamingMarkdownSegments(
            settledMarkdown: settled,
            activeMarkdown: speculativelyClosed(activeLines),
            openLine: openLine
        )
    }

    /// 개행으로 끝나지 않은 마지막 조각은 아직 문법을 판단할 수 없다.
    private static func separateOpenLine(
        _ source: String
    ) -> (completed: String, openLine: String) {
        guard let lastNewline = source.lastIndex(of: "\n") else {
            return ("", source)
        }
        return (
            String(source[..<lastNewline]),
            String(source[source.index(after: lastNewline)...])
        )
    }

    /// 코드 블록 밖의 마지막 빈 줄까지를 더 바뀌지 않는 구간으로 본다.
    private static func settledLineCount(of lines: [String]) -> Int {
        var count = 0
        var fenceMarker: String?

        for (index, line) in lines.enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let marker = fenceMarker {
                if trimmed.hasPrefix(marker) {
                    fenceMarker = nil
                }
                continue
            }

            if let marker = openingFenceMarker(trimmed) {
                fenceMarker = marker
                continue
            }

            if trimmed.isEmpty {
                count = index + 1
            }
        }
        return count
    }

    /// 열린 코드 펜스만 가상으로 닫아 작성 중 블록도 Markdown으로 렌더링한다.
    private static func speculativelyClosed(_ lines: [String]) -> String {
        var fenceMarker: String?

        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            if let marker = fenceMarker {
                if trimmed.hasPrefix(marker) {
                    fenceMarker = nil
                }
                continue
            }
            if let marker = openingFenceMarker(trimmed) {
                fenceMarker = marker
            }
        }

        let joined = lines.joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !joined.isEmpty else {
            return ""
        }
        guard let marker = fenceMarker else {
            return joined
        }
        return joined + "\n" + marker
    }

    private static func openingFenceMarker(_ trimmed: String) -> String? {
        for marker in ["```", "~~~"] where trimmed.hasPrefix(marker) {
            return marker
        }
        return nil
    }
}
