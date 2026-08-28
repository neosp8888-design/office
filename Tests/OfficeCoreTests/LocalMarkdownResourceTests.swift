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

    func testMissingWorktreeLinkFallsBackToMergedRepositoryFile() throws {
        let repository = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        let mergedFile = repository
            .appending(path: "Sources/OfficeCore/sample.mp4")
        try FileManager.default.createDirectory(
            at: mergedFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data([0]).write(to: mergedFile)
        defer {
            try? FileManager.default.removeItem(at: repository)
        }

        let staleURL = URL(
            fileURLWithPath:
                "/Users/example/.officestra/worktrees/project/task/"
                    + "Sources/OfficeCore/sample.mp4"
        )

        XCTAssertEqual(
            LocalMarkdownResource.existingFileURL(
                from: staleURL,
                fallbackDirectory: repository
            ),
            mergedFile.standardizedFileURL
        )
        XCTAssertEqual(
            LocalMarkdownResource.videoFileURLs(
                in: "[영상 보기](<\(staleURL.path)>)",
                fallbackDirectory: repository
            ),
            [mergedFile.standardizedFileURL]
        )
    }

    func testLocalVideoLinkProvidesOneInlinePreviewURL() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let videoURL = directory.appending(path: "sample video.mp4")
        try Data([0]).write(to: videoURL)
        let markdown = """
        [영상 보기](<\(videoURL.path)>)

        \(videoURL.path)
        """

        XCTAssertEqual(
            LocalMarkdownResource.videoFileURLs(
                in: markdown,
                fallbackDirectory: nil
            ),
            [videoURL.standardizedFileURL]
        )
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
        XCTAssertEqual(
            LocalMarkdownResource.imageFileURLs(
                in: "\(markdown)\n\n![미리보기](<\(imageURL.path)>)",
                fallbackDirectory: nil
            ),
            [imageURL.standardizedFileURL]
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

    func testCopiedImageIsShownOnceAndExplicitProjectLinkWins() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        defer {
            try? FileManager.default.removeItem(at: directory)
        }

        let generated = directory.appending(path: "generated.png")
        let projectCopy = directory.appending(path: "episode-03.png")
        let imageBytes = Data("same-image".utf8)
        try imageBytes.write(to: generated)
        try imageBytes.write(to: projectCopy)
        let markdown = """
        [결과 파일](<\(projectCopy.path)>)

        [![생성 이미지 1](<\(generated.absoluteString)>)](<\(generated.absoluteString)>)
        """

        XCTAssertEqual(
            LocalMarkdownResource.imageFileURLs(
                in: markdown,
                fallbackDirectory: nil
            ),
            [projectCopy.standardizedFileURL]
        )
    }

    func testGeneratedPreviewLinksAreRemovedFromVisibleMarkdown() {
        let markdown = """
        결과: [episode-03.png](</tmp/episode-03.png>)

        [![생성 이미지 1](<file:///tmp/generated.png>)](<file:///tmp/generated.png>)

        [![생성 이미지 2](<file:///tmp/copied.png>)](<file:///tmp/copied.png>)
        """

        XCTAssertEqual(
            LocalMarkdownResource.removingGeneratedImagePreviews(
                from: markdown
            ),
            "결과: [episode-03.png](</tmp/episode-03.png>)"
        )
    }
}
