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
        let turn = makeTurn(
            id: "local-command",
            characterID: OfficeCharacter.rightMan.rawValue,
            prompt: "변경 업무",
            startedAt: Date(),
            workspace: workspace
        )

        let replaced = turn.replacingID(with: "server-turn")

        XCTAssertEqual(replaced.id, "server-turn")
        XCTAssertEqual(replaced.workspace, workspace)
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

    func testWorkspaceApprovalRequiresCurrentCompleteDiff() {
        let missingDiff = makeWorkspace(status: .awaitingApproval)
        let completeDiff = makeWorkspace(
            status: .awaitingApproval,
            diff: "diff --git a/README.md b/README.md",
            diffTruncated: false
        )
        let truncatedDiff = makeWorkspace(
            status: .awaitingApproval,
            diff: "partial diff",
            diffTruncated: true
        )
        let unknownCompleteness = makeWorkspace(
            status: .awaitingApproval,
            diff: "diff without completeness metadata"
        )

        XCTAssertFalse(missingDiff.hasCompleteDiffForApproval)
        XCTAssertTrue(completeDiff.hasCompleteDiffForApproval)
        XCTAssertFalse(truncatedDiff.hasCompleteDiffForApproval)
        XCTAssertFalse(unknownCompleteness.hasCompleteDiffForApproval)
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
        XCTAssertFalse(workspace.hasCompleteDiffForApproval)
    }

    private func makeTurn(
        id: String,
        characterID: String,
        prompt: String,
        response: String = "",
        startedAt: Date,
        updatedAt: Date? = nil,
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
            prompt: prompt,
            response: response,
            status: .running,
            needsInput: false,
            errorMessage: nil,
            startedAt: startedAt,
            endedAt: nil,
            updatedAt: updatedAt ?? startedAt,
            estimatedCostUsd: nil,
            sessionContext: nil,
            activities: [],
            workspace: workspace
        )
    }

    private func makeWorkspace(
        status: WorkspaceReviewStatus,
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
            reviewTree: "review-tree",
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
}
