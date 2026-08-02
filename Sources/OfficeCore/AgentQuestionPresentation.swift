// 이 파일은 사용자 확인 질문의 본문과 선택지를 UI 표시용 구조로 분리한다.

import Foundation

public struct AgentQuestionChoice: Equatable, Sendable {
    public let title: String
    public let response: String

    public init(title: String, response: String) {
        self.title = title
        self.response = response
    }
}

public struct AgentQuestionPresentation: Equatable, Sendable {
    public let question: String
    public let choices: [AgentQuestionChoice]

    public init(text: String) {
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let lines = normalized.components(separatedBy: "\n")
        guard let block = Self.lastChoiceBlock(in: lines) else {
            question = text
            choices = []
            return
        }

        let prefix = lines[..<block.range.lowerBound]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = lines[block.range.upperBound...]
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let parsedQuestion = [prefix, suffix]
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        guard !parsedQuestion.isEmpty else {
            question = text
            choices = []
            return
        }

        question = parsedQuestion
        choices = block.choices.map { choice in
            AgentQuestionChoice(
                title: Self.plainText(from: choice.content),
                response: choice.response
            )
        }
    }

    private static func lastChoiceBlock(
        in lines: [String]
    ) -> (range: Range<Int>, choices: [ParsedChoice])? {
        var lastBlock: (Range<Int>, [ParsedChoice])?
        var start = lines.startIndex

        while start < lines.endIndex {
            guard ParsedChoice(line: lines[start]) != nil else {
                start += 1
                continue
            }

            var end = start
            var candidates: [ParsedChoice] = []
            while
                end < lines.endIndex,
                let choice = ParsedChoice(line: lines[end])
            {
                candidates.append(choice)
                end += 1
            }
            if isValidChoiceBlock(candidates) {
                lastBlock = (start..<end, candidates)
            }
            start = end
        }
        return lastBlock
    }

    private static func isValidChoiceBlock(
        _ choices: [ParsedChoice]
    ) -> Bool {
        guard let first = choices.first else {
            return false
        }
        switch first.marker {
        case .numbered:
            return choices.enumerated().allSatisfy { offset, choice in
                choice.marker == .numbered(offset + 1)
            }
        case .bullet:
            return choices.count >= 2
                && choices.allSatisfy { $0.marker == .bullet }
        }
    }

    private static func plainText(from markdown: String) -> String {
        guard let attributed = try? AttributedString(markdown: markdown) else {
            return markdown
        }
        return String(attributed.characters)
    }
}

private struct ParsedChoice {
    enum Marker: Equatable {
        case numbered(Int)
        case bullet
    }

    let marker: Marker
    let content: String
    let response: String

    init?(line: String) {
        let value = line.trimmingCharacters(in: .whitespaces)
        guard !value.isEmpty else {
            return nil
        }

        if let numbered = Self.numberedChoice(in: value) {
            marker = .numbered(numbered.number)
            content = numbered.content
            response = value
            return
        }

        guard
            value.count >= 2,
            ["-", "*", "•"].contains(String(value.first!)),
            value[value.index(after: value.startIndex)].isWhitespace
        else {
            return nil
        }
        let contentStart = value.index(after: value.startIndex)
        let parsedContent = value[contentStart...]
            .trimmingCharacters(in: .whitespaces)
        guard !parsedContent.isEmpty else {
            return nil
        }
        marker = .bullet
        content = parsedContent
        response = value
    }

    private static func numberedChoice(
        in value: String
    ) -> (number: Int, content: String)? {
        var delimiterIndex = value.startIndex
        while
            delimiterIndex < value.endIndex,
            value[delimiterIndex].isNumber
        {
            delimiterIndex = value.index(after: delimiterIndex)
        }
        guard
            delimiterIndex > value.startIndex,
            delimiterIndex < value.endIndex,
            value[delimiterIndex] == "." || value[delimiterIndex] == ")"
        else {
            return nil
        }

        let whitespaceIndex = value.index(after: delimiterIndex)
        guard
            whitespaceIndex < value.endIndex,
            value[whitespaceIndex].isWhitespace,
            let number = Int(value[..<delimiterIndex])
        else {
            return nil
        }
        let parsedContent = value[whitespaceIndex...]
            .trimmingCharacters(in: .whitespaces)
        guard !parsedContent.isEmpty else {
            return nil
        }
        return (number, parsedContent)
    }
}
