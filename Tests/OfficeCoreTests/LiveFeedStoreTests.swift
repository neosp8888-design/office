// 이 파일은 서버 응답 전 임시 업무 카드의 유지와 실제 턴 치환을 검증한다.

import OfficeCore
import XCTest
@testable import OfficeGame

@MainActor
final class LiveFeedStoreTests: XCTestCase {
    func testOptimisticTurnSurvivesUnrelatedFeedAndReconcilesByID() {
        let store = LiveFeedStore()
        let submittedAt = Date(timeIntervalSinceReferenceDate: 1_000)
        let optimistic = makeTurn(
            id: "local-command",
            characterID: OfficeCharacter.rightMan.rawValue,
            prompt: "원인을 확인해줘.",
            startedAt: submittedAt
        )
        let unrelated = makeTurn(
            id: "other-turn",
            characterID: OfficeCharacter.boss.rawValue,
            prompt: "다른 업무",
            startedAt: submittedAt.addingTimeInterval(-30)
        )

        store.insertOptimisticTurn(optimistic)
        store.replace(with: [unrelated])

        XCTAssertEqual(
            store.turns.map(\.id),
            ["local-command", "other-turn"]
        )

        store.reconcileOptimisticTurn(
            id: "local-command",
            with: "server-turn"
        )

        XCTAssertEqual(
            store.turns.map(\.id),
            ["server-turn", "other-turn"]
        )

        let persisted = makeTurn(
            id: "server-turn",
            characterID: OfficeCharacter.rightMan.rawValue,
            prompt: "원인을 확인해줘.",
            response: "확인했습니다.",
            startedAt: submittedAt.addingTimeInterval(0.1)
        )
        store.replace(with: [persisted, unrelated])

        XCTAssertEqual(store.turns.count, 2)
        XCTAssertEqual(store.turns.first?.id, "server-turn")
        XCTAssertEqual(store.turns.first?.response, "확인했습니다.")
    }

    func testMatchingServerTurnRemovesOptimisticDuplicateBeforeReconcile() {
        let store = LiveFeedStore()
        let submittedAt = Date(timeIntervalSinceReferenceDate: 2_000)
        store.insertOptimisticTurn(
            makeTurn(
                id: "local-command",
                characterID: OfficeCharacter.rightMan.rawValue,
                prompt: "같은 업무",
                startedAt: submittedAt
            )
        )

        let persisted = makeTurn(
            id: "server-turn",
            characterID: OfficeCharacter.rightMan.rawValue,
            prompt: "같은 업무",
            startedAt: submittedAt.addingTimeInterval(0.2)
        )
        store.replace(with: [persisted])

        XCTAssertEqual(store.turns.map(\.id), ["server-turn"])
        XCTAssertEqual(
            store.optimisticCharacterIDs,
            Set<String>()
        )
    }

    func testFailedStartRemovesOptimisticTurn() {
        let store = LiveFeedStore()
        store.insertOptimisticTurn(
            makeTurn(
                id: "local-command",
                characterID: OfficeCharacter.rightMan.rawValue,
                prompt: "실패할 업무",
                startedAt: Date()
            )
        )

        store.removeOptimisticTurn(id: "local-command")

        XCTAssertTrue(store.turns.isEmpty)
        XCTAssertTrue(store.optimisticCharacterIDs.isEmpty)
    }

    func testLatestConversationCharacterUsesNewestValidTurn() {
        let baseDate = Date(timeIntervalSinceReferenceDate: 3_000)
        let turns = [
            makeTurn(
                id: "older-turn",
                characterID: OfficeCharacter.boss.rawValue,
                prompt: "이전 업무",
                startedAt: baseDate,
                updatedAt: baseDate.addingTimeInterval(10)
            ),
            makeTurn(
                id: "newer-turn",
                characterID: OfficeCharacter.leftWoman.rawValue,
                prompt: "최근 업무",
                startedAt: baseDate.addingTimeInterval(20),
                updatedAt: baseDate.addingTimeInterval(30)
            ),
            makeTurn(
                id: "unknown-turn",
                characterID: "unknown-character",
                prompt: "알 수 없는 직원",
                startedAt: baseDate.addingTimeInterval(40),
                updatedAt: baseDate.addingTimeInterval(50)
            ),
        ]

        XCTAssertEqual(
            AgentDirector.latestConversationCharacter(in: turns),
            .leftWoman
        )
        XCTAssertNil(AgentDirector.latestConversationCharacter(in: []))
    }

