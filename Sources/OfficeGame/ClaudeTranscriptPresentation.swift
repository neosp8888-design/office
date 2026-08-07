// 이 파일은 Claude Code 활동 기록을 도구 중심 타임라인 항목으로 해석한다.

import Foundation

/// Claude 활동 텍스트에서 복원한 도구 호출 한 건이다.
struct ClaudeToolCall: Equatable {
    let name: String
    let detail: String
    let planSteps: [ClaudePlanStep]

    private static let prefix = "도구 · "
    private static let separator = " · "

    static func parse(_ activity: LiveFeedActivity) -> ClaudeToolCall {
        let lines = activity.text.components(separatedBy: "\n")
        let header = lines.first ?? ""
        var name = ""
        var detail = ""

        if header.hasPrefix(prefix) {
            let body = String(header.dropFirst(prefix.count))
            if let range = body.range(of: separator) {
                name = String(body[..<range.lowerBound])
                detail = String(body[range.upperBound...])
            } else {
                name = body
            }
        } else if activity.kind == "command" {
            name = "Bash"
            detail = header
        } else {
            detail = header
        }

        return ClaudeToolCall(
            name: name,
            detail: detail,
            planSteps: ClaudePlanStep.parse(Array(lines.dropFirst()))
        )
    }

    /// MCP 도구는 이름이 길어 마지막 구간만 배지에 쓴다.
    var displayName: String {
        guard !name.isEmpty else {
            return "도구"
        }
        guard name.hasPrefix("mcp__") else {
            return name
        }
        return name.components(separatedBy: "__").last ?? name
    }

    var family: ClaudeToolFamily {
        ClaudeToolFamily.of(name)
    }
}

/// 도구를 화면 표현이 같은 갈래로 묶는다.
enum ClaudeToolFamily: Equatable {
    case shell
    case read
    case edit
    case search
    case web
    case plan
    case delegate
    case other

    static func of(_ name: String) -> ClaudeToolFamily {
        switch name.lowercased() {
        case "bash", "shell", "terminal", "bashoutput", "killshell":
            .shell
        case "read", "notebookread":
            .read
        case "edit", "write", "multiedit", "notebookedit":
            .edit
        case "grep", "glob":
            .search
        case "websearch", "webfetch":
            .web
        case "todowrite":
            .plan
        case "task", "agent":
            .delegate
        default:
            .other
        }
    }
}

/// TodoWrite 한 줄에 해당하는 계획 단계다.
struct ClaudePlanStep: Equatable, Identifiable {
    enum State: Equatable {
        case done
        case active
        case todo
    }

    let id: Int
    let state: State
    let text: String

    static func parse(_ lines: [String]) -> [ClaudePlanStep] {
        lines.enumerated().compactMap { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.count > 3, trimmed.hasPrefix("[") else {
                return nil
            }
            let marker = trimmed[trimmed.index(trimmed.startIndex, offsetBy: 1)]
            guard trimmed[trimmed.index(trimmed.startIndex, offsetBy: 2)] == "]"
            else {
                return nil
            }
            let state: State = switch marker {
            case "x", "X":
                .done
            case "~", ">":
                .active
            default:
                .todo
            }
            return ClaudePlanStep(
                id: index,
                state: state,
                text: trimmed
                    .dropFirst(3)
                    .trimmingCharacters(in: .whitespaces)
            )
        }
    }
}

/// 타임라인에 놓이는 한 덩어리다.
enum ClaudeTranscriptEntry: Identifiable, Equatable {
    case thought(ClaudeThought)
    case tools(ClaudeToolRun)
    case edits(ClaudeEditRun)
    case plan(ClaudePlanBoard)
    case messageHistory(ClaudeMessageHistory)
    case message(ClaudeTranscriptMessage)

    var id: String {
        switch self {
        case .thought(let thought):
            thought.id
        case .tools(let run):
            run.id
        case .edits(let run):
            run.id
        case .plan(let board):
            board.id
        case .messageHistory(let history):
            history.id
        case .message(let message):
            message.id
        }
    }
}

struct ClaudeThought: Identifiable, Equatable {
    let activityID: String
    let text: String
    let occurredAt: Date
    let isRunning: Bool

    var id: String { "thought:\(activityID)" }

    /// 스트림 시작만 있고 원문이 아직 없는 상태다.
    var isPlaceholder: Bool {
        isRunning && text == "추론 중"
    }
}

