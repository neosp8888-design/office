import XCTest
@testable import OfficeGame

final class AgentInteractionAvailabilityTests: XCTestCase {
    func testPendingReviewAllowsCurrentBackendSettingsButBlocksBackend() {
        let availability = AgentQuickSettingsAvailability(
            isReady: true,
            isUpdatingConfiguration: false,
            isRunning: false,
            needsWorkspaceReview: true
        )

        XCTAssertTrue(availability.canChangeCurrentBackendSettings)
        XCTAssertFalse(availability.canChangeBackend)
    }

    func testRunningCharacterBlocksEveryQuickSetting() {
        let availability = AgentQuickSettingsAvailability(
            isReady: true,
            isUpdatingConfiguration: false,
            isRunning: true,
            needsWorkspaceReview: false
        )

        XCTAssertFalse(availability.canChangeCurrentBackendSettings)
        XCTAssertFalse(availability.canChangeBackend)
    }

    func testQueueAvailabilityDistinguishesReviewFromFullQueue() {
        let awaitingReview = SelectedCharacterQueueAvailability.resolve(
            isReady: true,
            isUpdatingConfiguration: false,
            hasSelectedCharacter: true,
            isSelectedCharacterRunning: true,
            needsWorkspaceReview: true,
            isFull: false
        )
        let full = SelectedCharacterQueueAvailability.resolve(
            isReady: true,
            isUpdatingConfiguration: false,
            hasSelectedCharacter: true,
            isSelectedCharacterRunning: true,
            needsWorkspaceReview: false,
            isFull: true
        )

        XCTAssertEqual(awaitingReview, .awaitingWorkspaceReview)
        XCTAssertEqual(full, .full)
    }

    func testQueueAvailabilityAllowsRunningCharacterWithCapacity() {
        XCTAssertEqual(
            SelectedCharacterQueueAvailability.resolve(
                isReady: true,
                isUpdatingConfiguration: false,
                hasSelectedCharacter: true,
                isSelectedCharacterRunning: true,
                needsWorkspaceReview: false,
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
}
