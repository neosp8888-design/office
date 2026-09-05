// 선택 영역은 카드별로 고정한다. 호버로 textSelection 분기를 바꾸면
// 표·본문·코드의 하위 뷰가 재생성돼 깜빡임과 TextKit 재조판이 발생한다.
// 피드/앱 루트에는 선택을 켜지 않고 각 카드 안에서만 선택을 제공한다.

import AppKit
import SwiftUI

@MainActor
final class ConversationTextSelectionCoordinator: NSObject, ObservableObject {
    static let shared = ConversationTextSelectionCoordinator()

    @Published private(set) var activeRegionID: String?
    private let activeLiveScrollViews = NSHashTable<NSScrollView>.weakObjects()
    private var pendingHoveredRegionID: String?
    private var liveScrollIdleTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    // 일부 사용자 스크롤은 willStart/didEnd 알림 쌍 없이 didLive만 온다.
    // 마지막 갱신 뒤 짧은 유휴 구간을 종료로 간주해 선택이 영구 정지하지
    // 않게 한다. 관성 스크롤 중에는 새 didLive가 이 타이머를 계속 미룬다.
    private static let liveScrollIdleDelayNanoseconds: UInt64 = 120_000_000

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveScrollDidBegin(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveScrollDidUpdate(_:)),
            name: NSScrollView.didLiveScrollNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveScrollDidEnd(_:)),
            name: NSScrollView.didEndLiveScrollNotification,
            object: nil
        )
    }

    deinit {
        liveScrollIdleTasks.values.forEach { $0.cancel() }
        NotificationCenter.default.removeObserver(self)
    }

    func activate(_ regionID: String) {
        guard activeRegionID != regionID else {
            return
        }
        activeRegionID = regionID
    }

    func deactivate(_ regionID: String) {
        guard activeRegionID == regionID else {
            return
        }
        activeRegionID = nil
    }

    func reset() {
        liveScrollIdleTasks.values.forEach { $0.cancel() }
        liveScrollIdleTasks.removeAll()
        activeRegionID = nil
        pendingHoveredRegionID = nil
        activeLiveScrollViews.removeAllObjects()
    }

    func handleHover(_ isHovering: Bool, in regionID: String) {
        if !activeLiveScrollViews.allObjects.isEmpty {
            if isHovering {
                pendingHoveredRegionID = regionID
            } else if pendingHoveredRegionID == regionID {
                pendingHoveredRegionID = nil
            }
            return
        }

        if isHovering {
            activate(regionID)
        } else if NSEvent.pressedMouseButtons & 1 == 0 {
            deactivate(regionID)
        }
    }

    func regionDidDisappear(_ regionID: String) {
        if pendingHoveredRegionID == regionID {
            pendingHoveredRegionID = nil
        }
        guard activeLiveScrollViews.allObjects.isEmpty else {
            return
        }
        deactivate(regionID)
    }

    func beginLiveScroll(in scrollView: NSScrollView) {
        let wasScrolling = !activeLiveScrollViews.allObjects.isEmpty
        activeLiveScrollViews.add(scrollView)
        if !wasScrolling {
            pendingHoveredRegionID = activeRegionID
        }
    }

    func endLiveScroll(in scrollView: NSScrollView) {
        let scrollViewID = ObjectIdentifier(scrollView)
        liveScrollIdleTasks.removeValue(forKey: scrollViewID)?.cancel()
        activeLiveScrollViews.remove(scrollView)
        guard activeLiveScrollViews.allObjects.isEmpty else {
            return
        }

        let nextRegionID = pendingHoveredRegionID
        pendingHoveredRegionID = nil
        guard activeRegionID != nextRegionID else {
            return
        }
        activeRegionID = nextRegionID
    }

    @objc
    private func liveScrollDidBegin(_ notification: Notification) {
        guard let scrollView = notification.object as? NSScrollView else {
            return
        }
        beginLiveScroll(in: scrollView)
    }

    @objc
    private func liveScrollDidUpdate(_ notification: Notification) {
        guard let scrollView = notification.object as? NSScrollView else {
            return
        }
        beginLiveScroll(in: scrollView)
        scheduleIdleEnd(for: scrollView)
    }

    @objc
    private func liveScrollDidEnd(_ notification: Notification) {
        guard let scrollView = notification.object as? NSScrollView else {
            return
        }
        endLiveScroll(in: scrollView)
    }

    private func scheduleIdleEnd(for scrollView: NSScrollView) {
        let scrollViewID = ObjectIdentifier(scrollView)
        liveScrollIdleTasks.removeValue(forKey: scrollViewID)?.cancel()
        liveScrollIdleTasks[scrollViewID] = Task {
            @MainActor [weak self] in
            do {
                try await Task.sleep(
                    nanoseconds: Self.liveScrollIdleDelayNanoseconds
                )
            } catch {
                return
            }
            guard let self else {
                return
            }
            self.liveScrollIdleTasks.removeValue(forKey: scrollViewID)
            self.endLiveScroll(in: scrollView)
        }
    }
}

private struct ConversationTextSelectionRegionModifier: ViewModifier {
    let regionID: String

    func body(content: Content) -> some View {
        content
            .textSelection(.enabled)
            .id(regionID)
    }
}

extension View {
    func conversationTextSelectionRegion(
        _ regionID: String
    ) -> some View {
        modifier(
            ConversationTextSelectionRegionModifier(
                regionID: regionID
            )
        )
    }
}
