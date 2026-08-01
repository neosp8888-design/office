// 이 파일은 축소된 오피스에서 백부장 말풍선이 인물을 가리지 않는지 검증한다.

import OfficeCore
import XCTest
@testable import OfficeGame

final class OfficeBubbleLayoutTests: XCTestCase {
    func testBossBubbleLeadingEdgeTracksFaceAtNarrowScale() throws {
        let fittedFrame = CGRect(x: 0, y: 50, width: 210, height: 140)
        let scale = fittedFrame.width / OfficeCanvasGeometry.designSize.width
        let faceBounds = try XCTUnwrap(
            OfficeInteractionGeometry.faceBounds(
                for: .boss,
                artStyle: .twoD
            )
        )
        let position = bossBubblePosition(
            fittedFrame: fittedFrame,
            scale: scale
        )
        let bubbleLeadingEdge = position.x
            - OfficeBubbleLayout.bossMaximumWidth / 2
        let faceRightEdge = fittedFrame.minX + faceBounds.maxX * scale

        XCTAssertEqual(
            bubbleLeadingEdge,
            faceRightEdge + OfficeBubbleLayout.bossMinimumFaceGap,
            accuracy: 0.001
        )
    }

    func testBossBubbleLeadingEdgeScalesFaceGapAtWideScale() throws {
        let fittedFrame = CGRect(x: 0, y: 20, width: 720, height: 480)
        let scale = fittedFrame.width / OfficeCanvasGeometry.designSize.width
        let faceBounds = try XCTUnwrap(
            OfficeInteractionGeometry.faceBounds(
                for: .boss,
                artStyle: .twoD
            )
        )
        let position = bossBubblePosition(
            fittedFrame: fittedFrame,
            scale: scale
        )
        let bubbleLeadingEdge = position.x
            - OfficeBubbleLayout.bossMaximumWidth / 2
        let faceRightEdge = fittedFrame.minX + faceBounds.maxX * scale

        XCTAssertEqual(
            bubbleLeadingEdge,
            faceRightEdge
                + OfficeBubbleLayout.bossFaceGapAtDesignScale * scale,
            accuracy: 0.001
        )
    }

    private func bossBubblePosition(
        fittedFrame: CGRect,
        scale: CGFloat
    ) -> CGPoint {
        OfficeBubbleLayout.position(
            for: .boss,
            bubbleAnchor: OfficeInteractionGeometry.bubbleAnchor(
                for: .boss,
                artStyle: .twoD,
                fallback: .zero
            ),
            fittedFrame: fittedFrame,
            scale: scale,
            artStyle: .twoD,
            fallbackHitbox: .zero
        )
    }
}
