// 이 파일은 시스템 언어에 따른 OfficeGame 표시 언어 선택을 검증한다.

import XCTest
@testable import OfficeGame

final class OfficeLocalizationTests: XCTestCase {
    func testKoreanSystemLanguageUsesKorean() {
        XCTAssertEqual(
            OfficeLocalization.languageIdentifier(for: ["ko-KR", "en-US"]),
            "ko"
        )
    }

    func testNonKoreanSystemLanguagesUseEnglish() {
        XCTAssertEqual(
            OfficeLocalization.languageIdentifier(for: ["en-US"]),
            "en"
        )
        XCTAssertEqual(
            OfficeLocalization.languageIdentifier(for: ["ja-JP", "en-US"]),
            "en"
        )
    }

    func testEnglishDefaultIdentityPromptReturnsToCanonicalKoreanValue() {
        XCTAssertEqual(
            OfficeLocalization.canonicalIdentityPrompt(
                "Understand work instructions precisely and report the execution plan and results concisely."
            ),
            "업무 지시를 정확히 이해하고 실행 계획과 결과를 간결하게 보고한다."
        )
    }
}
