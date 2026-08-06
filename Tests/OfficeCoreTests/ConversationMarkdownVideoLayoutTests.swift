// 이 파일은 대화 안 동영상이 원본 화면 비율로 표시되는지 검증한다.

import CoreGraphics
import XCTest
@testable import OfficeGame

final class ConversationMarkdownVideoLayoutTests: XCTestCase {
    func testInlinePlayerUsesBoundedWidth() {
        XCTAssertEqual(
            ConversationMarkdownVideoLayout.maximumWidth,
            294
        )
    }

    func testPortraitVideoUsesItsSourceAspectRatio() {
        XCTAssertEqual(
            ConversationMarkdownVideoLayout.aspectRatio(
                naturalSize: CGSize(width: 720, height: 1_280),
                preferredTransform: .identity
            ),
            9 / 16,
            accuracy: 0.000_1
        )
    }

    func testRotatedVideoUsesItsDisplayedAspectRatio() {
        XCTAssertEqual(
            ConversationMarkdownVideoLayout.aspectRatio(
                naturalSize: CGSize(width: 1_280, height: 720),
                preferredTransform: CGAffineTransform(
                    rotationAngle: .pi / 2
                )
            ),
            9 / 16,
            accuracy: 0.000_1
        )
    }

    func testInvalidVideoSizeUsesPortraitFallback() {
        XCTAssertEqual(
            ConversationMarkdownVideoLayout.aspectRatio(
                naturalSize: .zero,
                preferredTransform: .identity
            ),
            ConversationMarkdownVideoLayout.fallbackAspectRatio
        )
    }
}
