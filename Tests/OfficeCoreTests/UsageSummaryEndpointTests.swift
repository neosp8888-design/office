// 이 파일은 사용량 화면이 로컬 백엔드 API만 호출하는 계약을 검증한다.

import XCTest
@testable import OfficeGame

final class UsageSummaryEndpointTests: XCTestCase {
    func testRegularRefreshUsesCachedBackendSummary() {
        let client = OfficeDatabaseClient(
            baseURL: URL(string: "http://127.0.0.1:4317")!
        )

        XCTAssertEqual(
            client.usageSummaryURL().absoluteString,
            "http://127.0.0.1:4317/api/usage-summary"
        )
    }

    func testManualRefreshRequestsFreshProviderLimits() {
        let client = OfficeDatabaseClient(
            baseURL: URL(string: "http://127.0.0.1:4317")!
        )

        XCTAssertEqual(
            client.usageSummaryURL(force: true).absoluteString,
            "http://127.0.0.1:4317/api/usage-summary?force=1"
        )
    }
}
