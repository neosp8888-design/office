import XCTest
@testable import OfficeCore
@testable import OfficeGame

@MainActor
final class AgentModelCatalogSelectionTests: XCTestCase {
    func testCatalogShowsNewModelsAndAppliesExclusionsOnlyToPicker() {
        let director = AgentDirector(startBackgroundTasks: false)
        director.applyModelCatalogSnapshot(
            AgentModelCatalogSnapshot(
                providers: [
                    AgentModelProviderCatalog(
                        backend: .codex,
                        models: [
                            AgentModelOption(
                                id: "gpt-future",
                                title: "GPT Future",
                                efforts: ["low", "medium", "high"],
                                defaultEffort: "medium",
                                supportsFastMode: true,
                                contextWindow: 300_000,
                                maxContextWindow: 1_000_000
                            ),
                            AgentModelOption(
                                id: "gpt-future-mini",
                                title: "GPT Future Mini",
                                efforts: ["low", "medium"],
                                defaultEffort: "medium",
                                supportsFastMode: false
                            ),
                        ],
                        excludedModels: ["gpt-future-mini"],
                        fetchedAt: Date(timeIntervalSince1970: 1_788_000_000),
                        lastAttemptedAt: Date(timeIntervalSince1970: 1_788_000_000),
                        lastError: nil
                    ),
                    AgentModelProviderCatalog(
                        backend: .antigravity,
                        models: [
                            AgentModelOption(
                                id: "gemini-future-pro",
                                title: "Gemini Future Pro",
                                efforts: ["low", "high"],
                                defaultEffort: "high",
                                supportsFastMode: false
                            ),
                        ],
                        excludedModels: [],
                        fetchedAt: nil,
                        lastAttemptedAt: nil,
                        lastError: nil
                    ),
                    // Claude Code initialize 응답의 선택값은 대괄호 접미사를 쓴다.
                    AgentModelProviderCatalog(
                        backend: .claude,
                        models: [
                            AgentModelOption(
                                id: "opus[1m]",
                                title: "Opus 5.1 (1M)",
                                efforts: ["low", "medium", "high", "xhigh", "max"],
                                defaultEffort: "high",
                                supportsFastMode: true,
                                resolvedModel: "claude-opus-5-1[1m]",
                                previousResolvedModel: "claude-opus-5[1m]",
                                resolvedModelChangedAt: Date(
                                    timeIntervalSince1970: 1_788_000_000
                                )
                            ),
                            AgentModelOption(
                                id: "sonnet",
                                title: "Sonnet",
                                efforts: ["low", "medium", "high", "xhigh", "max"],
                                defaultEffort: "high",
                                supportsFastMode: false
                            ),
                            AgentModelOption(
                                id: "claude-opus-5",
                                title: "Opus 5",
                                efforts: ["high", "xhigh", "max"],
                                defaultEffort: "high",
                                supportsFastMode: true,
                                available: false
                            ),
                        ],
                        excludedModels: ["sonnet"],
                        fetchedAt: Date(timeIntervalSince1970: 1_788_000_000),
                        lastAttemptedAt: Date(timeIntervalSince1970: 1_788_000_000),
                        lastError: nil
                    ),
                ]
            )
        )

        XCTAssertEqual(
            director.modelOptions(for: .claude).map(\.id),
            ["opus[1m]", "claude-opus-5"]
        )
        XCTAssertEqual(director.excludedModels(for: .claude), ["sonnet"])
        XCTAssertTrue(
            director.supportsFastMode(for: .claude, model: "opus[1m]")
        )
        XCTAssertEqual(
            director.effortOptions(for: .claude, model: "opus[1m]"),
            ["low", "medium", "high", "xhigh", "max"]
        )
        // 목록에서 내려간 기존 설정값도 이름과 옵션을 계속 찾을 수 있다.
        XCTAssertEqual(
            director.modelTitle(for: .claude, model: "claude-opus-5"),
            "Opus 5"
        )
        // 같은 별칭이 새 모델을 가리키게 된 직후 2주 동안만 선택기에 알린다.
        let revised = director.modelOption(for: .claude, model: "opus[1m]")!
        let changedAt = Date(timeIntervalSince1970: 1_788_000_000)
        XCTAssertEqual(
            revised.pickerTitle(now: changedAt.addingTimeInterval(24 * 60 * 60)),
            "Opus 5.1 (1M) · 새 버전"
        )
        XCTAssertEqual(
            revised.pickerTitle(now: changedAt.addingTimeInterval(15 * 24 * 60 * 60)),
            "Opus 5.1 (1M)"
        )
        XCTAssertFalse(
            director.modelOption(for: .claude, model: "sonnet")!.isRecentlyRevised()
        )

        XCTAssertEqual(
            director.modelOptions(for: .codex).map(\.id),
            ["gpt-future"]
        )
        XCTAssertEqual(
            director.allDiscoveredModelOptions(for: .codex).map(\.id),
            ["gpt-future", "gpt-future-mini"]
        )
        XCTAssertEqual(
            director.excludedModels(for: .codex),
            ["gpt-future-mini"]
        )
        XCTAssertEqual(
            director.effortOptions(
                for: .antigravity,
                model: "gemini-future-pro"
            ),
            ["low", "high"]
        )
        XCTAssertTrue(
            director.supportsFastMode(for: .codex, model: "gpt-future")
        )
        XCTAssertFalse(
            director.supportsFastMode(
                for: .codex,
                model: "gpt-future-mini"
            )
        )
        XCTAssertEqual(
            director.modelTitle(
                for: .antigravity,
                model: "gemini-future-pro"
            ),
            "Gemini Future Pro"
        )
    }
}
