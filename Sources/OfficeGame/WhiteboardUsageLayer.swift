// 이 파일은 화이트보드 원근에 맞춰 Codex와 Claude의 잔여 한도를 실시간 표시한다.

import Foundation
import OfficeCore
import SwiftUI

struct WhiteboardUsageLayer: View {
    let isActive: Bool

    private let textVerticalScale: CGFloat = 1.3

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
            "Codex 5시간 \(percentText(snapshot.codexFiveHour))",
            "Codex 주간 \(percentText(snapshot.codexWeekly))",
            "Claude 5시간 \(percentText(snapshot.claudeFiveHour))",
            "Claude 주간 \(percentText(snapshot.claudeWeekly))",
        ]
        .joined(separator: ", ")
    }

    @MainActor
    private func refresh() async {
        isLoading = snapshot == nil
        do {
            snapshot = try await CodexBarUsageReader.fetch()
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
        let origin = OfficeWhiteboardGeometry.usageOrigin
        let transform = CGAffineTransform(
            a: scale,
            b: OfficeWhiteboardGeometry.horizontalShear * scale,
            c: 0,
            d: scale,
            tx: fittedFrame.minX + origin.x * scale,
            ty: fittedFrame.minY + origin.y * scale
        )
        context.concatenate(transform)

        let ink = Color(
            red: 0.12,
            green: 0.23,
            blue: 0.29
        )
        let mutedInk = ink.opacity(0.55)

        drawText(
            "AI LIMIT · LEFT",
            in: &context,
            at: CGPoint(x: 0, y: 0),
            size: 7.4,
            weight: .bold,
            color: ink
        )
        drawText(
            "5H",
            in: &context,
            at: CGPoint(x: 77, y: 11),
            anchor: .topTrailing,
            size: 6.2,
            weight: .semibold,
            color: mutedInk
        )
        drawText(
            "7D",
            in: &context,
            at: CGPoint(x: 108, y: 11),
            anchor: .topTrailing,
            size: 6.2,
            weight: .semibold,
            color: mutedInk
        )

        let divider = Path(
            CGRect(x: 0, y: 19, width: 108, height: 0.65)
        )
        context.fill(divider, with: .color(ink.opacity(0.20)))

        if let snapshot {
            drawUsageRow(
                provider: "CODEX",
                fiveHour: snapshot.codexFiveHour,
                weekly: snapshot.codexWeekly,
                y: 23,
                context: &context,
                ink: ink
            )
            drawUsageRow(
                provider: "CLAUDE",
                fiveHour: snapshot.claudeFiveHour,
                weekly: snapshot.claudeWeekly,
                y: 42,
                context: &context,
                ink: ink
            )

            drawText(
                snapshot.fetchedAt.formatted(
                    date: .omitted,
                    time: .shortened
                ),
                in: &context,
                at: CGPoint(x: 108, y: 60),
                anchor: .topTrailing,
                size: 5.5,
                weight: .medium,
                color: mutedInk
            )
        } else {
            drawText(
                isLoading ? "CHECKING…" : "LIMIT OFF",
                in: &context,
                at: CGPoint(x: 0, y: 30),
                size: 9,
                weight: .semibold,
                color: mutedInk
            )
        }

        if refreshFailed {
            drawText(
                "!",
                in: &context,
                at: CGPoint(x: 0, y: 59),
                size: 7,
                weight: .bold,
                color: Color(red: 0.77, green: 0.38, blue: 0.08)
            )
        }
    }

    private func drawUsageRow(
        provider: String,
        fiveHour: Int?,
        weekly: Int?,
        y: CGFloat,
        context: inout GraphicsContext,
        ink: Color
    ) {
        drawText(
            provider,
            in: &context,
            at: CGPoint(x: 0, y: y + 1),
            size: 8,
            weight: .bold,
            color: ink
        )
        drawValue(
            fiveHour,
            in: &context,
            x: 78,
            y: y
        )
        drawValue(
            weekly,
            in: &context,
            x: 108,
            y: y
        )
    }

    private func drawValue(
        _ value: Int?,
        in context: inout GraphicsContext,
        x: CGFloat,
        y: CGFloat
    ) {
        drawText(
            value.map { "\($0)%" } ?? "–",
            in: &context,
            at: CGPoint(x: x, y: y),
            anchor: .topTrailing,
            size: 10.5,
            weight: .bold,
            color: remainingColor(value)
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
            CGAffineTransform(
                a: 1,
                b: 0,
                c: 0,
                d: textVerticalScale,
                tx: point.x,
                ty: point.y
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
                .foregroundStyle(color),
            at: .zero,
            anchor: anchor
        )
    }

    private func remainingColor(_ remaining: Int?) -> Color {
        guard let remaining else {
            return Color.gray.opacity(0.65)
        }
        if remaining > 50 {
            return Color(red: 0.06, green: 0.46, blue: 0.42)
        }
        if remaining > 25 {
            return Color(red: 0.72, green: 0.43, blue: 0.06)
        }
        return Color(red: 0.76, green: 0.20, blue: 0.17)
    }

    private func percentText(_ value: Int?) -> String {
        value.map { "\($0)퍼센트" } ?? "정보 없음"
    }
}

struct AIUsageSnapshot: Equatable, Sendable {
    let codexFiveHour: Int?
    let codexWeekly: Int?
    let claudeFiveHour: Int?
    let claudeWeekly: Int?
    let fetchedAt: Date
}

enum CodexBarUsageReader {
    private static let executablePaths = [
        "/opt/homebrew/bin/codexbar",
        "/usr/local/bin/codexbar",
    ]

    static func fetch() async throws -> AIUsageSnapshot {
        try await Task.detached(priority: .utility) {
            do {
                return try fetch(source: "oauth")
            } catch {
                return try fetch(source: "auto")
            }
        }
        .value
    }

    private static func fetch(
        source: String
    ) throws -> AIUsageSnapshot {
        let executable = try locateExecutable()
        let data = try run(
            executable: executable,
            arguments: [
                "usage",
                "--provider",
                "both",
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
            let codex = providers.first(where: { $0.provider == "codex" }),
            let codexUsage = codex.usage,
            let claude = providers.first(where: { $0.provider == "claude" }),
            let claudeUsage = claude.usage
        else {
            throw UsageReaderError.providerUnavailable
        }

        return AIUsageSnapshot(
            codexFiveHour: codexUsage.remaining(windowMinutes: 300),
            codexWeekly: codexUsage.remaining(windowMinutes: 10_080),
            claudeFiveHour: claudeUsage.remaining(windowMinutes: 300),
            claudeWeekly: claudeUsage.remaining(windowMinutes: 10_080),
            fetchedAt: Date()
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
            let message = String(decoding: error, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw UsageReaderError.failed(message)
        }
        return output
    }
}

private struct UsageProviderPayload: Decodable {
    let provider: String
    let usage: UsagePayload?
}

private struct UsagePayload: Decodable {
    let primary: UsageWindow?
    let secondary: UsageWindow?
    let tertiary: UsageWindow?

    func remaining(windowMinutes: Int) -> Int? {
        let window = [primary, secondary, tertiary]
            .compactMap { $0 }
            .first { $0.windowMinutes == windowMinutes }
        guard let usedPercent = window?.usedPercent else {
            return nil
        }
        return Int(
            min(100, max(0, 100 - usedPercent)).rounded()
        )
    }
}

private struct UsageWindow: Decodable {
    let usedPercent: Double
    let windowMinutes: Int
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
