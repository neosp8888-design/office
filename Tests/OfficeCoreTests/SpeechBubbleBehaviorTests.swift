// 이 파일은 말풍선 열람과 유휴 직원 자동 대화 정책을 검증한다.

import OfficeCore
import XCTest
@testable import OfficeGame

@MainActor
final class SpeechBubbleBehaviorTests: XCTestCase {
    func testViewedOrdinaryBubbleDisappearsImmediately() {
        let director = AgentDirector(startBackgroundTasks: false)
        director.speechBubbleStore.set("완료했습니다.", for: .rightWoman)

        director.dismissViewedBubble(for: .rightWoman)

        XCTAssertNil(director.bubbles[.rightWoman])
    }

    func testIdleEmployeeCanSpeakWhileAnotherEmployeeIsWorking() throws {
        let configuration = try CharacterConfigurationAsset.load()

        let candidates = SpeechBubbleIdleChatterPolicy.candidates(
            characters: configuration.characters,
            runningCharacters: [.rightWoman],
            occupiedCharacters: [.rightWoman],
            questionCharacters: [],
            failedCharacters: [],
            offDutyCharacters: [],
            lastCharacter: nil
        )

        XCTAssertEqual(
            Set(candidates.map(\.id)),
            Set(OfficeCharacter.allCases).subtracting([.rightWoman])
        )
    }

    func testIdleChatterSkipsBusyAndProtectedEmployees() throws {
        let configuration = try CharacterConfigurationAsset.load()

        let candidates = SpeechBubbleIdleChatterPolicy.candidates(
            characters: configuration.characters,
            runningCharacters: [.boss],
            occupiedCharacters: [.leftMan],
            questionCharacters: [.leftWoman],
            failedCharacters: [.rightMan],
            offDutyCharacters: [],
            lastCharacter: .rightWoman
        )

        XCTAssertEqual(candidates.map(\.id), [.rightWoman])
    }

    func testIdleChatterAvoidsPreviousEmployeeWhenOthersAreAvailable() throws {
        let configuration = try CharacterConfigurationAsset.load()

        let candidates = SpeechBubbleIdleChatterPolicy.candidates(
            characters: configuration.characters,
            runningCharacters: [.boss],
            occupiedCharacters: [],
            questionCharacters: [],
            failedCharacters: [],
            offDutyCharacters: [],
            lastCharacter: .leftMan
        )

        XCTAssertFalse(candidates.map(\.id).contains(.leftMan))
        XCTAssertFalse(candidates.isEmpty)
    }

    func testIdleChatterDoesNotImmediatelyRepeatItsMessage() {
        XCTAssertEqual(
            SpeechBubbleIdleChatterPolicy.messages(
                from: ["첫 문구", "둘째 문구", "셋째 문구"],
                excluding: "둘째 문구"
            ),
            ["첫 문구", "셋째 문구"]
        )
    }
}
