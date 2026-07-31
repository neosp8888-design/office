// 이 파일은 공개 가능한 에이전트 진행 이벤트를 CLI형 타임라인으로 표시한다.

import AppKit
import OfficeCore
import SwiftUI

struct CodexTranscriptPresentation: Equatable {
    let entries: [CodexTranscriptEntry]
    let showsWaiting: Bool

    static func make(
        turnID: String,
        activities: [LiveFeedActivity],
        response: String,
        responseUpdatedAt: Date,
        isRunning: Bool
    ) -> CodexTranscriptPresentation {
        var entries: [CodexTranscriptEntry] = []
        var operationBuffer: [LiveFeedActivity] = []

        func flushOperations() {
            guard !operationBuffer.isEmpty else {
                return
            }
            entries.append(
                .operations(CodexOperationGroup(activities: operationBuffer))
            )
            operationBuffer.removeAll(keepingCapacity: true)
        }

        for activity in activities {
            if CodexFileChangeSummary.isFileChange(activity) {
                flushOperations()
                if let summary = CodexFileChangeSummary.make(
                    from: [activity]
                ) {
                    entries.append(.changes(summary))
                }
                continue
            }

            switch activity.kind {
            case "command", "tool":
                operationBuffer.append(activity)
            case "message":
                flushOperations()
                entries.append(
                    .message(
                        CodexTranscriptMessage(
                            id: "activity:\(activity.id)",
                            text: activity.text,
                            occurredAt: activity.occurredAt
                        )
                    )
                )
            default:
                flushOperations()
                entries.append(.narrative(activity))
            }
        }
        flushOperations()

        let promotedMessages = activities
            .filter { $0.kind == "message" }
            .map(\.text)
        let remainingResponse = responseAfterRemovingPromotedMessages(
            response,
            promotedMessages: promotedMessages
        )
        if
            isGeneratedImagePreviewSuffix(remainingResponse),
            let messageIndex = entries.lastIndex(where: { entry in
                if case .message = entry {
                    return true
                }
                return false
            }),
            case .message(let message) = entries[messageIndex]
        {
            entries[messageIndex] = .message(
                CodexTranscriptMessage(
                    id: message.id,
                    text: message.text + "\n\n" + remainingResponse,
                    occurredAt: responseUpdatedAt
                )
            )
        } else if !remainingResponse.isEmpty {
            entries.append(
                .message(
                    CodexTranscriptMessage(
                        id: "response:\(turnID)",
                        text: remainingResponse,
                        occurredAt: responseUpdatedAt
                    )
                )
            )
        }

        return CodexTranscriptPresentation(
            entries: entries,
            showsWaiting:
                isRunning
                    && !activities.contains { $0.status == .running }
        )
    }

    static func responseAfterRemovingPromotedMessages(
        _ response: String,
        promotedMessages: [String]
    ) -> String {
        var remaining = response
        var removedPrefixCount = 0
        for message in promotedMessages {
            if remaining == message {
                return ""
            }

            let prefix = message + "\n\n"
            guard remaining.hasPrefix(prefix) else {
                break
            }
            remaining.removeFirst(prefix.count)
            removedPrefixCount += 1
        }
        if removedPrefixCount > 0 {
            return remaining
        }

        for startIndex in promotedMessages.indices.reversed() {
            let knownSuffix = promotedMessages[startIndex...]
                .joined(separator: "\n\n")
            if response == knownSuffix {
                return ""
            }
            let prefix = knownSuffix + "\n\n"
            if response.hasPrefix(prefix) {
                return String(response.dropFirst(prefix.count))
            }
        }
        return remaining
    }

    static func isGeneratedImagePreviewSuffix(_ text: String) -> Bool {
        let blocks = text
            .components(separatedBy: "\n\n")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return !blocks.isEmpty && blocks.allSatisfy { block in
            block.hasPrefix("[![생성 이미지 ")
                && block.contains("](<file:")
                && block.hasSuffix(")")
        }
    }
}

