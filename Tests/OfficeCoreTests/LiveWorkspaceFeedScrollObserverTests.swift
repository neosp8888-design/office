import AppKit
import XCTest
@testable import OfficeGame

@MainActor
final class LiveWorkspaceFeedScrollObserverTests: XCTestCase {
    func testSameAttachmentAndBurstNotificationsStayBounded() async throws {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 300)
        )
        let documentView = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 1_000)
        )
        scrollView.documentView = documentView

        var metricReports = 0
        var userScrollStarts = 0
        var userScrollActivities = 0
        var userScrollEnds = 0
        let coordinator = LiveWorkspaceFeedScrollObserver.Coordinator(
            onMetrics: { _ in
                metricReports += 1
            },
            onUserScrollStarted: {
                userScrollStarts += 1
            },
            onUserScrollActivity: {
                userScrollActivities += 1
            },
            onUserScroll: { _ in
                userScrollEnds += 1
            }
        )
        defer {
            coordinator.detach()
        }

        coordinator.attach(to: scrollView)
        try await settleForObserverFrame()
        XCTAssertEqual(metricReports, 1)

        coordinator.attach(to: scrollView)
        try await settleForObserverFrame()
        XCTAssertEqual(
            metricReports,
            1,
            "같은 NSScrollView 재부착은 동일 metrics를 다시 발행하면 안 됩니다."
        )

        NotificationCenter.default.post(
            name: NSScrollView.willStartLiveScrollNotification,
            object: scrollView
        )
        for _ in 0..<500 {
            NotificationCenter.default.post(
                name: NSView.boundsDidChangeNotification,
                object: scrollView.contentView
            )
            NotificationCenter.default.post(
                name: NSScrollView.didLiveScrollNotification,
                object: scrollView
            )
        }
        try await settleForObserverFrame()

        XCTAssertEqual(userScrollStarts, 1)
        XCTAssertLessThanOrEqual(
            userScrollActivities,
            1,
            "한 gesture의 didLiveScroll burst는 frame당 한 번 이하로 합쳐야 합니다."
        )
        XCTAssertEqual(
            metricReports,
            1,
            "동일 좌표의 bounds burst는 epsilon dedupe 뒤 재발행하면 안 됩니다."
        )

        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        NotificationCenter.default.post(
            name: NSScrollView.didEndLiveScrollNotification,
            object: scrollView
        )
        try await settleForObserverFrame()
        XCTAssertEqual(
            userScrollEnds,
            1,
            "한 live-scroll gesture는 상단 로딩 판정용 종료 snapshot을 한 번만 내야 합니다."
        )

        let reportsAtRest = metricReports
        let activitiesAtRest = userScrollActivities
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertEqual(metricReports, reportsAtRest)
        XCTAssertEqual(userScrollActivities, activitiesAtRest)
    }

    func testDocumentGeometryDoesNotFeedMetricsBackIntoLayout() async throws {
        let scrollView = NSScrollView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 300)
        )
        let documentView = FlippedDocumentView(
            frame: NSRect(x: 0, y: 0, width: 500, height: 1_000)
        )
        scrollView.documentView = documentView

        var metricReports = 0
        let coordinator = LiveWorkspaceFeedScrollObserver.Coordinator(
            onMetrics: { _ in
                metricReports += 1
            },
            onUserScrollStarted: {},
            onUserScrollActivity: {},
            onUserScroll: { _ in }
        )
        defer {
            coordinator.detach()
        }

        coordinator.attach(to: scrollView)
        try await settleForObserverFrame()
        XCTAssertEqual(metricReports, 1)

        documentView.frame.size.height = 1_400
        for _ in 0..<500 {
            NotificationCenter.default.post(
                name: NSView.frameDidChangeNotification,
                object: documentView
            )
            NotificationCenter.default.post(
                name: NSView.boundsDidChangeNotification,
                object: documentView
            )
        }
        try await settleForObserverFrame()
        XCTAssertEqual(
            metricReports,
            1,
            "LazyVStack document layout 자체를 metrics 입력으로 다시 연결하면 안 됩니다."
        )
    }

    func testSnapshotEpsilonDeduplicatesSubpixelJitter() {
        let baseline = LiveWorkspaceFeedScrollSnapshot(
            distanceFromTop: 100,
            distanceFromBottom: 600,
            viewportHeight: 300,
            contentHeight: 1_000
        )
        let jitter = LiveWorkspaceFeedScrollSnapshot(
            distanceFromTop: 100.25,
            distanceFromBottom: 599.75,
            viewportHeight: 300.25,
            contentHeight: 1_000.25
        )
        let changed = LiveWorkspaceFeedScrollSnapshot(
            distanceFromTop: 102,
            distanceFromBottom: 598,
            viewportHeight: 300,
            contentHeight: 1_000
        )

        XCTAssertTrue(baseline.isApproximatelyEqual(to: jitter))
        XCTAssertFalse(baseline.isApproximatelyEqual(to: changed))
    }

    func testSemanticContentRevisionOwnsAutomaticFollowDecision() {
        XCTAssertEqual(
            LiveWorkspaceFeedContentRevisionPolicy.action(
                didPerformInitialScroll: false,
                isFollowingLatest: true
            ),
            .settleInitialAnchor
        )
        XCTAssertEqual(
            LiveWorkspaceFeedContentRevisionPolicy.action(
                didPerformInitialScroll: true,
                isFollowingLatest: true
            ),
            .followLatest
        )
        XCTAssertEqual(
            LiveWorkspaceFeedContentRevisionPolicy.action(
                didPerformInitialScroll: true,
                isFollowingLatest: false
            ),
            .revealContentBelow
        )
    }

    func testSubmissionScrollPolicyOnlyRevealsWhileFollowingLatest() {
        XCTAssertTrue(
            LiveWorkspaceFeedSubmissionScrollPolicy
                .shouldRevealSubmittedTurn(isFollowingLatest: true)
        )
        XCTAssertFalse(
            LiveWorkspaceFeedSubmissionScrollPolicy
                .shouldRevealSubmittedTurn(isFollowingLatest: false)
        )
    }

    private func settleForObserverFrame() async throws {
        try await Task.sleep(for: .milliseconds(40))
        await Task.yield()
    }
}

private final class FlippedDocumentView: NSView {
    override var isFlipped: Bool {
        true
    }
}
