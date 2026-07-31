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

    private func makeTurn(
        id: String,
        characterID: String,
        prompt: String,
        response: String = "",
        startedAt: Date,
        updatedAt: Date? = nil
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
            activities: []
        )
    }
}