enum CodexTranscriptEntry: Identifiable, Equatable {
    case narrative(LiveFeedActivity)
    case operations(CodexOperationGroup)
    case message(CodexTranscriptMessage)
    case changes(CodexFileChangeSummary)

    var id: String {
        switch self {
        case .narrative(let activity):
            "narrative:\(activity.id)"
        case .operations(let group):
            group.id
        case .message(let message):
            message.id
        case .changes(let summary):
            summary.id
        }
    }
}

struct CodexOperationGroup: Identifiable, Equatable {
    let activities: [LiveFeedActivity]

    var id: String {
        let first = activities.first?.id ?? "empty"
        return "operations:\(first)"
    }

    var isRunning: Bool {
        activities.contains { $0.status == .running }
    }

    func visibleActivities(
        showsAll: Bool,
        limit: Int
    ) -> [LiveFeedActivity] {
        guard !showsAll, activities.count > limit else {
            return activities
        }
        return Array(activities.suffix(limit))
    }

    func hiddenActivityCount(limit: Int) -> Int {
        max(0, activities.count - limit)
    }
}

struct CodexTranscriptMessage: Identifiable, Equatable {
    let id: String
    let text: String
    let occurredAt: Date
}

struct CodexFileChangeSummary: Equatable {
    let activityIDs: [String]
    let files: [String]
    let reportedFileCount: Int?
    let additions: Int?
    let deletions: Int?
    let status: LiveFeedActivityStatus

    var id: String {
        "changes:" + activityIDs.joined(separator: ",")
    }

    var title: String {
        if status == .running {
            if let reportedFileCount {
                return "파일 \(reportedFileCount)개를 편집하는 중"
            }
            return "파일 변경을 적용하는 중"
        }
        if status == .failed {
            if let reportedFileCount {
                return "파일 \(reportedFileCount)개 변경에 실패했습니다"
            }
            return "파일 변경에 실패했습니다"
        }
        if let reportedFileCount {
            return "파일 \(reportedFileCount)개를 편집했습니다"
        }
        return files.isEmpty ? "파일 변경을 반영했습니다" : "파일 변경 결과"
    }

    var copyText: String {
        var lines = [title]
        if let additions, let deletions {
            lines.append("+\(additions) -\(deletions)")
        }
        lines.append(contentsOf: files)
        return lines.joined(separator: "\n")
    }

    static func isFileChange(_ activity: LiveFeedActivity) -> Bool {
        guard activity.kind == "tool" else {
            return false
        }
        let firstLine = activity.text.split(
            separator: "\n",
            maxSplits: 1,
            omittingEmptySubsequences: true
        ).first.map(String.init) ?? ""
        return firstLine == "파일 변경 완료"
            || firstLine == "파일 변경을 반영했습니다."
            || isRunningTitle(firstLine)
            || firstLine.hasPrefix("파일 · ")
            || reportedCount(from: firstLine) != nil
    }

