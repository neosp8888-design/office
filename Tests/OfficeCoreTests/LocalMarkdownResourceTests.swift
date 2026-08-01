// 이 파일은 로컬 Markdown 링크의 파일 URL 변환과 이미지 미리보기 추가를 검증한다.

import Foundation
import XCTest
@testable import OfficeCore

final class LocalMarkdownResourceTests: XCTestCase {
    func testAbsolutePathBecomesFileURL() throws {
        let relativeURL = try XCTUnwrap(
            URL(string: "/Users/example/office/sample.png")
        )

        XCTAssertEqual(
            LocalMarkdownResource.fileURL(from: relativeURL)?.absoluteString,
            "file:///Users/example/office/sample.png"
        )
    }

    func testWebURLIsNotTreatedAsLocalFile() throws {
        let webURL = try XCTUnwrap(
            URL(string: "https://example.com/sample.png")
        )

        XCTAssertNil(LocalMarkdownResource.fileURL(from: webURL))
    }

    func testLocalImageLinkAddsInlinePreview() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let imageURL = directory.appending(path: "sample image.png")
        try Data([0]).write(to: imageURL)
        let markdown = "[이미지 열기](<\(imageURL.path)>)"
        let rendered = LocalMarkdownResource.addingLinkedImagePreviews(
            to: markdown
        )

        XCTAssertTrue(rendered.contains(markdown))
        XCTAssertTrue(
            rendered.contains(
                "[![생성 이미지 1](<\(imageURL.absoluteString)>)]"
            )
        )
        XCTAssertEqual(
            LocalMarkdownResource.addingLinkedImagePreviews(to: rendered),
            rendered
        )
    }

    func testBareLocalImagePathAddsInlinePreview() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let imageURL = directory.appending(path: "Claude preview.png")
        try Data([0]).write(to: imageURL)
        let markdown = """
        절대경로입니다.

        ```
        \(imageURL.path)
        ```
        """
        let rendered = LocalMarkdownResource.addingLinkedImagePreviews(
            to: markdown
        )

        XCTAssertTrue(rendered.contains(markdown))
        XCTAssertTrue(
            rendered.contains(
                "[![생성 이미지 1](<\(imageURL.absoluteString)>)]"
            )
        )
        XCTAssertEqual(
            LocalMarkdownResource.addingLinkedImagePreviews(to: rendered),
            rendered
        )
    }
}
