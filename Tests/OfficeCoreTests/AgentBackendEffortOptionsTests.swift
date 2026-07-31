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

    func testCodexModelsSupportFastMode() {
        XCTAssertTrue(
            AgentBackend.codex.modelOptions.allSatisfy {
                AgentBackend.codex.supportsFastMode(model: $0)
            }
        )
    }

    func testClaudeFastModeOnlySupportsOpusFive() {
        XCTAssertTrue(
            AgentBackend.claude.supportsFastMode(model: "claude-opus-5")
        )
        XCTAssertFalse(
            AgentBackend.claude.supportsFastMode(model: "fable")
        )
        XCTAssertFalse(
            AgentBackend.claude.supportsFastMode(model: "claude-sonnet-5")
        )
    }

    func testEnablingClaudeFastModeSelectsOpusFive() {
        var settings = CharacterAgentSettings(
            backend: .claude,
            model: "fable",
            effort: "high",
            fastMode: false,
            permission: .workspaceWrite
        )

        settings.setFastMode(true)

        XCTAssertTrue(settings.fastMode)
        XCTAssertEqual(settings.model, "claude-opus-5")
    }

    func testSelectingUnsupportedClaudeModelDisablesFastMode() {
        var settings = CharacterAgentSettings(
            backend: .claude,
            model: "claude-opus-5",
            effort: "high",
            fastMode: true,
            permission: .workspaceWrite
        )

        settings.selectModel("claude-sonnet-5")

        XCTAssertFalse(settings.fastMode)
        XCTAssertEqual(settings.model, "claude-sonnet-5")
    }
}
