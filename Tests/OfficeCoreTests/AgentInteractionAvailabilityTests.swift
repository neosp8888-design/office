import Foundation
import OfficeCore
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

    func testActiveSessionRestoreStateUsesOnlyKnownNonemptySessions() {
        let bossConversationID = UUID()
        let state = ActiveSessionRestoreState(
            activeSessions: [
                StoredActiveSession(
                    characterId: OfficeCharacter.boss.rawValue,
                    externalSessionId: "  codex-thread-1  ",
                    conversationId: bossConversationID
                ),
                StoredActiveSession(
                    characterId: "unknown-character",
                    externalSessionId: "unknown-session",
                    conversationId: UUID()
                ),
                StoredActiveSession(
                    characterId: OfficeCharacter.leftMan.rawValue,
                    externalSessionId: "  ",
                    conversationId: UUID()
                )
            ]
        )

        XCTAssertEqual(state.conversationIDs, [.boss: bossConversationID])
        XCTAssertEqual(state.sessionIDs, [.boss: "codex-thread-1"])
    }

    func testOnlyBackendChangesRequireANewSession() {
        let previous = CharacterAgentSettings(
            backend: .codex,
            model: "gpt-5.6-sol",
            effort: "high",
            fastMode: false,
            permission: .workspaceWrite
        )
        var modelChange = previous
        modelChange.model = "gpt-5.6-terra"
        var effortChange = previous
        effortChange.effort = "max"
        var fastModeChange = previous
        fastModeChange.fastMode = true
        var permissionChange = previous
        permissionChange.permission = .fullAccess

        for updated in [
            modelChange,
            effortChange,
            fastModeChange,
            permissionChange
        ] {
            XCTAssertFalse(
                CharacterSessionInvalidationPolicy.requiresNewSession(
                    previous: previous,
                    updated: updated
                )
            )
        }

        var backendChange = previous
        backendChange.backend = .claude
        XCTAssertTrue(
            CharacterSessionInvalidationPolicy.requiresNewSession(
                previous: previous,
                updated: backendChange
            )
        )
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
