// 이 파일은 첫 실행 업무 폴더 선택과 기존 설정 대체 규칙을 검증한다.

import Foundation
import XCTest
@testable import OfficeGame

@MainActor
final class OfficeWorkspacePreferenceTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        root = nil
    }

    func testPersistedRepositoryWinsOverConfiguredRepository() throws {
        let persisted = try makeRepository(named: "persisted")
        let configured = try makeRepository(named: "configured")

        XCTAssertEqual(
            OfficeWorkspacePreference.resolve(
                persistedPath: persisted.path,
                configuredPath: configured.path
            ),
            .ready(persisted.path)
        )
    }

    func testInvalidPersistedPathRequiresSelection() throws {
        let configured = try makeRepository(named: "configured")

        XCTAssertEqual(
            OfficeWorkspacePreference.resolve(
                persistedPath: root.appending(path: "missing").path,
                configuredPath: configured.path
            ),
            .needsSelection
        )
    }

    func testEmptyPersistedPathFallsBackToConfiguredRepository() throws {
        let configured = try makeRepository(named: "configured")

        XCTAssertEqual(
            OfficeWorkspacePreference.resolve(
                persistedPath: "  ",
                configuredPath: configured.path
            ),
            .ready(configured.path)
        )
    }

    func testMissingRepositoriesRequireSelection() {
        XCTAssertEqual(
            OfficeWorkspacePreference.resolve(
                persistedPath: nil,
                configuredPath: root.appending(path: "missing").path
            ),
            .needsSelection
        )
    }

    func testRegularDirectoryWithoutGitMetadataIsAccepted() throws {
        let directory = root.appending(path: "ordinary")
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        XCTAssertEqual(
            OfficeWorkspacePreference.validWorkspacePath(directory.path),
            directory.path
        )
    }

    func testLinkedWorktreeGitFileIsAccepted() throws {
        let worktree = root.appending(path: "worktree")
        try FileManager.default.createDirectory(
            at: worktree,
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: worktree.appending(path: ".git").path,
            contents: Data("gitdir: /tmp/example".utf8)
        ))

        XCTAssertEqual(
            OfficeWorkspacePreference.validWorkspacePath(worktree.path),
            worktree.path
        )
    }

    func testFileAndMissingPathAreRejected() throws {
        let file = root.appending(path: "not-a-folder")
        XCTAssertTrue(FileManager.default.createFile(
            atPath: file.path,
            contents: Data()
        ))

        XCTAssertNil(
            OfficeWorkspacePreference.validWorkspacePath(file.path)
        )
        XCTAssertNil(
            OfficeWorkspacePreference.validWorkspacePath(
                root.appending(path: "missing").path
            )
        )
    }

    func testRootAndHomeDirectoriesAreRejected() throws {
        let home = root.appending(path: "home")
        try FileManager.default.createDirectory(
            at: home,
            withIntermediateDirectories: true
        )

        XCTAssertNil(
            OfficeWorkspacePreference.validWorkspacePath(
                "/",
                homeDirectory: home
            )
        )
        XCTAssertNil(
            OfficeWorkspacePreference.validWorkspacePath(
                home.path,
                homeDirectory: home
            )
        )
    }

    func testAgentDirectorUsesSelectedWorkspaceOverride() {
        let director = AgentDirector(
            startBackgroundTasks: false,
            workspaceDirectory: "/Users/example/selected-project"
        )
        let workspaceDirectory = director.workspaceDirectory

        XCTAssertEqual(
            workspaceDirectory,
            "/Users/example/selected-project"
        )
    }

    func testEnglishWorkspaceSetupTitleIsLocalized() {
        XCTAssertEqual(
            OfficeLocalization.string(
                "OFFICESTRA 시작하기",
                languages: ["en-US"]
            ),
            "Get Started with OFFICESTRA"
        )
    }

    private func makeRepository(named name: String) throws -> URL {
        let repository = root.appending(path: name)
        try FileManager.default.createDirectory(
            at: repository.appending(path: ".git"),
            withIntermediateDirectories: true
        )
        return repository
    }
}
