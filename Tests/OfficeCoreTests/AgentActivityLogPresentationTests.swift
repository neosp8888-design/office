// 이 파일은 Codex 전사 타임라인의 순서와 그룹 펼침 정책을 검증한다.

import Foundation
import XCTest
@testable import OfficeGame

final class AgentActivityLogPresentationTests: XCTestCase {
    func testCodexOperationExpansionNeverOpensFromStatusChanges() {
        XCTAssertFalse(
            transcriptGroupExpansionState(
                current: false,
                isRunning: true
            )
        )
        XCTAssertTrue(
            transcriptGroupExpansionState(
                current: true,
                isRunning: true
            )
        )
        XCTAssertFalse(
            transcriptGroupExpansionState(
                current: true,
                isRunning: false
            )
        )
    }

    func testLargeActivityGroupKeepsLatestVisibleAndCapsHistory() throws {
        let activities = try (0..<50).map { index in
            try makeActivity(
                id: "command-\(index)",
                kind: "command",
                text: "command \(index)",
                status: "completed"
            )
        }
        let group = CodexActivityGroup(
            kind: .command,
            items: activities.map(CodexActivityGroupItem.activity)
        )

        XCTAssertEqual(group.latestItem?.id, "command-49")
        XCTAssertEqual(group.hiddenHistoryItemCount(limit: 20), 29)
        XCTAssertEqual(
            group.visibleHistoryItems(
                showsAll: false,
                limit: 20
            ).map(\.id),
            activities.dropLast().suffix(20).map(\.id)
        )
        XCTAssertEqual(
            group.visibleHistoryItems(showsAll: true, limit: 20).count,
            49
        )
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

    func testCodexTranscriptKeepsWaitingBelowRunningActivity() throws {
        let activity = try makeActivity(
            id: "command-1",
            kind: "command",
            text: "swift test",
            status: "running"
        )
        let presentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [activity],
            response: "",
            responseUpdatedAt: Date(timeIntervalSince1970: 1_000),
            isRunning: true
        )

        XCTAssertTrue(presentation.showsWaiting)
        XCTAssertEqual(presentation.entries.count, 1)
    }

    func testCodexTranscriptFindsLatestMessageAcrossOtherEntries() throws {
        let first = try makeActivity(
            id: "message-1",
            kind: "message",
            text: "첫 응답",
            status: "completed"
        )
        let command = try makeActivity(
            id: "command-1",
            kind: "command",
            text: "swift test",
            status: "completed"
        )
        let latest = try makeActivity(
            id: "message-2",
            kind: "message",
            text: "최신 응답",
            status: "completed"
        )
        let tool = try makeActivity(
            id: "tool-1",
            kind: "tool",
            text: "검증 완료",
            status: "completed"
        )
        let presentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: [first, command, latest, tool],
            response: "첫 응답\n\n최신 응답",
            responseUpdatedAt: Date(timeIntervalSince1970: 1_000),
            isRunning: true
        )

