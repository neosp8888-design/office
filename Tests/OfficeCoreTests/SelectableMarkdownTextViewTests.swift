// Markdown 본문이 문단과 표 전체를 하나의 선택 범위로 제공하는지 검증한다.

import AppKit
import XCTest
@testable import OfficeGame

@MainActor
final class SelectableMarkdownTextViewTests: XCTestCase {
    func testChangedFileMarkdownListBecomesCompactPresentation() {
        let source = """
        새 통로를 적용했습니다.

        변경 파일:

        - [structured-turn-result.mjs](</Users/neo/office/backend/src/structured-turn-result.mjs:26>)

        - [officestra-result](</Users/neo/office/backend/src/officestra-result:1>)

        커밋·푸시는 요청이 없어 하지 않았습니다.
        """

        let presentation = ConversationChangedFileListPresentation(
            source: source
        )

        XCTAssertEqual(
            presentation.leadingMarkdown,
            "새 통로를 적용했습니다."
        )
        XCTAssertEqual(
            presentation.files,
            [
                ConversationChangedFileReference(
                    id: 0,
                    title: "structured-turn-result.mjs",
                    path: "/Users/neo/office/backend/src/structured-turn-result.mjs"
                ),
                ConversationChangedFileReference(
                    id: 1,
                    title: "officestra-result",
                    path: "/Users/neo/office/backend/src/officestra-result"
                ),
            ]
        )
        XCTAssertEqual(
            presentation.trailingMarkdown,
            "커밋·푸시는 요청이 없어 하지 않았습니다."
        )
    }

    func testChangedFileHeadingWithoutListKeepsOriginalMarkdown() {
        let source = """
        변경 파일:

        현재 변경된 파일은 없습니다.
        """
        let presentation = ConversationChangedFileListPresentation(
            source: source
        )

        XCTAssertEqual(presentation.leadingMarkdown, source)
        XCTAssertTrue(presentation.files.isEmpty)
        XCTAssertTrue(presentation.trailingMarkdown.isEmpty)
    }

    func testEnglishChangedFileListDoesNotTreatWebLinkAsFinderPath() {
        let presentation = ConversationChangedFileListPresentation(
            source: """
            Done.

            ### Changed files
            - [README](README.md)
            - [Release notes](https://example.com/release)
            """
        )

        XCTAssertEqual(presentation.files.count, 2)
        XCTAssertEqual(presentation.files[0].path, "README.md")
        XCTAssertNil(presentation.files[1].path)
    }

    func testInlineChangedFileSummaryBecomesCompactPresentation() {
        let source = """
        깔끔하게 처리했습니다.

        과거 답변에도 적용됩니다.
        수정 파일: ConversationMarkdownView.swift · AgentActivityLogView.swift · ClaudeTranscriptView.swift
        """

        let presentation = ConversationChangedFileListPresentation(
            source: source
        )

        XCTAssertEqual(
            presentation.leadingMarkdown,
            """
            깔끔하게 처리했습니다.

            과거 답변에도 적용됩니다.
            """
        )
        XCTAssertEqual(
            presentation.files,
            [
                ConversationChangedFileReference(
                    id: 0,
                    title: "ConversationMarkdownView.swift",
                    path: "ConversationMarkdownView.swift"
                ),
                ConversationChangedFileReference(
                    id: 1,
                    title: "AgentActivityLogView.swift",
                    path: "AgentActivityLogView.swift"
                ),
                ConversationChangedFileReference(
                    id: 2,
                    title: "ClaudeTranscriptView.swift",
                    path: "ClaudeTranscriptView.swift"
                ),
            ]
        )
        XCTAssertTrue(presentation.trailingMarkdown.isEmpty)
    }

    func testInlineChangedFileSummaryWithNoFilesStaysUnmodified() {
        let source = "수정 파일: 없음"
        let presentation = ConversationChangedFileListPresentation(
            source: source
        )

        XCTAssertEqual(presentation.leadingMarkdown, source)
        XCTAssertTrue(presentation.files.isEmpty)
    }

    func testNaturalKoreanFileReportWithLocalLinksBecomesCompactPresentation() {
        let source = """
        이제 제가 쓴 `수정 파일: A · B · C` 형식도 접힌 카드로 표시됩니다. 과거 답변에도 적용됩니다.

        Swift 테스트 490개 전부 통과했고 앱 재빌드·서명도 완료했습니다. 앱을 완전히 종료 후 다시 열면 확인됩니다. 4317 백엔드는 재시작하지 않았습니다.

        이번 보완 파일은 [ConversationMarkdownView.swift](/Users/neo/office/Sources/OfficeGame/ConversationMarkdownView.swift)와 [SelectableMarkdownTextViewTests.swift](/Users/neo/office/Tests/OfficeCoreTests/SelectableMarkdownTextViewTests.swift)입니다.
        """

        let presentation = ConversationChangedFileListPresentation(
            source: source
        )

        XCTAssertEqual(
            presentation.leadingMarkdown,
            """
            이제 제가 쓴 `수정 파일: A · B · C` 형식도 접힌 카드로 표시됩니다. 과거 답변에도 적용됩니다.

            Swift 테스트 490개 전부 통과했고 앱 재빌드·서명도 완료했습니다. 앱을 완전히 종료 후 다시 열면 확인됩니다. 4317 백엔드는 재시작하지 않았습니다.
            """
        )
        XCTAssertEqual(
            presentation.files,
            [
                ConversationChangedFileReference(
                    id: 0,
                    title: "ConversationMarkdownView.swift",
                    path: "/Users/neo/office/Sources/OfficeGame/ConversationMarkdownView.swift"
                ),
                ConversationChangedFileReference(
                    id: 1,
                    title: "SelectableMarkdownTextViewTests.swift",
                    path: "/Users/neo/office/Tests/OfficeCoreTests/SelectableMarkdownTextViewTests.swift"
                ),
            ]
        )
        XCTAssertTrue(presentation.trailingMarkdown.isEmpty)
    }

