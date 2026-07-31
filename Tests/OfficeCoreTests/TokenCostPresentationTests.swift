// 이 파일은 완료 시간 아래의 토큰 환산 비용 문구 형식을 검증한다.

import XCTest
@testable import OfficeGame

final class TokenCostPresentationTests: XCTestCase {
    func testFormatsEstimatedTokenCostWithReadablePrecision() {
        XCTAssertEqual(
            estimatedTokenCostText(0.13599125),
            "토큰 환산 비용(추정) $0.135991"
        )
        XCTAssertEqual(
            estimatedTokenCostText(0.00001234),
            "토큰 환산 비용(추정) $0.00001234"
        )
    }
}
