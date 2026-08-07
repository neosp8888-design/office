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
}
