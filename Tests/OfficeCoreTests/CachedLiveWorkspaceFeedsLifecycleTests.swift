import AppKit
import OfficeCore
import XCTest
@testable import OfficeGame

@MainActor
final class CachedLiveWorkspaceFeedsLifecycleTests: XCTestCase {
    func testRapidSelectionDetachesInactiveHostsAndReusesTheirIdentity() {
        let director = AgentDirector(startBackgroundTasks: false)
        director.liveFeedStore.replace(with: makeTurns())
        director.liveFeedStore.finishInitialLoading()
        let container = CachedLiveWorkspaceFeedsNSView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700)
        )

        defer {
            container.tearDown()
        }

        var cachedHosts: [OfficeCharacter: NSView] = [:]
        var previouslyAttachedHost: NSView?
        let selectionSequence = (0..<6).flatMap { _ in
            OfficeCharacter.allCases
        }

        for character in selectionSequence {
            director.selectedCharacterID = character
            container.configure(
                director: director,
                selectedCharacterID: character
            )
            container.layoutSubtreeIfNeeded()

            guard container.subviews.count == 1 else {
                XCTFail(
                    "직원 \(character.rawValue) 선택 뒤 연결된 호스트가 "
                        + "\(container.subviews.count)개입니다. 선택된 호스트 "
                        + "하나만 view/window 계층에 남아야 합니다."
                )
                return
            }

            let attachedHost = container.subviews[0]
            XCTAssertFalse(attachedHost.isHidden)

            if let cachedHost = cachedHosts[character] {
                XCTAssertTrue(
                    attachedHost === cachedHost,
                    "직원 복귀 때 기존 NSHostingView identity를 재사용해야 "
                        + "스크롤과 뷰 상태가 보존됩니다."
                )
            } else {
                cachedHosts[character] = attachedHost
            }

            if
                let previouslyAttachedHost,
                previouslyAttachedHost !== attachedHost
            {
                XCTAssertNil(previouslyAttachedHost.superview)
                XCTAssertNil(
                    previouslyAttachedHost.window,
                    "비선택 호스트가 window에 남으면 스크롤 관찰자와 "
                        + "애니메이션이 계속 동작할 수 있습니다."
                )
            }

            previouslyAttachedHost = attachedHost
        }

        director.selectedCharacterID = nil
        container.configure(
            director: director,
            selectedCharacterID: nil
        )

        XCTAssertTrue(container.subviews.isEmpty)
        for host in cachedHosts.values {
            XCTAssertNil(host.superview)
            XCTAssertNil(host.window)
        }

        director.selectedCharacterID = .boss
        container.configure(
            director: director,
            selectedCharacterID: .boss
        )

        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertTrue(container.subviews.first === cachedHosts[.boss])
    }

    func testScrollGeometryReportsFlippedTopAndBottomWithoutPreferenceKeys() {
        let documentBounds = CGRect(x: 0, y: 0, width: 500, height: 1_000)

        let top = LiveWorkspaceFeedScrollGeometry.snapshot(
            documentBounds: documentBounds,
            visibleRect: CGRect(x: 0, y: 0, width: 500, height: 300),
            isFlipped: true
        )
        XCTAssertEqual(top.distanceFromTop, 0)
        XCTAssertEqual(top.distanceFromBottom, 700)
        XCTAssertEqual(top.viewportHeight, 300)
        XCTAssertEqual(top.contentHeight, 1_000)

        let bottom = LiveWorkspaceFeedScrollGeometry.snapshot(
            documentBounds: documentBounds,
            visibleRect: CGRect(x: 0, y: 700, width: 500, height: 300),
            isFlipped: true
        )
        XCTAssertEqual(bottom.distanceFromTop, 700)
        XCTAssertEqual(bottom.distanceFromBottom, 0)
    }

    func testScrollGeometryHandlesNonFlippedAndShortDocuments() {
        let nonFlippedTop = LiveWorkspaceFeedScrollGeometry.snapshot(
            documentBounds: CGRect(x: 0, y: 0, width: 500, height: 1_000),
            visibleRect: CGRect(x: 0, y: 700, width: 500, height: 300),
            isFlipped: false
        )
        XCTAssertEqual(nonFlippedTop.distanceFromTop, 0)
        XCTAssertEqual(nonFlippedTop.distanceFromBottom, 700)

        let shortDocument = LiveWorkspaceFeedScrollGeometry.snapshot(
            documentBounds: CGRect(x: 0, y: 0, width: 500, height: 200),
            visibleRect: CGRect(x: 0, y: 0, width: 500, height: 300),
            isFlipped: true
        )
        XCTAssertEqual(shortDocument.distanceFromTop, 0)
        XCTAssertEqual(shortDocument.distanceFromBottom, 0)
    }

    func testTopLoadGateLoadsOnlyOnceUntilUserLeavesTopThreshold() {
        var gate = LiveWorkspaceFeedTopLoadGate()

        XCTAssertTrue(
            gate.shouldLoad(
                distanceFromTop: 40,
                threshold: 120,
                isProgrammaticScrollInFlight: false
            )
        )
        XCTAssertFalse(
            gate.shouldLoad(
                distanceFromTop: 20,
                threshold: 120,
                isProgrammaticScrollInFlight: false
            )
        )
        XCTAssertFalse(
            gate.shouldLoad(
                distanceFromTop: 250,
                threshold: 120,
                isProgrammaticScrollInFlight: false
            )
        )
        XCTAssertTrue(
            gate.shouldLoad(
                distanceFromTop: 30,
                threshold: 120,
                isProgrammaticScrollInFlight: false
            )
        )
    }

    func testTopLoadGateDoesNotConsumeProgrammaticTopPosition() {
        var gate = LiveWorkspaceFeedTopLoadGate()

        XCTAssertFalse(
            gate.shouldLoad(
                distanceFromTop: 0,
                threshold: 120,
                isProgrammaticScrollInFlight: true
            )
        )
        XCTAssertTrue(
            gate.shouldLoad(
                distanceFromTop: 0,
                threshold: 120,
                isProgrammaticScrollInFlight: false
            )
        )
        gate.userScrollStarted()
        XCTAssertTrue(
            gate.shouldLoad(
                distanceFromTop: 0,
                threshold: 120,
                isProgrammaticScrollInFlight: false
            )
        )
    }

    private func makeTurns() -> [LiveFeedTurn] {
        let origin = Date(timeIntervalSinceReferenceDate: 10_000)
        return OfficeCharacter.allCases.flatMap { character in
            (0..<30).map { index in
                let timestamp = origin.addingTimeInterval(
                    TimeInterval(index)
                )
                return LiveFeedTurn(
                    id: "\(character.rawValue)-\(index)",
                    characterId: character.rawValue,
                    characterName: character.rawValue,
                    characterBackend: .codex,
                    backend: .codex,
                    model: "gpt-5.6-sol",
                    effort: "high",
                    fastMode: false,
                    externalSessionId: nil,
                    conversationWorkdir: "/repo",
                    prompt: "업무 \(index)",
                    response: "완료 \(index)",
                    feedback: nil,
                    status: .completed,
                    needsInput: false,
                    errorMessage: nil,
                    responseSourceWarning: nil,
                    startedAt: timestamp,
                    endedAt: timestamp,
                    updatedAt: timestamp,
                    estimatedCostUsd: nil,
                    sessionContext: nil,
                    activities: [],
                    sources: nil,
                    workspace: nil
                )
            }
        }
    }
}
