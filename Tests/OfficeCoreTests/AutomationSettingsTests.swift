// 이 파일은 자동 승인·병합 설정의 API JSON 형식을 검증한다.

import Foundation
import XCTest
@testable import OfficeGame

final class AutomationSettingsTests: XCTestCase {
    func testDecodesAutomationSettings() throws {
        let data = Data(#"{"autoApproveAndMerge":true}"#.utf8)

        let settings = try JSONDecoder().decode(
            AutomationSettings.self,
            from: data
        )

        XCTAssertTrue(settings.autoApproveAndMerge)
    }

    func testExplicitDisabledSettingRemainsDisabled() throws {
        let data = Data(#"{"autoApproveAndMerge":false}"#.utf8)

        let settings = try JSONDecoder().decode(
            AutomationSettings.self,
            from: data
        )

        XCTAssertFalse(settings.autoApproveAndMerge)
    }

    func testEncodesAutomationSettingsWithBackendKey() throws {
        let data = try JSONEncoder().encode(
            AutomationSettings(autoApproveAndMerge: true)
        )
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Bool]
        )

        XCTAssertEqual(object, ["autoApproveAndMerge": true])
    }
}
