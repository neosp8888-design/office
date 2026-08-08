// 이 파일은 백엔드 중지와 재기동에 쓰는 launchctl 명령 구성을 검증한다.

import Foundation
import XCTest
@testable import OfficeGame

final class OfficeBackendLaunchCommandsTests: XCTestCase {
    private let configuration = OfficeBackendLaunchConfiguration(
        workdir: URL(fileURLWithPath: "/Users/example/project"),
        backendDirectoryURL: URL(
            fileURLWithPath: "/Applications/OFFICESTRA.app/Contents/Resources/OFFICESTRARuntime/backend"
        ),
        healthURL: URL(string: "http://127.0.0.1:4317/health")!,
        runtimeConfigurationURL: URL(
            fileURLWithPath: "/Applications/OFFICESTRA.app/Contents/Resources/OfficeLLM_OfficeCore.bundle/characters.json"
        ),
        releaseID: "release-test",
        userID: 501
    )

    func testStopBootsOutOnlyTheOfficeBackendJob() {
        let command = OfficeBackendLaunchCommands.stop(
            configuration: configuration
        )

        XCTAssertEqual(command.executableURL.path, "/bin/launchctl")
        XCTAssertEqual(
            command.arguments,
            ["bootout", "gui/501/com.neo.office-backend-4317"]
        )
    }

    func testRestartTargetsTheExistingOfficeBackendJob() {
        let command = OfficeBackendLaunchCommands.restart(
            configuration: configuration
        )

        XCTAssertEqual(
            command.arguments,
            ["kickstart", "-k", "gui/501/com.neo.office-backend-4317"]
        )
    }

    func testStartSubmitsOfficeBackendWithRuntimeConfiguration() {
        let command = OfficeBackendLaunchCommands.start(
            configuration: configuration,
            nodeExecutableURL: URL(fileURLWithPath: "/opt/homebrew/bin/node")
        )

        XCTAssertEqual(command.arguments.prefix(5), [
            "submit",
            "-l",
            "com.neo.office-backend-4317",
            "--",
            "/bin/zsh",
        ])
        XCTAssertTrue(command.arguments.last?.contains(
            "CHARACTER_CONFIG_PATH='/Applications/OFFICESTRA.app/Contents/Resources/OfficeLLM_OfficeCore.bundle/characters.json'"
        ) == true)
        XCTAssertTrue(command.arguments.last?.contains(
            "OFFICE_WORKDIR='/Users/example/project'"
        ) == true)
        XCTAssertTrue(command.arguments.last?.contains(
            "OFFICESTRA_RELEASE_ID='release-test'"
        ) == true)
        XCTAssertTrue(command.arguments.last?.contains(
            "cd '/Applications/OFFICESTRA.app/Contents/Resources/OFFICESTRARuntime/backend'"
        ) == true)
    }

    func testBundledBackendIsPreferredOverWorkspaceBackend() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        let resources = root.appending(path: "Resources")
        let bundledBackend = resources
            .appending(path: "OFFICESTRARuntime")
            .appending(path: "backend")
        let server = bundledBackend
            .appending(path: "src")
            .appending(path: "server.mjs")
        let workdir = root.appending(path: "SelectedProject")
        try FileManager.default.createDirectory(
            at: server.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: server.path,
            contents: Data()
        ))
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            OfficeBackendRuntimeLocation.resolve(
                resourceURL: resources,
                workdir: workdir
            ),
            bundledBackend
        )
    }

    func testSourceBackendIsUsedForSwiftRunWithAnotherWorkspace() throws {
        let root = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString)
        let resources = root.appending(path: "build/resources")
        let sourceRoot = root.appending(path: "OFFICESTRA")
        let server = sourceRoot.appending(path: "backend/src/server.mjs")
        let workdir = root.appending(path: "SelectedProject")
        try FileManager.default.createDirectory(
            at: server.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        XCTAssertTrue(FileManager.default.createFile(
            atPath: server.path,
            contents: Data()
        ))
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertEqual(
            OfficeBackendRuntimeLocation.resolve(
                resourceURL: resources,
                workdir: workdir,
                developmentRoot: sourceRoot
            ),
            sourceRoot.appending(path: "backend")
        )
    }

    func testSourceCheckoutBackendRemainsDevelopmentFallback() {
        let resources = URL(fileURLWithPath: "/tmp/missing-resources")
        let workdir = URL(fileURLWithPath: "/Users/example/office")

        XCTAssertEqual(
            OfficeBackendRuntimeLocation.resolve(
                resourceURL: resources,
                workdir: workdir
            ),
            workdir.appending(path: "backend")
        )
    }
}
