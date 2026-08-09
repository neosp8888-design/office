import Foundation
import XCTest
@testable import OfficeGame

final class AttachmentInboxTests: XCTestCase {
    private var testDirectory: URL!
    private var inboxDirectory: URL!
    private var inbox: AttachmentInbox!

    override func setUpWithError() throws {
        testDirectory = FileManager.default.temporaryDirectory.appending(
            path: "officestra-attachment-inbox-tests-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        inboxDirectory = testDirectory.appending(
            path: "AttachmentInbox",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: testDirectory,
            withIntermediateDirectories: true
        )
        inbox = AttachmentInbox(rootDirectory: inboxDirectory)
    }

    override func tearDownWithError() throws {
        if let testDirectory {
            try? FileManager.default.removeItem(at: testDirectory)
        }
        inbox = nil
        inboxDirectory = nil
        testDirectory = nil
    }

    func testStageCopiesRegularFileIntoPrivateInbox() throws {
        let source = testDirectory.appending(path: "화면.png")
        let payload = Data("attachment".utf8)
        try payload.write(to: source)

        let attachment = try inbox.stage(source)

        XCTAssertEqual(attachment.sourceURL, source.standardizedFileURL)
        XCTAssertEqual(attachment.displayName, "화면.png")
        XCTAssertTrue(
            attachment.stagedURL.path.hasPrefix(inboxDirectory.path + "/")
        )
        XCTAssertEqual(try Data(contentsOf: attachment.stagedURL), payload)
        let attributes = try FileManager.default.attributesOfItem(
            atPath: attachment.stagedURL.path
        )
        let permissions = try XCTUnwrap(
            attributes[.posixPermissions] as? NSNumber
        ).intValue
        XCTAssertEqual(permissions & 0o777, 0o600)
    }

    func testSameNamedFilesUseDifferentInboxDirectories() throws {
        let firstDirectory = testDirectory.appending(path: "first")
        let secondDirectory = testDirectory.appending(path: "second")
        try FileManager.default.createDirectory(
            at: firstDirectory,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: secondDirectory,
            withIntermediateDirectories: true
        )
        let first = firstDirectory.appending(path: "capture.png")
        let second = secondDirectory.appending(path: "capture.png")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)

        let firstAttachment = try inbox.stage(first)
        let secondAttachment = try inbox.stage(second)

        XCTAssertNotEqual(
            firstAttachment.stagedURL.deletingLastPathComponent(),
            secondAttachment.stagedURL.deletingLastPathComponent()
        )
        XCTAssertEqual(firstAttachment.displayName, secondAttachment.displayName)
        XCTAssertEqual(
            try Data(contentsOf: firstAttachment.stagedURL),
            Data("first".utf8)
        )
        XCTAssertEqual(
            try Data(contentsOf: secondAttachment.stagedURL),
            Data("second".utf8)
        )
    }

    func testDirectoryIsRejected() throws {
        let directory = testDirectory.appending(
            path: "folder",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        XCTAssertThrowsError(try inbox.stage(directory)) { error in
            XCTAssertEqual(
                error.localizedDescription,
                "일반 파일만 첨부할 수 있습니다: folder"
            )
        }
    }

    func testBatchKeepsValidFilesWhenAnotherItemFails() throws {
        let source = testDirectory.appending(path: "valid.txt")
        try Data("valid".utf8).write(to: source)
        let directory = testDirectory.appending(
            path: "folder",
            directoryHint: .isDirectory
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        let batch = inbox.stage([source, directory])

        XCTAssertEqual(batch.attachments.count, 1)
        XCTAssertEqual(batch.attachments.first?.displayName, "valid.txt")
        XCTAssertEqual(
            batch.errorDescriptions,
            ["일반 파일만 첨부할 수 있습니다: folder"]
        )
    }

    func testRemoveDeletesOnlyStagedItemDirectory() throws {
        let source = testDirectory.appending(path: "remove.txt")
        try Data("remove".utf8).write(to: source)
        let attachment = try inbox.stage(source)
        let itemDirectory = attachment.stagedURL.deletingLastPathComponent()

        inbox.remove(attachment)

        XCTAssertFalse(FileManager.default.fileExists(atPath: itemDirectory.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path))
    }

    func testStaleCleanupPreservesActiveDraft() throws {
        let activeSource = testDirectory.appending(path: "active.txt")
        let staleSource = testDirectory.appending(path: "stale.txt")
        try Data("active".utf8).write(to: activeSource)
        try Data("stale".utf8).write(to: staleSource)
        let activeAttachment = try inbox.stage(activeSource)
        let staleAttachment = try inbox.stage(staleSource)
        let oldDate = Date(timeIntervalSince1970: 100)
        for attachment in [activeAttachment, staleAttachment] {
            try FileManager.default.setAttributes(
                [.modificationDate: oldDate],
                ofItemAtPath: attachment.stagedURL
                    .deletingLastPathComponent().path
            )
        }

        inbox.removeStaleItems(
            excluding: [activeAttachment],
            now: Date(timeIntervalSince1970: 200),
            maximumAge: 50
        )

        XCTAssertTrue(
            FileManager.default.fileExists(
                atPath: activeAttachment.stagedURL.path
            )
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: staleAttachment.stagedURL.path
            )
        )
    }
}
