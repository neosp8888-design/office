import XCTest
import AppKit
@testable import OfficeGame

final class TerminalWorkspaceLifecycleTests: XCTestCase {
    @MainActor
    func testMountedTerminalReleasesSelectionGateForRepeatedSwitching() async {
        let selectionStore = CharacterSelectionStore()
        let view = CachedTerminalWorkspacesNSView()
        view.startsProcesses = false
        let baseURL = URL(string: "http://127.0.0.1:4317")!

        XCTAssertFalse(selectionStore.canSelect(.leftMan))
        view.configure(
            selectedCharacterID: .boss,
            characterSelectionStore: selectionStore,
            databaseBaseURL: baseURL,
            sessionRevision: 0,
            restartRequest: nil
        )
        await Task.yield()
        XCTAssertTrue(selectionStore.canSelect(.leftMan))

        selectionStore.select(.leftMan)
        XCTAssertFalse(selectionStore.canSelect(.rightMan))
        view.configure(
            selectedCharacterID: .leftMan,
            characterSelectionStore: selectionStore,
            databaseBaseURL: baseURL,
            sessionRevision: 0,
            restartRequest: nil
        )
        await Task.yield()
        XCTAssertTrue(selectionStore.canSelect(.rightMan))
    }

    // 직원을 바꾸면 그 직원의 터미널로 포커스 요청이 가야 한다.
    @MainActor
    func testSwitchingCharacterRoutesFocusToSelectedTerminal() async {
        let selectionStore = CharacterSelectionStore()
        let view = CachedTerminalWorkspacesNSView()
        view.startsProcesses = false
        let baseURL = URL(string: "http://127.0.0.1:4317")!

        view.configure(
            selectedCharacterID: .boss,
            characterSelectionStore: selectionStore,
            databaseBaseURL: baseURL,
            sessionRevision: 0,
            restartRequest: nil
        )
        await Task.yield()
        XCTAssertEqual(view.lastFocusRequestCharacterForTesting, .boss)

        selectionStore.select(.leftMan)
        view.configure(
            selectedCharacterID: .leftMan,
            characterSelectionStore: selectionStore,
            databaseBaseURL: baseURL,
            sessionRevision: 0,
            restartRequest: nil
        )
        await Task.yield()
        XCTAssertEqual(view.lastFocusRequestCharacterForTesting, .leftMan)

        // 이미 떠 있는 직원으로 되돌아와도 다시 그 직원으로 포커스가 간다.
        selectionStore.select(.boss)
        view.configure(
            selectedCharacterID: .boss,
            characterSelectionStore: selectionStore,
            databaseBaseURL: baseURL,
            sessionRevision: 0,
            restartRequest: nil
        )
        await Task.yield()
        XCTAssertEqual(view.lastFocusRequestCharacterForTesting, .boss)
    }

    func testTerminalAppearanceKeepsDefaultTextReadableOnBlack() {
        let foreground = TerminalWorkspaceAppearance.foregroundColor
            .usingColorSpace(.deviceRGB)
        let background = TerminalWorkspaceAppearance.backgroundColor
            .usingColorSpace(.deviceRGB)

        XCTAssertNotNil(foreground)
        XCTAssertNotNil(background)
        let foregroundLuminance = [
            foreground?.redComponent,
            foreground?.greenComponent,
            foreground?.blueComponent,
        ]
        .compactMap { $0 }
        .reduce(0, +) / 3
        let backgroundLuminance = [
            background?.redComponent,
            background?.greenComponent,
            background?.blueComponent,
        ]
        .compactMap { $0 }
        .reduce(0, +) / 3

        XCTAssertGreaterThan(foregroundLuminance, 0.9)
        XCTAssertLessThan(backgroundLuminance, 0.1)
        XCTAssertEqual(TerminalWorkspaceAppearance.font.pointSize, 13)
        XCTAssertTrue(
            TerminalWorkspaceAppearance.font.fontDescriptor.symbolicTraits
                .contains(.monoSpace)
        )
    }

    func testSelectedCharactersAreCreatedLazilyAndCached() {
        var policy = TerminalWorkspaceCachePolicy()
        XCTAssertTrue(policy.select(.boss))
        XCTAssertFalse(policy.select(.boss))
        XCTAssertTrue(policy.select(.leftMan))
        XCTAssertEqual(policy.cachedCharacters, [.boss, .leftMan])
        XCTAssertEqual(policy.selectedCharacter, .leftMan)
    }

    func testRestartRevisionAppliesOnceToSelectedCharacter() {
        var policy = TerminalWorkspaceCachePolicy()
        _ = policy.select(.boss)
        XCTAssertTrue(policy.shouldRestart(character: .boss, revision: 1))
        XCTAssertFalse(policy.shouldRestart(character: .boss, revision: 1))
        XCTAssertFalse(policy.shouldRestart(character: .leftMan, revision: 2))
    }

    func testTearDownReturnsEveryCachedTerminal() {
        var policy = TerminalWorkspaceCachePolicy()
        _ = policy.select(.boss)
        _ = policy.select(.rightWoman)
        XCTAssertEqual(policy.tearDown(), [.boss, .rightWoman])
        XCTAssertTrue(policy.cachedCharacters.isEmpty)
        XCTAssertNil(policy.selectedCharacter)
    }
}
