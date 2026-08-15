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

    func testLocalizedStringsReuseLoadedLanguageTables() {
        XCTAssertEqual(
            OfficeLocalization.string(
                "대화 보관함",
                languages: ["ko-KR"]
            ),
            "대화 보관함"
        )
        XCTAssertEqual(
            OfficeLocalization.string(
                "대화 보관함",
                languages: ["en-US"]
            ),
            "Conversation Archive"
        )
        XCTAssertEqual(
            OfficeLocalization.string(
                "직원 업무 기록",
                languages: ["en-US"]
            ),
            "Team work records"
        )
        XCTAssertEqual(
            OfficeLocalization.string(
                "현재 사용 가능량",
                languages: ["en-US"]
            ),
            "Current availability"
        )
        XCTAssertEqual(
            OfficeLocalization.string(
                "번역에 없는 동적 명령",
                languages: ["en-US"]
            ),
            "번역에 없는 동적 명령"
        )
    }

    func testDockerDataChoicesAreLocalizedInEnglish() {
        XCTAssertEqual(
            OfficeLocalization.string(
                "현재 OFFICESTRA 데이터 사용",
                languages: ["en-US"]
            ),
            "Use Current OFFICESTRA Data"
        )
        XCTAssertEqual(
            OfficeLocalization.string(
                "기존 OFFICESTRA 데이터 사용",
                languages: ["en-US"]
            ),
            "Use Existing OFFICESTRA Data"
        )
        XCTAssertEqual(
            OfficeLocalization.string(
                "현재 형식과 구형 형식의 OFFICESTRA 데이터가 모두 발견됐습니다. 사용할 데이터를 선택하세요. 어느 쪽도 삭제되지 않습니다.",
                languages: ["en-US"]
            ),
            "Both current-format and legacy-format OFFICESTRA data were found. Choose which data to use. Neither volume will be deleted."
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
