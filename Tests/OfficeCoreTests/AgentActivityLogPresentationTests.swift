// 이 파일은 첫 실제 추론의 시작 행과 동일 항목 완료 전환 표시를 검증한다.

import Foundation
import XCTest
@testable import OfficeGame

final class AgentActivityLogPresentationTests: XCTestCase {
    func testLargeOperationGroupUsesRecentRowsUntilExpanded() throws {
        let activities = try (0..<50).map { index in
            try makeActivity(
                id: "command-\(index)",
                kind: "command",
                text: "command \(index)",
                status: "completed"
            )
        }
        let group = CodexOperationGroup(activities: activities)

        XCTAssertEqual(group.hiddenActivityCount(limit: 20), 30)
        XCTAssertEqual(
            group.visibleActivities(showsAll: false, limit: 20).map(\.id),
            activities.suffix(20).map(\.id)
        )
        XCTAssertEqual(
            group.visibleActivities(showsAll: true, limit: 20).count,
            50
        )
    }

    func testEmptyActivitiesDoNotCreateSyntheticStartRow() {
        let presentation = AgentActivityPresentation.make(
            activities: [],
            isRunning: true
        )

        XCTAssertNil(presentation.initialRunningReasoning)
        XCTAssertTrue(presentation.visible.isEmpty)
        XCTAssertEqual(presentation.displayedCount, 0)
    }

    func testInitialRunningReasoningIsVisibleAsStart() throws {
        let reasoning = try makeActivity(
            id: "reason-1",
            kind: "thinking",
            text: "실제 구조를 확인하고 있습니다.",
            status: "running"
        )

        let presentation = AgentActivityPresentation.make(
            activities: [reasoning],
            isRunning: true
        )

        XCTAssertEqual(presentation.initialRunningReasoning?.id, "reason-1")
        XCTAssertEqual(presentation.visible.map(\.id), ["reason-1"])
        XCTAssertTrue(presentation.completed.isEmpty)
        XCTAssertEqual(presentation.displayedCount, 1)
        XCTAssertEqual(agentActivityStatusTitle(reasoning.status), "시작")
    }

    func testSameReasoningIDBecomesCompletedRow() throws {
        let reasoning = try makeActivity(
            id: "reason-1",
            kind: "thinking",
            text: "실제 구조를 확인하고 있습니다.",
            status: "completed"
        )

        let presentation = AgentActivityPresentation.make(
            activities: [reasoning],
            isRunning: true
        )

        XCTAssertNil(presentation.initialRunningReasoning)
        XCTAssertEqual(presentation.visible.map(\.id), ["reason-1"])
        XCTAssertEqual(presentation.completed.map(\.id), ["reason-1"])
        XCTAssertEqual(agentActivityStatusTitle(reasoning.status), "완료")
    }

    func testLaterRunningReasoningIsNotDuplicatedInTimeline() throws {
        let first = try makeActivity(
            id: "reason-1",
            kind: "thinking",
            text: "첫 추론입니다.",
            status: "completed"
        )
        let second = try makeActivity(
            id: "reason-2",
            kind: "thinking",
            text: "두 번째 추론입니다.",
            status: "running"
        )

        let presentation = AgentActivityPresentation.make(
            activities: [first, second],
            isRunning: true
        )

        XCTAssertNil(presentation.initialRunningReasoning)
        XCTAssertEqual(presentation.visible.map(\.id), ["reason-1"])
        XCTAssertEqual(presentation.running?.id, "reason-2")
    }

    func testCodexTranscriptShowsWaitingImmediatelyWithoutActivities() {
        let presentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [],
            response: "",
            responseUpdatedAt: Date(timeIntervalSince1970: 1_000),
            isRunning: true
        )

