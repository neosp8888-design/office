// 대화 카드 하나에만 SwiftUI 텍스트 선택 오버레이를 설치해 드래그
// 복사는 제공하면서 긴 대화 전체의 AttributeGraph CPU 루프는 피한다.

import AppKit
import SwiftUI

@MainActor
final class ConversationTextSelectionCoordinator: ObservableObject {
    static let shared = ConversationTextSelectionCoordinator()

    @Published private(set) var activeRegionID: String?

    private init() {}

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
                if isHovering {
                    coordinator.activate(regionID)
                } else if NSEvent.pressedMouseButtons & 1 == 0 {
                    coordinator.deactivate(regionID)
                }
                // 카드 밖까지 드래그하는 동안에는 선택을 유지한다. 마우스를
                // 놓은 뒤 다른 카드로 이동하면 그 카드만 새로 활성화된다.
            }
            .onDisappear {
                coordinator.deactivate(regionID)
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
