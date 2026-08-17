import XCTest
@testable import OfficeCore
@testable import OfficeGame

final class CharacterSettingsDraftsTests: XCTestCase {
    func testBuildsEveryVisibleDraftFromDatabaseProfiles() {
        let drafts = CharacterSettingsDrafts(
            storedCharacters: [
                StoredCharacterProfile(
                    id: "boss",
                    name: "백부장",
                    backend: .codex,
                    model: "gpt-5.6-sol",
                    effort: "max",
                    fastMode: false,
                    permission: "danger-full-access",
                    identityPrompt: "DB에 저장한 최신 업무 지침"
                ),
                StoredCharacterProfile(
                    id: "future-character",
                    name: "미지원 직원",
                    backend: .claude,
                    model: "claude-opus-5",
                    effort: "high",
                    fastMode: false,
                    permission: "auto",
                    identityPrompt: "표시하지 않음"
                ),
            ],
            automationSettings: AutomationSettings(
                autoApproveAndMerge: false
            )
        )

        XCTAssertEqual(drafts.names, [.boss: "백부장"])
        XCTAssertEqual(
            drafts.identityPrompts,
            [.boss: "DB에 저장한 최신 업무 지침"]
        )
        XCTAssertEqual(
            drafts.settings[.boss],
            CharacterAgentSettings(
                backend: .codex,
                model: "gpt-5.6-sol",
                effort: "max",
                fastMode: false,
                permission: .fullAccess
            )
        )
        XCTAssertFalse(drafts.autoApproveAndMerge)
    }
}
