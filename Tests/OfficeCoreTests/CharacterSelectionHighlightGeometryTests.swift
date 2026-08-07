// 이 파일은 직원 선택 하이라이트가 각 버튼 위치에 정확히 맞는지 검증한다.

import XCTest
@testable import OfficeGame

final class CharacterSelectionHighlightGeometryTests: XCTestCase {
    func testDividesAvailableWidthAcrossAllCharacters() throws {
        let frame = try XCTUnwrap(
            CharacterSelectionHighlightGeometry.frame(
                in: CGRect(x: 0, y: 0, width: 512, height: 38),
                selectedIndex: 2,
                itemCount: 5,
                spacing: 3
            )
        )

        XCTAssertEqual(frame.minX, 206, accuracy: 0.001)
        XCTAssertEqual(frame.width, 100, accuracy: 0.001)
        XCTAssertEqual(frame.height, 38, accuracy: 0.001)
    }

    func testRejectsSelectionOutsideCharacterRange() {
        XCTAssertNil(
            CharacterSelectionHighlightGeometry.frame(
                in: CGRect(x: 0, y: 0, width: 512, height: 38),
                selectedIndex: 5,
                itemCount: 5,
                spacing: 3
            )
        )
    }
}