    func testFeedFollowStopsOnlyForUserScrollAndResumesAtBottom() {
        var state = LiveWorkspaceFeedFollowState()

        XCTAssertTrue(state.isFollowingLatest)

        state.userWillScroll()
        XCTAssertFalse(state.isFollowingLatest)

        state.userDidScroll(
            distanceFromBottom: 240,
            tolerance: 20
        )
        XCTAssertFalse(state.isFollowingLatest)

        state.userDidScroll(
            distanceFromBottom: 12,
            tolerance: 20
        )
        XCTAssertTrue(state.isFollowingLatest)

        state.userWillScroll()
        state.resume()
        XCTAssertTrue(state.isFollowingLatest)
    }

    func testExecutionModeTitleTreatsHistoricalValuesAsStandard() {
        XCTAssertEqual(agentExecutionModeTitle(true), "Fast")
        XCTAssertEqual(agentExecutionModeTitle(false), "Standard")
        XCTAssertEqual(agentExecutionModeTitle(nil), "Standard")
    }

    func testReplacingOptimisticIDPreservesWorkspaceReview() {
        let workspace = makeWorkspace(status: .awaitingApproval)
        let source = makeSource(kind: .database)
        let turn = makeTurn(
            id: "local-command",
            characterID: OfficeCharacter.rightMan.rawValue,
            prompt: "변경 업무",
            startedAt: Date(),
            sources: [source],
            workspace: workspace
        )

        let replaced = turn.replacingID(with: "server-turn")

        XCTAssertEqual(replaced.id, "server-turn")
        XCTAssertEqual(replaced.workspace, workspace)
        XCTAssertEqual(replaced.responseSources, [source])
    }

