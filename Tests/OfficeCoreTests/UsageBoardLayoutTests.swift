// 이 파일은 화이트보드의 반응형 제공자 열 배치를 검증한다.

import XCTest
@testable import OfficeGame

final class UsageBoardLayoutTests: XCTestCase {
    func testUsesSingleColumnBelowThreshold() {
        XCTAssertTrue(
            UsageBoardLayout.usesSingleColumn(
                for: UsageBoardLayout.singleColumnThreshold - 1
            )
        )
    }

    func testKeepsTwoColumnsAtThreshold() {
        XCTAssertFalse(
            UsageBoardLayout.usesSingleColumn(
                for: UsageBoardLayout.singleColumnThreshold
            )
        )
    }
}
