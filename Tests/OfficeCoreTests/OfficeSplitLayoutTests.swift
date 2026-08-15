// 이 파일은 사무실 화면의 좌우 분할 폭 제한을 검증한다.

import XCTest
@testable import OfficeGame

final class OfficeSplitLayoutTests: XCTestCase {
    func testColumnWidthsFixLeftPanelAtMinimumWidth() {
        let widths = OfficeSplitLayout.columnWidths(
            availableWidth: 1_000
        )

        XCTAssertEqual(
            widths.left,
            OfficeSplitLayout.fixedLeftColumnWidth
        )
        XCTAssertEqual(widths.right, 790)
    }

    func testColumnWidthsSplitSpaceEvenlyWhenNarrowerThanFixedWidth() {
        let widths = OfficeSplitLayout.columnWidths(
            availableWidth: 300
        )

        XCTAssertEqual(widths.left, 150)
        XCTAssertEqual(widths.right, 150)
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
