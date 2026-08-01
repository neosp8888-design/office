// 이 파일은 화면 분할선에 macOS 크기 조절 커서를 적용한다.

import AppKit
import SwiftUI

private struct OfficeResizeCursor: ViewModifier {
    let cursor: NSCursor
    @State private var hasPushedCursor = false

    func body(content: Content) -> some View {
        content
            .onHover { isHovering in
                guard isHovering != hasPushedCursor else {
                    return
                }
                hasPushedCursor = isHovering
                if isHovering {
                    cursor.push()
                } else {
                    NSCursor.pop()
                }
            }
            .onDisappear {
                guard hasPushedCursor else {
                    return
                }
                NSCursor.pop()
                hasPushedCursor = false
            }
    }
}

extension View {
    func officeColumnResizeCursor() -> some View {
        modifier(OfficeResizeCursor(cursor: .resizeLeftRight))
    }

    func officeRowResizeCursor() -> some View {
        modifier(OfficeResizeCursor(cursor: .resizeUpDown))
    }
}
