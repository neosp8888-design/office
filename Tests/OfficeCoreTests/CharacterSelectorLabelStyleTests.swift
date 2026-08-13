// 이 파일은 직원 선택 이름의 테마별 대비 정책을 검증한다.

import SwiftUI
import XCTest
@testable import OfficeGame

final class CharacterSelectorLabelStyleTests: XCTestCase {
    func testSelectedEmployeeUsesDarkTextInDarkTheme() {
        XCTAssertTrue(
            CharacterSelectorLabelStyle.usesDarkSelectedText(
                isSelected: true,
                colorScheme: .dark
            )
        )
    }

    func testLightThemeAndUnselectedEmployeeKeepExistingDynamicText() {
        XCTAssertFalse(
            CharacterSelectorLabelStyle.usesDarkSelectedText(
                isSelected: true,
                colorScheme: .light
            )
        )
        XCTAssertFalse(
            CharacterSelectorLabelStyle.usesDarkSelectedText(
                isSelected: false,
                colorScheme: .dark
            )
        )
    }
}
