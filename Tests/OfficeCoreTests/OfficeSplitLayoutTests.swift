// 이 파일은 사무실 화면의 좌우 분할 폭 제한을 검증한다.

import XCTest
@testable import OfficeGame

final class OfficeSplitLayoutTests: XCTestCase {
    func testColumnWidthsKeepBothPanelsAboveMinimumWidth() {
        let widths = OfficeSplitLayout.columnWidths(
            availableWidth: 1_000,
            fraction: 0.1,
            minimumColumnWidth: 210
        )

        XCTAssertEqual(widths.left, 210)
        XCTAssertEqual(widths.right, 790)
    }

    func testColumnWidthsSplitNarrowSpaceEvenlyAtMinimum() {
        let widths = OfficeSplitLayout.columnWidths(
            availableWidth: 600,
            fraction: 0.9,
            minimumColumnWidth: 420
        )

        XCTAssertEqual(widths.left, 300)
        XCTAssertEqual(widths.right, 300)
    }

    func testRowHeightsKeepBothPanelsAboveOneThird() {
        let rows = OfficeSplitLayout.rowHeights(
            availableHeight: 900,
            fraction: 0.1
        )

        XCTAssertEqual(rows.top, 300)
        XCTAssertEqual(rows.bottom, 600)
    }
}
