// 직원이 일하는 중이면 대화 모드에서 터미널 모드로 들어가지 못하는지 검증한다.

import XCTest

@testable import OfficeGame

final class ConversationModeSwitchPolicyTests: XCTestCase {
    func testIdleOfficeAllowsTerminalEntry() {
        XCTAssertNil(
            ConversationModeSwitchPolicy.terminalEntryBlockMessage(
                runningCharacterNames: []
            )
        )
        XCTAssertEqual(
            ConversationModeSwitchPolicy.toggleOpacity(
                mode: .chat,
                hasRunningWork: false
            ),
            1
        )
    }

    func testRunningWorkBlocksTerminalEntryAndNamesWorkers() throws {
        let message = try XCTUnwrap(
            ConversationModeSwitchPolicy.terminalEntryBlockMessage(
                runningCharacterNames: ["로과장", "클대리"]
            )
        )
        XCTAssertTrue(message.contains("일하는 중"))
        XCTAssertTrue(message.hasSuffix("일하는 직원: 로과장, 클대리"))
        XCTAssertEqual(
            ConversationModeSwitchPolicy.toggleOpacity(
                mode: .chat,
                hasRunningWork: true
            ),
            LiveWorkspaceCommandAvailability.lockedOpacity
        )
    }

    // 터미널 모드에서 대화 모드로 돌아가는 쪽은 잠그지 않는다. 그쪽은 기존
    // 확인 창이 담당한다.
    func testTerminalModeToggleStaysFullyVisibleWhileWorking() {
        XCTAssertEqual(
            ConversationModeSwitchPolicy.toggleOpacity(
                mode: .terminal,
                hasRunningWork: true
            ),
            1
        )
    }
}