        XCTAssertTrue(presentation.entries.isEmpty)
        XCTAssertTrue(presentation.showsWaiting)
    }

    func testCodexTranscriptKeepsMessagesBetweenOperationGroups() throws {
        let activities = try [
            makeActivity(
                id: "reason-1",
                kind: "thinking",
                text: "구조를 확인합니다.",
                status: "completed"
            ),
            makeActivity(
                id: "command-1",
                kind: "command",
                text: "swift test",
                status: "completed"
            ),
            makeActivity(
                id: "tool-1",
                kind: "tool",
                text: "검색 · Feed",
                status: "completed"
            ),
            makeActivity(
                id: "message-1",
                kind: "message",
                text: "첫 확인을 마쳤습니다.",
                status: "completed"
            ),
            makeActivity(
                id: "command-2",
                kind: "command",
                text: "swift build",
                status: "completed"
            ),
        ]

        let presentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: activities,
            response: "첫 확인을 마쳤습니다.\n\n최종 검증도 통과했습니다.",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        XCTAssertEqual(presentation.entries.count, 5)
        guard
            case .narrative = presentation.entries[0],
            case .operations(let firstGroup) = presentation.entries[1],
            case .message(let firstMessage) = presentation.entries[2],
            case .operations(let secondGroup) = presentation.entries[3],
            case .message(let finalMessage) = presentation.entries[4]
        else {
            return XCTFail("Codex 타임라인 순서가 다릅니다.")
        }
        XCTAssertEqual(firstGroup.activities.map(\.id), ["command-1", "tool-1"])
        XCTAssertEqual(firstMessage.text, "첫 확인을 마쳤습니다.")
        XCTAssertEqual(secondGroup.activities.map(\.id), ["command-2"])
        XCTAssertEqual(finalMessage.text, "최종 검증도 통과했습니다.")
        XCTAssertFalse(presentation.showsWaiting)
    }

    func testCodexTranscriptPreservesRepeatedMessageAfterPrefixRemoval() throws {
        let activity = try makeActivity(
            id: "message-1",
            kind: "message",
            text: "같은 문장",
            status: "completed"
        )

        let presentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [activity],
            response: "같은 문장\n\n같은 문장",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        let messages = presentation.entries.compactMap { entry -> String? in
            guard case .message(let message) = entry else {
                return nil
            }
            return message.text
        }
        XCTAssertEqual(messages, ["같은 문장", "같은 문장"])
    }

    func testCodexTranscriptDoesNotGuessAtMismatchedResponsePrefix() throws {
        let activity = try makeActivity(
            id: "message-1",
            kind: "message",
            text: "이전 형식 메시지",
            status: "completed"
        )

        let presentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [activity],
            response: "서로 다른 최종 응답",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        let messages = presentation.entries.compactMap { entry -> String? in
            guard case .message(let message) = entry else {
                return nil
            }
            return message.text
        }
        XCTAssertEqual(messages, ["이전 형식 메시지", "서로 다른 최종 응답"])
    }

    func testCodexTranscriptRemovesKnownLegacyMessageSuffix() throws {
        let activities = try [
            makeActivity(
                id: "message-1",
                kind: "message",
                text: "첫 메시지",
                status: "completed"
            ),
            makeActivity(
                id: "message-2",
                kind: "message",
                text: "두 번째 메시지",
                status: "completed"
            ),
        ]

        let presentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: activities,
            response: "두 번째 메시지\n\n최종 메시지",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        let messages = presentation.entries.compactMap { entry -> String? in
            guard case .message(let message) = entry else {
                return nil
            }
            return message.text
        }
        XCTAssertEqual(messages, ["첫 메시지", "두 번째 메시지", "최종 메시지"])
    }

    func testCodexTranscriptCollectsFileChangeResult() throws {
        let activity = try makeActivity(
            id: "files-1",
            kind: "tool",
            text: [
                "파일 2개를 편집했습니다",
                "+3 -1",
                "수정 Sources/OfficeGame/Feed.swift",
                "추가 Tests/FeedTests.swift",
            ].joined(separator: "\n"),
            status: "completed"
        )

        let presentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [activity],
            response: "완료했습니다.",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        guard
            presentation.entries.count == 2,
            case .changes(let changes) = presentation.entries[0],
            case .message = presentation.entries[1]
        else {
            return XCTFail("파일 변경 카드가 실제 위치에 없습니다.")
        }
        XCTAssertEqual(
            changes.files,
            [
                "수정 Sources/OfficeGame/Feed.swift",
                "추가 Tests/FeedTests.swift",
            ]
        )
        XCTAssertEqual(changes.additions, 3)
        XCTAssertEqual(changes.deletions, 1)
        XCTAssertEqual(changes.reportedFileCount, 2)
    }

    func testCodexTranscriptMergesGeneratedImagesIntoConclusion() throws {
        let message = try makeActivity(
            id: "message-1",
            kind: "message",
            text: "이미지를 만들었습니다.",
            status: "completed"
        )
        let preview = "[![생성 이미지 1](<file:///tmp/result.png>)](<file:///tmp/result.png>)"

        let presentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [message],
            response: "이미지를 만들었습니다.\n\n\(preview)",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        let messages = presentation.entries.compactMap { entry -> String? in
            guard case .message(let message) = entry else {
                return nil
            }
            return message.text
        }
        XCTAssertEqual(messages, ["이미지를 만들었습니다.\n\n\(preview)"])
    }

    func testFileSummaryCountsRepeatedPathOnce() throws {
        let first = try makeActivity(
            id: "files-1",
            kind: "tool",
            text: "파일 1개를 편집했습니다\n수정 A.swift",
            status: "completed"
        )
        let second = try makeActivity(
            id: "files-2",
            kind: "tool",
            text: "파일 1개를 편집했습니다\n수정 A.swift",
            status: "completed"
        )

        let summary = try XCTUnwrap(
            CodexFileChangeSummary.make(from: [first, second])
        )

        XCTAssertEqual(summary.files, ["수정 A.swift"])
        XCTAssertEqual(summary.reportedFileCount, 1)
        XCTAssertEqual(summary.title, "파일 1개를 편집했습니다")
    }

    func testRunningFileChangeUpdatesInPlaceBetweenMessages() throws {
        let before = try makeActivity(
            id: "message-1",
            kind: "message",
            text: "수정을 시작합니다.",
            status: "completed"
        )
        let running = try makeActivity(
            id: "files-1",
            kind: "tool",
            text: "파일 변경을 적용하는 중 · 2개",
            status: "running"
        )
        let after = try makeActivity(
            id: "message-2",
            kind: "message",
            text: "검증을 이어갑니다.",
            status: "completed"
        )
        let response = "수정을 시작합니다.\n\n검증을 이어갑니다."

        let runningPresentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [before, running, after],
            response: response,
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: true
        )

        guard
            runningPresentation.entries.count == 3,
            case .message = runningPresentation.entries[0],
            case .changes(let runningChanges) =
                runningPresentation.entries[1],
            case .message = runningPresentation.entries[2]
        else {
            return XCTFail("실행 중 파일 변경의 타임라인 위치가 다릅니다.")
        }
        XCTAssertEqual(
            runningChanges.title,
            "파일 2개를 편집하는 중"
        )
        XCTAssertTrue(runningChanges.files.isEmpty)
        XCTAssertEqual(runningChanges.status, .running)

        let completed = try makeActivity(
            id: "files-1",
            kind: "tool",
            text: "파일 2개를 편집했습니다\n+3 -1\n수정 A.swift\n수정 B.swift",
            status: "completed"
        )
        let completedPresentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [before, completed, after],
            response: response,
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: true
        )

        XCTAssertEqual(
            runningPresentation.entries.map(\.id),
            completedPresentation.entries.map(\.id)
        )
        guard
            case .changes(let completedChanges) =
                completedPresentation.entries[1]
        else {
            return XCTFail("완료 파일 변경 카드가 기존 위치를 잃었습니다.")
        }
        XCTAssertEqual(completedChanges.status, .completed)
        XCTAssertEqual(completedChanges.files, ["수정 A.swift", "수정 B.swift"])
        XCTAssertEqual(completedChanges.additions, 3)
        XCTAssertEqual(completedChanges.deletions, 1)
    }

    func testSeparatedFileChangesKeepIndependentPositions() throws {
        let first = try makeActivity(
            id: "files-1",
            kind: "tool",
            text: "파일 1개를 편집했습니다\n수정 A.swift",
            status: "completed"
        )
        let command = try makeActivity(
            id: "command-1",
            kind: "command",
            text: "swift test",
            status: "completed"
        )
        let second = try makeActivity(
            id: "files-2",
            kind: "tool",
            text: "파일 1개를 편집했습니다\n수정 B.swift",
            status: "completed"
        )

        let presentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [first, command, second],
            response: "",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        guard
            presentation.entries.count == 3,
            case .changes(let firstChanges) = presentation.entries[0],
            case .operations = presentation.entries[1],
            case .changes(let secondChanges) = presentation.entries[2]
        else {
            return XCTFail("여러 파일 변경의 실제 순서를 잃었습니다.")
        }
        XCTAssertEqual(firstChanges.files, ["수정 A.swift"])
        XCTAssertEqual(secondChanges.files, ["수정 B.swift"])
    }

    func testFileSummaryOmitsPartialStatistics() throws {
        let measured = try makeActivity(
            id: "files-1",
            kind: "tool",
            text: "파일 1개를 편집했습니다\n+3 -1\n수정 A.swift",
            status: "completed"
        )
        let unmeasured = try makeActivity(
            id: "files-2",
            kind: "tool",
            text: "파일 1개를 편집했습니다\n수정 Binary.dat",
            status: "completed"
        )

        let summary = try XCTUnwrap(
            CodexFileChangeSummary.make(from: [measured, unmeasured])
        )

        XCTAssertNil(summary.additions)
        XCTAssertNil(summary.deletions)
    }

    func testFailedFileChangeUsesFailureTitle() throws {
        let activity = try makeActivity(
            id: "files-failed",
            kind: "tool",
            text: "파일 2개를 편집했습니다\n수정 A.swift\n수정 B.swift",
            status: "failed"
        )

        let summary = try XCTUnwrap(
            CodexFileChangeSummary.make(from: [activity])
        )

        XCTAssertEqual(summary.title, "파일 2개 변경에 실패했습니다")
        XCTAssertEqual(summary.status, .failed)
    }

    func testSingleTruncatedFileSummaryKeepsDeclaredTotal() throws {
        let files = (0..<40).map { "수정 File\($0).swift" }
        let activity = try makeActivity(
            id: "files-1",
            kind: "tool",
            text: (["파일 50개를 편집했습니다"] + files + ["외 10개"])
                .joined(separator: "\n"),
            status: "completed"
        )

        let summary = try XCTUnwrap(
            CodexFileChangeSummary.make(from: [activity])
        )

        XCTAssertEqual(summary.files.count, 40)
        XCTAssertEqual(summary.reportedFileCount, 50)
        XCTAssertEqual(summary.title, "파일 50개를 편집했습니다")
        XCTAssertFalse(summary.files.contains("외 10개"))
    }

    func testLegacyFileChangeSentenceBecomesResultCard() throws {
        let activity = try makeActivity(
            id: "files-legacy",
            kind: "tool",
            text: "파일 변경을 반영했습니다.",
            status: "completed"
        )

        let presentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [activity],
            response: "완료했습니다.",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        guard
            presentation.entries.count == 2,
            case .changes(let changes) = presentation.entries[0]
        else {
            return XCTFail("이전 파일 변경 기록의 위치가 다릅니다.")
        }
        XCTAssertEqual(changes.files, [])
        XCTAssertEqual(changes.title, "파일 변경을 반영했습니다")
    }

    func testLegacyTruncatedFileSummarySeparatesRemainder() throws {
        let activity = try makeActivity(
            id: "files-legacy",
            kind: "tool",
            text: "파일 · 수정 A.swift, 수정 B.swift, 수정 C.swift 외 4개",
            status: "completed"
        )

        let summary = try XCTUnwrap(
            CodexFileChangeSummary.make(from: [activity])
        )

        XCTAssertEqual(
            summary.files,
            ["수정 A.swift", "수정 B.swift", "수정 C.swift"]
        )
        XCTAssertEqual(summary.reportedFileCount, 7)
        XCTAssertEqual(summary.title, "파일 7개를 편집했습니다")
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
