import XCTest
@testable import OfficeCore
@testable import OfficeGame

final class CharacterSettingsDraftsTests: XCTestCase {
    func testPersonalSettingsWindowUsesSingleEditorLayout() {
        XCTAssertEqual(CharacterIdentitySettingsLayout.width, 620)
        XCTAssertEqual(CharacterIdentitySettingsLayout.height, 500)
        XCTAssertEqual(
            CharacterIdentitySettingsLayout.identityPromptHeight,
            280
        )
    }

    func testBuildsPersonalDraftFromDatabaseProfile() {
        let draft = CharacterIdentitySettingsDraft(
            storedCharacter: StoredCharacterProfile(
                id: "boss",
                name: "백부장",
                backend: .codex,
                model: "gpt-5.6-sol",
                effort: "max",
                fastMode: false,
                permission: "danger-full-access",
                identityPrompt: "DB에 저장한 최신 업무 지침"
            )
        )

        XCTAssertEqual(draft.name, "백부장")
        XCTAssertEqual(draft.identityPrompt, "DB에 저장한 최신 업무 지침")
    }

    func testCommandBarOwnsPerCharacterSettingsWithoutNestedScroll() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let source = try String(
            contentsOf: sourceRoot
                .appending(path: "Sources/OfficeGame/OfficeGameApp.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            source.contains("identitySettingsCharacter = character.id")
        )
        XCTAssertTrue(
            source.contains("Label(\"설정\", systemImage: \"gearshape\")")
        )
        XCTAssertTrue(source.contains("CharacterIdentitySettingsView("))
        XCTAssertFalse(source.contains("showsCharacterSettings"))
        XCTAssertFalse(source.contains("private struct CharacterSettingsView"))

        let editorStart = try XCTUnwrap(
            source.range(of: "private struct CharacterIdentitySettingsView")
        )
        let editor = String(source[editorStart.lowerBound...])
        XCTAssertTrue(editor.contains("TextEditor(text: $identityPromptDraft)"))
        XCTAssertFalse(editor.contains("ScrollView"))
        XCTAssertFalse(editor.contains("@ObservedObject"))
    }
}
