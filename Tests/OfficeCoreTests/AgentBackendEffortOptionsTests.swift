// 이 파일은 공급자별 추론 옵션이 서로 섞이지 않는지 검증한다.

import XCTest
@testable import OfficeCore

final class AgentBackendEffortOptionsTests: XCTestCase {
    func testCodexIncludesUltraEffort() {
        XCTAssertEqual(
            AgentBackend.codex.effortOptions,
            ["low", "medium", "high", "xhigh", "max", "ultra"]
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

    func testSelectingDiscoveredModelUsesItsOwnEffortsAndFastCapability() {
        var settings = CharacterAgentSettings(
            backend: .codex,
            model: "gpt-5.6-sol",
            effort: "ultra",
            fastMode: true,
            permission: .workspaceWrite
        )
        let discovered = AgentModelOption(
            id: "gpt-future-mini",
            title: "GPT Future Mini",
            efforts: ["low", "medium"],
            defaultEffort: "medium",
            supportsFastMode: false
        )

        settings.selectModel(discovered)

        XCTAssertEqual(settings.model, "gpt-future-mini")
        XCTAssertEqual(settings.effort, "medium")
        XCTAssertFalse(settings.fastMode)
        settings.setFastMode(true, option: discovered)
        XCTAssertFalse(settings.fastMode)
    }

    func testAntigravityModelsUseNativeEffortLevelsWithoutFastMode() {
        XCTAssertEqual(
            AgentBackend.antigravity.modelOptions,
            [
                "gemini-3.8-flash",
                "gemini-3.1-pro",
            ]
        )
        XCTAssertEqual(
            AgentBackend.antigravity.effortOptions(
                for: "gemini-3.8-flash"
            ),
            ["low", "medium", "high"]
        )
        XCTAssertEqual(
            AgentBackend.antigravity.effortOptions(
                for: "gemini-3.1-pro"
            ),
            ["low", "high"]
        )
        XCTAssertFalse(
            AgentBackend.antigravity.supportsFastMode(
                model: "gemini-3.7-flash"
            )
        )
        XCTAssertEqual(AgentBackend.antigravity.executableName, "agy")
    }

    func testSelectingAntigravityProRepairsUnsupportedMediumEffort() {
        var settings = CharacterAgentSettings(
            backend: .antigravity,
            model: "gemini-3.7-flash",
            effort: "medium",
            fastMode: false,
            permission: .workspaceWrite
        )

        settings.selectModel("gemini-3.1-pro")

        XCTAssertEqual(settings.effort, "high")
        settings.setFastMode(true)
        XCTAssertFalse(settings.fastMode)
    }

    // 목록에서 내린 모델이 이미 직원 설정이나 지난 턴에 남아 있어도
    // 화면에 원본 식별자가 그대로 드러나거나 빈칸이 되면 안 된다.
    func testRetiredAntigravityModelsKeepReadableTitles() {
        for model in [
            "gemini-3.7-flash",
            "gemini-3.6-flash",
            "gemini-3.5-flash",
        ] {
            let title = AgentBackend.antigravity.modelTitle(model)
            XCTAssertNotEqual(title, model)
            XCTAssertFalse(title.isEmpty)
            XCTAssertFalse(
                AgentBackend.antigravity.modelOptions.contains(model)
            )
        }
        XCTAssertEqual(
            AgentBackend.antigravity.modelTitle("gemini-3.8-flash"),
            "Gemini 3.8 Flash"
        )
        XCTAssertEqual(
            AgentBackend.antigravity.defaultModel,
            "gemini-3.8-flash"
        )
    }
}
