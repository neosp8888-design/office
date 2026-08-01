// 이 파일은 축소된 오피스에서 백부장 말풍선이 인물을 가리지 않는지 검증한다.

import OfficeCore
import XCTest
@testable import OfficeGame

final class OfficeBubbleLayoutTests: XCTestCase {
    func testBossBubbleLeadingEdgeClearsBossAtNarrowScale() {
        let fittedFrame = CGRect(x: 0, y: 50, width: 210, height: 140)
        let scale = fittedFrame.width / OfficeCanvasGeometry.designSize.width
        let hitbox = OfficeInteractionGeometry.characterHitbox(
            for: .boss,
            artStyle: .twoD,
            fallback: .zero
        )
        let position = OfficeBubbleLayout.position(
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
        let bubbleLeadingEdge = position.x
            - OfficeBubbleLayout.bossMaximumWidth / 2
        let bossRightEdge = fittedFrame.minX + hitbox.maxX * scale

        XCTAssertGreaterThanOrEqual(
            bubbleLeadingEdge,
            bossRightEdge + OfficeBubbleLayout.bossLeadingGap
        )
    }
}