struct ClaudeToolStep: Identifiable, Equatable {
    let activityID: String
    let call: ClaudeToolCall
    let status: LiveFeedActivityStatus
    let occurredAt: Date

    var id: String { activityID }
}

struct ClaudeToolRun: Identifiable, Equatable {
    let steps: [ClaudeToolStep]

    var id: String { "tools:\(steps.first?.activityID ?? "empty")" }

    var isRunning: Bool {
        steps.contains { $0.status == .running }
    }

    /// 사용한 도구 이름을 실제 호출 순서대로 요약한다.
    var title: String {
        var order: [String] = []
        var counts: [String: Int] = [:]
        for step in steps {
            let name = step.call.displayName
            if counts[name] == nil {
                order.append(name)
            }
            counts[name, default: 0] += 1
        }
        let visible = order.prefix(3).map { name in
            let count = counts[name] ?? 0
            return count > 1 ? "\(name) \(count)" : name
        }
        let remainder = order.count - visible.count
        return visible.joined(separator: " · ")
            + (remainder > 0 ? " 외 \(remainder)종" : "")
    }

    func visibleSteps(showsAll: Bool, limit: Int) -> [ClaudeToolStep] {
        guard !showsAll, steps.count > limit else {
            return steps
        }
        return Array(steps.suffix(limit))
    }

    func hiddenStepCount(limit: Int) -> Int {
        max(0, steps.count - limit)
    }
}

struct ClaudeEditRun: Identifiable, Equatable {
    let steps: [ClaudeToolStep]

    var id: String { "edits:\(steps.first?.activityID ?? "empty")" }

    var status: LiveFeedActivityStatus {
        if steps.contains(where: { $0.status == .failed }) {
            return .failed
        }
        if steps.contains(where: { $0.status == .running }) {
            return .running
        }
        return .completed
    }

    /// 같은 파일을 여러 번 고쳐도 한 건으로 센다.
    var fileCount: Int {
        Set(steps.map(\.call.detail).filter { !$0.isEmpty }).count
    }

    var title: String {
        switch status {
        case .running:
            "파일을 편집하는 중"
        case .failed:
            "파일 편집에 실패했습니다"
        case .completed:
            fileCount > 0
                ? "파일 \(fileCount)개를 편집했습니다"
                : "파일을 편집했습니다"
        }
    }

    var copyText: String {
        ([title] + steps.map { step in
            step.call.detail.isEmpty
                ? step.call.displayName
                : "\(step.call.displayName) \(step.call.detail)"
        })
            .joined(separator: "\n")
    }
}

struct ClaudePlanBoard: Identifiable, Equatable {
    let activityID: String
    let steps: [ClaudePlanStep]
    let occurredAt: Date

    var id: String { "plan:\(activityID)" }

    var doneCount: Int {
        steps.filter { $0.state == .done }.count
    }

    var activeStep: ClaudePlanStep? {
        steps.first { $0.state == .active }
    }
}

struct ClaudeTranscriptMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let occurredAt: Date
}

/// 현재 또는 최종 대화보다 앞선 공개 대화를 한 카드로 접는다.
struct ClaudeMessageHistory: Identifiable, Equatable {
    let messages: [ClaudeTranscriptMessage]

    var id: String {
        "message-history:\(messages.first?.id ?? "empty")"
    }
}

/// Claude 턴 하나를 발생 순서대로 재구성한 결과다.
struct ClaudeTranscriptPresentation: Equatable {
    let entries: [ClaudeTranscriptEntry]
    let showsWaiting: Bool
    /// 글자 단위로 계속 늘어나는 마지막 응답 메시지다.
    let streamingMessageID: String?

    var latestMessage: ClaudeTranscriptMessage? {
        for entry in entries.reversed() {
            if case .message(let message) = entry {
                return message
            }
        }
        return nil
    }

