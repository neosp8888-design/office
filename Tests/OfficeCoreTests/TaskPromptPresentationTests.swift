// 이 파일은 실행용 업무 문구의 첨부 접미부가 표시용 데이터로 안전하게 분리되는지 검증한다.

import XCTest
@testable import OfficeCore
@testable import OfficeGame

final class TaskPromptPresentationTests: XCTestCase {
    func testOnlyImageThumbnailUsesPreviewAction() {
        XCTAssertEqual(
            taskAttachmentOpenActionTitle(
                for: "/tmp/screenshot.png",
                isThumbnail: true
            ),
            "미리보기에서 열기"
        )
        XCTAssertEqual(
            taskAttachmentOpenActionTitle(
                for: "/tmp/screenshot.png",
                isThumbnail: false
            ),
            "Finder에서 보기"
        )
        XCTAssertEqual(
            taskAttachmentOpenActionTitle(
                for: "/tmp/report.pdf",
                isThumbnail: true
            ),
            "Finder에서 보기"
        )
    }

    func testSeparatesCanonicalAttachmentBlock() {
        let presentation = TaskPromptPresentation(
            prompt: """
            화면을 확인해줘.

            첨부 파일
            다음 로컬 파일을 업무 자료로 사용하세요.
            - "화면.png": "/Users/example/office/.office-attachments/abc/01-화면.png"
            """
        )

        XCTAssertEqual(presentation.text, "화면을 확인해줘.")
        XCTAssertEqual(
            presentation.attachments,
            [
                TaskPromptAttachment(
                    name: "화면.png",
                    path: "/Users/example/office/.office-attachments/abc/01-화면.png"
                ),
            ]
        )
    }

    func testSeparatesMultipleJSONEscapedAttachments() {
        let presentation = TaskPromptPresentation(
            prompt: #"""
            두 파일을 비교해줘.

            첨부 파일
            다음 로컬 파일을 업무 자료로 사용하세요.
            - "a \"quote\".txt": "/tmp/a \"quote\".txt"
            - "보고서.pdf": "/tmp/보고서.pdf"
            """#
        )

        XCTAssertEqual(presentation.text, "두 파일을 비교해줘.")
        XCTAssertEqual(presentation.attachments.count, 2)
        XCTAssertEqual(presentation.attachments[0].name, "a \"quote\".txt")
        XCTAssertEqual(
            presentation.attachments[0].path,
            "/tmp/a \"quote\".txt"
        )
        XCTAssertEqual(presentation.attachments[1].name, "보고서.pdf")
    }

    func testLeavesOrdinaryPromptUnchanged() {
        let prompt = "첨부 파일이라는 제목을 화면에 써줘."
        let presentation = TaskPromptPresentation(prompt: prompt)

        XCTAssertEqual(presentation.text, prompt)
        XCTAssertTrue(presentation.attachments.isEmpty)
    }

    func testMalformedAttachmentBlockFallsBackToRawPrompt() {
        let prompt = """
        내용을 확인해줘.

        첨부 파일
        다음 로컬 파일을 업무 자료로 사용하세요.
        - 경로가 없는 파일
        """
        let presentation = TaskPromptPresentation(prompt: prompt)

        XCTAssertEqual(presentation.text, prompt)
        XCTAssertTrue(presentation.attachments.isEmpty)
    }

    func testBuildsCanonicalAttachmentPromptForImmediateDisplay() {
        let prompt = TaskPromptPresentation.canonicalPrompt(
            text: "파일을 확인해줘.",
            attachmentPaths: [
                "/tmp/a \"quote\".txt",
                "/tmp/a \"quote\".txt",
                "/tmp/보고서.pdf",
            ]
        )
        let presentation = TaskPromptPresentation(prompt: prompt)

        XCTAssertEqual(presentation.text, "파일을 확인해줘.")
        XCTAssertEqual(
            presentation.attachments,
            [
                TaskPromptAttachment(
                    name: "a \"quote\".txt",
                    path: "/tmp/a \"quote\".txt"
                ),
                TaskPromptAttachment(
                    name: "보고서.pdf",
                    path: "/tmp/보고서.pdf"
                ),
            ]
        )
    }
}
