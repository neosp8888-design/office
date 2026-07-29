// 이 파일은 긴 한글과 이모지 응답의 적응형 타자 표시량을 검증한다.

import XCTest
@testable import OfficeCore

final class StreamingTextPacerTests: XCTestCase {
    func testEmptyBacklogHasNoImmediatePrefix() {
        XCTAssertEqual(
            StreamingTextPacer.immediatelyVisibleCharacterCount(
                remainingCharacterCount: 0
            ),
            0
        )
    }

    func testShortBacklogKeepsOnlyAnimatedTail() {
        XCTAssertEqual(
            StreamingTextPacer.immediatelyVisibleCharacterCount(
                remainingCharacterCount: 180
            ),
            0
        )
        XCTAssertEqual(
            StreamingTextPacer.immediatelyVisibleCharacterCount(
                remainingCharacterCount: 181
            ),
            1
        )
    }

    func testLargeBacklogAppearsImmediatelyExceptForTail() {
        XCTAssertEqual(
            StreamingTextPacer.immediatelyVisibleCharacterCount(
                remainingCharacterCount: 1_920
            ),
            1_740
        )
        XCTAssertEqual(
            StreamingTextPacer.immediatelyVisibleCharacterCount(
                remainingCharacterCount: 20_000
            ),
            19_820
        )
    }

    func testTailAnimationPreservesUnicodeAndMarkdownText() {
        let target = String(
            repeating: "한글🙂 **굵게**\n| 열 | 값 |\n",
            count: 80
        )
        var rendered = ""
        var index = target.startIndex
        var remaining = target.count
        let immediatelyVisibleCount =
            StreamingTextPacer.immediatelyVisibleCharacterCount(
                remainingCharacterCount: remaining
            )

        if immediatelyVisibleCount > 0 {
            let nextIndex = target.index(
                index,
                offsetBy: immediatelyVisibleCount
            )
            rendered.append(contentsOf: target[index ..< nextIndex])
            index = nextIndex
            remaining -= immediatelyVisibleCount
        }

        var animatedFrameCount = 0
        while remaining > 0 {
            let nextIndex = target.index(after: index)
            rendered.append(contentsOf: target[index ..< nextIndex])
            index = nextIndex
            remaining -= 1
            animatedFrameCount += 1
            XCTAssertTrue(target.hasPrefix(rendered))
        }

        XCTAssertEqual(rendered, target)
        XCTAssertLessThanOrEqual(
            animatedFrameCount,
            StreamingTextPacer.animatedTailCharacterCount
        )
    }

    func testUpdatePlanAnimatesOnlyNewUnicodeSuffix() {
        let plan = StreamingTextPacer.updatePlan(
            current: "한글🙂",
            target: "한글🙂 문장이 이어집니다.",
            animates: true
        )

        XCTAssertEqual(plan.immediateText, "한글🙂")
        XCTAssertEqual(
            String(plan.animatedCharacters),
            " 문장이 이어집니다."
        )
    }

    func testUpdatePlanHandlesReplacementAndDisabledAnimation() {
        let replacement = StreamingTextPacer.updatePlan(
            current: "이전 응답",
            target: "새 응답",
            animates: true
        )
        XCTAssertEqual(replacement.immediateText, "")
        XCTAssertEqual(String(replacement.animatedCharacters), "새 응답")

        let immediate = StreamingTextPacer.updatePlan(
            current: "이전 응답",
            target: "새 응답",
            animates: false
        )
        XCTAssertEqual(immediate.immediateText, "새 응답")
        XCTAssertTrue(immediate.animatedCharacters.isEmpty)
    }
}
