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

    func testHostedLiveScrollStressQuiesces() async throws {
        let director = AgentDirector(startBackgroundTasks: false)
        director.liveFeedStore.replace(with: makeTurns(streamingStep: 1))
        director.liveFeedStore.finishInitialLoading()

        let rootHost = NSHostingView(
            rootView: CachedLiveWorkspaceFeeds(director: director)
                .frame(width: 900, height: 700)
        )
        rootHost.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(
            contentRect: rootHost.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = rootHost
        rootHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(200))
        XCTAssertTrue(
            rootHost.window === window,
            "실제 window가 없으면 scroll observer와 live feed AppKit 뷰가 "
                + "mount되지 않습니다."
        )

        guard let container = allDescendants(of: rootHost)
            .compactMap({ $0 as? CachedLiveWorkspaceFeedsNSView })
            .first
        else {
            XCTFail("SwiftUI representable이 live feed container를 만들지 못했습니다.")
            window.contentView = nil
            return
        }

        defer {
            container.tearDown()
            window.contentView = nil
        }

        // 실제 NSWindow 안에서 representable update, NSScrollView observer,
        // 타자 뷰와 자동 하단 이동을 함께 동작하게 한다.
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

    func testImmediateScrollAfterSelectionWithCompletedTypingQuiesces()
        async throws
    {
        let director = AgentDirector(startBackgroundTasks: false)
        let response = (0..<12).map { index in
            "### 완료 줄 \(index)\n직원 전환 직후에도 안정적으로 표시합니다."
        }.joined(separator: "\n")
        let turns = makeTurns(completedResponse: response)
        director.liveFeedStore.replace(with: turns)
        director.liveFeedStore.finishInitialLoading()
        for character in OfficeCharacter.allCases {
            director.liveFeedStore.beginResponseAnimation(
                for: "\(character.rawValue)-29"
            )
        }

        let rootHost = NSHostingView(
            rootView: CachedLiveWorkspaceFeeds(director: director)
                .frame(width: 900, height: 700)
        )
        rootHost.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(
            contentRect: rootHost.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = rootHost
        rootHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(120))

        guard let container = allDescendants(of: rootHost)
            .compactMap({ $0 as? CachedLiveWorkspaceFeedsNSView })
            .first
        else {
            XCTFail("완료 타이핑용 live feed container를 만들지 못했습니다.")
            window.contentView = nil
            return
        }
        defer {
            container.tearDown()
            window.contentView = nil
        }

        for index in 0..<15 {
            director.selectedCharacterID = OfficeCharacter.allCases[
                index % OfficeCharacter.allCases.count
            ]
            rootHost.layoutSubtreeIfNeeded()
            try await settle(for: .milliseconds(4))
            guard
                let scrollView = try await waitForPrimaryScrollView(
                    in: rootHost
                )
            else {
                XCTFail("직원 전환 직후 live feed scroll view가 사라졌습니다.")
                return
            }
            performSmallLiveScroll(
                scrollView,
                delta: index.isMultiple(of: 2) ? 8 : -8
            )
        }

        XCTAssertEqual(container.subviews.count, 1)
        let clock = ContinuousClock()
        let startedAt = clock.now
        try await settle(for: .seconds(2))
        XCTAssertLessThan(
            startedAt.duration(to: clock.now),
            .seconds(4),
            "입력 종료 뒤에도 live feed transaction이 "
                + "메인 스레드를 점유합니다."
        )
        XCTAssertEqual(container.subviews.count, 1)
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

    func testFeedRemountTokenRebuildsSameEmployeeHostLikeReselection()
        async throws
    {
        let director = AgentDirector(startBackgroundTasks: false)
        director.liveFeedStore.replace(with: makeTurns())
        director.liveFeedStore.finishInitialLoading()
        let characterStore = director.liveFeedStore.characterStore(
            for: OfficeCharacter.boss.rawValue
        )
        let container = CachedLiveWorkspaceFeedsNSView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700)
        )
        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        defer {
            container.tearDown()
            window.contentView = nil
        }

        container.configure(
            director: director,
            selectedCharacterID: .boss,
            feedRemountToken: 0
        )
        container.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(120))

        var mountedHost: NSView? = container.subviews.first
        guard mountedHost != nil else {
            XCTFail("첫 선택에서 대화 호스트가 만들어지지 않았습니다.")
            return
        }
        let revisionAfterMount = characterStore.presentationRevision
        XCTAssertEqual(revisionAfterMount, 1)

        // 같은 직원·같은 토큰의 재구성은 아무것도 다시 만들지 않는다.
        container.configure(
            director: director,
            selectedCharacterID: .boss,
            feedRemountToken: 0
        )
        container.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(60))
        XCTAssertTrue(
            container.subviews.first === mountedHost,
            "토큰이 그대로면 기존 호스트를 유지해야 합니다."
        )
        XCTAssertNotNil(mountedHost)
        XCTAssertEqual(
            characterStore.presentationRevision,
            revisionAfterMount,
            "토큰이 그대로면 목록을 다시 발행하지 않아야 합니다."
        )

        // 제출이 CLI로 넘어간 뒤의 재마운트 요청. 다른 직원에 갔다
        // 돌아온 것과 똑같이 호스트를 새로 만들고 목록을 다시 발행한다.
        weak var releasedHost: NSView? = mountedHost
        mountedHost = nil
        container.configure(
            director: director,
            selectedCharacterID: .boss,
            feedRemountToken: 1
        )
        container.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(150))

        guard let remountedHost = container.subviews.first else {
            XCTFail("재마운트 뒤 대화 호스트가 없습니다.")
            return
        }
        XCTAssertFalse(
            remountedHost === releasedHost,
            "재마운트 요청이 기존 호스트를 그대로 뒀습니다. 직원 전환과 "
                + "같은 경로를 타지 않았습니다."
        )
        XCTAssertEqual(
            container.subviews.count,
            1,
            "이전 호스트가 화면에 남아 있으면 안 됩니다."
        )
        XCTAssertGreaterThan(
            characterStore.presentationRevision,
            revisionAfterMount,
            "재마운트 뒤 목록 재발행이 일어나지 않았습니다."
        )
        let remountedScrollView = try await waitForPrimaryScrollView(
            in: container
        )
        XCTAssertNotNil(
            remountedScrollView,
            "재마운트 뒤 대화 목록이 실제로 다시 mount되어야 합니다."
        )

        try await settle(for: .milliseconds(50))
        XCTAssertNil(
            releasedHost,
            "재마운트로 버려진 이전 호스트가 해제되지 않았습니다."
        )
    }

    func testPostMountRefreshWaitsUntilSelectedHostIsInWindow()
        async throws
    {
        let director = AgentDirector(startBackgroundTasks: false)
        director.liveFeedStore.replace(with: makeTurns())
        director.liveFeedStore.finishInitialLoading()
        let characterStore = director.liveFeedStore.characterStore(
            for: OfficeCharacter.boss.rawValue
        )
        let container = CachedLiveWorkspaceFeedsNSView(
            frame: NSRect(x: 0, y: 0, width: 900, height: 700)
        )

        defer {
            container.tearDown()
        }

        container.configure(
            director: director,
            selectedCharacterID: .boss
        )
        container.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(50))

        XCTAssertEqual(
            characterStore.presentationRevision,
            0,
            "window에 연결되기 전의 갱신은 새 SwiftUI 그래프가 구독하기 "
                + "전에 유실될 수 있습니다."
        )

        let window = NSWindow(
            contentRect: container.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = container
        container.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(100))

        XCTAssertEqual(characterStore.presentationRevision, 1)
        XCTAssertTrue(container.window === window)
        let scrollView = try await waitForPrimaryScrollView(in: container)
        XCTAssertNotNil(
            scrollView,
            "창에 연결된 뒤 선택 직원 대화 목록이 실제로 mount되어야 합니다."
        )
        window.contentView = nil
    }

    func testSameEmployeeTurnIDTransitionKeepsConversationMountedAtBottom()
        async throws
    {
        let director = AgentDirector(startBackgroundTasks: false)
        let questionID = "existing-inline-question"
        let question = """
        다음 작업 방향을 선택해 주세요.

        1. 첫 번째 선택지
        2. 두 번째 선택지
        3. 세 번째 선택지
        4. 네 번째 선택지
        5. 다섯 번째 선택지
        6. 여섯 번째 선택지
        7. 일곱 번째 선택지
        8. 여덟 번째 선택지
        """
        var existingTurns = Array(
            makeTurns()
                .filter {
                    $0.characterId == OfficeCharacter.boss.rawValue
                }
                .prefix(9)
        )
        existingTurns.insert(
            makeTurn(
                id: questionID,
                characterID: OfficeCharacter.boss.rawValue,
                prompt: "기존 확인 질문",
                response: question,
                status: .completed,
                needsInput: true,
                startedAt: Date(timeIntervalSinceReferenceDate: 25_000)
            ),
            at: 0
        )
        director.liveFeedStore.replace(with: existingTurns)
        director.liveFeedStore.finishInitialLoading()

        let rootHost = NSHostingView(
            rootView: CachedLiveWorkspaceFeeds(director: director)
                .frame(width: 900, height: 700)
        )
        rootHost.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(
            contentRect: rootHost.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = rootHost
        rootHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(250))

        guard
            let container = allDescendants(of: rootHost)
                .compactMap({ $0 as? CachedLiveWorkspaceFeedsNSView })
                .first,
            let mountedHost = container.subviews.first,
            let mountedScrollView = try await waitForPrimaryScrollView(
                in: rootHost
            ),
            let mountedDocumentView = mountedScrollView.documentView
        else {
            XCTFail("기존 대화의 실제 NSHostingView/NSScrollView 계층이 없습니다.")
            window.contentView = nil
            return
        }
        defer {
            container.tearDown()
            window.contentView = nil
        }

        performLiveScroll(mountedScrollView, toTop: false)
        try await settle(for: .milliseconds(100))

        var persistedTurns = existingTurns
        let submittedAt = Date(timeIntervalSinceReferenceDate: 30_000)
        for index in 0..<8 {
            let localID = "local-same-employee-\(index)"
            let serverID = "server-same-employee-\(index)"
            let prompt = "동일 직원 새 업무 \(index)"
            let startedAt = submittedAt.addingTimeInterval(
                TimeInterval(index)
            )
            let optimistic = makeTurn(
                id: localID,
                characterID: OfficeCharacter.boss.rawValue,
                prompt: prompt,
                status: .running,
                startedAt: startedAt
            )

            director.liveFeedStore.insertOptimisticTurn(optimistic)
            let presentationID = director.liveFeedStore.presentationID(
                forTurnID: localID
            )
            rootHost.layoutSubtreeIfNeeded()
            try await settle(for: .milliseconds(8))
            director.liveFeedStore.reconcileOptimisticTurn(
                id: localID,
                with: serverID
            )
            XCTAssertEqual(
                director.liveFeedStore.presentationID(forTurnID: serverID),
                presentationID,
                "서버 turn ID 전환이 같은 카드의 SwiftUI 정체성을 "
                    + "삭제 후 재삽입으로 바꿨습니다."
            )
            rootHost.layoutSubtreeIfNeeded()
            try await settle(for: .milliseconds(8))

            let persisted = optimistic.replacingID(with: serverID)
            persistedTurns.insert(persisted, at: 0)
            director.liveFeedStore.replace(with: persistedTurns)
            rootHost.layoutSubtreeIfNeeded()
            try await settle(for: .milliseconds(16))

            XCTAssertTrue(
                container.subviews.first === mountedHost,
                "동일 직원 제출 중 NSHostingView가 교체됐습니다."
            )
            XCTAssertTrue(
                primaryScrollView(in: rootHost) === mountedScrollView,
                "optimistic/server ID 전환 중 NSScrollView가 교체됐습니다."
            )
            XCTAssertTrue(
                mountedScrollView.documentView === mountedDocumentView,
                "optimistic/server ID 전환 중 대화 문서가 교체됐습니다."
            )
        }

        try await settle(for: .milliseconds(350))
        rootHost.layoutSubtreeIfNeeded()

        guard let documentView = mountedScrollView.documentView else {
            XCTFail("새 업무 제출 뒤 대화 문서가 사라졌습니다.")
            return
        }
        let snapshot = LiveWorkspaceFeedScrollGeometry.snapshot(
            documentBounds: documentView.bounds,
            visibleRect: mountedScrollView.documentVisibleRect,
            isFlipped: documentView.isFlipped
        )

        XCTAssertEqual(director.selectedCharacterID, .boss)
        XCTAssertEqual(container.subviews.count, 1)
        XCTAssertLessThanOrEqual(
            snapshot.distanceFromBottom,
            20,
            "기존 대화가 있는 동일 직원에게 새 업무를 제출한 뒤 "
                + "대화 화면이 문서 위쪽/빈 영역으로 이동했습니다."
        )
        XCTAssertGreaterThan(
            mountedScrollView.documentVisibleRect.intersection(
                documentView.bounds
            ).height,
            0,
            "대화 viewport가 문서 밖의 흰 영역에 남았습니다."
        )
    }

    func testScrollBeforeSubmissionStillKeepsExistingCardsMounted()
        async throws
    {
        // 실제 사용 순서 재현. 사용자가 이전 답변을 읽으려 스크롤한 뒤
        // 같은 직원에게 다음 질문을 제출한다. 이 스크롤이 초기 정착을
        // 선점해 앵커가 비어 있는 채로 제출에 진입하던 것이 흰 화면의
        // 남은 원인이었다.
        let director = AgentDirector(startBackgroundTasks: false)
        let characterID = OfficeCharacter.rightMan.rawValue
        let tallResponse = (0..<90)
            .map { "완료된 응답 \($0)번째 줄입니다. 카드가 화면보다 큽니다." }
            .joined(separator: "\n")
        let baseDate = Date(timeIntervalSinceReferenceDate: 70_000)
        let completedTurns = [
            makeTurn(
                id: "read-second",
                characterID: characterID,
                prompt: "두 번째 질문",
                response: tallResponse,
                status: .completed,
                startedAt: baseDate.addingTimeInterval(60)
            ),
            makeTurn(
                id: "read-first",
                characterID: characterID,
                prompt: "첫 번째 질문",
                response: tallResponse,
                status: .completed,
                startedAt: baseDate
            ),
        ]
        director.liveFeedStore.replace(with: completedTurns)
        director.liveFeedStore.finishInitialLoading()
        director.selectedCharacterID = .rightMan

        let rootHost = NSHostingView(
            rootView: CachedLiveWorkspaceFeeds(director: director)
                .frame(width: 900, height: 700)
        )
        rootHost.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(
            contentRect: rootHost.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = rootHost
        rootHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(300))

        guard
            let container = allDescendants(of: rootHost)
                .compactMap({ $0 as? CachedLiveWorkspaceFeedsNSView })
                .first,
            let scrollView = try await waitForPrimaryScrollView(in: rootHost)
        else {
            XCTFail("긴 완료 카드 2개의 NSScrollView 계층이 없습니다.")
            window.contentView = nil
            return
        }
        defer {
            container.tearDown()
            window.contentView = nil
        }

        // 사용자가 이전 답변을 읽으려 위로 스크롤한다.
        performLiveScroll(scrollView, toTop: true)
        rootHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(150))

        let heightBeforeSubmission =
            scrollView.documentView?.bounds.height ?? 0
        XCTAssertGreaterThan(
            heightBeforeSubmission,
            scrollView.contentView.bounds.height,
            "재현 조건상 두 카드가 화면보다 커야 합니다."
        )

        // 읽던 상태에서 다음 질문을 제출한다.
        director.liveFeedStore.insertOptimisticTurn(
            makeTurn(
                id: "local-third",
                characterID: characterID,
                prompt: "세 번째 질문",
                status: .running,
                startedAt: baseDate.addingTimeInterval(120)
            )
        )
        rootHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(150))

        let heightAfterSubmission =
            scrollView.documentView?.bounds.height ?? 0
        XCTAssertGreaterThanOrEqual(
            heightAfterSubmission,
            heightBeforeSubmission - 1,
            "읽던 중 제출에서 기존 카드가 표시 창 밖으로 잘려 문서가 "
                + "\(Int(heightBeforeSubmission)) → "
                + "\(Int(heightAfterSubmission))로 붕괴했습니다."
        )

        guard let documentView = scrollView.documentView else {
            XCTFail("제출 뒤 대화 문서가 사라졌습니다.")
            return
        }
        XCTAssertGreaterThan(
            scrollView.documentVisibleRect.intersection(
                documentView.bounds
            ).height,
            0,
            "제출 뒤 viewport가 문서 밖 흰 영역에 남았습니다."
        )
    }

    func testSecondSubmissionKeepsTallCompletedCardsAndViewportInBounds()
        async throws
    {
        let director = AgentDirector(startBackgroundTasks: false)
        let characterID = OfficeCharacter.boss.rawValue
        let tallResponse = (0..<70)
            .map { "완료된 응답 본문 \($0)번째 줄입니다. 내용이 길어 카드가 화면보다 큽니다." }
            .joined(separator: "\n")
        let tallerResponse = (0..<200)
            .map { "첫 카드 본문 \($0)번째 줄입니다. 카드가 매우 큽니다." }
            .joined(separator: "\n")
        let baseDate = Date(timeIntervalSinceReferenceDate: 50_000)
        let completedTurns = [
            makeTurn(
                id: "tall-first",
                characterID: characterID,
                prompt: "첫 번째 질문",
                response: tallerResponse,
                status: .completed,
                startedAt: baseDate
            ),
            makeTurn(
                id: "tall-second",
                characterID: characterID,
                prompt: "두 번째 질문",
                response: tallResponse,
                status: .completed,
                startedAt: baseDate.addingTimeInterval(60)
            ),
        ]
        director.liveFeedStore.replace(with: completedTurns)
        director.liveFeedStore.finishInitialLoading()

        let rootHost = NSHostingView(
            rootView: CachedLiveWorkspaceFeeds(director: director)
                .frame(width: 900, height: 700)
        )
        rootHost.frame = NSRect(x: 0, y: 0, width: 900, height: 700)
        let window = NSWindow(
            contentRect: rootHost.bounds,
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.contentView = rootHost
        rootHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(300))

        guard
            let container = allDescendants(of: rootHost)
                .compactMap({ $0 as? CachedLiveWorkspaceFeedsNSView })
                .first,
            let scrollView = try await waitForPrimaryScrollView(
                in: rootHost
            ),
            let documentView = scrollView.documentView
        else {
            XCTFail("긴 완료 카드 2개의 NSScrollView 계층이 없습니다.")
            window.contentView = nil
            return
        }
        defer {
            container.tearDown()
            window.contentView = nil
        }

        let mountedHeight = documentView.bounds.height
        XCTAssertGreaterThan(
            mountedHeight,
            scrollView.contentView.bounds.height * 2,
            "긴 완료 카드 2개가 화면보다 충분히 커야 재현 조건이 됩니다."
        )

        func assertViewportInBounds(_ step: String) {
            guard let currentDocument = scrollView.documentView else {
                XCTFail("\(step): 대화 문서가 사라졌습니다.")
                return
            }
            XCTAssertGreaterThan(
                scrollView.documentVisibleRect.intersection(
                    currentDocument.bounds
                ).height,
                0,
                "\(step): viewport가 문서 밖 흰 영역에 남았습니다."
            )
        }

        // 1) 같은 직원에게 두 번째 질문 제출: 빈 optimistic 턴 삽입.
        let localID = "local-third"
        let serverID = "server-third"
        let submittedAt = baseDate.addingTimeInterval(120)
        director.liveFeedStore.insertOptimisticTurn(
            makeTurn(
                id: localID,
                characterID: characterID,
                prompt: "세 번째 질문",
                status: .running,
                startedAt: submittedAt
            )
        )
        let presentationID = director.liveFeedStore.presentationID(
            forTurnID: localID
        )
        rootHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(60))

        let heightAfterOptimistic =
            scrollView.documentView?.bounds.height ?? 0
        XCTAssertGreaterThanOrEqual(
            heightAfterOptimistic,
            mountedHeight - 1,
            "빈 optimistic 턴 삽입이 기존 긴 카드를 제거해 문서 높이가 "
                + "\(Int(mountedHeight)) → \(Int(heightAfterOptimistic))로 "
                + "급락했습니다. 이 급락이 흰 화면의 원인입니다."
        )
        assertViewportInBounds("optimistic 삽입 직후")

        // 2) local → server ID 전환.
        director.liveFeedStore.reconcileOptimisticTurn(
            id: localID,
            with: serverID
        )
        rootHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(60))
        XCTAssertEqual(
            director.liveFeedStore.presentationID(forTurnID: serverID),
            presentationID,
            "server ID 전환이 카드 정체성을 바꿨습니다."
        )
        XCTAssertGreaterThanOrEqual(
            scrollView.documentView?.bounds.height ?? 0,
            mountedHeight - 1,
            "server ID 전환 중 기존 카드가 제거돼 문서가 줄었습니다."
        )
        assertViewportInBounds("server ID 전환 직후")

        // 3) 활동·응답 증가를 반영한 서버 스냅샷 반영.
        var persisted = Array(completedTurns.reversed())
        persisted.insert(
            makeTurn(
                id: serverID,
                characterID: characterID,
                prompt: "세 번째 질문",
                response: String(
                    repeating: "생성 중 응답 줄입니다.\n",
                    count: 12
                ),
                status: .running,
                startedAt: submittedAt
            ),
            at: 0
        )
        director.liveFeedStore.replace(with: persisted)
        rootHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(60))
        XCTAssertGreaterThanOrEqual(
            scrollView.documentView?.bounds.height ?? 0,
            mountedHeight - 1,
            "응답 증가 반영 중 기존 카드가 제거돼 문서가 줄었습니다."
        )
        assertViewportInBounds("응답 증가 반영 직후")

        // 4) 위로 스크롤해 카드를 실체화한 상태에서 또 한 번 제출한다.
        //    과거 기록을 읽는 중의 새 제출에서 기존 카드 identity와
        //    문서 높이가 유지되고 viewport가 문서 안에 남는지 본다.
        //    표시 창 재슬라이스 제거 자체의 판별 회귀는
        //    LiveWorkspaceFeedDisplayAnchor 단위 테스트가 담당한다.
        //    (흰 화면의 화면 픽셀 상태는 윈도서버 밖에서 관찰할 수
        //    없어 in-process 테스트로는 직접 판정하지 못한다.)
        performLiveScroll(scrollView, toTop: true)
        rootHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(150))
        assertViewportInBounds("위로 스크롤 직후")
        let materializedHeight =
            scrollView.documentView?.bounds.height ?? 0
        XCTAssertGreaterThan(
            materializedHeight,
            mountedHeight - 1,
            "위로 스크롤 뒤에는 모든 카드가 실체화돼 있어야 합니다."
        )

        director.liveFeedStore.insertOptimisticTurn(
            makeTurn(
                id: "local-fourth",
                characterID: characterID,
                prompt: "네 번째 질문",
                status: .running,
                startedAt: baseDate.addingTimeInterval(180)
            )
        )
        rootHost.layoutSubtreeIfNeeded()
        try await settle(for: .milliseconds(80))

        let heightAfterFourth =
            scrollView.documentView?.bounds.height ?? 0
        XCTAssertGreaterThanOrEqual(
            heightAfterFourth,
            materializedHeight - 200,
            "과거 기록을 읽는 중의 새 제출이 표시 중이던 카드를 "
                + "제거해 문서가 \(Int(materializedHeight)) → "
                + "\(Int(heightAfterFourth))로 붕괴했습니다. 이 붕괴가 "
                + "흰 화면과 스크롤바 튐의 원인입니다."
        )
        assertViewportInBounds("실체화 상태 제출 직후")

        try await settle(for: .milliseconds(250))
        assertViewportInBounds("정착 후")
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
        // 로드 뒤 상단 임계 안에 머무는 동안에는 새 휠 세션이
        // 시작돼도 다음 페이지를 연쇄 로드하지 않는다. 문서가 짧아진
        // 비정상 상태에서 페이지가 계속 쌓여 CPU가 치솟는 것을 막는다.
        XCTAssertFalse(
            gate.shouldLoad(
                distanceFromTop: 0,
                threshold: 120,
                isProgrammaticScrollInFlight: false
            )
        )
        XCTAssertFalse(
            gate.shouldLoad(
                distanceFromTop: 60,
                threshold: 120,
                isProgrammaticScrollInFlight: false
            )
        )
        // 임계 밖으로 나가면 재장전되고, 다시 상단에 닿으면 다음
        // 페이지를 한 번 로드한다.
        XCTAssertFalse(
            gate.shouldLoad(
                distanceFromTop: 300,
                threshold: 120,
                isProgrammaticScrollInFlight: false
            )
        )
        XCTAssertTrue(
            gate.shouldLoad(
                distanceFromTop: 10,
                threshold: 120,
                isProgrammaticScrollInFlight: false
            )
        )
    }

    private func makeTurns(
        streamingStep: Int? = nil,
        completedResponse: String? = nil
    ) -> [LiveFeedTurn] {
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
                        : completedResponse ?? "완료 \(index)",
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

    private func makeTurn(
        id: String,
        characterID: String,
        prompt: String,
        response: String = "",
        status: LiveTurnStatus,
        needsInput: Bool = false,
        startedAt: Date
    ) -> LiveFeedTurn {
        LiveFeedTurn(
            id: id,
            characterId: characterID,
            characterName: characterID,
            characterBackend: .codex,
            backend: .codex,
            model: "gpt-5.6-sol",
            effort: "high",
            fastMode: false,
            externalSessionId: nil,
            conversationWorkdir: "/repo",
            prompt: prompt,
            response: response,
            feedback: nil,
            status: status,
            needsInput: needsInput,
            errorMessage: nil,
            responseSourceWarning: nil,
            startedAt: startedAt,
            endedAt: status.isRunning ? nil : startedAt,
            updatedAt: startedAt,
            estimatedCostUsd: nil,
            sessionContext: nil,
            activities: [],
            sources: nil,
            workspace: nil
        )
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

    private func waitForPrimaryScrollView(
        in root: NSView,
        timeout: Duration = .milliseconds(500)
    ) async throws -> NSScrollView? {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            root.layoutSubtreeIfNeeded()
            if let scrollView = primaryScrollView(in: root) {
                return scrollView
            }
            try await settle(for: .milliseconds(4))
        } while clock.now < deadline
        root.layoutSubtreeIfNeeded()
        return primaryScrollView(in: root)
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

    private func performSmallLiveScroll(
        _ scrollView: NSScrollView,
        delta: CGFloat
    ) {
        guard let documentView = scrollView.documentView else {
            return
        }
        let clipView = scrollView.contentView
        let maximumY = max(
            documentView.bounds.minY,
            documentView.bounds.height - clipView.bounds.height
        )
        let targetY = min(
            maximumY,
            max(documentView.bounds.minY, clipView.bounds.minY + delta)
        )
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
