// 이 파일은 스트리밍 Markdown 분할이 줄 단위로 렌더링되고 문법을 깨지 않는지 검증한다.

import XCTest

@testable import OfficeCore

final class StreamingMarkdownSplitterTests: XCTestCase {
    func testCompletedLineRendersWithoutWaitingForBlankLine() {
        let segments = StreamingMarkdownSplitter.split(
            """
            ## 제목
            **굵은** 문장입니다.
            아직 쓰는 중
            """
        )

        XCTAssertEqual(segments.settledMarkdown, "")
        XCTAssertEqual(
            segments.activeMarkdown,
            """
            ## 제목
            **굵은** 문장입니다.
            """
        )
        XCTAssertEqual(segments.openLine, "아직 쓰는 중")
    }

    func testBlankLineMovesEarlierBlockIntoSettledRegion() {
        let segments = StreamingMarkdownSplitter.split(
            """
            첫 문단입니다.

            | 항목 | 값 |
            |---|---|
            | 하나 | 1 |
            """
        )

        XCTAssertEqual(segments.settledMarkdown, "첫 문단입니다.")
        XCTAssertEqual(
            segments.activeMarkdown,
            """
            | 항목 | 값 |
            |---|---|
            """
        )
        XCTAssertEqual(segments.openLine, "| 하나 | 1 |")
    }

    func testTableRowsAppearAsTheyComplete() {
        let segments = StreamingMarkdownSplitter.split(
            """
            | 항목 | 값 |
            |---|---|
            | 하나 | 1 |
            | 둘 |
            """
        )

        // 구분선과 완성된 행까지는 곧바로 표로 렌더링한다.
        XCTAssertEqual(
            segments.activeMarkdown,
            """
            | 항목 | 값 |
            |---|---|
            | 하나 | 1 |
            """
        )
        XCTAssertEqual(segments.openLine, "| 둘 |")
    }

    func testOpenCodeFenceIsSpeculativelyClosed() {
        let segments = StreamingMarkdownSplitter.split(
            """
            설명입니다.

            ```swift
            let value = 1
            let other =
            """
        )

        XCTAssertEqual(segments.settledMarkdown, "설명입니다.")
        XCTAssertEqual(
            segments.activeMarkdown,
            """
            ```swift
            let value = 1
            ```
            """
        )
        XCTAssertEqual(segments.openLine, "let other =")
    }

    func testClosedCodeFenceIsNotDoubleClosed() {
        let segments = StreamingMarkdownSplitter.split(
            """
            ```swift
            let value = 1
            ```
            다음 줄
            """
        )

        XCTAssertEqual(
            segments.activeMarkdown,
            """
            ```swift
            let value = 1
            ```
            """
        )
        XCTAssertEqual(segments.openLine, "다음 줄")
    }

    func testBlankLineInsideCodeFenceIsNotASettledBoundary() {
        let segments = StreamingMarkdownSplitter.split(
            """
            ```swift
            let value = 1

            let other = 2
            ```

            다음 문단
            """
        )

        XCTAssertEqual(
            segments.settledMarkdown,
            """
            ```swift
            let value = 1

            let other = 2
            ```
            """
        )
        XCTAssertEqual(segments.activeMarkdown, "")
        XCTAssertEqual(segments.openLine, "다음 문단")
    }

    func testFirstPartialLineStaysPlain() {
        let segments = StreamingMarkdownSplitter.split("## 제목을 쓰는")

        XCTAssertEqual(segments.settledMarkdown, "")
        XCTAssertEqual(segments.activeMarkdown, "")
        XCTAssertEqual(segments.openLine, "## 제목을 쓰는")
    }

    func testSettledRegionNeverShrinksWhileStreaming() {
        let full = """
        첫 문단

        | 항목 | 값 |
        |---|---|
        | 하나 | 1 |

        ```swift
        let value = 1
        ```

        마지막 문단
        """
        var previousLength = 0

        for endIndex in 1 ... full.count {
            let settled = StreamingMarkdownSplitter
                .split(String(full.prefix(endIndex)))
                .settledMarkdown
            XCTAssertGreaterThanOrEqual(settled.count, previousLength)
            previousLength = settled.count
        }
    }

    func testSegmentsCoverTheWholeSource() {
        let source = """
        첫 문단

        둘째 줄
        셋째를 쓰는 중
        """
        let segments = StreamingMarkdownSplitter.split(source)
        let rejoined = [
            segments.settledMarkdown,
            segments.activeMarkdown,
            segments.openLine,
        ]
        .filter { !$0.isEmpty }
        .joined(separator: "\n")

        XCTAssertEqual(
            rejoined.replacingOccurrences(of: "\n", with: ""),
            source.replacingOccurrences(of: "\n", with: "")
        )
    }
}