        XCTAssertEqual(
            presentation.latestMessage?.id,
            "activity:message-2"
        )
        XCTAssertEqual(presentation.latestMessage?.text, "최신 응답")
    }

    func testCodexWaterfallPacingIsVisibleAndBounded() {
        XCTAssertEqual(
            CodexWaterfallRevealPacing.pendingContentOpacity,
            0
        )
        XCTAssertEqual(
            CodexWaterfallRevealPacing.featherHeight(
                forVisibleHeight: 0
            ),
            0
        )
        XCTAssertEqual(
            CodexWaterfallRevealPacing.revealDuration(
                forContentHeight: 20
            ),
            1.755,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CodexWaterfallRevealPacing.revealDuration(
                forContentHeight: 640
            ),
            2.6,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CodexWaterfallRevealPacing.revealDuration(
                forContentHeight: 2_000
            ),
            3.64,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CodexWaterfallRevealPacing.featherHeight(
                forVisibleHeight: 24
            ),
            11.52,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CodexWaterfallRevealPacing.featherHeight(
                forVisibleHeight: 120
            ),
            57.6,
            accuracy: 0.001
        )
        XCTAssertEqual(
            CodexWaterfallRevealPacing.featherHeight(
                forVisibleHeight: 200
            ),
            72,
            accuracy: 0.001
        )
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
                id: "reason-2",
                kind: "thinking",
                text: "검증 범위를 확정합니다.",
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

        XCTAssertEqual(presentation.entries.count, 6)
        guard
            case .activityGroup(let reasoningGroup) =
                presentation.entries[0],
            case .activityGroup(let commandGroup) =
                presentation.entries[1],
            case .activityGroup(let toolGroup) = presentation.entries[2],
            case .message(let firstMessage) = presentation.entries[3],
            case .activityGroup(let secondCommandGroup) =
                presentation.entries[4],
            case .message(let finalMessage) = presentation.entries[5]
        else {
            return XCTFail("Codex 타임라인 순서가 다릅니다.")
        }
        XCTAssertEqual(reasoningGroup.kind, .reasoning)
        XCTAssertEqual(
            reasoningGroup.items.map(\.id),
            ["reason-1", "reason-2"]
        )
        XCTAssertEqual(reasoningGroup.latestItem?.id, "reason-2")
        XCTAssertEqual(commandGroup.kind, .command)
        XCTAssertEqual(commandGroup.items.map(\.id), ["command-1"])
        XCTAssertEqual(toolGroup.kind, .tool)
        XCTAssertEqual(toolGroup.items.map(\.id), ["tool-1"])
        XCTAssertEqual(firstMessage.text, "첫 확인을 마쳤습니다.")
        XCTAssertEqual(secondCommandGroup.kind, .command)
        XCTAssertEqual(secondCommandGroup.items.map(\.id), ["command-2"])
        XCTAssertEqual(finalMessage.text, "최종 검증도 통과했습니다.")
        XCTAssertFalse(presentation.showsWaiting)
    }

    func testCodexTranscriptSeparatesCollaborationAroundPublicMessages() throws {
        let activities = try [
            makeActivity(
                id: "collab-spawn",
                kind: "collaboration",
                text: "스크롤 정책을 검토해 주세요.",
                status: "running",
                collaboration: [
                    "action": "spawn",
                    "agentThreadId": "reviewer-1",
                    "prompt": "스크롤 정책을 검토해 주세요.",
                    "agentStatus": "running",
                ]
            ),
            makeActivity(
                id: "legacy-wait",
                kind: "tool",
                text: "협업 · wait",
                status: "completed"
            ),
            makeActivity(
                id: "message-1",
                kind: "message",
                text: "첫 검토를 요청했습니다.",
                status: "completed"
            ),
            makeActivity(
                id: "collab-result",
                kind: "collaboration",
                text: "회귀 위험이 없습니다.",
                status: "completed",
                collaboration: [
                    "action": "result",
                    "agentThreadId": "reviewer-1",
                    "message": "회귀 위험이 없습니다.",
                    "agentStatus": "completed",
                ]
            ),
        ]

        let presentation = CodexTranscriptPresentation.make(
            turnID: "turn-1",
            activities: activities,
            response: "첫 검토를 요청했습니다.\n\n완료했습니다.",
            responseUpdatedAt: Date(timeIntervalSince1970: 2_000),
            isRunning: false
        )

        XCTAssertEqual(presentation.entries.count, 4)
        guard
            case .activityGroup(let firstGroup) = presentation.entries[0],
            case .message = presentation.entries[1],
            case .activityGroup(let secondGroup) = presentation.entries[2],
            case .message = presentation.entries[3]
        else {
            return XCTFail("대화 전후 협업 그룹의 순서가 다릅니다.")
        }
        XCTAssertEqual(firstGroup.kind, .collaboration)
        XCTAssertEqual(firstGroup.items.map(\.id), ["collab-spawn"])
        XCTAssertEqual(secondGroup.kind, .collaboration)
        XCTAssertEqual(secondGroup.items.map(\.id), ["collab-result"])
    }

    func testCollaborationSummaryCombinesRequestsAndLatestResultsByReviewer()
        throws
    {
        let activities = try [
            makeActivity(
                id: "spawn-1",
                kind: "collaboration",
                text: "UI 구조를 검토해 주세요.",
                status: "running",
                collaboration: [
                    "action": "spawn",
                    "agentThreadId": "reviewer-1",
                    "prompt": "UI 구조를 검토해 주세요.",
                    "agentStatus": "running",
                ]
            ),
            makeActivity(
                id: "spawn-2",
                kind: "collaboration",
                text: "CPU 부하를 검토해 주세요.",
                status: "running",
                collaboration: [
                    "action": "spawn",
                    "agentThreadId": "reviewer-2",
                    "prompt": "CPU 부하를 검토해 주세요.",
                    "agentStatus": "running",
                ]
            ),
            makeActivity(
                id: "result-1",
                kind: "collaboration",
                text: "접힘 UI가 적절합니다.",
                status: "completed",
                collaboration: [
                    "action": "result",
                    "agentThreadId": "reviewer-1",
                    "message": "접힘 UI가 적절합니다.",
                    "agentStatus": "completed",
                ]
            ),
            makeActivity(
                id: "follow-up-2",
                kind: "collaboration",
                text: "Markdown 비용도 확인해 주세요.",
                status: "running",
                collaboration: [
                    "action": "follow_up",
                    "agentThreadId": "reviewer-2",
                    "prompt": "Markdown 비용도 확인해 주세요.",
                    "agentStatus": "running",
                ]
            ),
            makeActivity(
                id: "result-2",
                kind: "collaboration",
                text: "렌더링 회귀가 발견됐습니다.",
                status: "failed",
                collaboration: [
                    "action": "result",
                    "agentThreadId": "reviewer-2",
                    "message": "렌더링 회귀가 발견됐습니다.",
                    "agentStatus": "errored",
                ]
            ),
        ]
        let group = CodexActivityGroup(
            kind: .collaboration,
            items: activities.map(CodexActivityGroupItem.activity)
        )
        let summary = try XCTUnwrap(
            CodexCollaborationSummary.make(from: group.items)
        )

        XCTAssertEqual(summary.agents.count, 2)
        XCTAssertEqual(summary.completedCount, 1)
        XCTAssertEqual(summary.failedCount, 1)
        XCTAssertEqual(summary.runningCount, 0)
        XCTAssertEqual(summary.statusText, "2명 · 1명 완료 · 1명 오류")
        XCTAssertEqual(summary.agents[0].prompt, "UI 구조를 검토해 주세요.")
        XCTAssertEqual(summary.agents[0].result, "접힘 UI가 적절합니다.")
        XCTAssertEqual(
            summary.agents[1].followUps,
            ["Markdown 비용도 확인해 주세요."]
        )
        XCTAssertEqual(
            summary.latestEvent?.text,
            "렌더링 회귀가 발견됐습니다."
        )
        XCTAssertEqual(
            summary.displayLabel(for: "reviewer-2"),
            "검토자 2"
        )
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
            case .activityGroup(let changeGroup) = presentation.entries[0],
            case .message = presentation.entries[1]
        else {
            return XCTFail("파일 변경 카드가 실제 위치에 없습니다.")
        }
        XCTAssertEqual(changeGroup.kind, .changes)
        let changes = try XCTUnwrap(
            changeGroup.latestItem?.changeSummary
        )
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

    func testFileChangeDescriptionExtractsFinderPath() {
        XCTAssertEqual(
            CodexFileChangeSummary.filePath(
                from: "수정 Sources/OfficeGame/Feed.swift"
            ),
            "Sources/OfficeGame/Feed.swift"
        )
        XCTAssertEqual(
            CodexFileChangeSummary.filePath(
                from: "이동 Sources/OfficeGame/NewFeed.swift"
            ),
            "Sources/OfficeGame/NewFeed.swift"
        )
        XCTAssertNil(CodexFileChangeSummary.filePath(from: "삭제 "))
    }

    func testFinderTargetResolvesRelativeAndAbsoluteFiles() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = workspace.appendingPathComponent("Sources/Feed.swift")
        try fileManager.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(fileManager.createFile(atPath: file.path, contents: Data()))
        defer { try? fileManager.removeItem(at: workspace) }

        let relative = try XCTUnwrap(
            WorkspaceFileRevealTarget.resolve(
                path: "Sources/Feed.swift",
                workspaceDirectory: workspace.path,
                fileManager: fileManager
            )
        )
        XCTAssertEqual(relative.url, file.standardizedFileURL)
        XCTAssertTrue(relative.selectsItem)

        let absolute = try XCTUnwrap(
            WorkspaceFileRevealTarget.resolve(
                path: file.path,
                workspaceDirectory: "/unused",
                fileManager: fileManager
            )
        )
        XCTAssertEqual(absolute.url, file.standardizedFileURL)
        XCTAssertTrue(absolute.selectsItem)
    }

    func testFinderTargetUsesClosestFolderForDeletedFile() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let existingFolder = workspace
            .appendingPathComponent("Sources", isDirectory: true)
        try fileManager.createDirectory(
            at: existingFolder,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: workspace) }

        let target = try XCTUnwrap(
            WorkspaceFileRevealTarget.resolve(
                path: "Sources/Deleted.swift",
                workspaceDirectory: workspace.path,
                fileManager: fileManager
            )
        )
        XCTAssertEqual(target.url, existingFolder.standardizedFileURL)
        XCTAssertFalse(target.selectsItem)
    }

    func testFinderTargetResolvesCompactedLegacyPath() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let file = workspace.appendingPathComponent("Sources/Feed.swift")
        try fileManager.createDirectory(
            at: file.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(fileManager.createFile(atPath: file.path, contents: Data()))
        defer { try? fileManager.removeItem(at: workspace) }

        let target = try XCTUnwrap(
            WorkspaceFileRevealTarget.resolve(
                path: "…/Sources/Feed.swift",
                workspaceDirectory: workspace.path,
                fileManager: fileManager
            )
        )
        XCTAssertEqual(target.url, file.standardizedFileURL)
        XCTAssertTrue(target.selectsItem)
    }

    func testFinderTargetRecoversLegacyWorktreeRootWithoutGuessing() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let rootFile = workspace.appendingPathComponent("Package.swift")
        let deepFile = workspace.appendingPathComponent(
            "packages/app/Sources/Feed.swift"
        )
        try fileManager.createDirectory(
            at: deepFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(
            fileManager.createFile(atPath: rootFile.path, contents: Data())
        )
        XCTAssertTrue(
            fileManager.createFile(atPath: deepFile.path, contents: Data())
        )
        defer { try? fileManager.removeItem(at: workspace) }

        let rootTarget = try XCTUnwrap(
            WorkspaceFileRevealTarget.resolve(
                path: "…/03ffd78858a8/right-woman-70d95def-eae4-441f-b0ec-e5cd2e230dee/Package.swift",
                workspaceDirectory: workspace.path,
                fileManager: fileManager
            )
        )
        XCTAssertEqual(rootTarget.url, rootFile.standardizedFileURL)
        XCTAssertTrue(rootTarget.selectsItem)

        let deepTarget = try XCTUnwrap(
            WorkspaceFileRevealTarget.resolve(
                path: "…/Sources/Feed.swift",
                workspaceDirectory: workspace.path,
                fileManager: fileManager
            )
        )
        XCTAssertEqual(deepTarget.url, workspace.standardizedFileURL)
        XCTAssertFalse(deepTarget.selectsItem)
    }

    func testFinderTargetDoesNotSelectAmbiguousCompactedPath() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        for prefix in ["packages/one", "vendor/packages/two"] {
            let file = workspace.appendingPathComponent(
                "\(prefix)/Sources/Feed.swift"
            )
            try fileManager.createDirectory(
                at: file.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            XCTAssertTrue(
                fileManager.createFile(atPath: file.path, contents: Data())
            )
        }
        defer { try? fileManager.removeItem(at: workspace) }

        let target = try XCTUnwrap(
            WorkspaceFileRevealTarget.resolve(
                path: "…/Sources/Feed.swift",
                workspaceDirectory: workspace.path,
                fileManager: fileManager
            )
        )
        XCTAssertEqual(target.url, workspace.standardizedFileURL)
        XCTAssertFalse(target.selectsItem)
    }

    func testFinderTargetKeepsCompactedDeletedPathInsideWorkspace() throws {
        let fileManager = FileManager.default
        let workspace = fileManager.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let existingFolder = workspace.appendingPathComponent(
            "Sources/OfficeGame",
            isDirectory: true
        )
        try fileManager.createDirectory(
            at: existingFolder,
            withIntermediateDirectories: true
        )
        defer { try? fileManager.removeItem(at: workspace) }

        let target = try XCTUnwrap(
            WorkspaceFileRevealTarget.resolve(
                path: "…/Sources/OfficeGame/Deleted.swift",
                workspaceDirectory: workspace.path,
                fileManager: fileManager
            )
        )
        XCTAssertEqual(target.url, existingFolder.standardizedFileURL)
        XCTAssertFalse(target.selectsItem)
    }

    func testFinderTargetDoesNotEscapeMissingCompactedWorkspace() {
        let missingWorkspace = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        XCTAssertNil(
            WorkspaceFileRevealTarget.resolve(
                path: "…/Sources/Deleted.swift",
                workspaceDirectory: missingWorkspace.path
            )
        )
    }

    func testFinderTargetRejectsUnsafeCompactedPath() {
        XCTAssertNil(
            WorkspaceFileRevealTarget.fileURL(
                path: "…/../outside.txt",
                workspaceDirectory: "/Users/example/office"
            )
        )
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
            case .activityGroup(let runningChangeGroup) =
                runningPresentation.entries[1],
            case .message = runningPresentation.entries[2]
        else {
            return XCTFail("실행 중 파일 변경의 타임라인 위치가 다릅니다.")
        }
        XCTAssertEqual(runningChangeGroup.kind, .changes)
        let runningChanges = try XCTUnwrap(
            runningChangeGroup.latestItem?.changeSummary
        )
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
            case .activityGroup(let completedChangeGroup) =
                completedPresentation.entries[1]
        else {
            return XCTFail("완료 파일 변경 카드가 기존 위치를 잃었습니다.")
        }
        let completedChanges = try XCTUnwrap(
            completedChangeGroup.latestItem?.changeSummary
        )
        XCTAssertEqual(completedChanges.status, .completed)
        XCTAssertEqual(completedChanges.files, ["수정 A.swift", "수정 B.swift"])
        XCTAssertEqual(completedChanges.additions, 3)
        XCTAssertEqual(completedChanges.deletions, 1)
    }

    func testSamePhaseFileChangesShareCategoryGroup() throws {
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
            presentation.entries.count == 2,
            case .activityGroup(let changeGroup) =
                presentation.entries[0],
            case .activityGroup(let commandGroup) = presentation.entries[1]
        else {
            return XCTFail("같은 구간의 파일 변경 그룹이 다릅니다.")
        }
        XCTAssertEqual(changeGroup.kind, .changes)
        XCTAssertEqual(changeGroup.items.map(\.id), ["files-1", "files-2"])
        XCTAssertEqual(commandGroup.kind, .command)
        let firstChanges = try XCTUnwrap(
            changeGroup.visibleHistoryItems(
                showsAll: true,
                limit: 20
            ).first?.changeSummary
        )
        let secondChanges = try XCTUnwrap(
            changeGroup.latestItem?.changeSummary
        )
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
            case .activityGroup(let changeGroup) = presentation.entries[0]
        else {
            return XCTFail("이전 파일 변경 기록의 위치가 다릅니다.")
        }
        let changes = try XCTUnwrap(
            changeGroup.latestItem?.changeSummary
        )
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
        status: String,
        collaboration: [String: Any]? = nil
    ) throws -> LiveFeedActivity {
        var object: [String: Any] = [
            "id": id,
            "kind": kind,
            "text": text,
            "status": status,
            "occurredAt": 1_000,
        ]
        if let collaboration {
            object["collaboration"] = collaboration
        }
        let data = try JSONSerialization.data(withJSONObject: object)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try decoder.decode(LiveFeedActivity.self, from: data)
    }
}