    static func make(
        from activities: [LiveFeedActivity]
    ) -> CodexFileChangeSummary? {
        guard !activities.isEmpty else {
            return nil
        }

        var files: [String] = []
        var seenFiles = Set<String>()
        var additions = 0
        var deletions = 0
        var hasCompleteStatistics = true
        var declaredFileCount: Int?
        var hasTruncatedFiles = false

        for activity in activities {
            var activityHasStatistics = false
            let lines = activity.text
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            guard !lines.isEmpty else {
                hasCompleteStatistics = false
                continue
            }

            if activity.text.hasPrefix("파일 · ") {
                let legacy = legacyFiles(
                    from: String(activity.text.dropFirst("파일 · ".count))
                )
                for file in legacy.files {
                    appendUnique(file, to: &files, seen: &seenFiles)
                }
                if legacy.remainder > 0 {
                    hasTruncatedFiles = true
                    if activities.count == 1 {
                        declaredFileCount = legacy.files.count + legacy.remainder
                    }
                }
                hasCompleteStatistics = false
                continue
            }

            for (index, line) in lines.enumerated() {
                if index == 0 {
                    if let count = reportedCount(from: line) {
                        if activities.count == 1 {
                            declaredFileCount = count
                        }
                        continue
                    }
                    if isRunningTitle(line) {
                        if
                            activities.count == 1,
                            let count = runningCount(from: line)
                        {
                            declaredFileCount = count
                        }
                        continue
                    }
                }
                if let values = statistics(from: line) {
                    additions += values.additions
                    deletions += values.deletions
                    activityHasStatistics = true
                    continue
                }
                if line.hasPrefix("외 ") {
                    hasTruncatedFiles = true
                } else if
                    line != "파일 변경 완료",
                    line != "파일 변경을 반영했습니다."
                {
                    appendUnique(line, to: &files, seen: &seenFiles)
                }
            }
            if !activityHasStatistics {
                hasCompleteStatistics = false
            }
        }

        let exactFileCount: Int?
        if activities.count == 1, let declaredFileCount {
            exactFileCount = declaredFileCount
        } else if !hasTruncatedFiles, !files.isEmpty {
            exactFileCount = files.count
        } else {
            exactFileCount = nil
        }

        let status: LiveFeedActivityStatus
        if activities.contains(where: { $0.status == .failed }) {
            status = .failed
        } else if activities.contains(where: { $0.status == .running }) {
            status = .running
        } else {
            status = .completed
        }

        return CodexFileChangeSummary(
            activityIDs: activities.map(\.id),
            files: files,
            reportedFileCount: exactFileCount,
            additions: hasCompleteStatistics ? additions : nil,
            deletions: hasCompleteStatistics ? deletions : nil,
            status: status
        )
    }

    private static func appendUnique(
        _ value: String,
        to values: inout [String],
        seen: inout Set<String>
    ) {
        let key = fileIdentity(value)
        guard !value.isEmpty, seen.insert(key).inserted else {
            return
        }
        values.append(value)
    }

    private static func fileIdentity(_ value: String) -> String {
        for prefix in ["추가 ", "수정 ", "삭제 "] where value.hasPrefix(prefix) {
            return String(value.dropFirst(prefix.count))
        }
        return value
    }

    private static func legacyFiles(
        from value: String
    ) -> (files: [String], remainder: Int) {
        var body = value
        var remainder = 0
        if let marker = value.range(of: " 외 ", options: .backwards) {
            let suffix = value[marker.upperBound...]
            if suffix.hasSuffix("개"), let count = Int(suffix.dropLast()) {
                body = String(value[..<marker.lowerBound])
                remainder = count
            }
        }
        return (
            body.components(separatedBy: ", ").filter { !$0.isEmpty },
            remainder
        )
    }

    private static func statistics(
        from line: String
    ) -> (additions: Int, deletions: Int)? {
        let parts = line.split(separator: " ")
        guard
            parts.count == 2,
            parts[0].hasPrefix("+"),
            parts[1].hasPrefix("-"),
            let additions = Int(parts[0].dropFirst()),
            let deletions = Int(parts[1].dropFirst())
        else {
            return nil
        }
        return (additions, deletions)
    }

    private static func reportedCount(from line: String) -> Int? {
        let prefix = "파일 "
        let suffix = "개를 편집했습니다"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else {
            return nil
        }
        return Int(
            line
                .dropFirst(prefix.count)
                .dropLast(suffix.count)
        )
    }

    private static func isRunningTitle(_ line: String) -> Bool {
        line == "파일 변경을 적용하는 중"
            || runningCount(from: line) != nil
    }

    private static func runningCount(from line: String) -> Int? {
        let prefix = "파일 변경을 적용하는 중 · "
        let suffix = "개"
        guard line.hasPrefix(prefix), line.hasSuffix(suffix) else {
            return nil
        }
        return Int(
            line
                .dropFirst(prefix.count)
                .dropLast(suffix.count)
        )
    }
}

struct CodexTranscriptView: View {
    let turnID: String
    let activities: [LiveFeedActivity]
    let response: String
    let responseUpdatedAt: Date
    let isRunning: Bool
    let isCompleted: Bool
    let needsInput: Bool
    let onResponsePresented: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsAllEntries = false

    private static let compactEntryLimit = 18

