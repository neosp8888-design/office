// 이 파일은 2D·3D 화이트보드에 Codex와 Claude의 잔여 한도를 실시간 표시한다.

import Foundation
import OfficeCore
import SwiftUI

struct WhiteboardUsageLayer: View {
    let isActive: Bool
    let artStyle: OfficeArtStyle

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
            snapshot = try await CodexBarUsageReader.fetch(
                scope: .limits
            )
            refreshFailed = false
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

struct AIUsageSnapshot: Equatable, Sendable {
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
    let fetchedAt: Date
}

struct AIUsageActivitySnapshot: Equatable, Sendable {
    let todayCostUSD: Double?
    let recentTokens: Int64?
    let last30DaysCostUSD: Double?
    let last30DaysTokens: Int64?
}

enum AIUsageFetchScope: Hashable, Sendable {
    case limits
    case limitsAndActivity

    var costCommandArguments: [String]? {
        switch self {
        case .limits:
            nil
        case .limitsAndActivity:
            [
                "cost",
                "--provider",
                "both",
                "--days",
                "30",
                "--json-only",
            ]
        }
    }
}

enum CodexBarUsageReader {
    private static let executablePaths = [
        "/opt/homebrew/bin/codexbar",
        "/usr/local/bin/codexbar",
    ]
    private static let coordinator = UsageFetchCoordinator()

    static func fetch(
        force: Bool = false,
        scope: AIUsageFetchScope
    ) async throws -> AIUsageSnapshot {
        try await coordinator.fetch(force: force, scope: scope)
    }

    fileprivate static func fetchUncoordinated(
        scope: AIUsageFetchScope
    ) throws -> AIUsageSnapshot {
        let executable = try locateExecutable()
        let codexResult: Result<UsageProviderPayload, Error> = Result {
            try fetchProviderWithFallback(
                executable: executable,
                provider: "codex"
            )
        }
        let claudeResult: Result<UsageProviderPayload, Error> = Result {
            try fetchProviderWithFallback(
                executable: executable,
                provider: "claude"
            )
        }
        let codex = try? codexResult.get()
        let claude = try? claudeResult.get()

        guard codex?.usage != nil || claude?.usage != nil else {
            let messages = [codexResult, claudeResult]
                .compactMap { result -> String? in
                    guard case .failure(let error) = result else {
                        return nil
                    }
                    return error.localizedDescription
                }
                .filter { !$0.isEmpty }
            throw UsageReaderError.failed(
                messages.first
                    ?? UsageReaderError.providerUnavailable
                    .localizedDescription
            )
        }

        let costProviders = scope.costCommandArguments.flatMap {
            try? fetchCostProviders(
                executable: executable,
                arguments: $0
            )
        }
        let codexUsage = codex?.usage
        let claudeUsage = claude?.usage

        return AIUsageSnapshot(
            codexFiveHour: codexUsage?.remaining(windowMinutes: 300),
            codexFiveHourResetAt: codexUsage?.resetAt(windowMinutes: 300),
            codexWeekly: codexUsage?.remaining(windowMinutes: 10_080),
            codexWeeklyResetAt: codexUsage?.resetAt(windowMinutes: 10_080),
            claudeFiveHour: claudeUsage?.remaining(windowMinutes: 300),
            claudeFiveHourResetAt: claudeUsage?.resetAt(windowMinutes: 300),
            claudeWeekly: claudeUsage?.remaining(windowMinutes: 10_080),
            claudeWeeklyResetAt: claudeUsage?.resetAt(
                windowMinutes: 10_080
            ),
            codexPlan: codex?.plan,
            claudePlan: claude?.plan,
            codexActivity: costProviders?
                .first(where: { $0.provider == "codex" })?
                .activitySnapshot,
            claudeActivity: costProviders?
                .first(where: { $0.provider == "claude" })?
                .activitySnapshot,
            fetchedAt: Date()
        )
    }

    private static func fetchProviderWithFallback(
        executable: URL,
        provider: String
    ) throws -> UsageProviderPayload {
        do {
            return try fetchProvider(
                executable: executable,
                provider: provider,
                source: "oauth"
            )
        } catch {
            if error.localizedDescription.localizedCaseInsensitiveContains(
                "rate limit"
            ) {
                throw error
            }
            return try fetchProvider(
                executable: executable,
                provider: provider,
                source: "auto"
            )
        }
    }

    private static func fetchProvider(
        executable: URL,
        provider: String,
        source: String
    ) throws -> UsageProviderPayload {
        let data = try run(
            executable: executable,
            arguments: [
                "usage",
                "--provider",
                provider,
                "--source",
                source,
                "--json-only",
            ]
        )
        let providers = try JSONDecoder().decode(
            [UsageProviderPayload].self,
            from: data
        )
        guard
            let payload = providers.first(
                where: { $0.provider == provider }
            )
        else {
            throw UsageReaderError.providerUnavailable
        }
        guard payload.usage != nil else {
            throw UsageReaderError.failed(
                payload.error?.message
                    ?? UsageReaderError.providerUnavailable
                    .localizedDescription
            )
        }
        return payload
    }

