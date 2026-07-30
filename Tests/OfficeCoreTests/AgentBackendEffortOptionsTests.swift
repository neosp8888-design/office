// 이 파일은 공급자별 추론 옵션이 서로 섞이지 않는지 검증한다.

import XCTest
@testable import OfficeCore

final class AgentBackendEffortOptionsTests: XCTestCase {
    func testCodexIncludesUltraEffort() {
        XCTAssertEqual(
            AgentBackend.codex.effortOptions,
            ["high", "xhigh", "max", "ultra"]
        )
    }

    func testClaudeDoesNotIncludeUltraEffort() {
        XCTAssertEqual(
            AgentBackend.claude.effortOptions,
            ["high", "xhigh", "max"]
        )
    }
}
