// 이 파일은 사무실 상호작용 레이어가 실제 표시 상태 변화에만 반응하는지 검증한다.

import OfficeCore
import XCTest
@testable import OfficeGame

final class CharacterInteractionPresentationTests: XCTestCase {
    func testPresentationStateChangesForVisibleStatus() throws {
        let configuration = try CharacterConfigurationAsset.load()
        let state = makeState(configuration: configuration)

        XCTAssertNotEqual(
            state,
            makeState(
                configuration: configuration,
                runningCharacters: [.boss]
            )
        )
        XCTAssertNotEqual(
            state,
            makeState(
                configuration: configuration,
                questionCharacters: [.leftMan]
            )
        )
        XCTAssertNotEqual(
            state,
            makeState(
                configuration: configuration,
                failedCharacters: [.rightMan]
            )
        )
        XCTAssertNotEqual(
            state,
            makeState(
                configuration: configuration,
                offDutyCharacters: [.rightWoman]
            )
        )
    }

    func testPresentationStateRemainsEqualForIdenticalVisibleInputs() throws {
        let configuration = try CharacterConfigurationAsset.load()

        XCTAssertEqual(
            makeState(configuration: configuration),
            makeState(configuration: configuration)
        )
    }

    private func makeState(
        configuration: OfficeAgentConfiguration,
        runningCharacters: Set<OfficeCharacter> = [],
        questionCharacters: Set<OfficeCharacter> = [],
        failedCharacters: Set<OfficeCharacter> = [],
        offDutyCharacters: Set<OfficeCharacter> = []
    ) -> CharacterInteractionPresentationState {
        CharacterInteractionPresentationState(
            characters: configuration.characters,
            displayNames: Dictionary(uniqueKeysWithValues:
                configuration.characters.map { ($0.id, $0.name) }
            ),
            archiveCabinetHitbox: configuration.archiveCabinetHitbox,
            runningCharacters: runningCharacters,
            questionCharacters: questionCharacters,
            failedCharacters: failedCharacters,
            offDutyCharacters: offDutyCharacters
        )
    }
}