    static func make(
        turnID: String,
        activities: [LiveFeedActivity],
        response: String,
        responseUpdatedAt: Date,
        isRunning: Bool
    ) -> ClaudeTranscriptPresentation {
        var entries: [ClaudeTranscriptEntry] = []
        var toolBuffer: [ClaudeToolStep] = []
        var editBuffer: [ClaudeToolStep] = []

        func flushTools() {
            guard !toolBuffer.isEmpty else {
                return
            }
            entries.append(.tools(ClaudeToolRun(steps: toolBuffer)))
            toolBuffer.removeAll(keepingCapacity: true)
        }

        func flushEdits() {
            guard !editBuffer.isEmpty else {
                return
            }
            entries.append(.edits(ClaudeEditRun(steps: editBuffer)))
            editBuffer.removeAll(keepingCapacity: true)
        }

        func flushOperations() {
            flushTools()
            flushEdits()
        }

        for activity in activities {
            switch activity.kind {
            case "thinking":
                flushOperations()
                entries.append(
                    .thought(
                        ClaudeThought(
                            activityID: activity.id,
                            text: activity.text,
                            occurredAt: activity.occurredAt,
                            isRunning: activity.status == .running
                        )
                    )
                )
            case "message":
                flushOperations()
                entries.append(
                    .message(
                        ClaudeTranscriptMessage(
                            id: "activity:\(activity.id)",
                            text: activity.text,
                            occurredAt: activity.occurredAt
                        )
                    )
                )
            default:
                let call = ClaudeToolCall.parse(activity)
                let step = ClaudeToolStep(
                    activityID: activity.id,
                    call: call,
                    status: activity.status,
                    occurredAt: activity.occurredAt
                )
                switch call.family {
                case .plan:
                    flushOperations()
                    // 계획은 갱신되는 하나의 보드이므로 최신 위치에만 남긴다.
                    entries.removeAll { entry in
                        if case .plan = entry {
                            return true
                        }
                        return false
                    }
                    entries.append(
                        .plan(
                            ClaudePlanBoard(
                                activityID: activity.id,
                                steps: call.planSteps,
                                occurredAt: activity.occurredAt
                            )
                        )
                    )
                case .edit:
                    flushTools()
                    editBuffer.append(step)
                default:
                    flushEdits()
                    toolBuffer.append(step)
                }
            }
        }
        flushOperations()

        let promotedMessages = activities
            .filter { $0.kind == "message" }
            .map(\.text)
        let remainingResponse = AgentTranscriptText
            .responseAfterRemovingPromotedMessages(
                response,
                promotedMessages: promotedMessages
            )

        var streamingMessageID: String?
        if
            AgentTranscriptText
                .isGeneratedImagePreviewSuffix(remainingResponse),
            let messageIndex = entries.lastIndex(where: { entry in
                if case .message = entry {
                    return true
                }
                return false
            }),
            case .message(let message) = entries[messageIndex]
        {
            entries[messageIndex] = .message(
                ClaudeTranscriptMessage(
                    id: message.id,
                    text: message.text + "\n\n" + remainingResponse,
                    occurredAt: responseUpdatedAt
                )
            )
        } else if !remainingResponse.isEmpty {
            let id = "response:\(turnID)"
            entries.append(
                .message(
                    ClaudeTranscriptMessage(
                        id: id,
                        text: remainingResponse,
                        occurredAt: responseUpdatedAt
                    )
                )
            )
            streamingMessageID = isRunning ? id : nil
        }

        entries = groupingEarlierMessages(in: entries)

        return ClaudeTranscriptPresentation(
            entries: entries,
            showsWaiting: isRunning
                && streamingMessageID == nil
                && !activities.contains { $0.status == .running },
            streamingMessageID: streamingMessageID
        )
    }

    private static func groupingEarlierMessages(
        in entries: [ClaudeTranscriptEntry]
    ) -> [ClaudeTranscriptEntry] {
        let messageIndices = entries.indices.filter { index in
            if case .message = entries[index] {
                return true
            }
            return false
        }
        guard messageIndices.count > 1 else {
            return entries
        }

        let earlierIndices = Array(messageIndices.dropLast())
        let earlierMessages = earlierIndices.compactMap { index in
            if case .message(let message) = entries[index] {
                return message
            }
            return nil
        }
        guard let insertionIndex = earlierIndices.first else {
            return entries
        }

        let earlierIndexSet = Set(earlierIndices)
        var groupedEntries: [ClaudeTranscriptEntry] = []
        groupedEntries.reserveCapacity(entries.count - earlierIndices.count + 1)

        for index in entries.indices {
            if index == insertionIndex {
                groupedEntries.append(
                    .messageHistory(
                        ClaudeMessageHistory(messages: earlierMessages)
                    )
                )
            }
            if earlierIndexSet.contains(index) {
                continue
            }
            groupedEntries.append(entries[index])
        }
        return groupedEntries
    }
}
