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

    func testCodexRawReasoningContentTakesPriorityWhenAvailable() {
        let line = #"""
        {"type":"item.completed","item":{"type":"reasoning","text":"요약","content":[{"text":"원문 추론 내용"}]}}
        """#

        XCTAssertEqual(
            AgentProgressEventParser.message(
                fromJSONLine: line,
                backend: .codex
            ),
            "원문 추론 내용"
        )
    }

    func testCodexCommandHidesSensitiveArgumentsAndShowsProgram() {
        let line = #"""
        {"type":"item.started","item":{"type":"command_execution","command":"deploy --token secret-value"}}
        """#

        let message = AgentProgressEventParser.message(
            fromJSONLine: line,
            backend: .codex
        )

        XCTAssertEqual(message, "실행 · deploy [민감 인자 숨김]")
        XCTAssertFalse(message?.contains("secret-value") == true)
    }

    func testCodexCommandCompletionShowsExitCodeAndSafeCommand() {
        let line = #"""
        {"type":"item.completed","item":{"type":"command_execution","command":"swift test --filter ParserTests","exit_code":0}}
        """#

        XCTAssertEqual(
            AgentProgressEventParser.message(
                fromJSONLine: line,
                backend: .codex
            ),
            "완료(0) · swift test --filter ParserTests"
        )
    }

    func testCodexFileChangeShowsKindsAndPaths() {
        let line = #"""
        {"type":"item.completed","item":{"type":"file_change","changes":[{"kind":"update","path":"Sources/OfficeGame/Feed.swift"},{"kind":"add","path":"Tests/FeedTests.swift"}]}}
        """#

        XCTAssertEqual(
            AgentProgressEventParser.message(
                fromJSONLine: line,
                backend: .codex
            ),
            "파일 · 수정 Sources/OfficeGame/Feed.swift, 추가 Tests/FeedTests.swift"
        )
    }

    func testCodexMCPShowsServerAndTool() {
        let line = #"""
        {"type":"item.started","item":{"type":"mcp_tool_call","server":"computer-use","actionName":"inspect"}}
        """#

        XCTAssertEqual(
            AgentProgressEventParser.message(
                fromJSONLine: line,
                backend: .codex
            ),
            "도구 호출 · computer-use/inspect"
        )
    }

    func testCodexCollaborationShowsRequestAndResultButNotWaiting() {
        let request = #"""
        {"type":"item.completed","item":{"type":"collab_tool_call","tool":"spawn_agent","prompt":"스크롤 정책을 검토해 주세요.","receiver_thread_ids":["reviewer-1"],"status":"completed"}}
        """#
        let result = #"""
        {"type":"item.completed","item":{"type":"collab_tool_call","tool":"wait","agents_states":{"reviewer-1":{"status":"completed","message":"회귀 위험이 없습니다."}},"status":"completed"}}
        """#
        let waiting = #"""
        {"type":"item.started","item":{"type":"collab_tool_call","tool":"wait","status":"in_progress"}}
        """#

        XCTAssertEqual(
            AgentProgressEventParser.message(
                fromJSONLine: request,
                backend: .codex
            ),
            "협업 요청 · 스크롤 정책을 검토해 주세요."
        )
        XCTAssertEqual(
            AgentProgressEventParser.message(
                fromJSONLine: result,
                backend: .codex
            ),
            "협업 결과 · 회귀 위험이 없습니다."
        )
        XCTAssertNil(
            AgentProgressEventParser.message(
                fromJSONLine: waiting,
                backend: .codex
            )
        )
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

    func testClaudeThinkingDisplaysProviderThinkingText() {
        let line = #"""
        {"type":"assistant","message":{"content":[{"type":"thinking","thinking":"internal details"}]}}
        """#

        let message = AgentProgressEventParser.message(
            fromJSONLine: line,
            backend: .claude
        )

        XCTAssertEqual(message, "internal details")
    }

    func testClaudeToolUseShowsNameAndSafePath() {
        let line = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","input":{"file_path":"Sources/OfficeGame/Feed.swift"}}]}}
        """#

        let message = AgentProgressEventParser.message(
            fromJSONLine: line,
            backend: .claude
        )

        XCTAssertEqual(
            message,
            "도구 · Read · Sources/OfficeGame/Feed.swift"
        )
    }

    func testClaudeBashDoesNotExposeSensitiveInput() {
        let line = #"""
        {"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash","input":{"command":"curl --token secret-value example.com"}}]}}
        """#

        let message = AgentProgressEventParser.message(
            fromJSONLine: line,
            backend: .claude
        )

        XCTAssertEqual(
            message,
            "도구 · Bash · curl [민감 인자 숨김]"
        )
        XCTAssertFalse(message?.contains("secret-value") == true)
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
