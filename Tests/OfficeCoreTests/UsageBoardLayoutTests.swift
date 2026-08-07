// 이 파일은 화이트보드의 반응형 제공자 열 배치를 검증한다.

import XCTest
@testable import OfficeGame

final class UsageBoardLayoutTests: XCTestCase {
    func testUsesSingleColumnBelowThreshold() {
        XCTAssertTrue(
            UsageBoardLayout.usesSingleColumn(
                for: UsageBoardLayout.singleColumnThreshold - 1
            )
        )
    }

    func testKeepsTwoColumnsAtThreshold() {
        XCTAssertFalse(
            UsageBoardLayout.usesSingleColumn(
                for: UsageBoardLayout.singleColumnThreshold
            )
        )
    }

    func testResetTimeUsesLocalRelativeDate() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Seoul"))
        let now = try XCTUnwrap(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: 7,
                hour: 22
            ))
        )
        let today = try XCTUnwrap(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: 7,
                hour: 23,
                minute: 30
            ))
        )
        let tomorrow = try XCTUnwrap(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: 8,
                hour: 4
            ))
        )
        let later = try XCTUnwrap(
            calendar.date(from: DateComponents(
                year: 2026,
                month: 8,
                day: 13,
                hour: 9
            ))
        )

        XCTAssertEqual(
            usageResetTimeText(today, relativeTo: now, calendar: calendar),
            "오늘 23:30"
        )
        XCTAssertEqual(
            usageResetTimeText(tomorrow, relativeTo: now, calendar: calendar),
            "내일 04:00"
        )
        XCTAssertEqual(
            usageResetTimeText(later, relativeTo: now, calendar: calendar),
            "8/13 09:00"
        )
    }

    func testUsageWindowDecodesResetTimestamp() throws {
        let data = Data(
            #"{"usedPercent":10,"windowMinutes":300,"resetsAt":"2026-08-07T19:00:00Z"}"#
                .utf8
        )

        let window = try JSONDecoder().decode(UsageWindow.self, from: data)

        XCTAssertEqual(window.usedPercent, 10)
        XCTAssertEqual(window.windowMinutes, 300)
        XCTAssertEqual(
            window.resetsAt,
            ISO8601DateFormatter().date(from: "2026-08-07T19:00:00Z")
        )
    }
}
