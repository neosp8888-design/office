// 터미널 평가 토스트가 어떤 턴을 띄우는지 규칙을 검증한다.
import OfficeCore
import XCTest
@testable import OfficeGame

final class TerminalFeedbackToastTests: XCTestCase {
    private let now = Date(timeIntervalSinceReferenceDate: 100_000)

    func testPicksLatestFreshCompletedTerminalTurnOfCharacter() {
        let turns = [
            makeTurn(id: "old", endedAt: now.addingTimeInterval(-600)),
            makeTurn(id: "earlier", endedAt: now.addingTimeInterval(-20)),
            makeTurn(id: "latest", endedAt: now.addingTimeInterval(-5)),
            makeTurn(id: "chat", origin: "gui", endedAt: now),
            makeTurn(id: "running", status: .running, endedAt: nil),
            makeTurn(id: "other", character: .leftMan, endedAt: now),
            makeTurn(id: "question", needsInput: true, endedAt: now),
        ]

        let candidate = TerminalFeedbackToastPresentation.candidate(
            in: turns,
            character: .boss,
            shownTurnIDs: [],
            now: now
        )

        XCTAssertEqual(candidate?.id, "latest")
    }

    func testSkipsAlreadyShownTurnsAndOtherCharacters() {
        let turns = [makeTurn(id: "latest", endedAt: now)]

        XCTAssertNil(
            TerminalFeedbackToastPresentation.candidate(
                in: turns,
                character: .boss,
                shownTurnIDs: ["latest"],
                now: now
            )
        )
        XCTAssertNil(
            TerminalFeedbackToastPresentation.candidate(
                in: turns,
                character: .leftMan,
                shownTurnIDs: [],
                now: now
            )
        )
    }

    private func makeTurn(
        id: String,
        character: OfficeCharacter = .boss,
        origin: String = "terminal",
        status: LiveTurnStatus = .completed,
        needsInput: Bool = false,
        endedAt: Date?
    ) -> LiveFeedTurn {
        LiveFeedTurn(
            id: id,
            characterId: character.rawValue,
            characterName: "직원",
            characterBackend: .claude,
            backend: .claude,
            model: "claude-fable-5-1",
            effort: "high",
            fastMode: false,
            origin: origin,
            externalSessionId: nil,
            conversationWorkdir: nil,
            prompt: "질문",
            response: "답",
            feedback: nil,
            status: status,
            needsInput: needsInput,
            errorMessage: nil,
            responseSourceWarning: nil,
            wikiProposalWarning: nil,
            startedAt: now.addingTimeInterval(-30),
            endedAt: endedAt,
            updatedAt: endedAt ?? now,
            estimatedCostUsd: nil,
            sessionContext: nil,
            activities: [],
            sources: nil,
            workspace: nil
        )
    }
}
