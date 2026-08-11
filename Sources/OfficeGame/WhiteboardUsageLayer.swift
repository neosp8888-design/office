// 이 파일은 2D·3D 화이트보드에 Codex와 Claude의 잔여 한도를 실시간 표시한다.

import Foundation
import OfficeCore
import SwiftUI

struct WhiteboardUsageLayer: View {
    let isActive: Bool
    let artStyle: OfficeArtStyle
    let databaseBaseURL: URL

    private var textVerticalScale: CGFloat {
        artStyle == .twoD ? 1 : 1.3
    }

    @State private var snapshot: AIUsageSnapshot?
    @State private var isLoading = true
    @State private var refreshFailed = false

    var body: some View {
        GeometryReader { geometry in
            Canvas { context, _ in
                drawBoard(
                    context: &context,
                    containerSize: geometry.size
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("AI 잔여 한도")
        .accessibilityValue(accessibilityValue)
        .task(id: isActive) {
            guard isActive else {
                return
            }

            while !Task.isCancelled {
                await refresh()
                do {
                    try await Task.sleep(for: .seconds(300))
                } catch {
                    return
                }
            }
        }
    }

    private var accessibilityValue: String {
        guard let snapshot else {
            return isLoading ? "조회 중" : "조회할 수 없음"
        }

        return [
            accessibilityLimitText(
                provider: "Codex",
                window: "5시간",
                remaining: snapshot.codexFiveHour,
                resetAt: snapshot.codexFiveHourResetAt
            ),
            accessibilityLimitText(
                provider: "Codex",
                window: "주간",
                remaining: snapshot.codexWeekly,
                resetAt: snapshot.codexWeeklyResetAt
            ),
            accessibilityLimitText(
                provider: "Claude",
                window: "5시간",
                remaining: snapshot.claudeFiveHour,
                resetAt: snapshot.claudeFiveHourResetAt
            ),
            accessibilityLimitText(
                provider: "Claude",
                window: "주간",
                remaining: snapshot.claudeWeekly,
                resetAt: snapshot.claudeWeeklyResetAt
            ),
        ]
        .joined(separator: ", ")
    }

    @MainActor
    private func refresh() async {
        isLoading = snapshot == nil
        do {
            let refreshed = try await OfficeDatabaseClient(
                baseURL: databaseBaseURL
            ).fetchUsageSummary()
            snapshot = refreshed
            refreshFailed = refreshed.codexLimitError != nil
                || refreshed.claudeLimitError != nil
        } catch {
            refreshFailed = true
        }
        isLoading = false
    }

    private func drawBoard(
        context: inout GraphicsContext,
        containerSize: CGSize
    ) {
        let fittedFrame = OfficeCanvasGeometry.fittedFrame(
            in: containerSize
        )
        guard fittedFrame.width > 0 else {
            return
        }

        let scale =
            fittedFrame.width / OfficeCanvasGeometry.designSize.width
        let transform = CGAffineTransform(
            a: scale,
            b: 0,
            c: 0,
            d: scale,
            tx: fittedFrame.minX,
            ty: fittedFrame.minY
        )
        context.concatenate(transform)

        let ink = Color(
            red: 0.08,
            green: 0.18,
            blue: 0.22
        )
        let mutedInk = ink.opacity(0.84)

        if let snapshot {
            drawUsageGroup(
                provider: "CODEX",
                fiveHour: snapshot.codexFiveHour,
                fiveHourResetAt: snapshot.codexFiveHourResetAt,
                weekly: snapshot.codexWeekly,
                weeklyResetAt: snapshot.codexWeeklyResetAt,
                providerY: 0,
                context: &context,
                ink: ink,
                mutedInk: mutedInk
            )
            drawUsageGroup(
                provider: "CLAUDE",
                fiveHour: snapshot.claudeFiveHour,
                fiveHourResetAt: snapshot.claudeFiveHourResetAt,
                weekly: snapshot.claudeWeekly,
                weeklyResetAt: snapshot.claudeWeeklyResetAt,
                providerY: 40,
                context: &context,
                ink: ink,
                mutedInk: mutedInk
            )
        } else {
            drawText(
                "AI LIMIT",
                in: &context,
                at: CGPoint(x: 0, y: 11),
                size: 12.5,
                weight: .bold,
                color: ink
            )
            drawText(
                isLoading ? "CHECKING…" : "LIMIT OFF",
                in: &context,
                at: CGPoint(x: 0, y: 44),
                size: 13,
                weight: .bold,
                color: mutedInk
            )
        }

        if refreshFailed {
            drawText(
                "!",
                in: &context,
                at: CGPoint(x: 128, y: 1),
                anchor: .topTrailing,
                size: 7,
                weight: .bold,
                color: Color(red: 0.77, green: 0.38, blue: 0.08)
            )
        }
    }

    private func drawUsageGroup(
        provider: String,
        fiveHour: Int?,
        fiveHourResetAt: Date?,
        weekly: Int?,
        weeklyResetAt: Date?,
        providerY: CGFloat,
        context: inout GraphicsContext,
        ink: Color,
        mutedInk: Color
    ) {
        drawText(
            provider,
            in: &context,
            at: CGPoint(x: 0, y: providerY),
            size: 11,
            weight: .bold,
            color: ink
        )
        drawText(
            compactLimitText(
                label: "5H",
                remaining: fiveHour,
                resetAt: fiveHourResetAt
            ),
            in: &context,
            at: CGPoint(x: 0, y: providerY + 14),
            size: 9,
            weight: .semibold,
            color: mutedInk
        )
        drawText(
            compactLimitText(
                label: "7D",
                remaining: weekly,
                resetAt: weeklyResetAt
            ),
            in: &context,
            at: CGPoint(x: 0, y: providerY + 26),
            size: 9,
            weight: .semibold,
            color: mutedInk
        )
    }

    private func drawText(
        _ text: String,
        in context: inout GraphicsContext,
        at point: CGPoint,
        anchor: UnitPoint = .topLeading,
        size: CGFloat,
        weight: Font.Weight,
        color: Color
    ) {
        var textContext = context
        textContext.concatenate(
            OfficeWhiteboardGeometry.usageTransform(
                for: artStyle,
                at: point
            )
        )
        textContext.concatenate(
            CGAffineTransform(
                a: 1,
                b: 0,
                c: 0,
                d: textVerticalScale,
                tx: 0,
                ty: 0
            )
        )
        textContext.draw(
            Text(text)
                .font(
                    .system(
                        size: size,
                        weight: weight,
                        design: .rounded
                    )
                )
                .fontWidth(.condensed)
                .foregroundStyle(color),
            at: .zero,
            anchor: anchor
        )
    }

    private func compactPercentText(_ value: Int?) -> String {
        value.map { "\($0)%" } ?? "–"
    }

    private func percentText(_ value: Int?) -> String {
        value.map { "\($0)퍼센트" } ?? "정보 없음"
    }

    private func compactLimitText(
        label: String,
        remaining: Int?,
        resetAt: Date?
    ) -> String {
        let limit = "\(label) \(compactPercentText(remaining))"
        guard let reset = usageResetTimeText(resetAt) else {
            return limit
        }
        return "\(limit) · \(reset)"
    }

    private func accessibilityLimitText(
        provider: String,
        window: String,
        remaining: Int?,
        resetAt: Date?
    ) -> String {
        let limit = "\(provider) \(window) \(percentText(remaining))"
        guard let reset = usageResetTimeText(resetAt) else {
            return limit
        }
        return "\(limit), 초기화 \(reset)"
    }
}

func usageResetTimeText(
    _ resetAt: Date?,
    relativeTo now: Date = Date(),
    calendar sourceCalendar: Calendar = .autoupdatingCurrent
) -> String? {
    guard let resetAt else {
        return nil
    }

    let calendar = sourceCalendar
    let time = calendar.dateComponents([.hour, .minute], from: resetAt)
    guard let hour = time.hour, let minute = time.minute else {
        return nil
    }
    let clock = String(format: "%02d:%02d", hour, minute)

    if calendar.isDate(resetAt, inSameDayAs: now) {
        return "오늘 \(clock)"
    }
    let tomorrow = calendar.date(
        byAdding: .day,
        value: 1,
        to: calendar.startOfDay(for: now)
    )
    if
        let tomorrow,
        calendar.isDate(resetAt, inSameDayAs: tomorrow)
    {
        return "내일 \(clock)"
    }

    let date = calendar.dateComponents([.month, .day], from: resetAt)
    guard let month = date.month, let day = date.day else {
        return clock
    }
    return "\(month)/\(day) \(clock)"
}

struct AIUsageSnapshot: Decodable, Equatable, Sendable {
    let codexFiveHour: Int?
    let codexFiveHourResetAt: Date?
    let codexWeekly: Int?
    let codexWeeklyResetAt: Date?
    let claudeFiveHour: Int?
    let claudeFiveHourResetAt: Date?
    let claudeWeekly: Int?
    let claudeWeeklyResetAt: Date?
    let codexPlan: String?
    let claudePlan: String?
    let codexActivity: AIUsageActivitySnapshot?
    let claudeActivity: AIUsageActivitySnapshot?
    let codexLimitError: String?
    let claudeLimitError: String?
    let fetchedAt: Date
}

struct AIUsageActivitySnapshot: Decodable, Equatable, Sendable {
    let todayCostUSD: Double?
    let recentTokens: Int64?
    let last30DaysCostUSD: Double?
    let last30DaysTokens: Int64?
}
