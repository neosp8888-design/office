// 이 파일은 대화 동영상의 메타데이터 캐시와 원본 비율 표시를 검증한다.

import CoreGraphics
import Foundation
import XCTest
@testable import OfficeGame

@MainActor
final class ConversationMarkdownVideoLayoutTests: XCTestCase {
    func testVideoAspectRatioCacheReusesLoadedMetadata() {
        let cache = ConversationMarkdownVideoAspectRatioCache()
        let url = URL(fileURLWithPath: "/tmp/sample.mp4")

        XCTAssertNil(cache.aspectRatio(for: url))
        cache.store(16 / 9, for: url)

        XCTAssertEqual(cache.aspectRatio(for: url), 16 / 9)
    }

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
