// 이 파일은 확인 질문 답변란이 붙는 대화 카드를 고르는 규칙을 검증한다.

import XCTest
@testable import OfficeCore

final class InlineQuestionVisibilityTests: XCTestCase {
    func testShowsOnlyOnTheTurnThatAsked() {
        XCTAssertTrue(
            InlineQuestionVisibility.showsAnswerComposer(
                turnNeedsInput: true,
                turnID: "turn-2",
                pendingQuestionTurnID: "turn-2"
            )
        )
        XCTAssertFalse(
            InlineQuestionVisibility.showsAnswerComposer(
                turnNeedsInput: true,
                turnID: "turn-1",
                pendingQuestionTurnID: "turn-2"
            )
        )
    }

    func testAnsweredTurnKeepsNeedsInputButHidesComposer() {
        XCTAssertFalse(
            InlineQuestionVisibility.showsAnswerComposer(
                turnNeedsInput: true,
                turnID: "turn-1",
                pendingQuestionTurnID: nil
            )
        )
    }

    func testOrdinaryTurnNeverShowsComposer() {
        XCTAssertFalse(
            InlineQuestionVisibility.showsAnswerComposer(
                turnNeedsInput: false,
                turnID: "turn-1",
                pendingQuestionTurnID: "turn-1"
            )
        )
    }
}
