// 이 파일은 CLI JSONL 진행 이벤트가 안전한 말풍선 문구로 변환되는지 검증한다.

import XCTest
@testable import OfficeCore

final class AgentProgressEventParserTests: XCTestCase {
    func testCodexReasoningSummaryIsDisplayed() {
        let line = #"""
        {"type":"item.completed","item":{"type":"reasoning","text":"파일 배치를 확인하고 수정 범위를 좁혔습니다."}}
        """#

        XCTAssertEqual(
            AgentProgressEventParser.message(
                fromJSONLine: line,
                backend: .codex
            ),
            "파일 배치를 확인하고 수정 범위를 좁혔습니다."
        )
    }

    func testCodexCommandArgumentsAreNotExposed() {
        let line = #"""
        {"type":"item.started","item":{"type":"command_execution","command":"deploy --token secret-value"}}
        """#

        let message = AgentProgressEventParser.message(
            fromJSONLine: line,
            backend: .codex
        )

        XCTAssertEqual(message, "터미널 출동 🧰")
        XCTAssertFalse(message?.contains("secret-value") == true)
    }

    func testClaudePublicTextTakesPriorityOverThinking() {
        let line = #"""
        {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"internal"},{"type":"text","text":"현재 파일 구조를 확인했습니다."}]}}
        """#

        XCTAssertEqual(
            AgentProgressEventParser.message(
                fromJSONLine: line,
                backend: .claude
            ),
            "현재 파일 구조를 확인했습니다."
        )
    }

    func testClaudeThinkingUsesGenericSafeStatus() {
        let line = #"""
        {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"internal details"}]}}
        """#

        let message = AgentProgressEventParser.message(
            fromJSONLine: line,
            backend: .claude
        )

        XCTAssertEqual(message, "각 잡고 분석 중 🧠")
        XCTAssertFalse(message?.contains("internal details") == true)
    }

    func testClaudeToolUseDoesNotExposeInput() {
        let line = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"secret-command"}}]}}
        """#

        let message = AgentProgressEventParser.message(
            fromJSONLine: line,
            backend: .claude
        )

        XCTAssertEqual(message, "도구로 뚝딱 처리 중 🛠️")
        XCTAssertFalse(message?.contains("secret-command") == true)
    }

    func testMalformedEventIsIgnored() {
        XCTAssertNil(
            AgentProgressEventParser.message(
                fromJSONLine: "not-json",
                backend: .codex
            )
        )
    }
}