    var body: some View {
        let presentation = CodexTranscriptPresentation.make(
            turnID: turnID,
            activities: activities,
            response: response,
            responseUpdatedAt: responseUpdatedAt,
            isRunning: isRunning
        )
        let hiddenCount = max(
            0,
            presentation.entries.count - Self.compactEntryLimit
        )
        let visibleEntries = showsAllEntries
            ? presentation.entries
            : Array(presentation.entries.suffix(Self.compactEntryLimit))
        let conclusionMessageID: String? = {
            guard
                isCompleted,
                let lastEntry = presentation.entries.last,
                case .message(let message) = lastEntry
            else {
                return nil
            }
            return message.id
        }()

        VStack(alignment: .leading, spacing: 14) {
            if hiddenCount > 0, !showsAllEntries {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) {
                        showsAllEntries = true
                    }
                } label: {
                    Label(
                        "이전 기록 \(hiddenCount)개 보기",
                        systemImage: "clock.arrow.circlepath"
                    )
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            ForEach(visibleEntries) { entry in
                transcriptEntry(
                    entry,
                    isConclusion: entry.id == conclusionMessageID
                )
            }

            if presentation.showsWaiting {
                CodexWaitingView()
                    .transition(
                        reduceMotion
                            ? .opacity
                            : .opacity.combined(with: .scale(scale: 0.98))
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(
            reduceMotion ? nil : .easeOut(duration: 0.18),
            value: presentation.showsWaiting
        )
        .task(id: response) {
            if !response.isEmpty {
                onResponsePresented()
            }
        }
    }

    @ViewBuilder
    private func transcriptEntry(
        _ entry: CodexTranscriptEntry,
        isConclusion: Bool
    ) -> some View {
        switch entry {
        case .narrative(let activity):
            CodexNarrativeActivityView(activity: activity)
        case .operations(let group):
            CodexOperationGroupView(group: group)
        case .message(let message):
            CodexMessageView(
                message: message,
                isConclusion: isConclusion,
                needsInput: isConclusion && needsInput
            )
        case .changes(let summary):
            CodexFileChangeSummaryView(summary: summary)
        }
    }
}

private struct CodexWaitingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 9) {
            CoreAnimationDotsView(
                dotSize: 4,
                spacing: 2.5,
                travel: 2.5,
                color: NSColor(
                    calibratedRed: 0.13,
                    green: 0.55,
                    blue: 0.52,
                    alpha: 1
                ),
                isAnimated: !reduceMotion
            )
            .frame(width: 20, height: 16)
            .accessibilityHidden(true)

            Text("생각 중")
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 36)
        .background(
            DashboardPalette.accent.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("생각 중")
    }
}

private struct CodexNarrativeActivityView: View {
    let activity: LiveFeedActivity

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            if activity.status == .running {
                ProgressView()
                    .controlSize(.mini)
                    .tint(DashboardPalette.accent)
                    .frame(width: 18, height: 18)
            } else {
                Image(systemName: "book.pages")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18, height: 18)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(activity.text)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(activity.occurredAt.formatted(
                    date: .omitted,
                    time: .standard
                ))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "추론, \(activity.text), "
                + activity.occurredAt.formatted(
                    date: .omitted,
                    time: .standard
                )
        )
    }
}

func codexOperationExpansionState(
    current: Bool,
    isRunning: Bool
) -> Bool {
    isRunning ? current : false
}

private struct CodexOperationGroupView: View {
    let group: CodexOperationGroup
    @State private var isExpanded: Bool
    @State private var showsAllActivities = false

    private static let compactActivityLimit = 20

    init(group: CodexOperationGroup) {
        self.group = group
        _isExpanded = State(initialValue: false)
    }

