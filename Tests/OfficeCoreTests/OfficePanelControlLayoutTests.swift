// 이 파일은 오피스 화면 조작 버튼의 고정 위치를 검증한다.

import SwiftUI
import XCTest
@testable import OfficeGame

final class OfficePanelControlLayoutTests: XCTestCase {
    func testThemeControlUsesTopLeadingCorner() {
        XCTAssertEqual(
            OfficePanelControlLayout.alignment(for: .theme),
            .topLeading
        )
    }

    func testArtStyleControlUsesBottomTrailingCorner() {
        XCTAssertEqual(
            OfficePanelControlLayout.alignment(for: .artStyle),
            .bottomTrailing
        )
    }

    func testArtStyleControlUsesSquareTouchAreaForCircularAppearance() {
        XCTAssertEqual(
            OfficePanelControlLayout.artStyleControlDiameter,
            42
        )
    }

    func testSettingsControlUsesTopTrailingCorner() {
        XCTAssertEqual(
            OfficePanelControlLayout.alignment(for: .settings),
            .topTrailing
        )
    }
}
