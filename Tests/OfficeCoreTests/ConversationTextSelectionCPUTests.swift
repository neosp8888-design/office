// 이 파일은 직원 전환과 스크롤 뒤 대화 화면이 유휴 상태로 돌아오는지 검증한다.

import AppKit
import Darwin
import OfficeCore
import SwiftUI
import XCTest
@testable import OfficeGame

@MainActor
final class ConversationTextSelectionCPUTests: XCTestCase {
    // 긴 Markdown의 SelectionOverlay가 직원 전환 직후 스크롤과 겹치면
    // AttributeGraph 갱신이 끝나지 않는다. 실제 전환·스트리밍·스크롤
    // 조합 뒤 CPU가 자연스럽게 유휴 상태로 돌아오는지 함께 확인한다.
    func testConversationStaysIdleAfterTransitionAndScroll()
        async throws
    {
        let selectionCoordinator =
            ConversationTextSelectionCoordinator.shared
        selectionCoordinator.reset()
        let director = AgentDirector(startBackgroundTasks: false)
        director.liveFeedStore.replace(with: makeMarkdownHeavyTurns())
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

        guard let container = allDescendants(of: rootHost)
            .compactMap({ $0 as? CachedLiveWorkspaceFeedsNSView })
            .first
        else {
            XCTFail("선택 가능한 대화 container를 만들지 못했습니다.")
            window.contentView = nil
            return
        }
        defer {
            selectionCoordinator.reset()
            container.tearDown()
            window.contentView = nil
        }

        // 사용자 재현과 같은 조합이다. 카드 하나에 실제 선택 환경을 켠
        // 상태에서 직원 전환 직후 곧바로 선택·스크롤하고, 타이핑 중인
        // 턴도 함께 자라게 한다.
        let busyCPU = try await measureCPUUtilization {
            for index in 0..<12 {
                let character = OfficeCharacter.allCases[
                    index % OfficeCharacter.allCases.count
                ]
                director.selectedCharacterID = character
                let turns = makeMarkdownHeavyTurns(
                    streamingStep: index + 1
                )
                director.liveFeedStore.replace(with: turns)
                if let visibleTurn = turns.first(where: {
                    $0.characterId == character.rawValue
                }) {
                    selectionCoordinator.activate(
                        "live-turn-\(visibleTurn.id)"
                    )
                }
                rootHost.layoutSubtreeIfNeeded()
                try await settle(for: .milliseconds(4))
                guard
                    let scrollView = try await waitForPrimaryScrollView(
                        in: rootHost
                    )
                else {
                    XCTFail("직원 전환 직후 scroll view가 사라졌습니다.")
                    return
                }
                performSmallLiveScroll(
                    scrollView,
                    delta: index.isMultiple(of: 2) ? 12 : -12
                )
                performTextDrag(in: rootHost)
            }
        }

        // 입력이 끝난 뒤의 유휴 구간. 선택 오버레이가 AttributeGraph를
        // 계속 재촉발하면 아무 입력이 없어도 CPU가 그대로 유지된다.
        var idleCPU = 0.0
        for _ in 0..<3 {
            idleCPU = try await measureCPUUtilization {
                try await settle(for: .milliseconds(700))
            }
            if idleCPU < 0.35 {
                break
            }
        }

        XCTAssertGreaterThan(
            busyCPU,
            0.02,
            "스트레스 구간에서도 CPU가 잡히지 않으면 측정 자체가 "
                + "무의미합니다. 측정값: \(busyCPU)"
        )
        XCTAssertLessThan(
            idleCPU,
            0.35,
            "전환·스크롤 뒤 유휴 구간에서 CPU를 "
                + "\(Int(idleCPU * 100))% 계속 사용합니다. 선택 오버레이가 "
                + "갱신 루프에 빠졌을 때의 증상입니다. (스트레스 구간 "
                + "\(Int(busyCPU * 100))%)"
        )
        let didFinishFinalTransition = try await waitNaturallyUntil(
            timeout: .seconds(6)
        ) {
            container.subviews.count == 1
        }
        XCTAssertTrue(
            didFinishFinalTransition,
            "마지막 직원 전환이 끝난 뒤에도 로딩 차폐나 이전 host가 남았습니다."
        )
        XCTAssertEqual(container.subviews.count, 1)
    }

    func testSelectionCoordinatorActivatesOnlyOneConversationRegion() {
        let coordinator = ConversationTextSelectionCoordinator.shared
        coordinator.reset()
        defer { coordinator.reset() }

        coordinator.activate("first")
        XCTAssertEqual(coordinator.activeRegionID, "first")

        coordinator.activate("second")
        XCTAssertEqual(coordinator.activeRegionID, "second")

        coordinator.deactivate("first")
        XCTAssertEqual(coordinator.activeRegionID, "second")

        coordinator.deactivate("second")
        XCTAssertNil(coordinator.activeRegionID)
    }

    // 앱 루트에서 선택을 켜면 입력창을 포함한 전체 화면에 오버레이가
    // 생긴다. 실시간 피드는 분리된 NSHostingView에서도 선택을 명시적으로
    // 꺼야 상위 환경 변경으로 같은 문제가 되살아나지 않는다.
    func testLiveConversationDoesNotInstallBroadSelectionOverlays() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/OfficeGame", directoryHint: .isDirectory)

