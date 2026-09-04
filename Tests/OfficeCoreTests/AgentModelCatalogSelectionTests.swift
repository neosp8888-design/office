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
                ]
            )
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
