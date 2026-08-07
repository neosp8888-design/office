// 이 파일은 Claude 활동을 도구·편집·계획 항목으로 나누는 규칙을 검증한다.

import Foundation
import XCTest
@testable import OfficeGame

final class ClaudeTranscriptPresentationTests: XCTestCase {
    func testToolCallSplitsNameAndDetail() throws {
        let call = ClaudeToolCall.parse(
            try makeActivity(
                id: "tool-1",
                kind: "tool",
                text: "도구 · Read · /Users/example/office/Package.swift",
                status: "completed"
            )
        )

        XCTAssertEqual(call.name, "Read")
        XCTAssertEqual(call.detail, "/Users/example/office/Package.swift")
        XCTAssertEqual(call.family, .read)
    }

    func testBashDetailKeepsSeparatorsInsideCommand() throws {
        let call = ClaudeToolCall.parse(
            try makeActivity(
                id: "tool-1",
                kind: "tool",
                text: "도구 · Bash · git log --oneline · head -3",
                status: "running"
            )
        )

        XCTAssertEqual(call.name, "Bash")
        XCTAssertEqual(call.detail, "git log --oneline · head -3")
        XCTAssertEqual(call.family, .shell)
    }

    func testLegacyAndDetaillessToolsStayReadable() throws {
        let legacy = ClaudeToolCall.parse(
            try makeActivity(
                id: "tool-1",
                kind: "tool",
                text: "도구를 사용해 업무를 처리하는 중...",
                status: "running"
            )
        )
        let pending = ClaudeToolCall.parse(
            try makeActivity(
                id: "tool-2",
                kind: "tool",
                text: "도구 · Bash",
                status: "running"
            )
        )

        XCTAssertEqual(legacy.displayName, "도구")
        XCTAssertEqual(legacy.family, .other)
        XCTAssertEqual(pending.displayName, "Bash")
        XCTAssertEqual(pending.detail, "")
    }

    func testMCPToolBadgeUsesLastNameSegment() throws {
        let call = ClaudeToolCall.parse(
            try makeActivity(
                id: "tool-1",
                kind: "tool",
                text: "도구 · mcp__claude_ai_Google_Drive__search_files",
                status: "completed"
            )
        )

        XCTAssertEqual(call.displayName, "search_files")
        XCTAssertEqual(call.family, .other)
    }

    func testTimelineKeepsOrderAndSeparatesEditsFromTools() throws {
        let activities = try [
            makeActivity(
                id: "think-1",
                kind: "thinking",
                text: "먼저 구조를 확인한다.",
                status: "completed"
            ),
            makeActivity(
                id: "tool-1",
                kind: "tool",
                text: "도구 · Read · Sources/App.swift",
                status: "completed"
            ),
            makeActivity(
                id: "tool-2",
                kind: "tool",
                text: "도구 · Bash · swift build",
                status: "completed"
            ),
            makeActivity(
                id: "tool-3",
                kind: "tool",
                text: "도구 · Edit · Sources/App.swift",
                status: "completed"
            ),
            makeActivity(
                id: "tool-4",
                kind: "tool",
                text: "도구 · Write · Sources/New.swift",
                status: "completed"
            ),
            makeActivity(
                id: "tool-5",
                kind: "tool",
                text: "도구 · Bash · swift test",
                status: "running"
            ),
        ]

        let presentation = ClaudeTranscriptPresentation.make(
            turnID: "turn-1",
            activities: activities,
            response: "",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: true
        )

        XCTAssertEqual(presentation.entries.count, 4)
        guard
            case .thoughts(let thoughts) = presentation.entries[0],
            case .tools(let reads) = presentation.entries[1],
            case .tools(let commands) = presentation.entries[2],
            case .edits(let edits) = presentation.entries[3]
        else {
            return XCTFail("Claude 타임라인 순서가 다릅니다.")
        }
        XCTAssertEqual(
            thoughts.latestThought?.text,
            "먼저 구조를 확인한다."
        )
        XCTAssertEqual(reads.kind, .read)
        XCTAssertEqual(reads.steps.map(\.activityID), ["tool-1"])
        XCTAssertEqual(reads.title, "Read")
        XCTAssertEqual(commands.kind, .shell)
        XCTAssertEqual(
            commands.steps.map(\.activityID),
            ["tool-2", "tool-5"]
        )
        XCTAssertEqual(commands.title, "Bash 2")
        XCTAssertTrue(commands.isRunning)
        XCTAssertEqual(edits.steps.map(\.activityID), ["tool-3", "tool-4"])
        XCTAssertEqual(edits.fileCount, 2)
        XCTAssertEqual(edits.title, "파일 2개를 편집했습니다")
        XCTAssertFalse(presentation.showsWaiting)
    }

