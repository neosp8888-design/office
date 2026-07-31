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
                text: "도구 · Read · /Users/neo/office/Package.swift",
                status: "completed"
            )
        )

        XCTAssertEqual(call.name, "Read")
        XCTAssertEqual(call.detail, "/Users/neo/office/Package.swift")
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
            case .thought(let thought) = presentation.entries[0],
            case .tools(let reads) = presentation.entries[1],
            case .edits(let edits) = presentation.entries[2],
            case .tools(let tests) = presentation.entries[3]
        else {
            return XCTFail("Claude 타임라인 순서가 다릅니다.")
        }
        XCTAssertEqual(thought.text, "먼저 구조를 확인한다.")
        XCTAssertEqual(reads.steps.map(\.activityID), ["tool-1", "tool-2"])
        XCTAssertEqual(reads.title, "Read · Bash")
        XCTAssertEqual(edits.steps.map(\.activityID), ["tool-3", "tool-4"])
        XCTAssertEqual(edits.fileCount, 2)
        XCTAssertEqual(edits.title, "파일 2개를 편집했습니다")
        XCTAssertTrue(tests.isRunning)
        XCTAssertFalse(presentation.showsWaiting)
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

        guard case .tools(let run) = presentation.entries.first else {
            return XCTFail("도구 그룹이 없습니다.")
        }
        XCTAssertEqual(run.title, "Read 3 · Grep")
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

        guard case .thought(let thought) = presentation.entries.first else {
            return XCTFail("사고 항목이 없습니다.")
        }
        XCTAssertTrue(thought.isPlaceholder)
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