    func testOrdinaryLocalFileLinkWithoutReportCueStaysUnmodified() {
        let source = "자세한 내용은 [README](README.md)를 확인하세요."
        let presentation = ConversationChangedFileListPresentation(
            source: source
        )

        XCTAssertEqual(presentation.leadingMarkdown, source)
        XCTAssertTrue(presentation.files.isEmpty)
    }

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

    func testRepeatedHeightRequestsReuseTextKitLayoutUntilInputChanges() {
        let documentView = SelectableMarkdownDocumentView(fontSize: 12)
        documentView.apply(
            source: String(
                repeating: "긴 Markdown 문단입니다. **선택 가능**해야 합니다.\n\n",
                count: 40
            ),
            fallbackDirectory: nil,
            isDark: false
        )

        let firstHeight = documentView.heightThatFits(width: 520)
        let firstMeasurementCount = documentView.textLayoutMeasurementCount
        XCTAssertGreaterThan(firstHeight, 0)
        XCTAssertEqual(firstMeasurementCount, 1)

        documentView.frame = NSRect(
            x: 0,
            y: 0,
            width: 520,
            height: firstHeight
        )
        for _ in 0..<50 {
            XCTAssertEqual(
                documentView.heightThatFits(width: 520),
                firstHeight
            )
            documentView.layout()
        }
        XCTAssertEqual(
            documentView.textLayoutMeasurementCount,
            firstMeasurementCount,
            "같은 내용과 폭의 SwiftUI 재배치는 TextKit 전체 측정을 반복하면 안 됩니다."
        )

        _ = documentView.heightThatFits(width: 360)
        XCTAssertEqual(
            documentView.textLayoutMeasurementCount,
            firstMeasurementCount + 1,
            "폭이 달라지면 새 레이아웃 높이를 한 번 측정해야 합니다."
        )

        documentView.apply(
            source: "교체된 본문\n\n| 항목 | 상태 |\n| --- | --- |\n| 캐시 | 갱신 |",
            fallbackDirectory: nil,
            isDark: false
        )
        let changedSourceMeasurementCount =
            documentView.textLayoutMeasurementCount
        XCTAssertEqual(
            changedSourceMeasurementCount,
            firstMeasurementCount + 2,
            "본문이 달라지면 현재 폭으로 새 높이를 측정해야 합니다."
        )

        _ = documentView.heightThatFits(width: 360)
        XCTAssertEqual(
            documentView.textLayoutMeasurementCount,
            changedSourceMeasurementCount,
            "변경된 본문도 첫 측정 뒤 같은 폭에서는 캐시를 재사용해야 합니다."
        )
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

    func testLocalMarkdownLinkClickOpensResolvedFile() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }
        let fileURL = directory.appending(path: "episode 03.png")
        try Data([0]).write(to: fileURL)
        let documentView = SelectableMarkdownDocumentView(fontSize: 12)
        documentView.apply(
            source: "[결과 파일](<\(fileURL.path)>)",
            fallbackDirectory: nil,
            isDark: false
        )

        var openedURL: URL?
        documentView.linkOpener = { url in
            openedURL = url
            return true
        }
        let link = try XCTUnwrap(
            documentView.textView.textStorage?.attribute(
                .link,
                at: 0,
                effectiveRange: nil
            )
        )

        XCTAssertTrue(
            documentView.textView(
                documentView.textView,
                clickedOnLink: link,
                at: 0
            )
        )
        XCTAssertEqual(openedURL, fileURL.standardizedFileURL)
    }

    func testWebMarkdownLinkUsesExternalOpener() throws {
        let documentView = SelectableMarkdownDocumentView(fontSize: 12)
        documentView.apply(
            source: "[웹](https://example.com/result)",
            fallbackDirectory: nil,
            isDark: false
        )

        var openedURL: URL?
        documentView.linkOpener = { url in
            openedURL = url
            return true
        }
        let link = try XCTUnwrap(
            documentView.textView.textStorage?.attribute(
                .link,
                at: 0,
                effectiveRange: nil
            )
        )

        XCTAssertTrue(
            documentView.textView(
                documentView.textView,
                clickedOnLink: link,
                at: 0
            )
        )
        XCTAssertEqual(openedURL?.absoluteString, "https://example.com/result")
    }
}
