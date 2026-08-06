// 이 파일은 CodexBar 사용량 조회 범위별 외부 명령 구성을 검증한다.

import XCTest
@testable import OfficeGame

final class CodexBarUsageFetchScopeTests: XCTestCase {
    func testLimitsScopeSkipsCostHistoryCommand() {
        XCTAssertNil(AIUsageFetchScope.limits.costCommandArguments)
    }

    func testDetailedScopeKeepsThirtyDayCostHistoryCommand() {
        XCTAssertEqual(
            AIUsageFetchScope.limitsAndActivity.costCommandArguments,
            [
                "cost",
                "--provider",
                "both",
                "--days",
                "30",
                "--json-only",
            ]
        )
    }
}
