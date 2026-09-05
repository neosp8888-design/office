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

    func testNewUIStringsAreLocalizedInEnglish() {
        let testCases: [(korean: String, english: String)] = [
            ("사내 위키", "Company Wiki"),
            ("승인된 지식과 확인", "Approved knowledge and verification"),
            ("위키 검색", "Search wiki"),
            ("거절 사유 (선택)", "Rejection reason (optional)"),
            ("예약이 가득 찼습니다 · 최대 %d개", "Queue is full · max %d"),
            ("터미널 상태를 확인하지 못했습니다", "Could not check terminal status"),
            ("5시간", "5H"),
            ("7일", "7D"),
            ("주간", "Weekly"),
            ("오늘 비용", "Today"),
            ("30일 비용", "30D"),
            ("답변 필요", "Needs answer"),
            ("작성 중인 응답", "Response in progress"),
            ("최종 응답", "Final response"),
            ("코드 복사", "Copy code"),
            ("파일 편집에 실패했습니다", "Failed to edit files"),
            ("미리보기에서 열기", "Open in Preview"),
            ("파일 목록 복사", "Copy file list"),
            ("변경 파일 %d개", "%d changed files"),
            ("지금 작업을 중단하고 이 예약으로 다시 질문", "Stop current task and send this queued prompt"),
            ("🫡 콜! 준비 완료", "🫡 Ready when you are!"),
            ("오늘 할당량 끝, 퇴근 모드 🌙", "Quota reached for today, off duty 🌙"),
            ("앗, 작업 멈춤\n%@", "Oops, task stopped\n%@"),
            ("작업 정리 중... 🧹", "Cleaning up tasks... 🧹"),
            ("작업이 멈췄어요.", "Task has stopped."),
            ("이전 기록 보기", "Show previous record"),
            ("다음 기록 보기", "Show next record"),
            ("목록", "List"),
            ("기록 목록으로 돌아가기", "Back to record list"),
            ("펼쳐 보기", "Expand"),
            ("기록을 넓은 창으로 펼치기", "Open the record in a larger view"),
            ("펼쳐 보기 닫기", "Close the expanded view"),
            ("Antigravity 준비", "Set Up Antigravity"),
            ("Antigravity, Claude Code 또는 Codex가 확인할 파일을 선택하세요.", "Select files for Antigravity, Claude Code, or Codex to review."),
            ("응답 중인 터미널이 있습니다. 대화 모드로 돌아가면 해당 CLI 프로세스가 종료됩니다.", "A terminal is currently responding. Switching to conversation mode will terminate that CLI process."),
            ("일반 파일만 첨부할 수 있습니다: %@", "Only regular files can be attached: %@"),
            ("%@ · 새 버전", "%@ · New Version"),
            ("설치본 %@ → %@", "Installed %@ → %@")
        ]

        for testCase in testCases {
            XCTAssertEqual(
                OfficeLocalization.string(testCase.korean, languages: ["en-US"]),
                testCase.english,
                "Failed to localize '\(testCase.korean)'"
            )
        }
    }

    func testWhiteboardLabelsAreCompactInBothLanguages() {
        for lang in [["ko-KR"], ["en-US"]] {
            XCTAssertEqual(OfficeLocalization.string("5시간", languages: lang), "5H")
            XCTAssertEqual(OfficeLocalization.string("7일", languages: lang), "7D")
            XCTAssertEqual(OfficeLocalization.string("오늘 비용", languages: lang), "Today")
            XCTAssertEqual(OfficeLocalization.string("30일 비용", languages: lang), "30D")
        }
    }
}
