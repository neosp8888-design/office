// 이 파일은 일반 응답 카드의 시간과 복사 버튼이 좁은 폭에서도 세로로 놓이는지 검증한다.

import AppKit
import SwiftUI
import XCTest
@testable import OfficeGame

@MainActor
final class ResponseMessageFooterLayoutTests: XCTestCase {
    func testTimestampUsesMediumWeight() {
        XCTAssertEqual(
            ResponseMessageFooter.timestampFontWeight,
            .medium
        )
    }

    func testCopyButtonStaysBelowTimeAtNarrowWidth() {
        let footer = ResponseMessageFooter(
            occurredAt: Date(timeIntervalSince1970: 1_000),
            copied: false,
            accentColor: .teal,
            accessibilityID: "copyMessage-test",
            copy: {}
        )

        let narrowHeight = measuredHeight(footer, width: 80)
        let wideHeight = measuredHeight(footer, width: 320)

        XCTAssertGreaterThan(narrowHeight, 24)
        XCTAssertEqual(narrowHeight, wideHeight, accuracy: 0.5)
    }

    private func measuredHeight(
        _ footer: ResponseMessageFooter,
        width: CGFloat
    ) -> CGFloat {
        let controller = NSHostingController(rootView: footer.frame(width: width))
        return controller.sizeThatFits(
            in: NSSize(width: width, height: 1_000)
        ).height
    }
}
