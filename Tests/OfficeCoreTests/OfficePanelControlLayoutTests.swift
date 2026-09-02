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

    func testBackendControlUsesBottomLeadingCorner() {
        XCTAssertEqual(
            OfficePanelControlLayout.alignment(for: .backend),
            .bottomLeading
        )
    }

    func testTerminalControlUsesTopTrailingCorner() {
        XCTAssertEqual(
            OfficePanelControlLayout.alignment(for: .terminal),
            .topTrailing
        )
    }

    func testBackendControlWarnsOnlyWhenStopped() {
        XCTAssertFalse(OfficeBackendStatus.running.showsStoppedWarning)
        XCTAssertFalse(OfficeBackendStatus.changing.showsStoppedWarning)
        XCTAssertTrue(OfficeBackendStatus.stopped.showsStoppedWarning)
    }

    func testArtStyleAndBackendControlsUseCompactCircularTouchArea() {
        XCTAssertEqual(
            OfficePanelControlLayout.artStyleControlDiameter,
            36
        )
    }
}