    func testToolGroupsSplitByKindAndResetAfterMessage() throws {
        let activities = try [
            makeActivity(
                id: "tool-1",
                kind: "tool",
                text: "도구 · Grep · struct Claude",
                status: "completed"
            ),
            makeActivity(
                id: "tool-2",
                kind: "tool",
                text: "도구 · WebFetch · https://example.com",
                status: "completed"
            ),
            makeActivity(
                id: "tool-3",
                kind: "tool",
                text: "도구 · Task · 하위 검토 위임",
                status: "completed"
            ),
            makeActivity(
                id: "message-1",
                kind: "message",
                text: "1차 정리를 마쳤습니다.",
                status: "completed"
            ),
            makeActivity(
                id: "tool-4",
                kind: "tool",
                text: "도구 · Grep · func make",
                status: "completed"
            ),
        ]

        let presentation = ClaudeTranscriptPresentation.make(
            turnID: "turn-1",
            activities: activities,
            response: "",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        XCTAssertEqual(
            presentation.entries.map(\.id),
            [
                "tools:search:tool-1",
                "tools:web:tool-2",
                "tools:delegate:tool-3",
                "activity:message-1",
                "tools:search:tool-4",
            ]
        )
    }

    func testConsecutiveThoughtsCollapseIntoOneRun() throws {
        let activities = try (0..<3).map { index in
            try makeActivity(
                id: "think-\(index)",
                kind: "thinking",
                text: "\(index)번째 추론",
                status: "completed"
            )
        }

        let presentation = ClaudeTranscriptPresentation.make(
            turnID: "turn-1",
            activities: activities,
            response: "",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        XCTAssertEqual(presentation.entries.count, 1)
        guard case .thoughts(let run) = presentation.entries[0] else {
            return XCTFail("추론 그룹이 없습니다.")
        }
        XCTAssertEqual(run.thoughts.count, 3)
        XCTAssertEqual(run.latestThought?.text, "2번째 추론")
        XCTAssertEqual(
            run.visibleHistoryThoughts(showsAll: false, limit: 20)
                .map(\.text),
            ["0번째 추론", "1번째 추론"]
        )
        XCTAssertEqual(run.hiddenHistoryThoughtCount(limit: 1), 1)
        XCTAssertEqual(
            run.visibleHistoryThoughts(showsAll: false, limit: 1)
                .map(\.text),
            ["1번째 추론"]
        )
        XCTAssertFalse(run.isRunning)
    }

    func testRepeatedToolsAreCountedInGroupTitle() throws {
        let activities = try (0..<4).map { index in
            try makeActivity(
                id: "tool-\(index)",
                kind: "tool",
                text: index == 3
                    ? "도구 · Grep · struct"
                    : "도구 · Read · Sources/File\(index).swift",
                status: "completed"
            )
        }

        let presentation = ClaudeTranscriptPresentation.make(
            turnID: "turn-1",
            activities: activities,
            response: "",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        guard
            case .tools(let reads) = presentation.entries.first,
            case .tools(let searches) = presentation.entries.last
        else {
            return XCTFail("도구 그룹이 없습니다.")
        }
        XCTAssertEqual(reads.kind, .read)
        XCTAssertEqual(reads.title, "Read 3")
        XCTAssertEqual(searches.kind, .search)
        XCTAssertEqual(searches.title, "Grep")
    }

    func testPlanBoardKeepsOnlyTheLatestChecklist() throws {
        let activities = try [
            makeActivity(
                id: "plan-1",
                kind: "tool",
                text: "도구 · TodoWrite · 0/2단계\n[~] 분석\n[ ] 구현",
                status: "completed"
            ),
            makeActivity(
                id: "tool-1",
                kind: "tool",
                text: "도구 · Read · Sources/App.swift",
                status: "completed"
            ),
            makeActivity(
                id: "plan-2",
                kind: "tool",
                text: "도구 · TodoWrite · 1/2단계\n[x] 분석\n[~] 구현",
                status: "completed"
            ),
        ]

        let presentation = ClaudeTranscriptPresentation.make(
            turnID: "turn-1",
            activities: activities,
            response: "",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        XCTAssertEqual(presentation.entries.count, 2)
        guard
            case .tools = presentation.entries[0],
            case .plan(let board) = presentation.entries[1]
        else {
            return XCTFail("계획 보드가 최신 위치에 없습니다.")
        }
        XCTAssertEqual(board.activityID, "plan-2")
        XCTAssertEqual(board.doneCount, 1)
        XCTAssertEqual(board.steps.map(\.text), ["분석", "구현"])
        XCTAssertEqual(board.activeStep?.text, "구현")
    }

    func testRunningResponseIsMarkedAsStreamingMessage() throws {
        let activity = try makeActivity(
            id: "message-1",
            kind: "message",
            text: "중간 보고입니다.",
            status: "completed"
        )

        let presentation = ClaudeTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [activity],
            response: "중간 보고입니다.\n\n이어서 작성 중",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: true
        )

        XCTAssertEqual(presentation.streamingMessageID, "response:turn-1")
        XCTAssertFalse(presentation.showsWaiting)
        guard case .message(let last) = presentation.entries.last else {
            return XCTFail("응답 메시지가 없습니다.")
        }
        XCTAssertEqual(last.text, "이어서 작성 중")
    }

    func testMessagesStayAtChronologicalPositionsBetweenWorkGroups() throws {
        let activities = try [
            makeActivity(
                id: "message-1",
                kind: "message",
                text: "첫 번째 진행 보고",
                status: "completed"
            ),
            makeActivity(
                id: "tool-1",
                kind: "tool",
                text: "도구 · Bash · swift test",
                status: "completed"
            ),
            makeActivity(
                id: "message-2",
                kind: "message",
                text: "두 번째 진행 보고",
                status: "completed"
            ),
            makeActivity(
                id: "tool-2",
                kind: "tool",
                text: "도구 · Read · Package.swift",
                status: "completed"
            ),
            makeActivity(
                id: "message-3",
                kind: "message",
                text: "최종 보고",
                status: "completed"
            ),
        ]

        let presentation = ClaudeTranscriptPresentation.make(
            turnID: "turn-1",
            activities: activities,
            response: "첫 번째 진행 보고\n\n두 번째 진행 보고\n\n최종 보고",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        XCTAssertEqual(presentation.entries.count, 5)
        guard
            case .message(let first) = presentation.entries[0],
            case .tools = presentation.entries[1],
            case .message(let second) = presentation.entries[2],
            case .tools = presentation.entries[3],
            case .message(let latest) = presentation.entries[4]
        else {
            return XCTFail("공개 대화가 실제 발생 위치에 있지 않습니다.")
        }
        XCTAssertEqual(first.text, "첫 번째 진행 보고")
        XCTAssertEqual(second.text, "두 번째 진행 보고")
        XCTAssertEqual(latest.text, "최종 보고")
        XCTAssertEqual(presentation.latestMessage, latest)
    }

    func testStreamingResponseKeepsPromotedMessageAtOriginalPosition() throws {
        let activity = try makeActivity(
            id: "message-1",
            kind: "message",
            text: "완료 전 보고",
            status: "completed"
        )

        let presentation = ClaudeTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [activity],
            response: "완료 전 보고\n\n작성 중인 최신 응답",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: true
        )

        XCTAssertEqual(presentation.entries.count, 2)
        guard
            case .message(let promoted) = presentation.entries[0],
            case .message(let latest) = presentation.entries[1]
        else {
            return XCTFail("진행 메시지와 최신 응답이 분리되지 않았습니다.")
        }
        XCTAssertEqual(promoted.text, "완료 전 보고")
        XCTAssertEqual(latest.text, "작성 중인 최신 응답")
        XCTAssertEqual(presentation.streamingMessageID, latest.id)
    }

    func testCompletedResponseIsNotStreaming() throws {
        let presentation = ClaudeTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [],
            response: "완료했습니다.",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        XCTAssertNil(presentation.streamingMessageID)
        XCTAssertFalse(presentation.showsWaiting)
    }

    func testWaitingShowsBeforeFirstActivity() {
        let presentation = ClaudeTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [],
            response: "",
            responseUpdatedAt: Date(timeIntervalSince1970: 1_000),
            isRunning: true
        )

        XCTAssertTrue(presentation.entries.isEmpty)
        XCTAssertTrue(presentation.showsWaiting)
    }

    func testRunningThinkingPlaceholderIsMarked() throws {
        let activity = try makeActivity(
            id: "think-1",
            kind: "thinking",
            text: "추론 중",
            status: "running"
        )

        let presentation = ClaudeTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [activity],
            response: "",
            responseUpdatedAt: Date(timeIntervalSince1970: 1_000),
            isRunning: true
        )

        guard
            case .thoughts(let run) = presentation.entries.first,
            let thought = run.latestThought
        else {
            return XCTFail("사고 항목이 없습니다.")
        }
        XCTAssertTrue(thought.isPlaceholder)
        XCTAssertTrue(run.isRunning)
        XCTAssertFalse(presentation.showsWaiting)
    }

    private func makeActivity(
        id: String,
        kind: String,
        text: String,
        status: String
    ) throws -> LiveFeedActivity {
        let data = try JSONSerialization.data(withJSONObject: [
            "id": id,
            "kind": kind,
            "text": text,
            "status": status,
            "occurredAt": 1_000,
        ])
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(LiveFeedActivity.self, from: data)
    }
}