    var body: some View {
        let hiddenCount = group.hiddenActivityCount(
            limit: Self.compactActivityLimit
        )
        let visibleActivities = group.visibleActivities(
            showsAll: showsAllActivities,
            limit: Self.compactActivityLimit
        )

        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 0) {
                if hiddenCount > 0, !showsAllActivities {
                    Button {
                        showsAllActivities = true
                    } label: {
                        Label(
                            "이전 작업 \(hiddenCount)개 보기",
                            systemImage: "clock.arrow.circlepath"
                        )
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .padding(.vertical, 6)
                }

                ForEach(visibleActivities) { activity in
                    operationRow(activity)
                }
            }
            .padding(.top, 7)
        } label: {
            HStack(spacing: 8) {
                Image(systemName: groupIcon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(group.isRunning
                        ? DashboardPalette.accent
                        : Color.secondary)
                    .frame(width: 18)

                Text(groupTitle)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)

                if group.isRunning {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(DashboardPalette.accent)
                }

                Spacer(minLength: 6)

                Text("\(group.activities.count)개")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .tint(.secondary)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06))
        }
        .onChange(of: group.isRunning) { _, running in
            isExpanded = codexOperationExpansionState(
                current: isExpanded,
                isRunning: running
            )
        }
    }

    private func operationRow(_ activity: LiveFeedActivity) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if activity.status == .running {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(operationColor(activity))
                } else {
                    Image(
                        systemName: activity.status == .failed
                            ? "xmark.circle.fill"
                            : "checkmark.circle.fill"
                    )
                    .foregroundStyle(
                        activity.status == .failed
                            ? Color.red
                            : operationColor(activity)
                    )
                }
            }
            .frame(width: 15, height: 15)

            Image(systemName: activity.kind == "command"
                ? "terminal"
                : "wrench.and.screwdriver")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 14)

            Text(activity.text)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(activity.occurredAt.formatted(
                date: .omitted,
                time: .standard
            ))
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
    }

    private var groupTitle: String {
        let commands = group.activities.filter { $0.kind == "command" }.count
        let tools = group.activities.count - commands
        if group.isRunning {
            if commands > 0, tools > 0 {
                return "명령과 도구를 사용하는 중"
            }
            return commands > 0 ? "명령을 실행하는 중" : "도구를 사용하는 중"
        }
        if commands > 0, tools > 0 {
            return "명령과 도구를 사용했습니다"
        }
        return commands > 0 ? "명령을 실행했습니다" : "도구를 사용했습니다"
    }

    private var groupIcon: String {
        group.activities.contains { $0.kind == "command" }
            ? "terminal"
            : "wrench.and.screwdriver"
    }

    private func operationColor(_ activity: LiveFeedActivity) -> Color {
        activity.kind == "command" ? .indigo : .orange
    }
}

private struct CodexMessageView: View {
    let message: CodexTranscriptMessage
    let isConclusion: Bool
    let needsInput: Bool

    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if isConclusion || needsInput {
                Label(
                    needsInput ? "답변 필요" : "최종 응답",
                    systemImage: needsInput
                        ? "questionmark.bubble.fill"
                        : "checkmark.bubble.fill"
                )
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(
                    needsInput ? Color.orange : DashboardPalette.accent
                )
            }

            ConversationMarkdownView(
                source: message.text,
                fontSize: 14
            )
            .textSelection(.enabled)

            HStack(spacing: 7) {
                Text(message.occurredAt.formatted(
                    date: .omitted,
                    time: .standard
                ))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)

                Spacer(minLength: 6)

                Button {
                    copyMessage()
                } label: {
                    Label(
                        copied ? "복사됨" : "복사",
                        systemImage: copied ? "checkmark" : "doc.on.doc"
                    )
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(
                        copied ? DashboardPalette.accent : Color.secondary
                    )
                }
                .buttonStyle(.plain)
                .help(copied ? "메시지 복사됨" : "메시지 복사")
                .accessibilityIdentifier("copyMessage-\(message.id)")
            }
        }
        .padding(.vertical, 2)
        .onChange(of: message.text) { _, _ in
            copyResetTask?.cancel()
            copied = false
        }
        .onDisappear {
            copyResetTask?.cancel()
        }
    }

    private func copyMessage() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(message.text, forType: .string)
        copied = true

        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled {
                copied = false
            }
        }
    }
}

