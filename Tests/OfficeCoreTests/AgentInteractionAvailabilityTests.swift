import XCTest
@testable import OfficeGame

final class AgentInteractionAvailabilityTests: XCTestCase {
    func testIdleCharacterAllowsEveryQuickSetting() {
        let availability = AgentQuickSettingsAvailability(
            isReady: true,
            isUpdatingConfiguration: false,
            isRunning: false
        )

        XCTAssertTrue(availability.canChangeCurrentBackendSettings)
        XCTAssertTrue(availability.canChangeBackend)
    }

    func testRunningCharacterBlocksEveryQuickSetting() {
        let availability = AgentQuickSettingsAvailability(
            isReady: true,
            isUpdatingConfiguration: false,
            isRunning: true
        )

        XCTAssertFalse(availability.canChangeCurrentBackendSettings)
        XCTAssertFalse(availability.canChangeBackend)
    }

    func testCompactingCharacterBlocksEveryQuickSetting() {
        let availability = AgentQuickSettingsAvailability(
            isReady: true,
            isUpdatingConfiguration: false,
            isRunning: false,
            isCompacting: true
        )

        XCTAssertFalse(availability.canChangeCurrentBackendSettings)
        XCTAssertFalse(availability.canChangeBackend)
    }

    func testQueueAvailabilityReportsFullQueue() {
        let full = SelectedCharacterQueueAvailability.resolve(
            isReady: true,
            isUpdatingConfiguration: false,
            hasSelectedCharacter: true,
            isSelectedCharacterRunning: true,
            isFull: true
        )

        XCTAssertEqual(full, .full)
    }

    func testQueueAvailabilityAllowsRunningCharacterWithCapacity() {
        XCTAssertEqual(
            SelectedCharacterQueueAvailability.resolve(
                isReady: true,
                isUpdatingConfiguration: false,
                hasSelectedCharacter: true,
                isSelectedCharacterRunning: true,
                isFull: false
            ),
            .available
        )
    }

    func testContextCompactionRequiresIdleActiveSession() {
        let available = ContextCompactionAvailability(
            isReady: true,
            isUpdatingConfiguration: false,
            isRunning: false,
            hasActiveSession: true,
            isCompacting: false
        )
        let noSession = ContextCompactionAvailability(
            isReady: true,
            isUpdatingConfiguration: false,
            isRunning: false,
            hasActiveSession: false,
            isCompacting: false
        )

        XCTAssertTrue(available.canAdjustThreshold)
        XCTAssertTrue(available.canCompactNow)
        XCTAssertTrue(noSession.canAdjustThreshold)
        XCTAssertFalse(noSession.canCompactNow)
    }

    func testContextCompactionLocksControlsWhileRunning() {
        let availability = ContextCompactionAvailability(
            isReady: true,
            isUpdatingConfiguration: false,
            isRunning: true,
            hasActiveSession: true,
            isCompacting: false
        )

        XCTAssertFalse(availability.canAdjustThreshold)
        XCTAssertFalse(availability.canCompactNow)
    }

    func testStoredCharacterProfileDecodesAutoCompactPercent() throws {
        let data = Data(
            #"{"id":"boss","name":"백부장","backend":"codex","model":"gpt-5.6-sol","effort":"max","fastMode":true,"autoCompactPercent":95,"permission":"danger-full-access","identityPrompt":"업무 지침"}"#.utf8
        )

        let profile = try JSONDecoder().decode(
            StoredCharacterProfile.self,
            from: data
        )

        XCTAssertEqual(profile.autoCompactPercent, 95)
    }

    func testContextCompactionConfirmationUsesConfiguredDisplayName() {
        let message = ContextCompactionPresentation.confirmationMessage(
            displayName: "로과장",
            backendTitle: "Claude Code"
        )

        XCTAssertEqual(
            message,
            "로과장의 Claude Code 대화 내용을 요약으로 바꿉니다. 이전 세부 내용은 되돌릴 수 없습니다."
        )
        XCTAssertFalse(message.contains("왼쪽 여자"))
    }

    func testOnlyClaudeShowsAdjustableAutoCompactionThreshold() {
        XCTAssertTrue(
            ContextCompactionPresentation.usesAdjustableThreshold(
                backend: .claude
            )
        )
        XCTAssertFalse(
            ContextCompactionPresentation.usesAdjustableThreshold(
                backend: .codex
            )
        )
        XCTAssertFalse(
            ContextCompactionPresentation.supportsManualCompaction(
                backend: .antigravity
            )
        )
    }
}
