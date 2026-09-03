// 터미널 모드에서 하단 바가 프로필·설정만 남기는지 검증한다.

import XCTest

@testable import OfficeGame

final class LiveWorkspaceCommandAvailabilityTests: XCTestCase {
    func testChatModeKeepsEveryControlEnabled() {
        for control in allControls {
            XCTAssertTrue(
                LiveWorkspaceCommandAvailability.isEnabled(control, in: .chat)
            )
            XCTAssertEqual(
                LiveWorkspaceCommandAvailability.opacity(control, in: .chat),
                1
            )
        }
    }

    func testTerminalModeLeavesOnlyProfileAndSettings() {
        XCTAssertTrue(
            LiveWorkspaceCommandAvailability.isEnabled(.profile, in: .terminal)
        )
        XCTAssertTrue(
            LiveWorkspaceCommandAvailability.isEnabled(
                .identitySettings,
                in: .terminal
            )
        )
        XCTAssertFalse(
            LiveWorkspaceCommandAvailability.isEnabled(
                .characterSelector,
                in: .terminal
            )
        )
        XCTAssertFalse(
            LiveWorkspaceCommandAvailability.isEnabled(
                .quickSettings,
                in: .terminal
            )
        )
    }

    // 눌리지 않는 것만으로는 부족하고 비활성인 것이 보여야 한다.
    func testLockedControlsLookDimmedInTerminalMode() {
        for control in [
            LiveWorkspaceCommandAvailability.Control.characterSelector,
            .quickSettings,
        ] {
            XCTAssertEqual(
                LiveWorkspaceCommandAvailability.opacity(
                    control,
                    in: .terminal
                ),
                LiveWorkspaceCommandAvailability.lockedOpacity
            )
        }
        XCTAssertLessThan(LiveWorkspaceCommandAvailability.lockedOpacity, 1)
        for control in [
            LiveWorkspaceCommandAvailability.Control.profile,
            .identitySettings,
        ] {
            XCTAssertEqual(
                LiveWorkspaceCommandAvailability.opacity(
                    control,
                    in: .terminal
                ),
                1
            )
        }
    }

    private var allControls: [LiveWorkspaceCommandAvailability.Control] {
        [.characterSelector, .quickSettings, .profile, .identitySettings]
    }
}