private struct CodexFileChangeSummaryView: View {
    let summary: CodexFileChangeSummary

    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "doc.badge.gearshape")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(statusColor)
                    .frame(width: 28, height: 28)
                    .background(
                        statusColor.opacity(0.10),
                        in: RoundedRectangle(cornerRadius: 8)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(summary.title)
                        .font(.system(size: 12.5, weight: .bold))

                    if let additions = summary.additions,
                        let deletions = summary.deletions
                    {
                        HStack(spacing: 5) {
                            Text("+\(additions)")
                                .foregroundStyle(.green)
                            Text("-\(deletions)")
                                .foregroundStyle(.red)
                        }
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                    }
                }

                Spacer(minLength: 6)

                Button {
                    copySummary()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            copied ? DashboardPalette.accent : Color.secondary
                        )
                }
                .buttonStyle(.plain)
                .help(copied ? "변경 결과 복사됨" : "변경 결과 복사")
                .accessibilityLabel(
                    copied ? "변경 결과 복사됨" : "변경 결과 복사"
                )
                .accessibilityIdentifier("copyChanges-\(summary.id)")
            }

            if !summary.files.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(Array(summary.files.enumerated()), id: \.offset) {
                        _, file in
                        Text(file)
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(11)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.07))
        }
        .onChange(of: summary.copyText) { _, _ in
            copyResetTask?.cancel()
            copied = false
        }
        .onDisappear {
            copyResetTask?.cancel()
        }
    }

    private var statusColor: Color {
        switch summary.status {
        case .running:
            DashboardPalette.accent
        case .completed:
            .green
        case .failed:
            .red
        }
    }

    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(summary.copyText, forType: .string)
        copied = true

        copyResetTask?.cancel()
        copyResetTask = Task {
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled {
                copied = false
            }
        }
    }
}

struct AgentActivityPresentation {
    let running: LiveFeedActivity?
    let completed: [LiveFeedActivity]
    let visible: [LiveFeedActivity]
    let hiddenCount: Int
    let latest: LiveFeedActivity?
    let initialRunningReasoning: LiveFeedActivity?

    var displayedCount: Int {
        completed.count + (initialRunningReasoning == nil ? 0 : 1)
    }

    static func make(
        activities: [LiveFeedActivity],
        isRunning: Bool
    ) -> AgentActivityPresentation {
        let running = isRunning
            ? activities.last { $0.status == .running }
            : nil
        let firstReasoning = activities.first { activity in
            activity.kind == "thinking"
                && !isLegacyStartedActivity(activity)
                && !isBoilerplateActivity(activity)
        }
        let initialRunningReasoning = isRunning
                && firstReasoning?.status == .running
            ? firstReasoning
            : nil
        let completed = activities.filter { activity in
            if isRunning && activity.status == .running {
                return false
            }
            return !isLegacyStartedActivity(activity)
                && !isBoilerplateActivity(activity)
        }
        let narratives = completed
            .filter { $0.kind == "thinking" || $0.kind == "message" }
            .suffix(6)
        let operations = completed
            .filter { $0.kind == "command" || $0.kind == "tool" }
            .suffix(5)
        let visibleCompletedIDs = Set(
            (Array(narratives) + Array(operations)).map(\.id)
        )
        var visibleIDs = visibleCompletedIDs
        if let initialRunningReasoning {
            visibleIDs.insert(initialRunningReasoning.id)
        }
        let visible = activities.filter { visibleIDs.contains($0.id) }
        return AgentActivityPresentation(
            running: running,
            completed: completed,
            visible: visible,
            hiddenCount: completed.count - visibleCompletedIDs.count,
            latest: running ?? visible.last,
            initialRunningReasoning: initialRunningReasoning
        )
    }

    private static func isLegacyStartedActivity(
        _ activity: LiveFeedActivity
    ) -> Bool {
        let text = activity.text
        return text.hasPrefix("실행 · ")
            || text.hasPrefix("도구 호출 · ")
            || text == "명령을 실행하는 중..."
            || text == "연결된 도구를 사용하는 중..."
    }

