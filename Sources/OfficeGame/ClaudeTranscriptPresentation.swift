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

/// 도구 그룹 한 칸의 갈래다. 편집과 계획은 별도 항목이라 여기에 오지 않는다.
enum ClaudeToolGroupKind: String, Equatable, Hashable {
    case shell
    case read
    case search
    case web
    case delegate
    case other

    init(family: ClaudeToolFamily) {
        switch family {
        case .shell:
            self = .shell
        case .read:
            self = .read
        case .search:
            self = .search
        case .web:
            self = .web
        case .delegate:
            self = .delegate
        case .edit, .plan, .other:
            self = .other
        }
    }
}

/// 타임라인에 놓이는 한 덩어리다.
enum ClaudeTranscriptEntry: Identifiable, Equatable {
    case thoughts(ClaudeThoughtRun)
    case tools(ClaudeToolRun)
    case edits(ClaudeEditRun)
    case plan(ClaudePlanBoard)
    case message(ClaudeTranscriptMessage)

    var id: String {
        switch self {
        case .thoughts(let run):
            run.id
        case .tools(let run):
            run.id
        case .edits(let run):
            run.id
        case .plan(let board):
            board.id
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

    /// 스트림 시작만 알리는 자리표시자다. 원문이 끝내 오지 않는 경우도 있다.
    static let placeholderText = "추론 중"

    /// 보여줄 원문이 없으면 카드로 만들지 않는다.
    static func hasContent(_ activity: LiveFeedActivity) -> Bool {
        guard activity.kind == "thinking" else {
            return false
        }
        let text = activity.text.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return !text.isEmpty && text != placeholderText
    }
}

/// 한 대화 구간의 추론을 한 칸으로 묶는다. 최신 추론만 원문 그대로 펼쳐 둔다.
struct ClaudeThoughtRun: Identifiable, Equatable {
    let thoughts: [ClaudeThought]

    var id: String { "thoughts:\(thoughts.first?.activityID ?? "empty")" }

    var isRunning: Bool {
        thoughts.contains { $0.isRunning }
    }

    var latestThought: ClaudeThought? {
        thoughts.last
    }

    func visibleHistoryThoughts(
        showsAll: Bool,
        limit: Int
    ) -> [ClaudeThought] {
        let history = thoughts.dropLast()
        guard !showsAll, history.count > limit else {
            return Array(history)
        }
        return Array(history.suffix(limit))
    }

    func hiddenHistoryThoughtCount(limit: Int) -> Int {
        max(0, thoughts.count - 1 - limit)
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
    let kind: ClaudeToolGroupKind
    let steps: [ClaudeToolStep]

    var id: String {
        "tools:\(kind.rawValue):\(steps.first?.activityID ?? "empty")"
    }

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

    var latestStep: ClaudeToolStep? {
        steps.last
    }

    func visibleHistorySteps(
        showsAll: Bool,
        limit: Int
    ) -> [ClaudeToolStep] {
        let history = steps.dropLast()
        guard !showsAll, history.count > limit else {
            return Array(history)
        }
        return Array(history.suffix(limit))
    }

    func hiddenHistoryStepCount(limit: Int) -> Int {
        max(0, steps.count - 1 - limit)
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

/// Claude 턴 하나를 발생 순서대로 재구성한 결과다.
struct ClaudeTranscriptPresentation: Equatable {
    let entries: [ClaudeTranscriptEntry]
    let showsWaiting: Bool
    /// 글자 단위로 계속 늘어나는 마지막 응답 메시지다.
    let streamingMessageID: String?

    /// 버퍼에 모으는 동안 갈래별 자리를 가리키는 값이다.
    private enum GroupSlot: Hashable {
        case thoughts
        case tools(ClaudeToolGroupKind)
        case edits
    }

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
        var slotOrder: [GroupSlot] = []
        var thoughtBuffer: [ClaudeThought] = []
        var toolBuffers: [ClaudeToolGroupKind: [ClaudeToolStep]] = [:]
        var editBuffer: [ClaudeToolStep] = []

        // 같은 갈래는 한 칸에 모으되 처음 등장한 순서를 유지한다.
        func reserve(_ slot: GroupSlot) {
            guard !slotOrder.contains(slot) else {
                return
            }
            slotOrder.append(slot)
        }

        func flushGroups() {
            for slot in slotOrder {
                switch slot {
                case .thoughts:
                    guard !thoughtBuffer.isEmpty else {
                        continue
                    }
                    entries.append(
                        .thoughts(ClaudeThoughtRun(thoughts: thoughtBuffer))
                    )
                case .tools(let kind):
                    guard let steps = toolBuffers[kind], !steps.isEmpty else {
                        continue
                    }
                    entries.append(
                        .tools(ClaudeToolRun(kind: kind, steps: steps))
                    )
                case .edits:
                    guard !editBuffer.isEmpty else {
                        continue
                    }
                    entries.append(.edits(ClaudeEditRun(steps: editBuffer)))
                }
            }
            slotOrder.removeAll(keepingCapacity: true)
            thoughtBuffer.removeAll(keepingCapacity: true)
            toolBuffers.removeAll(keepingCapacity: true)
            editBuffer.removeAll(keepingCapacity: true)
        }

        for activity in activities {
            switch activity.kind {
            case "thinking":
                // 원문 없는 자리표시자는 아래쪽 `생각 중` 표시가 대신한다.
                guard ClaudeThought.hasContent(activity) else {
                    continue
                }
                reserve(.thoughts)
                thoughtBuffer.append(
                    ClaudeThought(
                        activityID: activity.id,
                        text: activity.text,
                        occurredAt: activity.occurredAt,
                        isRunning: activity.status == .running
                    )
                )
            case "message":
                flushGroups()
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
                    flushGroups()
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
                    reserve(.edits)
                    editBuffer.append(step)
                default:
                    let kind = ClaudeToolGroupKind(family: call.family)
                    reserve(.tools(kind))
                    toolBuffers[kind, default: []].append(step)
                }
            }
        }
        flushGroups()

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

        return ClaudeTranscriptPresentation(
            entries: entries,
            // 자리표시자 추론만 돌고 있으면 화면에 남는 카드가 없으므로
            // 아래쪽 `생각 중`으로 진행 중임을 알린다.
            showsWaiting: isRunning
                && streamingMessageID == nil
                && !activities.contains { activity in
                    activity.status == .running
                        && !(
                            activity.kind == "thinking"
                                && !ClaudeThought.hasContent(activity)
                        )
                },
            streamingMessageID: streamingMessageID
        )
    }
}
