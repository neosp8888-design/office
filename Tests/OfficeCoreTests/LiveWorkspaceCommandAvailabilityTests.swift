// 터미널 모드에서 하단 바가 실행 설정만 잠그는지 검증한다.

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

    func testTerminalModeLocksOnlyQuickSettings() {
        XCTAssertFalse(
            LiveWorkspaceCommandAvailability.isEnabled(
                .quickSettings,
                in: .terminal
            )
        )
        for control in [
            LiveWorkspaceCommandAvailability.Control.characterSelector,
            .profile,
            .identitySettings,
        ] {
            XCTAssertTrue(
                LiveWorkspaceCommandAvailability.isEnabled(
                    control,
                    in: .terminal
                )
            )
        }
    }

    // 직원 선택은 다른 직원의 터미널로 옮겨 가는 통로라 잠기면 갇힌다.
    func testTerminalModeKeepsCharacterSelectorUsable() {
        XCTAssertTrue(
            LiveWorkspaceCommandAvailability.isEnabled(
                .characterSelector,
                in: .terminal
            )
        )
        XCTAssertEqual(
            LiveWorkspaceCommandAvailability.opacity(
                .characterSelector,
                in: .terminal
            ),
            1
        )
    }

    // 눌리지 않는 것만으로는 부족하고 비활성인 것이 보여야 한다.
    func testLockedControlsLookDimmedInTerminalMode() {
        XCTAssertEqual(
            LiveWorkspaceCommandAvailability.opacity(
                .quickSettings,
                in: .terminal
            ),
            LiveWorkspaceCommandAvailability.lockedOpacity
        )
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
