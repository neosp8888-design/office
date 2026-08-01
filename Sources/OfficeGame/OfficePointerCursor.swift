// 이 파일은 사무실의 실제 조작 영역에 macOS 포인터 커서를 적용한다.

import AppKit
import SwiftUI

private struct OfficePointerCursor: ViewModifier {
    let cursor: NSCursor
    let isEnabled: Bool
    @State private var hasPushedCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                updateCursor(isHovering && isEnabled)
            }
            .onChange(of: isEnabled) { _, isEnabled in
                if !isEnabled {
                    updateCursor(false)
                }
            }
            .onDisappear {
                updateCursor(false)
            }
    }

    private func updateCursor(_ shouldUseCursor: Bool) {
        guard shouldUseCursor != hasPushedCursor else {
            return
        }
        hasPushedCursor = shouldUseCursor
        if shouldUseCursor {
            cursor.push()
        } else {
            NSCursor.pop()
        }
    }
}

extension View {
    func officePointingHandCursor(
        isEnabled: Bool = true
    ) -> some View {
        modifier(
            OfficePointerCursor(
                cursor: .pointingHand,
                isEnabled: isEnabled
            )
        )
    }

    func officeColumnResizeCursor() -> some View {
        modifier(
            OfficePointerCursor(
                cursor: .resizeLeftRight,
                isEnabled: true
            )
        )
    }
}