    private static func fetchCostProviders(
        executable: URL,
        arguments: [String]
    ) throws -> [CostProviderPayload] {
        let data = try run(
            executable: executable,
            arguments: arguments
        )
        return try JSONDecoder().decode(
            [CostProviderPayload].self,
            from: data
        )
    }

    private static func locateExecutable() throws -> URL {
        for path in executablePaths
        where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        throw UsageReaderError.executableMissing
    }

    private static func run(
        executable: URL,
        arguments: [String]
    ) throws -> Data {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        try process.run()
        let deadline = Date().addingTimeInterval(30)
        while process.isRunning, Date() < deadline {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning {
            process.terminate()
            throw UsageReaderError.timedOut
        }

        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            if !output.isEmpty {
                return output
            }
            let message = String(decoding: error, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UsageReaderError.failed(message)
        }
        return output
    }
}

private actor UsageFetchCoordinator {
    private let cacheLifetime = TimeInterval(30)
    private var cachedSnapshots: [AIUsageFetchScope: AIUsageSnapshot] = [:]
    private var inFlightTasks: [
        AIUsageFetchScope: Task<AIUsageSnapshot, Error>
    ] = [:]

    func fetch(
        force: Bool,
        scope: AIUsageFetchScope
    ) async throws -> AIUsageSnapshot {
        if
            !force,
            let cachedSnapshot = cachedSnapshots[scope],
            Date().timeIntervalSince(cachedSnapshot.fetchedAt)
                < cacheLifetime
        {
            return cachedSnapshot
        }
        if let inFlight = inFlightTasks[scope] {
            return try await inFlight.value
        }
        if
            scope == .limits,
            let detailedInFlight = inFlightTasks[.limitsAndActivity]
        {
            return try await detailedInFlight.value
        }

        let task = Task.detached(priority: .utility) {
            try CodexBarUsageReader.fetchUncoordinated(scope: scope)
        }
        inFlightTasks[scope] = task

        do {
            let snapshot = try await task.value
            cachedSnapshots[scope] = snapshot
            if scope == .limitsAndActivity {
                cachedSnapshots[.limits] = snapshot
            }
            inFlightTasks[scope] = nil
            return snapshot
        } catch {
            inFlightTasks[scope] = nil
            if let cachedSnapshot = cachedSnapshots[scope] {
                return cachedSnapshot
            }
            throw error
        }
    }
}

private struct UsageProviderPayload: Decodable {
    let provider: String
    let usage: UsagePayload?
    let openaiDashboard: UsageDashboardPayload?
    let error: UsageProviderErrorPayload?

    var plan: String? {
        openaiDashboard?.accountPlan
            ?? usage?.loginMethod
            ?? usage?.identity?.loginMethod
    }
}

private struct UsageProviderErrorPayload: Decodable {
    let message: String?
}

private struct UsageDashboardPayload: Decodable {
    let accountPlan: String?
}

private struct UsagePayload: Decodable {
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let tertiary: UsageWindow?
    let loginMethod: String?
    let identity: UsageIdentityPayload?

    func remaining(windowMinutes: Int) -> Int? {
        let window = window(minutes: windowMinutes)
        guard let usedPercent = window?.usedPercent else {
            return nil
        }
        return Int(
            min(100, max(0, 100 - usedPercent)).rounded()
        )
    }

    func resetAt(windowMinutes: Int) -> Date? {
        window(minutes: windowMinutes)?.resetsAt
    }

    private func window(minutes: Int) -> UsageWindow? {
        [primary, secondary, tertiary]
            .compactMap { $0 }
            .first { $0.windowMinutes == minutes }
    }
}

private struct UsageIdentityPayload: Decodable {
    let loginMethod: String?
}

struct UsageWindow: Decodable {
    let usedPercent: Double
    let windowMinutes: Int
    let resetsAt: Date?

    private enum CodingKeys: String, CodingKey {
        case usedPercent
        case windowMinutes
        case resetsAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        usedPercent = try container.decode(Double.self, forKey: .usedPercent)
        windowMinutes = try container.decode(Int.self, forKey: .windowMinutes)
        if
            let value = try container.decodeIfPresent(
                String.self,
                forKey: .resetsAt
            )
        {
            resetsAt = ISO8601DateFormatter().date(from: value)
        } else {
            resetsAt = nil
        }
    }
}

private struct CostProviderPayload: Decodable {
    let provider: String
    let sessionCostUSD: Double?
    let sessionTokens: Int64?
    let last30DaysCostUSD: Double?
    let last30DaysTokens: Int64?

    var activitySnapshot: AIUsageActivitySnapshot {
        AIUsageActivitySnapshot(
            todayCostUSD: sessionCostUSD,
            recentTokens: sessionTokens,
            last30DaysCostUSD: last30DaysCostUSD,
            last30DaysTokens: last30DaysTokens
        )
    }
}

private enum UsageReaderError: LocalizedError {
    case executableMissing
    case providerUnavailable
    case timedOut
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing:
            "CodexBar 실행 파일을 찾을 수 없습니다."
        case .providerUnavailable:
            "Codex 또는 Claude 한도를 불러올 수 없습니다."
        case .timedOut:
            "CodexBar 한도 조회 시간이 초과됐습니다."
        case .failed(let message):
            message.isEmpty ? "CodexBar 한도 조회가 실패했습니다." : message
        }
    }
}
