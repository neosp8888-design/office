// 대화 카드 하나에만 SwiftUI 텍스트 선택 오버레이를 설치해 드래그
// 복사는 제공하면서 긴 대화 전체의 AttributeGraph CPU 루프는 피한다.

import AppKit
import SwiftUI

@MainActor
final class ConversationTextSelectionCoordinator: NSObject, ObservableObject {
    static let shared = ConversationTextSelectionCoordinator()

    @Published private(set) var activeRegionID: String?
    private let activeLiveScrollViews = NSHashTable<NSScrollView>.weakObjects()
    private var pendingHoveredRegionID: String?

    private override init() {
        super.init()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveScrollDidBeginOrUpdate(_:)),
            name: NSScrollView.willStartLiveScrollNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(liveScrollDidBeginOrUpdate(_:)),
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
    private func liveScrollDidBeginOrUpdate(_ notification: Notification) {
        guard let scrollView = notification.object as? NSScrollView else {
            return
        }
        beginLiveScroll(in: scrollView)
    }

    @objc
    private func liveScrollDidEnd(_ notification: Notification) {
        guard let scrollView = notification.object as? NSScrollView else {
            return
        }
        endLiveScroll(in: scrollView)
    }
}

private struct ConversationTextSelectionRegionModifier: ViewModifier {
    let regionID: String

    @ObservedObject private var coordinator =
        ConversationTextSelectionCoordinator.shared

    @ViewBuilder
    func body(content: Content) -> some View {
        Group {
            if coordinator.activeRegionID == regionID {
                content.textSelection(.enabled)
            } else {
                content
            }
        }
            .onHover { isHovering in
                coordinator.handleHover(isHovering, in: regionID)
                // 카드 밖까지 드래그하는 동안에는 선택을 유지한다. 마우스를
                // 놓은 뒤 다른 카드로 이동하면 그 카드만 새로 활성화된다.
            }
            .onDisappear {
                coordinator.regionDidDisappear(regionID)
            }
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
