// 이 파일은 사용자 확인 질문의 선택지 파싱과 안전한 원문 보존을 검증한다.

import XCTest
@testable import OfficeCore

final class AgentQuestionPresentationTests: XCTestCase {
    func testSeparatesNumberedMarkdownChoices() {
        let presentation = AgentQuestionPresentation(
            text: """
            다음 업무는 어느 쪽으로 갈까요?

            1. **UI 연결** — 선택지를 버튼으로 표시
            2. `ultra` 비교 — 비용과 품질 확인
            3. worktree 갱신

            권고는 **3번 → 1번**입니다.
            """
        )

        XCTAssertEqual(
            presentation.question,
            """
            다음 업무는 어느 쪽으로 갈까요?

            권고는 **3번 → 1번**입니다.
            """
        )
        XCTAssertEqual(
            presentation.choices,
            [
                AgentQuestionChoice(
                    title: "UI 연결 — 선택지를 버튼으로 표시",
                    response: "1. **UI 연결** — 선택지를 버튼으로 표시"
                ),
                AgentQuestionChoice(
                    title: "ultra 비교 — 비용과 품질 확인",
                    response: "2. `ultra` 비교 — 비용과 품질 확인"
                ),
                AgentQuestionChoice(
                    title: "worktree 갱신",
                    response: "3. worktree 갱신"
                ),
            ]
        )
    }

    func testSeparatesBulletChoices() {
        let presentation = AgentQuestionPresentation(
            text: """
            배포할까요?

            - 지금 배포
            - 나중에 배포
            """
        )

        XCTAssertEqual(presentation.question, "배포할까요?")
        XCTAssertEqual(
            presentation.choices,
            [
                AgentQuestionChoice(
                    title: "지금 배포",
                    response: "- 지금 배포"
                ),
                AgentQuestionChoice(
                    title: "나중에 배포",
                    response: "- 나중에 배포"
                ),
            ]
        )
    }

    func testAcceptsOneExplicitNumberedChoice() {
        let presentation = AgentQuestionPresentation(
            text: """
            변경을 승인할까요?

            1) 승인
            """
        )

        XCTAssertEqual(presentation.question, "변경을 승인할까요?")
        XCTAssertEqual(
            presentation.choices,
            [AgentQuestionChoice(title: "승인", response: "1) 승인")]
        )
    }

    func testLeavesOrdinarySingleBulletInQuestion() {
        let text = """
        다음 내용을 확인해 주세요.

        - 오류 로그 첨부
        """
        let presentation = AgentQuestionPresentation(text: text)

        XCTAssertEqual(presentation.question, text)
        XCTAssertTrue(presentation.choices.isEmpty)
    }

    func testRejectsNonSequentialNumberedChoices() {
        let text = """
        어느 쪽으로 갈까요?

        1. 첫 번째
        3. 세 번째
        """
        let presentation = AgentQuestionPresentation(text: text)

        XCTAssertEqual(presentation.question, text)
        XCTAssertTrue(presentation.choices.isEmpty)
    }
}
