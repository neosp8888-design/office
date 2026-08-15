// 이 파일은 사무실 화면의 좌우 분할 폭 제한을 검증한다.

import XCTest
@testable import OfficeGame

final class OfficeSplitLayoutTests: XCTestCase {
    func testColumnWidthsKeepLeftPanelAboveMinimumWidth() {
        let widths = OfficeSplitLayout.columnWidths(
            availableWidth: 1_000,
            fraction: 0.1,
            minimumColumnWidth: OfficeSplitLayout.minimumLeftColumnWidth
        )

        XCTAssertEqual(
            widths.left,
            OfficeSplitLayout.minimumLeftColumnWidth
        )
        XCTAssertEqual(widths.right, 700)
    }

    func testColumnWidthsPreserveSavedWidthAboveMinimum() {
        let widths = OfficeSplitLayout.columnWidths(
            availableWidth: 1_512,
            fraction: 0.2026977270534981,
            minimumColumnWidth: OfficeSplitLayout.minimumLeftColumnWidth
        )

        XCTAssertEqual(widths.left, 306.479, accuracy: 0.001)
        XCTAssertEqual(widths.right, 1_205.521, accuracy: 0.001)
    }

    func testColumnWidthsSplitNarrowSpaceEvenlyAtMinimum() {
        let widths = OfficeSplitLayout.columnWidths(
            availableWidth: 500,
            fraction: 0.9,
            minimumColumnWidth: OfficeSplitLayout.minimumLeftColumnWidth
        )

        XCTAssertEqual(widths.left, 250)
        XCTAssertEqual(widths.right, 250)
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
