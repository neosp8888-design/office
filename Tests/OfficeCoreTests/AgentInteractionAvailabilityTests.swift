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
}