    private static func isBoilerplateActivity(
        _ activity: LiveFeedActivity
    ) -> Bool {
        [
            "업무 세팅 중 🧳",
            "업무 환경을 준비하는 중...",
            "요청서 정독 중 👀",
            "업무 내용을 살펴보는 중...",
            "작전 짜는 중 🧠",
            "작업 순서를 정리하는 중...",
        ].contains(activity.text)
    }
}

func agentActivityStatusTitle(
    _ status: LiveFeedActivityStatus
) -> String {
    switch status {
    case .running:
        "시작"
    case .completed:
        "완료"
    case .failed:
        "실패"
    }
}

struct AgentActivityLogView: View {
    let activities: [LiveFeedActivity]
    let backend: AgentBackend?
    let isRunning: Bool
    @Binding var isExpanded: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let presentation = activityPresentation
        if
            isRunning
                || presentation.running != nil
                || !presentation.completed.isEmpty
        {
            DisclosureGroup(isExpanded: $isExpanded) {
                if !presentation.visible.isEmpty {
                    VStack(alignment: .leading, spacing: 9) {
                        HStack(spacing: 6) {
                            Text(
                                presentation.initialRunningReasoning == nil
                                    ? "완료 기록"
                                    : "작업 기록"
                            )
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.secondary)

                            Text("\(presentation.displayedCount)건")
                                .font(
                                    .system(
                                        size: 8.5,
                                        weight: .semibold,
                                        design: .monospaced
                                    )
                                )
                                .foregroundStyle(.tertiary)

                            Spacer()
                        }

                        VStack(alignment: .leading, spacing: 0) {
                            ForEach(presentation.visible) { activity in
                                activityRow(
                                    activity,
                                    isLast: activity.id
                                        == presentation.visible.last?.id
                                )
                            }
                        }

                        if presentation.hiddenCount > 0 {
                            Text(
                                "이전 완료 기록 "
                                    + "\(presentation.hiddenCount)건 생략"
                            )
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.tertiary)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(
                        Color.primary.opacity(
                            colorScheme == .dark ? 0.10 : 0.035
                        ),
                        in: RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        )
                    )
                    .overlay {
                        RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        )
                            .stroke(Color.primary.opacity(0.065))
                    }
                    .padding(.top, 7)
                }
            } label: {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: backendIcon)
                        .foregroundStyle(providerColor)

                    Text("\(backendTitle) · 추론 및 작업")
                        .font(
                            .system(
                                size: 10.5,
                                weight: .bold,
                                design: .monospaced
                            )
                        )

                    Text(
                        headerStatus(
                            runningActivity: presentation.running
                        )
                    )
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(
                            presentation.running != nil
                                ? providerColor
                                : Color.secondary
                        )
                        .padding(.horizontal, 6)
                        .frame(height: 18)
                        .background(
                            (
                                presentation.running != nil
                                    ? providerColor
                                    : Color.secondary
                            )
                                .opacity(0.10),
                            in: Capsule()
                        )

                    Spacer(minLength: 6)

                    Text("\(presentation.completed.count)건")
                        .font(
                            .system(
                                size: 8.5,
                                weight: .semibold,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(.tertiary)
                }

                if let latestActivity = presentation.latest {
                    HStack(spacing: 6) {
                        if latestActivity.status == .running && isRunning {
                            ProgressView()
                                .controlSize(.mini)
                                .tint(providerColor)
                                .frame(width: 12, height: 12)
                                .accessibilityHidden(true)
                        } else {
                            Image(systemName: "checkmark")
                                .font(.system(size: 8, weight: .bold))
                                .foregroundStyle(.secondary)
                                .frame(width: 12)
                        }

                        Text(displayText(latestActivity))
                            .font(.system(size: 10.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        Spacer(minLength: 6)

                        Text(activityTime(latestActivity))
                            .font(.system(size: 8.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 9)
            .padding(.vertical, 8)
            .background(
                providerColor.opacity(isRunning ? 0.055 : 0.025),
                in: RoundedRectangle(
                    cornerRadius: 10,
                    style: .continuous
                )
            )
            .contentShape(Rectangle())
        }
            .tint(providerColor)
            .onAppear {
                if !isRunning {
                    isExpanded = false
                }
            }
            .onChange(of: isRunning) { _, running in
                if !running {
                    isExpanded = false
                }
            }
        }
    }

    private func activityRow(
        _ activity: LiveFeedActivity,
        isLast: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 9) {
            ZStack {
                Circle()
                    .fill(
                        Color(nsColor: .controlBackgroundColor)
                    )
                    .frame(width: 18, height: 18)

                if activity.status == .running {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(activityColor(activity.kind))
                        .frame(width: 12, height: 12)
                } else {
                    Image(
                        systemName: activity.status == .failed
                            ? "xmark"
                            : "checkmark"
                    )
                    .font(.system(size: 8.5, weight: .bold))
                    .foregroundStyle(
                        activity.status == .failed
                            ? Color.red
                            : activityColor(activity.kind)
                    )
                }
            }
            .overlay(alignment: .bottom) {
                if !isLast {
                    Rectangle()
                        .fill(Color.primary.opacity(0.13))
                        .frame(width: 1, height: 17)
                        .offset(y: 17)
                }
            }
            .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(
                        "\(agentActivityStatusTitle(activity.status))"
                            + " · \(activityTitle(activity.kind))"
                    )
                        .font(
                            .system(
                                size: 8.5,
                                weight: .bold,
                                design: .monospaced
                            )
                        )
                        .foregroundStyle(activityColor(activity.kind))

                    Spacer(minLength: 4)

                    Text(activityTime(activity))
                        .font(.system(size: 8.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }

                Text(displayText(activity))
                    .font(
                        .system(
                            size: 10.5,
                            weight: .medium,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 3)
        .background(Color.clear)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(agentActivityStatusTitle(activity.status)) · "
                + "\(activityTitle(activity.kind)), "
                + "\(displayText(activity)), \(activityTime(activity))"
        )
    }

    private var activityPresentation: AgentActivityPresentation {
        AgentActivityPresentation.make(
            activities: activities,
            isRunning: isRunning
        )
    }

    private func headerStatus(
        runningActivity: LiveFeedActivity?
    ) -> String {
        if runningActivity != nil {
            return "실행 중"
        }
        return isRunning ? "진행 중" : "완료"
    }

    private func runningTitle(_ kind: String) -> String {
        switch kind {
        case "command":
            "명령 실행 중"
        case "tool":
            "도구 사용 중"
        case "message":
            "진행 설명 중"
        default:
            "추론 중"
        }
    }

    private func displayText(_ activity: LiveFeedActivity) -> String {
        let text = activity.text
        let prefixes = [
            "도구 완료 · ",
            "도구 실패 · ",
            "완료 · ",
            "실패 · ",
        ]
        if let prefix = prefixes.first(where: { text.hasPrefix($0) }) {
            return String(text.dropFirst(prefix.count))
        }
        if
            let separator = text.firstIndex(of: "·"),
            text.hasPrefix("완료(") || text.hasPrefix("실패(")
        {
            return text[text.index(after: separator)...]
                .trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private var backendTitle: String {
        backend?.title ?? "에이전트"
    }

    private var backendIcon: String {
        switch backend {
        case .codex:
            "terminal.fill"
        case .claude:
            "sparkles"
        case nil:
            "bolt.horizontal.fill"
        }
    }

    private var providerColor: Color {
        switch backend {
        case .claude:
            Color(red: 0.78, green: 0.42, blue: 0.23)
        case .codex, nil:
            DashboardPalette.accent
        }
    }

    private func activityTitle(_ kind: String) -> String {
        switch kind {
        case "command":
            "COMMAND"
        case "tool":
            "TOOL"
        case "message":
            "MESSAGE"
        default:
            "REASONING"
        }
    }

    private func activityColor(_ kind: String) -> Color {
        switch kind {
        case "command":
            Color.indigo
        case "tool":
            Color.orange
        case "message":
            providerColor
        default:
            Color.purple
        }
    }

    private func activityTime(_ activity: LiveFeedActivity) -> String {
        activity.occurredAt.formatted(
            date: .omitted,
            time: .standard
        )
    }
}
