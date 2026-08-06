// 이 파일은 전신 프로필 이미지의 크기와 비율을 검증한다.

import XCTest
@testable import OfficeGame

final class CharacterFullBodyProfileLayoutTests: XCTestCase {
    func testImageUsesHalfOfProfileContentWidth() {
        XCTAssertEqual(
            CharacterFullBodyProfileLayout.imageWidth,
            CharacterFullBodyProfileLayout.referenceContentWidth * 0.5
        )
    }

    func testSheetUsesOnlyProfileImageWidthAndPadding() {
        XCTAssertEqual(
            CharacterFullBodyProfileLayout.sheetWidth,
            CharacterFullBodyProfileLayout.imageWidth
                + (CharacterFullBodyProfileLayout.horizontalPadding * 2)
        )
    }

    func testImagePreservesTwoToOnePortraitRatio() {
        XCTAssertEqual(
            CharacterFullBodyProfileLayout.imageHeight
                / CharacterFullBodyProfileLayout.imageWidth,
            2,
            accuracy: 0.000_1
        )
    }

    func testProfileSelectionWrapsInBothDirections() {
        XCTAssertEqual(
            CharacterFullBodyProfileSelection.previousIndex(from: 0, count: 3),
            2
        )
        XCTAssertEqual(
            CharacterFullBodyProfileSelection.nextIndex(from: 2, count: 3),
            0
        )
    }

    func testProfileSelectionRespondsOnlyToHorizontalDragThreshold() {
        XCTAssertEqual(
            CharacterFullBodyProfileSelection.index(
                afterHorizontalDrag: -36,
                from: 0,
                count: 3
            ),
            1
        )
        XCTAssertEqual(
            CharacterFullBodyProfileSelection.index(
                afterHorizontalDrag: 36,
                from: 0,
                count: 3
            ),
            2
        )
        XCTAssertEqual(
            CharacterFullBodyProfileSelection.index(
                afterHorizontalDrag: 35,
                from: 0,
                count: 3
            ),
            0
        )
    }

    func testProfileAdvancesAfterExactlyTwoCompletedLoops() {
        XCTAssertFalse(
            CharacterFullBodyProfileSelection.shouldAutomaticallyAdvance(
                afterCompletedLoops: 1
            )
        )
        XCTAssertTrue(
            CharacterFullBodyProfileSelection.shouldAutomaticallyAdvance(
                afterCompletedLoops: 2
            )
        )
        XCTAssertEqual(
            CharacterFullBodyProfileSelection.crossfadeDuration,
            1.2
        )
    }
}
