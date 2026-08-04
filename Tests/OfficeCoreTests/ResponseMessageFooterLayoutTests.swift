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
            showsFeedback: true,
            feedback: nil,
            feedbackAccessibilityIDPrefix: "test-turn",
            copy: {},
            feedbackChanged: { _ in }
        )

        let narrowHeight = measuredHeight(footer, width: 80)
        let wideHeight = measuredHeight(footer, width: 320)

        XCTAssertGreaterThan(narrowHeight, 24)
        XCTAssertEqual(narrowHeight, wideHeight, accuracy: 0.5)
    }

    func testFeedbackSelectionTogglesAndRemainsMutuallyExclusive() {
        XCTAssertEqual(
            TurnResponseFeedback.toggled(
                current: nil,
                selection: .liked
            ),
            .liked
        )
        XCTAssertNil(
            TurnResponseFeedback.toggled(
                current: .liked,
                selection: .liked
            )
        )
        XCTAssertEqual(
            TurnResponseFeedback.toggled(
                current: .liked,
                selection: .disliked
            ),
            .disliked
        )
    }

    func testSelectedFeedbackIconsRenderAsFilledStates() throws {
        let neutral = try renderedFooter(feedback: nil)
        let liked = try renderedFooter(feedback: .liked)
        let disliked = try renderedFooter(feedback: .disliked)

        XCTAssertEqual(redPixelCount(in: neutral), 0)
        XCTAssertGreaterThan(redPixelCount(in: liked), 20)
        XCTAssertGreaterThan(changedPixelCount(neutral, disliked), 20)
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

    private func renderedFooter(
        feedback: TurnResponseFeedback?
    ) throws -> NSBitmapImageRep {
        let footer = ResponseMessageFooter(
            occurredAt: Date(timeIntervalSince1970: 1_000),
            copied: false,
            accentColor: .teal,
            accessibilityID: "copyMessage-render-test",
            showsFeedback: true,
            feedback: feedback,
            feedbackAccessibilityIDPrefix: "render-test-turn",
            copy: {},
            feedbackChanged: { _ in }
        )
        .environment(\.colorScheme, .light)
        .frame(width: 220, height: 44, alignment: .topLeading)

        let hostingView = NSHostingView(rootView: footer)
        hostingView.frame = NSRect(x: 0, y: 0, width: 220, height: 44)
        hostingView.layoutSubtreeIfNeeded()
        guard let bitmap = hostingView.bitmapImageRepForCachingDisplay(
            in: hostingView.bounds
        ) else {
            throw XCTSkip("SwiftUI 푸터 비트맵을 만들 수 없습니다.")
        }
        hostingView.cacheDisplay(in: hostingView.bounds, to: bitmap)
        return bitmap
    }

    private func redPixelCount(in bitmap: NSBitmapImageRep) -> Int {
        pixelColors(in: bitmap).reduce(into: 0) { count, color in
            guard let rgb = color.usingColorSpace(.deviceRGB) else {
                return
            }
            if rgb.redComponent > 0.65,
               rgb.redComponent > rgb.greenComponent * 1.4,
               rgb.redComponent > rgb.blueComponent * 1.4,
               rgb.alphaComponent > 0.2 {
                count += 1
            }
        }
    }

    private func changedPixelCount(
        _ lhs: NSBitmapImageRep,
        _ rhs: NSBitmapImageRep
    ) -> Int {
        zip(pixelColors(in: lhs), pixelColors(in: rhs)).reduce(into: 0) {
            count,
            colors in
            guard let left = colors.0.usingColorSpace(.deviceRGB),
                  let right = colors.1.usingColorSpace(.deviceRGB) else {
                return
            }
            let difference = abs(left.redComponent - right.redComponent)
                + abs(left.greenComponent - right.greenComponent)
                + abs(left.blueComponent - right.blueComponent)
                + abs(left.alphaComponent - right.alphaComponent)
            if difference > 0.15 {
                count += 1
            }
        }
    }

    private func pixelColors(in bitmap: NSBitmapImageRep) -> [NSColor] {
        (0..<bitmap.pixelsHigh).flatMap { y in
            (0..<bitmap.pixelsWide).compactMap { x in
                bitmap.colorAt(x: x, y: y)
            }
        }
    }
}
