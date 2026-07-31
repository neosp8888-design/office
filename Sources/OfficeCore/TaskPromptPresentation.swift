// 이 파일은 실행용 업무 문구에서 화면에 표시할 본문과 첨부 파일 정보를 안전하게 분리한다.

import Foundation

public struct TaskPromptAttachment: Equatable, Sendable {
    public let name: String
    public let path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

public struct TaskPromptPresentation: Equatable, Sendable {
    public let text: String
    public let attachments: [TaskPromptAttachment]

    public init(prompt: String) {
        let normalizedPrompt = prompt.replacingOccurrences(
            of: "\r\n",
            with: "\n"
        )
        guard
            let markerRange = normalizedPrompt.range(
                of: Self.attachmentMarker,
                options: .backwards
            )
        else {
            text = prompt
            attachments = []
            return
        }

        let attachmentSource = String(
            normalizedPrompt[markerRange.upperBound...]
        )
        let attachmentLines = attachmentSource
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
        let parsedAttachments = attachmentLines.compactMap(
            Self.parseAttachmentLine
        )

        guard
            !attachmentLines.isEmpty,
            parsedAttachments.count == attachmentLines.count
        else {
            text = prompt
            attachments = []
            return
        }

        text = String(normalizedPrompt[..<markerRange.lowerBound])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        attachments = parsedAttachments
    }

    public static func canonicalPrompt(
        text: String,
        attachmentPaths: [String]
    ) -> String {
        var seenPaths: Set<String> = []
        let paths = attachmentPaths.compactMap { source -> String? in
            let path = source.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            guard !path.isEmpty, seenPaths.insert(path).inserted else {
                return nil
            }
            return path
        }
        let prompt = text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        let effectivePrompt = prompt.isEmpty
            ? "첨부 파일을 확인해줘."
            : prompt
        guard !paths.isEmpty else {
            return effectivePrompt
        }

        let references = paths.map { path in
            let name = URL(fileURLWithPath: path).lastPathComponent
            return "- \(jsonString(name)): \(jsonString(path))"
        }
        return effectivePrompt
            + attachmentMarker
            + references.joined(separator: "\n")
    }

    private static let attachmentMarker = """


    첨부 파일
    다음 로컬 파일을 업무 자료로 사용하세요.

    """

    private static func parseAttachmentLine(
        _ source: String
    ) -> TaskPromptAttachment? {
        let line = source.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard line.first == "-" else {
            return nil
        }

        var index = line.index(after: line.startIndex)
        skipWhitespace(in: line, index: &index)
        guard
            let (name, nameEndIndex) = decodeJSONString(
                in: line,
                from: index
            )
        else {
            return nil
        }

        index = nameEndIndex
        skipWhitespace(in: line, index: &index)
        guard index < line.endIndex, line[index] == ":" else {
            return nil
        }

        index = line.index(after: index)
        skipWhitespace(in: line, index: &index)
        guard
            let (path, pathEndIndex) = decodeJSONString(
                in: line,
                from: index
            )
        else {
            return nil
        }

        index = pathEndIndex
        skipWhitespace(in: line, index: &index)
        guard index == line.endIndex else {
            return nil
        }
        return TaskPromptAttachment(name: name, path: path)
    }

    private static func decodeJSONString(
        in source: String,
        from startIndex: String.Index
    ) -> (String, String.Index)? {
        guard
            startIndex < source.endIndex,
            source[startIndex] == "\""
        else {
            return nil
        }

        var index = source.index(after: startIndex)
        var isEscaped = false
        while index < source.endIndex {
            let character = source[index]
            if isEscaped {
                isEscaped = false
            } else if character == "\\" {
                isEscaped = true
            } else if character == "\"" {
                let literal = String(source[startIndex...index])
                guard
                    let data = literal.data(using: .utf8),
                    let decoded = try? JSONDecoder().decode(
                        String.self,
                        from: data
                    )
                else {
                    return nil
                }
                return (decoded, source.index(after: index))
            }
            index = source.index(after: index)
        }
        return nil
    }

    private static func skipWhitespace(
        in source: String,
        index: inout String.Index
    ) {
        while
            index < source.endIndex,
            source[index].isWhitespace
        {
            index = source.index(after: index)
        }
    }

    private static func jsonString(_ value: String) -> String {
        guard
            let data = try? JSONEncoder().encode(value),
            let encoded = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return encoded
    }
}
