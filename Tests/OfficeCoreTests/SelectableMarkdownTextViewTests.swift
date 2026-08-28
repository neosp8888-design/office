// Markdown 본문이 문단과 표 전체를 하나의 선택 범위로 제공하는지 검증한다.

import AppKit
import XCTest
@testable import OfficeGame

@MainActor
final class SelectableMarkdownTextViewTests: XCTestCase {
    func testSelectionCrossesParagraphsAndTableCells() throws {
        let source = """
        첫 문단입니다.

        둘째 문단입니다.

        | 항목 | 결과 |
        | --- | --- |
        | 문단 선택 | 통과 |
        | 표 선택 | 통과 |

        마지막 문단입니다.
        """
        let documentView = SelectableMarkdownDocumentView(fontSize: 12)
        documentView.apply(
            source: source,
            fallbackDirectory: nil,
            isDark: false
        )
        documentView.frame = NSRect(x: 0, y: 0, width: 560, height: 500)
        _ = documentView.heightThatFits(width: 560)
        documentView.layoutSubtreeIfNeeded()

        let rendered = documentView.textView.string as NSString
        let start = rendered.range(of: "첫 문단입니다.").location
        let endRange = rendered.range(of: "마지막 문단입니다.")
        XCTAssertNotEqual(start, NSNotFound)
        XCTAssertNotEqual(endRange.location, NSNotFound)

        let selectedRange = NSRange(
            location: start,
            length: NSMaxRange(endRange) - start
        )
        documentView.textView.setSelectedRange(selectedRange)

        let copied = rendered.substring(with: selectedRange)
        XCTAssertTrue(copied.contains("첫 문단입니다."))
        XCTAssertTrue(copied.contains("둘째 문단입니다."))
        XCTAssertTrue(copied.contains("항목"))
        XCTAssertTrue(copied.contains("문단 선택"))
        XCTAssertTrue(copied.contains("표 선택"))
        XCTAssertTrue(copied.contains("마지막 문단입니다."))
    }

    func testTableUsesNativeTextTableBlocks() {
        let rendered = SelectableMarkdownAttributedRenderer.render(
            source: """
            | A | B |
            | --- | --- |
            | 1 | 2 |
            """,
            fontSize: 12,
            fallbackDirectory: nil,
            isDark: false
        )

        var foundTableBlock = false
        rendered.enumerateAttribute(
            .paragraphStyle,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, stop in
            guard
                let paragraphStyle = value as? NSParagraphStyle,
                !paragraphStyle.textBlocks.isEmpty
            else {
                return
            }
            foundTableBlock = true
            stop.pointee = true
        }
        XCTAssertTrue(foundTableBlock)
    }

    func testSingleNewlinesRemainVisibleAndSelectable() {
        let rendered = SelectableMarkdownAttributedRenderer.render(
            source: "첫째 줄\n둘째 줄\n셋째 줄",
            fontSize: 12,
            fallbackDirectory: nil,
            isDark: false
        )

        XCTAssertEqual(rendered.string, "첫째 줄\n둘째 줄\n셋째 줄\n")
    }

    func testNarrowTableKeepsReadableWidthForHorizontalScrolling() {
        let documentView = SelectableMarkdownDocumentView(
            fontSize: 12,
            minimumLayoutWidth: 330
        )
        documentView.apply(
            source: """
            | 긴 항목 이름 | 현재 상태 | 비고 |
            | --- | --- | --- |
            | 문단 선택 | 통과 | 연속 범위 |
            """,
            fallbackDirectory: nil,
            isDark: false
        )
        let width = CGFloat(170)
        let height = documentView.heightThatFits(width: width)
        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: width,
            height: height
        )
        documentView.layout()

        XCTAssertGreaterThan(
            documentView.textView.frame.width,
            width,
            "좁은 보관함에서도 표 열이 한 글자 폭으로 찌그러지면 안 됩니다."
        )
    }

    func testSegmenterKeepsParagraphsAndTablesInOneSelectionDocument() {
        let segments = SelectableMarkdownSegmenter.split(
            """
            첫 문단입니다.

            둘째 문단입니다.

            | 항목 | 상태 | 비고 |
            | --- | --- | --- |
            | 문단 | 통과 | 연속 선택 |

            마지막 문단입니다.
            """
        )

        XCTAssertEqual(segments.count, 1)
        XCTAssertEqual(segments[0].kind, .table(columnCount: 3))
        XCTAssertEqual(segments[0].minimumLayoutWidth, 330)
        XCTAssertTrue(segments[0].source.contains("첫 문단"))
        XCTAssertTrue(segments[0].source.contains("둘째 문단"))
        XCTAssertTrue(segments[0].source.contains("| 항목 | 상태 | 비고 |"))
        XCTAssertTrue(segments[0].source.contains("마지막 문단"))
    }

    func testTableViewportDoesNotAddNestedScrollView() {
        let documentView = SelectableMarkdownDocumentView(
            fontSize: 12,
            minimumLayoutWidth: 440
        )
        documentView.apply(
            source: "문단\n\n| A | B | C | D |\n| --- | --- | --- | --- |\n| 1 | 2 | 3 | 4 |",
            fallbackDirectory: nil,
            isDark: false
        )
        let height = documentView.heightThatFits(width: 220)
        documentView.frame = NSRect(x: 0, y: 0, width: 220, height: height)
        documentView.layoutSubtreeIfNeeded()

        func descendants(of view: NSView) -> [NSView] {
            view.subviews.flatMap { [$0] + descendants(of: $0) }
        }

        XCTAssertFalse(
            descendants(of: documentView).contains { $0 is NSScrollView },
            "표의 가로 이동 영역이 직원별 세로 대화 스크롤과 중첩되면 안 됩니다."
        )
    }

    func testRemoteImagesAreRemovedBeforeHTMLImport() {
        let rendered = SelectableMarkdownAttributedRenderer.render(
            source: "앞 ![원격 이미지](https://example.com/tracker.png) 뒤",
            fontSize: 12,
            fallbackDirectory: nil,
            isDark: false
        )

        XCTAssertFalse(rendered.string.contains("tracker.png"))
        XCTAssertTrue(rendered.string.contains("원격 이미지"))
        var foundAttachment = false
        rendered.enumerateAttribute(
            .attachment,
            in: NSRange(location: 0, length: rendered.length)
        ) { value, _, stop in
            guard value != nil else {
                return
            }
            foundAttachment = true
            stop.pointee = true
        }
        XCTAssertFalse(foundAttachment)
    }
}
