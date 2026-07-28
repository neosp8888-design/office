// 이 파일은 긴 한글과 이모지 응답의 적응형 타자 표시량을 검증한다.

import XCTest
@testable import OfficeCore

final class StreamingTextPacerTests: XCTestCase {
    func testEmptyBacklogDoesNotAdvance() {
        XCTAssertEqual(
            StreamingTextPacer.charactersPerFrame(
                remainingCharacterCount: 0
            ),
            0
        )
    }

    func testShortBacklogKeepsSingleCharacterFrames() {
        XCTAssertEqual(
            StreamingTextPacer.charactersPerFrame(
                remainingCharacterCount: 30
            ),
            1
        )
        XCTAssertEqual(
            StreamingTextPacer.charactersPerFrame(
                remainingCharacterCount: 31
            ),
            2
        )
    }

    func testLargeBacklogUsesBoundedBatches() {
        XCTAssertEqual(
            StreamingTextPacer.charactersPerFrame(
                remainingCharacterCount: 1_920
            ),
            64
        )
        XCTAssertEqual(
            StreamingTextPacer.charactersPerFrame(
                remainingCharacterCount: 20_000
            ),
            64
        )
    }

    func testBatchesPreserveUnicodeAndMarkdownText() {
        let target = String(
            repeating: "한글🙂 **굵게**\n| 열 | 값 |\n",
            count: 80
        )
        var rendered = ""
        var index = target.startIndex
        var remaining = target.count

        while remaining > 0 {
            let batch = StreamingTextPacer.charactersPerFrame(
                remainingCharacterCount: remaining
            )
            let count = min(batch, remaining)
            let nextIndex = target.index(index, offsetBy: count)
            rendered.append(contentsOf: target[index ..< nextIndex])
            index = nextIndex
            remaining -= count

            XCTAssertTrue(target.hasPrefix(rendered))
        }

        XCTAssertEqual(rendered, target)
    }
}
