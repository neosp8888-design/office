import AppKit
import OfficeCore
import SwiftUI
import XCTest
@testable import OfficeGame

@MainActor
final class CachedLiveWorkspaceFeedsLifecycleTests: XCTestCase {
    func testScrollObserverCoalescesLogitechStyleBurstPerGesture() async throws {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 500)
        )
        let documentView = FlippedScrollDocumentView(
            frame: NSRect(x: 0, y: 0, width: 700, height: 6_000)
        )
        scrollView.documentView = documentView

        var metricsCount = 0
        var userScrollStartedCount = 0
        var userScrollActivityCount = 0
        var userScrollCompletionCount = 0
        var topLoadCount = 0
        var topLoadGate = LiveWorkspaceFeedTopLoadGate()
        let coordinator = LiveWorkspaceFeedScrollObserver.Coordinator(
            onMetrics: { _ in
                metricsCount += 1
            },
            onUserScrollStarted: {
                userScrollStartedCount += 1
                topLoadGate.userScrollStarted()
            },
            onUserScrollActivity: {
                userScrollActivityCount += 1
            },
            onUserScroll: { snapshot in
                userScrollCompletionCount += 1
                if topLoadGate.shouldLoad(
                    distanceFromTop: snapshot.distanceFromTop,
                    threshold: 120,
                    isProgrammaticScrollInFlight: false
                ) {
                    topLoadCount += 1
                }
            }
        )
        coordinator.attach(to: scrollView)
        defer {
            coordinator.detach()
        }
        try await settle(for: .milliseconds(50))

        metricsCount = 0
        userScrollStartedCount = 0
        userScrollActivityCount = 0
        userScrollCompletionCount = 0
        topLoadCount = 0

        let notificationCenter = NotificationCenter.default
        notificationCenter.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        for index in 0..<300 {
            let remainingDistance = max(0, 5_500 - CGFloat(index) * 24)
            scrollView.contentView.scroll(
                to: NSPoint(x: 0, y: remainingDistance)
            )
            scrollView.reflectScrolledClipView(scrollView.contentView)
            notificationCenter.post(
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView
            )
        }
        notificationCenter.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        try await settle(for: .milliseconds(100))

        XCTAssertEqual(userScrollStartedCount, 1)
        XCTAssertEqual(
            userScrollActivityCount,
            1,
            "300회 wheel burst가 user activity callback "
                + "\(userScrollActivityCount)회로 그대로 증폭됐습니다."
        )
        XCTAssertLessThanOrEqual(
            metricsCount,
            2,
            "한 run-loop의 300회 bounds 변경이 metrics callback "
                + "\(metricsCount)회로 증폭됐습니다."
        )
        XCTAssertEqual(userScrollCompletionCount, 1)
        XCTAssertEqual(
            topLoadCount,
            1,
            "한 wheel gesture에서 이전 대화 로딩은 한 번만 허용됩니다."
        )

        let settledCounts = (
            metricsCount,
            userScrollActivityCount,
            userScrollCompletionCount,
            topLoadCount
        )
        try await settle(for: .seconds(2))
        XCTAssertEqual(metricsCount, settledCounts.0)
        XCTAssertEqual(userScrollActivityCount, settledCounts.1)
        XCTAssertEqual(userScrollCompletionCount, settledCounts.2)
        XCTAssertEqual(topLoadCount, settledCounts.3)
    }

    func testHostedSelectionAndLiveScrollStressQuiesces() async throws {
        let director = AgentDirector(startBackgroundTasks: false)
        director.liveFeedStore.replace(with: makeTurns(streamingStep: 1))
        director.liveFeedStore.finishInitialLoading()

        let rootHost = NSHostingView(
            rootView: CachedLiveWorkspaceFeeds(director: director)
                .frame(width: 900, height: 700)
        )
        rootHost.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let parentView = NSView(frame: rootHost.bounds)
        parentView.addSubview(rootHost)
        rootHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(200))

        guard let container = allDescendants(of: rootHost)
            .compactMap({ $0 as? CachedLiveWorkspaceFeedsNSView })
            .first
        else {
            XCTFail("SwiftUI representable이 live feed container를 만들지 못했습니다.")
            rootHost.removeFromSuperview()
            return
        }

        defer {
            container.tearDown()
            rootHost.removeFromSuperview()
        }

        // 실제 NSHostingView 안에서 representable update, NSScrollView
        // 관찰자, 자동 하단 이동을 함께 동작하게 한다. 테스트 프로세스의
        // 전역 NSWindow 전환 애니메이션은 검증 범위가 아니므로 만들지 않는다.
        for index in 0..<10 {
            let character = OfficeCharacter.allCases[
                index % OfficeCharacter.allCases.count
            ]
            director.selectedCharacterID = character
            rootHost.layoutSubtreeIfNeeded()
            try await settle(for: .milliseconds(80))
        }

        for _ in 0..<8 {
            guard let scrollView = primaryScrollView(in: rootHost) else {
                XCTFail("실제 window 계층에서 live feed NSScrollView를 찾지 못했습니다.")
                return
            }
            performLiveScroll(scrollView, toTop: true)
            try await settle(for: .milliseconds(80))

            guard let refreshedScrollView = primaryScrollView(in: rootHost)
            else {
                XCTFail("상단 로딩 뒤 live feed NSScrollView가 사라졌습니다.")
                return
            }
            performLiveScroll(refreshedScrollView, toTop: false)
            try await settle(for: .milliseconds(80))
        }

        // 실제 실행 중 카드처럼 콘텐츠 높이를 연속 변경해 geometry report
        // -> scrollTo -> layout report 폐루프가 남아 있다면 깨운다.
        for step in 2...12 {
            director.liveFeedStore.replace(
                with: makeTurns(streamingStep: step)
            )
            try await settle(for: .milliseconds(40))
        }

        guard
            let scrollView = primaryScrollView(in: rootHost),
            let documentView = scrollView.documentView
        else {
            XCTFail("스트레스 직후 live feed scroll 계층을 찾지 못했습니다.")
            return
        }

        var geometryNotificationCount = 0
        let notificationCenter = NotificationCenter.default
        let registrations = [
            notificationCenter.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { _ in
                geometryNotificationCount += 1
            },
            notificationCenter.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { _ in
                geometryNotificationCount += 1
            },
            notificationCenter.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: documentView,
                queue: .main
            ) { _ in
                geometryNotificationCount += 1
            },
            notificationCenter.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: documentView,
                queue: .main
            ) { _ in
                geometryNotificationCount += 1
            },
        ]
        defer {
            registrations.forEach(notificationCenter.removeObserver)
        }

        // 입력이 멈춘 뒤에도 레이아웃/스크롤이 계속 자기 자신을 깨우는
        // 회귀를 빠르게 검출한다. 정상 상태에서는 2초 동안 0~수회다.
        try await settle(for: .seconds(2))
        XCTAssertLessThanOrEqual(
            geometryNotificationCount,
            20,
            "입력이 끝난 뒤에도 scroll geometry 알림이 "
                + "\(geometryNotificationCount)회 발생했습니다. 자동 스크롤과 "
                + "layout 측정이 서로 재촉발되는 상태입니다."
        )
    }

    func testRapidSelectionReleasesInactiveHostsAndCreatesFreshHosts()
        async throws
    {
        let director = AgentDirector(startBackgroundTasks: false)
        director.liveFeedStore.replace(with: makeTurns())
        director.liveFeedStore.finishInitialLoading()
        let container = CachedLiveWorkspaceFeedsNSView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700)
        )

        defer {
            container.tearDown()
        }

        var firstBossHost: NSView?
        weak var releasedFirstBossHost: NSView?
        var previouslyAttachedHost: NSView?
        let selectionSequence = (0..<3).flatMap { _ in
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

            if firstBossHost == nil, character == .boss {
                firstBossHost = attachedHost
                releasedFirstBossHost = attachedHost
            } else if
                character == .boss,
                let firstBossHost
            {
                XCTAssertFalse(
                    attachedHost === firstBossHost,
                    "직원 복귀 때 이전 NSHostingView를 재사용하면 비활성 "
                        + "SwiftUI 그래프가 계속 살아 있습니다."
                )
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

        firstBossHost = nil
        try await settle(for: .milliseconds(50))
        XCTAssertNil(
            releasedFirstBossHost,
            "컨테이너가 비활성 직원의 NSHostingView와 전체 SwiftUI "
                + "그래프를 계속 강하게 보유하고 있습니다."
        )

        director.selectedCharacterID = nil
        container.configure(
            director: director,
            selectedCharacterID: nil
        )

        XCTAssertTrue(container.subviews.isEmpty)
        weak var releasedLastHost: NSView?
        releasedLastHost = previouslyAttachedHost
        XCTAssertNil(previouslyAttachedHost?.superview)
        XCTAssertNil(previouslyAttachedHost?.window)
        previouslyAttachedHost = nil
        try await settle(for: .milliseconds(50))
        XCTAssertNil(releasedLastHost)

        director.selectedCharacterID = .boss
        container.configure(
            director: director,
            selectedCharacterID: .boss
        )

        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertNotNil(container.subviews.first)
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

    private func makeTurns(streamingStep: Int? = nil) -> [LiveFeedTurn] {
        let origin = Date(timeIntervalSinceReferenceDate: 10_000)
        return OfficeCharacter.allCases.flatMap { character in
            (0..<30).map { index in
                let timestamp = origin.addingTimeInterval(
                    TimeInterval(index)
                )
                let isStreaming = streamingStep != nil && index == 29
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
                    response: isStreaming
                        ? String(
                            repeating: "진행 중인 응답 줄입니다.\n",
                            count: streamingStep ?? 1
                        )
                        : "완료 \(index)",
                    feedback: nil,
                    status: isStreaming ? .running : .completed,
                    needsInput: false,
                    errorMessage: nil,
                    responseSourceWarning: nil,
                    startedAt: timestamp,
                    endedAt: isStreaming ? nil : timestamp,
                    updatedAt: timestamp.addingTimeInterval(
                        TimeInterval(streamingStep ?? 0)
                    ),
                    estimatedCostUsd: nil,
                    sessionContext: nil,
                    activities: [],
                    sources: nil,
                    workspace: nil
                )
            }
        }
    }

    private func settle(for duration: Duration) async throws {
        try await Task.sleep(for: duration)
        await Task.yield()
    }

    private func primaryScrollView(in root: NSView) -> NSScrollView? {
        allDescendants(of: root)
            .compactMap { $0 as? NSScrollView }
            .max { lhs, rhs in
                lhs.bounds.width * lhs.bounds.height
                    < rhs.bounds.width * rhs.bounds.height
            }
    }

    private func allDescendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { subview in
            [subview] + allDescendants(of: subview)
        }
    }

    private func performLiveScroll(
        _ scrollView: NSScrollView,
        toTop: Bool
    ) {
        guard let documentView = scrollView.documentView else {
            return
        }
        let clipView = scrollView.contentView
        let scrollableHeight = max(
            0,
            documentView.bounds.height - clipView.bounds.height
        )
        let targetY: CGFloat
        if documentView.isFlipped {
            targetY = toTop ? documentView.bounds.minY : scrollableHeight
        } else {
            targetY = toTop ? scrollableHeight : documentView.bounds.minY
        }

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        clipView.scroll(to: NSPoint(x: clipView.bounds.minX, y: targetY))
        scrollView.reflectScrolledClipView(clipView)
        NotificationCenter.default.post(
            name: NSScrollView.didLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
    }
}

@MainActor
private final class FlippedScrollDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}