    func testLiveFeedSourcesDecodeAllKindsAndLocators() throws {
        let payload = Data(
            #"""
            [
              {
                "id": "source-rag",
                "sourceKind": "rag",
                "title": "이전 결정",
                "locator": "rag_documents/record",
                "excerpt": null,
                "ragDocumentId": null,
                "workRecordId": null
              },
              {
                "id": "source-database",
                "sourceKind": "database",
                "title": "업무 기록",
                "locator": "work_records/record",
                "excerpt": "세션을 유지한다.",
                "ragDocumentId": null,
                "workRecordId": null
              },
              {
                "id": "source-file",
                "sourceKind": "file",
                "title": "README",
                "locator": "/repo/README.md:14-18",
                "excerpt": null,
                "ragDocumentId": null,
                "workRecordId": null
              },
              {
                "id": "source-web",
                "sourceKind": "web",
                "title": "공식 문서",
                "locator": "https://example.com/guide?q=office",
                "excerpt": null,
                "ragDocumentId": null,
                "workRecordId": null
              },
              {
                "id": "source-tool",
                "sourceKind": "tool",
                "title": "실행 도구",
                "locator": "web.search",
                "excerpt": null,
                "ragDocumentId": null,
                "workRecordId": null
              },
              {
                "id": "source-skill",
                "sourceKind": "skill",
                "title": "사용 스킬",
                "locator": "openai-docs",
                "excerpt": null,
                "ragDocumentId": null,
                "workRecordId": null
              }
            ]
            """#.utf8
        )

        let sources = try JSONDecoder().decode(
            [LiveFeedSource].self,
            from: payload
        )

        XCTAssertEqual(
            sources.map(\.sourceKind),
            [.rag, .database, .file, .web, .tool, .skill]
        )
        XCTAssertEqual(
            sources.map(\.sourceKind.title),
            ["RAG", "DB", "파일", "웹", "도구", "스킬"]
        )
        XCTAssertEqual(sources[2].filePath, "/repo/README.md")
        XCTAssertEqual(
            sources[3].webURL?.absoluteString,
            "https://example.com/guide?q=office"
        )
        XCTAssertNil(sources[4].webURL)
        XCTAssertNil(sources[5].webURL)
    }

    func testWebSourceAllowsOnlySafeHTTPURLs() {
        let https = makeSource(
            kind: .web,
            locator: "https://example.com/reference"
        )
        let http = makeSource(
            kind: .web,
            locator: "http://example.com/reference"
        )
        let credentials = makeSource(
            kind: .web,
            locator: "https://user:password@example.com/reference"
        )
        let script = makeSource(
            kind: .web,
            locator: "javascript:alert(1)"
        )
        let missingHost = makeSource(
            kind: .web,
            locator: "https:///reference"
        )

        XCTAssertEqual(https.webURL?.scheme, "https")
        XCTAssertEqual(http.webURL?.scheme, "http")
        XCTAssertNil(credentials.webURL)
        XCTAssertNil(script.webURL)
        XCTAssertNil(missingHost.webURL)
        XCTAssertNil(makeSource(kind: .file).webURL)
    }

    func testArchiveRefreshesWhenOnlyResponseSourcesChange() {
        let store = ArchiveFeedStore()
        let startedAt = Date(timeIntervalSinceReferenceDate: 7_000)
        let original = makeTurn(
            id: "turn",
            characterID: OfficeCharacter.boss.rawValue,
            prompt: "근거 확인",
            startedAt: startedAt
        )
        let sourced = makeTurn(
            id: "turn",
            characterID: OfficeCharacter.boss.rawValue,
            prompt: "근거 확인",
            startedAt: startedAt,
            sources: [makeSource(kind: .file)]
        )

        store.replaceIfNeeded(with: [original])
        store.replaceIfNeeded(with: [sourced])

        XCTAssertEqual(store.turns.first?.responseSources.count, 1)
        XCTAssertEqual(store.turns.first?.responseSources.first?.sourceKind, .file)
    }

    func testArchiveRefreshesWhenOnlyResponseSourceWarningClears() {
        let store = ArchiveFeedStore()
        let startedAt = Date(timeIntervalSinceReferenceDate: 7_100)
        let warning = makeTurn(
            id: "turn",
            characterID: OfficeCharacter.boss.rawValue,
            prompt: "근거 확인",
            startedAt: startedAt,
            responseSourceWarning: "근거 형식을 읽지 못했습니다."
        )
        let cleared = makeTurn(
            id: "turn",
            characterID: OfficeCharacter.boss.rawValue,
            prompt: "근거 확인",
            startedAt: startedAt
        )

        store.replaceIfNeeded(with: [warning])
        store.replaceIfNeeded(with: [cleared])

        XCTAssertNil(store.turns.first?.responseSourceWarning)
    }

    func testWorkspaceReviewBlocksOnlyUnresolvedMergeStates() {
        XCTAssertTrue(WorkspaceReviewStatus.awaitingApproval.blocksNewTasks)
        XCTAssertTrue(WorkspaceReviewStatus.merging.blocksNewTasks)
        XCTAssertTrue(WorkspaceReviewStatus.conflict.blocksNewTasks)
        XCTAssertFalse(WorkspaceReviewStatus.active.blocksNewTasks)
        XCTAssertFalse(WorkspaceReviewStatus.merged.blocksNewTasks)
        XCTAssertFalse(WorkspaceReviewStatus.rejected.blocksNewTasks)
        XCTAssertFalse(WorkspaceReviewStatus.closed.blocksNewTasks)
        XCTAssertFalse(WorkspaceReviewStatus.failed.blocksNewTasks)
        XCTAssertFalse(WorkspaceReviewStatus.active.showsReviewPanel)
        XCTAssertFalse(WorkspaceReviewStatus.closed.showsReviewPanel)
        XCTAssertTrue(WorkspaceReviewStatus.awaitingApproval.showsReviewPanel)
    }

    func testSnapshotKeepsOldBlockingWorkspaceTurnBeyondRecentLimit() {
        let baseDate = Date(timeIntervalSinceReferenceDate: 10_000)
        var turns = (0 ..< 120).map { index in
            makeTurn(
                id: "recent-\(index)",
                characterID: OfficeCharacter.rightMan.rawValue,
                prompt: "최근 업무",
                startedAt: baseDate.addingTimeInterval(-Double(index))
            )
        }
        turns.append(
            makeTurn(
                id: "old-closed-review",
                characterID: OfficeCharacter.leftWoman.rawValue,
                prompt: "종료된 검토",
                startedAt: baseDate.addingTimeInterval(-120),
                workspace: makeWorkspace(status: .closed)
            )
        )
        turns.append(
            makeTurn(
                id: "old-blocking-review",
                characterID: OfficeCharacter.boss.rawValue,
                prompt: "승인 대기 검토",
                startedAt: baseDate.addingTimeInterval(-121),
                workspace: makeWorkspace(status: .awaitingApproval)
            )
        )

        let snapshot = LiveFeedStore.snapshotTurns(
            from: turns,
            recentLimit: 120
        )

        XCTAssertEqual(snapshot.count, 121)
        XCTAssertFalse(snapshot.contains { $0.id == "old-closed-review" })
        XCTAssertEqual(snapshot.last?.id, "old-blocking-review")
    }

    func testWorkspaceFileBaseFollowsReviewLifecycle() {
        let awaiting = makeWorkspace(status: .awaitingApproval)
        let merged = makeWorkspace(status: .merged)

        XCTAssertEqual(
            awaiting.fileBaseDirectory(fallback: "/fallback"),
            "/tmp/worktree/project"
        )
        XCTAssertEqual(
            awaiting.reviewFileBaseDirectory(fallback: "/fallback"),
            "/tmp/worktree"
        )
        XCTAssertEqual(
            merged.fileBaseDirectory(fallback: "/fallback"),
            "/repo/project"
        )
        XCTAssertEqual(
            merged.reviewFileBaseDirectory(fallback: "/fallback"),
            "/repo"
        )
    }

    func testWorkspaceApprovalRequiresOnlyCurrentReviewTree() {
        let unopenedDiff = makeWorkspace(status: .awaitingApproval)
        let loadedDiff = makeWorkspace(
            status: .awaitingApproval,
            diff: "diff --git a/README.md b/README.md",
            diffTruncated: false
        )
        let truncatedDiff = makeWorkspace(
            status: .awaitingApproval,
            diff: "partial diff",
            diffTruncated: true
        )
        let blankTree = makeWorkspace(
            status: .awaitingApproval,
            reviewTree: " "
        )
        let wrongStatus = makeWorkspace(status: .conflict)

        XCTAssertTrue(unopenedDiff.canApprove)
        XCTAssertTrue(loadedDiff.canApprove)
        XCTAssertTrue(truncatedDiff.canApprove)
        XCTAssertFalse(blankTree.canApprove)
        XCTAssertFalse(wrongStatus.canApprove)
    }

    func testWorkspaceMergeRetryRequiresConflictReviewTree() {
        let conflict = makeWorkspace(status: .conflict)
        let awaiting = makeWorkspace(status: .awaitingApproval)

        XCTAssertTrue(conflict.canRetryMerge)
        XCTAssertFalse(awaiting.canRetryMerge)
    }

    func testLiveFeedWorkspaceDecodesWithoutOnDemandDiff() throws {
        let payload = Data(
            #"""
            {
              "status": "awaiting_approval",
              "repositoryRoot": "/repo",
              "worktreePath": "/tmp/worktree",
              "executionWorkdir": "/tmp/worktree/project",
              "branchName": "officestra/right-man/task",
              "baseBranch": "main",
              "baseCommit": "base",
              "reviewTree": "review-tree",
              "headCommit": "head",
              "changedFiles": [
                {"status": "M", "path": "README.md"}
              ],
              "mergedCommit": null,
              "errorMessage": null
            }
            """#.utf8
        )

        let workspace = try JSONDecoder().decode(
            TurnWorkspaceReview.self,
            from: payload
        )

        XCTAssertEqual(workspace.status, .awaitingApproval)
        XCTAssertEqual(workspace.reviewTree, "review-tree")
        XCTAssertEqual(workspace.executionWorkdir, "/tmp/worktree/project")
        XCTAssertEqual(workspace.changedFiles.first?.path, "README.md")
        XCTAssertNil(workspace.diff)
        XCTAssertNil(workspace.diffTruncated)
    }

    func testWorkspaceReviewMetadataRemainsBackwardCompatible() throws {
        let payload = Data(
            #"""
            {
              "status": "awaiting_approval",
              "repositoryRoot": "/repo",
              "worktreePath": "/tmp/worktree",
              "branchName": "officestra/right-man/task",
              "baseBranch": "main",
              "baseCommit": "base",
              "headCommit": "head",
              "changedFiles": [],
              "mergedCommit": null,
              "errorMessage": null
            }
            """#.utf8
        )

        let workspace = try JSONDecoder().decode(
            TurnWorkspaceReview.self,
            from: payload
        )

        XCTAssertNil(workspace.executionWorkdir)
        XCTAssertNil(workspace.reviewTree)
        XCTAssertFalse(workspace.canApprove)
    }

    private func makeTurn(
        id: String,
        characterID: String,
        prompt: String,
        response: String = "",
        startedAt: Date,
        updatedAt: Date? = nil,
        sources: [LiveFeedSource]? = nil,
        responseSourceWarning: String? = nil,
        workspace: TurnWorkspaceReview? = nil
    ) -> LiveFeedTurn {
        LiveFeedTurn(
            id: id,
            characterId: characterID,
            characterName: characterID,
            characterBackend: .codex,
            backend: .codex,
            model: "gpt-5.6-sol",
            effort: "high",
            fastMode: true,
            externalSessionId: nil,
            conversationWorkdir: "/repo",
            prompt: prompt,
            response: response,
            status: .running,
            needsInput: false,
            errorMessage: nil,
            responseSourceWarning: responseSourceWarning,
            startedAt: startedAt,
            endedAt: nil,
            updatedAt: updatedAt ?? startedAt,
            estimatedCostUsd: nil,
            sessionContext: nil,
            activities: [],
            sources: sources,
            workspace: workspace
        )
    }

    private func makeWorkspace(
        status: WorkspaceReviewStatus,
        reviewTree: String? = "review-tree",
        diff: String? = nil,
        diffTruncated: Bool? = nil
    ) -> TurnWorkspaceReview {
        TurnWorkspaceReview(
            status: status,
            repositoryRoot: "/repo",
            worktreePath: "/tmp/worktree",
            executionWorkdir:
                status == .merged
                    ? "/repo/project"
                    : "/tmp/worktree/project",
            branchName: "officestra/right-man/task",
            baseBranch: "main",
            baseCommit: "base",
            reviewTree: reviewTree,
            headCommit: "head",
            changedFiles: [
                WorkspaceChangedFile(status: "M", path: "README.md")
            ],
            mergedCommit: status == .merged ? "merged" : nil,
            errorMessage: nil,
            diff: diff,
            diffTruncated: diffTruncated
        )
    }

    private func makeSource(
        kind: LiveFeedSourceKind,
        locator: String? = nil
    ) -> LiveFeedSource {
        LiveFeedSource(
            id: "source-\(kind.rawValue)",
            sourceKind: kind,
            title: "근거",
            locator: locator
                ?? (kind == .file ? "/repo/README.md:14" : "record/14"),
            excerpt: nil,
            ragDocumentId: nil,
            workRecordId: nil
        )
    }
}