        let appSource = try String(
            contentsOf: sourceRoot.appending(path: "OfficeGameApp.swift"),
            encoding: .utf8
        )
        let appRoot = try XCTUnwrap(
            sourceSection(
                in: appSource,
                from: "@main\nstruct OfficeGameApp",
                to: "private struct OfficeLaunchRootView"
            )
        )
        XCTAssertFalse(
            appRoot.filter { !$0.isWhitespace }
                .contains(".textSelection(.enabled)"),
            "앱 루트 전체에 텍스트 선택을 켜면 입력과 스크롤까지 "
                + "SelectionOverlay 갱신 대상이 됩니다."
        )

        let dashboardSource = try String(
            contentsOf: sourceRoot.appending(path: "OfficeDashboardPanels.swift"),
            encoding: .utf8
        )
        let hostedFeed = try XCTUnwrap(
            sourceSection(
                in: dashboardSource,
                from: "private struct HostedLiveWorkspaceFeed",
                to: "private enum LiveWorkspaceFeedMountReadiness"
            )
        )
        let compactFeed = hostedFeed.filter { !$0.isWhitespace }
        XCTAssertFalse(compactFeed.contains(".textSelection(.enabled)"))
        XCTAssertTrue(
            compactFeed.contains(".textSelection(.disabled)"),
            "분리된 대화 NSHostingView에서 선택을 명시적으로 꺼야 합니다."
        )

        let promptBlock = try XCTUnwrap(
            sourceSection(
                in: dashboardSource,
                from: "struct LiveTurnPromptBlock",
                to: "private struct LiveTurnCard"
            )
        )
        XCTAssertTrue(
            promptBlock.contains("conversationTextSelectionRegion"),
            "사용자 질문 카드의 드래그 선택 영역이 빠졌습니다."
        )

        let responseCard = try XCTUnwrap(
            sourceSection(
                in: dashboardSource,
                from: "private struct LiveTurnCard",
                to: "private struct AgentPromptSuggestionList"
            )
        )
        XCTAssertTrue(
            responseCard.contains("conversationTextSelectionRegion"),
            "직원 응답 카드의 드래그 선택 영역이 빠졌습니다."
        )
    }

    private func sourceSection(
        in source: String,
        from startMarker: String,
        to endMarker: String
    ) -> String? {
        guard
            let start = source.range(of: startMarker)?.lowerBound,
            let end = source.range(
                of: endMarker,
                range: start..<source.endIndex
            )?.lowerBound
        else {
            return nil
        }
        return String(source[start..<end])
    }

    /// 블록이 실행되는 동안 이 프로세스가 쓴 CPU 시간을 벽시계 시간으로
    /// 나눈 값. 1.0이면 코어 하나를 가득 쓴 것이다.
    private func measureCPUUtilization(
        _ body: () async throws -> Void
    ) async rethrows -> Double {
        let clock = ContinuousClock()
        let startedCPU = processCPUSeconds()
        let startedAt = clock.now
        try await body()
        let elapsed = startedAt.duration(to: clock.now)
        let wallSeconds =
            Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        guard wallSeconds > 0 else {
            return 0
        }
        return (processCPUSeconds() - startedCPU) / wallSeconds
    }

    private func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else {
            return 0
        }
        func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// 실제 사용자가 카드 본문을 드래그하는 것과 같은 마우스 이벤트다.
    private func performTextDrag(in root: NSView) {
        guard
            let window = root.window,
            let scrollView = primaryScrollView(in: root),
            let documentView = scrollView.documentView
        else {
            return
        }
        let visible = scrollView.documentVisibleRect
        guard visible.height > 40 else {
            return
        }
        let start = documentView.convert(
            NSPoint(x: visible.minX + 80, y: visible.midY - 8),
            to: nil
        )
        let end = documentView.convert(
            NSPoint(x: visible.maxX - 80, y: visible.midY + 8),
            to: nil
        )
        for (type, location) in [
            (NSEvent.EventType.leftMouseDown, start),
            (NSEvent.EventType.leftMouseDragged, end),
            (NSEvent.EventType.leftMouseUp, end),
        ] {
            guard let event = NSEvent.mouseEvent(
                with: type,
                location: location,
                modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber,
                context: nil,
                eventNumber: 0,
                clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1
            ) else {
                continue
            }
            window.sendEvent(event)
        }
    }

    private func makeMarkdownHeavyTurns(
        streamingStep: Int? = nil
    ) -> [LiveFeedTurn] {
        let origin = Date(timeIntervalSinceReferenceDate: 10_000)
        let response = (0..<14).map { index in
            """
            ### 완료 응답 절 \(index)

            드래그로 선택해 복사할 수 있어야 하는 **본문 문단**입니다.
            항목도 함께 확인합니다.

            - 첫 번째 항목 \(index)
            - 두 번째 항목 \(index)
            """
        }.joined(separator: "\n\n")

        return OfficeCharacter.allCases.flatMap { character in
            (0..<6).map { index in
                let timestamp = origin.addingTimeInterval(
                    TimeInterval(index)
                )
                let isStreaming = streamingStep != nil && index == 5
                let streamingResponse = String(
                    repeating: "타이핑 중인 **응답 줄**입니다.\n\n",
                    count: streamingStep ?? 1
                )
                return LiveFeedTurn(
                    id: "\(character.rawValue)-selection-\(index)",
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
                    response: isStreaming ? streamingResponse : response,
                    feedback: nil,
                    status: isStreaming ? .running : .completed,
                    needsInput: false,
                    errorMessage: nil,
                    responseSourceWarning: nil,
                    wikiProposalWarning: nil,
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

    private func waitNaturallyUntil(
        timeout: Duration,
        pollInterval: Duration = .milliseconds(20),
        condition: () -> Bool
    ) async throws -> Bool {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        repeat {
            if condition() {
                return true
            }
            try await settle(for: pollInterval)
        } while clock.now < deadline
        return condition()
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
