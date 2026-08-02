// 이 파일은 백엔드 중지와 재기동에 쓰는 launchctl 명령 구성을 검증한다.

import Foundation
import XCTest
@testable import OfficeGame

final class OfficeBackendLaunchCommandsTests: XCTestCase {
    private let configuration = OfficeBackendLaunchConfiguration(
        workdir: URL(fileURLWithPath: "/Users/neo/office"),
        healthURL: URL(string: "http://127.0.0.1:4317/health")!,
        runtimeConfigurationURL: URL(
            fileURLWithPath: "/Applications/OFFICESTRA.app/Contents/Resources/OfficeLLM_OfficeCore.bundle/characters.json"
        ),
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
            "OFFICE_WORKDIR='/Users/neo/office'"
        ) == true)
        XCTAssertTrue(command.arguments.last?.contains(
            "cd '/Users/neo/office/backend'"
        ) == true)
    }
}
