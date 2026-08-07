// 이 파일은 전신 프로필 이미지의 크기와 비율을 검증한다.

import XCTest
@testable import OfficeGame

final class CharacterFullBodyProfileLayoutTests: XCTestCase {
    func testImageWidthIsEightyPercentLargerThanBefore() {
        XCTAssertEqual(
            CharacterFullBodyProfileLayout.imageWidth,
            CharacterFullBodyProfileLayout.referenceContentWidth
                * CharacterFullBodyProfileLayout.previousImageWidthRatio
                * 1.8,
            accuracy: 0.000_1
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

    func testCloseButtonUsesCompactAnimatedMetrics() {
        XCTAssertEqual(
            CharacterFullBodyProfileCloseButtonMetrics.diameter,
            18
        )
        XCTAssertEqual(
            CharacterFullBodyProfileCloseButtonMetrics.iconSize,
            8
        )
        XCTAssertEqual(
            CharacterFullBodyProfileCloseButtonMetrics.hoverRotation,
            90
        )
        XCTAssertEqual(
            CharacterFullBodyProfileCloseButtonMetrics.hoverScale,
            1.08
        )
        XCTAssertEqual(
            CharacterFullBodyProfileCloseButtonMetrics.pressedScale,
            0.88
        )
    }

    func testProfilePresentationUsesSubtleSpringStartingPose() {
        XCTAssertEqual(
            CharacterFullBodyProfilePresentationMetrics.initialScale,
            0.82
        )
        XCTAssertEqual(
            CharacterFullBodyProfilePresentationMetrics.initialRotation,
            7
        )
        XCTAssertEqual(
            CharacterFullBodyProfilePresentationMetrics
                .initialVerticalOffset,
            18
        )
    }

    func testConversationAvatarHasHoverAndPressFeedback() {
        XCTAssertEqual(
            CharacterFullBodyProfilePresentationMetrics.avatarHoverScale,
            1.08
        )
        XCTAssertEqual(
            CharacterFullBodyProfilePresentationMetrics.avatarPressedScale,
            0.90
        )
    }
}
