// 보관함 시트에서 이전·다음 기록으로 넘길 수 있는지 판정을 검증한다.

import XCTest

@testable import OfficeGame

final class ArchiveBookPagingTests: XCTestCase {
    // 첫 기록에서는 이전이 없고, 그 뒤부터는 있다.
    func testPreviousNeedsAnEarlierIndex() {
        XCTAssertFalse(ArchiveBookPaging.canGoPrevious(index: 0))
        XCTAssertTrue(ArchiveBookPaging.canGoPrevious(index: 1))
    }

    // 불러온 목록 안에 다음 칸이 있으면 넘길 수 있다.
    func testNextInsideLoadedList() {
        XCTAssertTrue(
            ArchiveBookPaging.canGoNext(
                index: 0,
                loadedCount: 12,
                totalCount: 12
            )
        )
        XCTAssertFalse(
            ArchiveBookPaging.canGoNext(
                index: 11,
                loadedCount: 12,
                totalCount: 12
            )
        )
    }

    // 검색 결과가 12건보다 많으면 마지막 칸에서도 더 받아 와서 넘길 수 있다.
    func testNextAtEndLoadsMoreOnlyWhenTotalIsLarger() {
        XCTAssertTrue(
            ArchiveBookPaging.canGoNext(
                index: 11,
                loadedCount: 12,
                totalCount: 30
            )
        )
        XCTAssertFalse(
            ArchiveBookPaging.canGoNext(
                index: 2,
                loadedCount: 3,
                totalCount: 3
            )
        )
    }
}
