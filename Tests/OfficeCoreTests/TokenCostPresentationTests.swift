// 이 파일은 완료 시간 아래의 토큰 환산 비용과 컨텍스트 잔량 문구 형식을 검증한다.

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

    func testFormatsSessionContextRemainingBelowCost() {
        XCTAssertEqual(
            sessionContextRemainingText(
                SessionContextUsage(
                    usedTokens: 268_544,
                    limitTokens: 1_000_000
                )
            ),
            "컨텍스트 잔량 731,456 / 1,000,000 (73.1%)"
        )
        XCTAssertEqual(
            sessionContextRemainingText(
                SessionContextUsage(
                    usedTokens: 57_218,
                    limitTokens: 258_400
                )
            ),
            "컨텍스트 잔량 201,182 / 258,400 (77.9%)"
        )
    }

    func testClampsSessionContextRemainingAtZero() {
        let usage = SessionContextUsage(
            usedTokens: 300_000,
            limitTokens: 258_400
        )

        XCTAssertEqual(usage.remainingTokens, 0)
        XCTAssertEqual(
            sessionContextRemainingText(usage),
            "컨텍스트 잔량 0 / 258,400 (0.0%)"
        )
    }
}
