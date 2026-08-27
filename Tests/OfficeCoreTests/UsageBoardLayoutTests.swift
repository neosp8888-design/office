// 이 파일은 화이트보드의 반응형 제공자 열 배치를 검증한다.

import XCTest
@testable import OfficeGame

final class UsageBoardLayoutTests: XCTestCase {
    func testUsageCardPresentsOnlyEstimatedAPICost() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/OfficeGame", directoryHint: .isDirectory)
        let source = try String(
            contentsOf: sourceRoot.appending(path: "OfficeDashboardPanels.swift"),
            encoding: .utf8
        )
        let start = try XCTUnwrap(
            source.range(of: "private struct UsageActivityCard")?.lowerBound
        )
        let end = try XCTUnwrap(
            source.range(
                of: "private struct UsageMetricCell",
                range: start..<source.endIndex
            )?.lowerBound
        )
        let card = String(source[start..<end])

        XCTAssertTrue(card.contains("\"API 요금 추정\""))
        XCTAssertTrue(card.contains("label: \"오늘 비용\""))
        XCTAssertTrue(card.contains("label: \"30일 비용\""))
        XCTAssertFalse(card.contains("label: \"오늘 토큰\""))
        XCTAssertFalse(card.contains("label: \"30일 토큰\""))
    }

    func testUsesSingleColumnBelowThreshold() {
        XCTAssertTrue(
            UsageBoardLayout.usesSingleColumn(
                for: UsageBoardLayout.singleColumnThreshold - 1
            )
        )
    }

    func testAntigravityTranscriptUsesWhiteboardBlueAccent() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "Sources/OfficeGame", directoryHint: .isDirectory)
        let dashboard = try String(
            contentsOf: sourceRoot.appending(path: "OfficeDashboardPanels.swift"),
            encoding: .utf8
        )
        let transcript = try String(
            contentsOf: sourceRoot.appending(path: "ClaudeTranscriptView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(
            dashboard.contains(
                "tint: DashboardPalette.providerAccent(for: .antigravity)"
            )
        )
        XCTAssertTrue(
            dashboard.contains("backend: effectiveBackend")
        )
        XCTAssertTrue(
            dashboard.contains(
                "antigravityAccent = Color(red: 0.19, green: 0.49, blue: 0.88)"
            )
        )
        XCTAssertTrue(
            transcript.contains(
                "DashboardPalette.providerAccent(for: backend)"
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

    func testUsageSummaryDecodesProviderResetTimestamp() throws {
        let data = Data(
            #"{"codexFiveHour":90,"codexFiveHourResetAt":"2026-08-07T19:00:00.000Z","codexWeekly":null,"codexWeeklyResetAt":null,"claudeFiveHour":null,"claudeFiveHourResetAt":null,"claudeWeekly":null,"claudeWeeklyResetAt":null,"codexPlan":"Pro","claudePlan":null,"codexActivity":null,"claudeActivity":null,"codexLimitError":null,"claudeLimitError":null,"fetchedAt":"2026-08-07T18:00:00.000Z"}"#
                .utf8
        )
        let client = OfficeDatabaseClient(
            baseURL: URL(string: "http://127.0.0.1:4317")!
        )

        let snapshot = try client.decodeUsageSummary(data)

        XCTAssertEqual(snapshot.codexFiveHour, 90)
        XCTAssertEqual(snapshot.codexPlan, "Pro")
        XCTAssertEqual(
            snapshot.codexFiveHourResetAt,
            ISO8601DateFormatter().date(from: "2026-08-07T19:00:00Z")
        )
    }
}
