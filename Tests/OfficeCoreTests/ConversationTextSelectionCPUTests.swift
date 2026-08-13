// 이 파일은 드래그 선택을 켠 대화 화면이 유휴 상태에서 CPU를 계속 태우지 않는지 검증한다.

import AppKit
import Darwin
import OfficeCore
import SwiftUI
import XCTest
@testable import OfficeGame

@MainActor
final class ConversationTextSelectionCPUTests: XCTestCase {
    // 2026-08-09 846cfe1은 `.textSelection(.enabled)`가 직원 전환 직후
    // 스크롤과 겹치면 AttributeGraph 갱신을 끝없이 재촉발한다는 이유로
    // 선택을 전면 제거했다. 소스에서 문자열을 금지하는 방식은 선택
    // 기능을 영구히 막을 뿐 실제 위험을 재지 않는다. 여기서는 그
    // 위험 자체(유휴 CPU 점유)를 직접 측정해 회귀를 잡는다.
    func testSelectableConversationStaysIdleAfterSelectionAndScroll()
        async throws
    {
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
            container.tearDown()
            window.contentView = nil
        }

        // 과거 CPU 루프의 방아쇠였던 조합. 직원 전환 직후 곧바로
        // 스크롤하고, 그 위에서 실제 드래그 선택까지 얹는다. 타이핑
        // 중인 턴도 함께 자라게 해 16ms 주기로 다시 만들어지는 트리
        // 위에서 선택 오버레이가 생기는 경로까지 포함한다.
        let busyCPU = try await measureCPUUtilization {
            for index in 0..<12 {
                director.selectedCharacterID = OfficeCharacter.allCases[
                    index % OfficeCharacter.allCases.count
                ]
                director.liveFeedStore.replace(
                    with: makeMarkdownHeavyTurns(streamingStep: index + 1)
                )
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
            "선택·전환·스크롤 뒤 유휴 구간에서 CPU를 "
                + "\(Int(idleCPU * 100))% 계속 사용합니다. 선택 오버레이가 "
                + "갱신 루프에 빠졌을 때의 증상입니다. (스트레스 구간 "
                + "\(Int(busyCPU * 100))%)"
        )
        XCTAssertEqual(container.subviews.count, 1)
    }

    // 대화 카드는 앱 루트와 분리된 NSHostingView 안에서 그려지므로
    // 루트에서 켠 환경 값이 넘어오지 않는다. 두 경계 중 하나라도
    // 빠지면 화면 절반이 다시 선택 불가가 되므로 함께 확인한다.
    func testSelectionIsEnabledAtBothSwiftUIHostingBoundaries() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/OfficeGame", directoryHint: .isDirectory)

        for (fileName, description) in [
            ("OfficeGameApp.swift", "앱 루트"),
            ("OfficeDashboardPanels.swift", "대화 카드 호스팅 경계"),
        ] {
            let source = try String(
                contentsOf: sourceRoot.appending(path: fileName),
                encoding: .utf8
            )
            XCTAssertTrue(
                source.filter { !$0.isWhitespace }
                    .contains(".textSelection(.enabled)"),
                "\(description)(\(fileName))에서 드래그 선택이 꺼졌습니다. "
                    + "이 경계가 빠지면 해당 트리 전체를 복사할 수 없습니다."
            )
        }
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

    /// 실제 사용자가 본문 위에서 드래그해 텍스트를 선택하는 동작.
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
            NSPoint(x: visible.minX + 40, y: visible.midY - 12),
            to: nil
        )
        let end = documentView.convert(
            NSPoint(x: visible.maxX - 40, y: visible.midY + 12),
            to: nil
        )
        let events = [
            (NSEvent.EventType.leftMouseDown, start),
            (NSEvent.EventType.leftMouseDragged, end),
            (NSEvent.EventType.leftMouseUp, end),
        ]
        for (type, location) in events {
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
