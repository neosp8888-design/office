// 이 파일은 Claude Code 업무를 도구 배지와 계획 중심 타임라인으로 보여준다.

import AppKit
import OfficeCore
import SwiftUI

enum ClaudePalette {
    static let accent = Color(red: 0.78, green: 0.42, blue: 0.23)

    static func color(for family: ClaudeToolFamily) -> Color {
        switch family {
        case .shell:
            .indigo
        case .read:
            Color(red: 0.28, green: 0.5, blue: 0.72)
        case .edit:
            .green
        case .search:
            .purple
        case .web:
            .teal
        case .plan:
            .orange
        case .delegate:
            .pink
        case .other:
            .secondary
        }
    }

    static func icon(for family: ClaudeToolFamily) -> String {
        switch family {
        case .shell:
            "terminal"
        case .read:
            "doc.text"
        case .edit:
            "square.and.pencil"
        case .search:
            "magnifyingglass"
        case .web:
            "globe"
        case .plan:
            "checklist"
        case .delegate:
            "person.2"
        case .other:
            "wrench.and.screwdriver"
        }
    }

    static func color(for kind: ClaudeToolGroupKind) -> Color {
        color(for: family(of: kind))
    }

    static func icon(for kind: ClaudeToolGroupKind) -> String {
        icon(for: family(of: kind))
    }

    private static func family(
        of kind: ClaudeToolGroupKind
    ) -> ClaudeToolFamily {
        switch kind {
        case .shell:
            .shell
        case .read:
            .read
        case .search:
            .search
        case .web:
            .web
        case .delegate:
            .delegate
        case .other:
            .other
        }
    }
}

extension ClaudeToolGroupKind {
    /// 그룹 카드 제목이다.
    var title: String {
        switch self {
        case .shell:
            OfficeLocalization.string("명령 실행")
        case .read:
            OfficeLocalization.string("파일 읽기")
        case .search:
            OfficeLocalization.string("검색")
        case .web:
            OfficeLocalization.string("웹 조회")
        case .delegate:
            OfficeLocalization.string("서브에이전트")
        case .other:
            OfficeLocalization.string("도구 사용")
        }
    }

    /// `이전 OO 3개 보기`에 들어가는 낱말이다.
    var historyNoun: String {
        switch self {
        case .shell:
            "명령"
        case .read:
            "읽기"
        case .search:
            "검색"
        case .web:
            "조회"
        case .delegate:
            "위임"
        case .other:
            "도구 사용"
        }
    }
}

struct ClaudeTranscriptView: View {
    let turnID: String
    let workspaceDirectory: String
    let activities: [LiveFeedActivity]
    let response: String
    let responseUpdatedAt: Date
    let isRunning: Bool
    let isCompleted: Bool
    let needsInput: Bool
    let animatesResponse: Bool
    let responseFeedback: TurnResponseFeedback?
    let updateResponseFeedback: (TurnResponseFeedback?) async -> Void
    let onResponsePresented: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsAllEntries = false

    private static let compactEntryLimit = 18

    var body: some View {
        let presentation = TranscriptPresentationCache.shared.presentation(
            provider: .claude,
            turnID: turnID,
            activities: activities,
            response: response,
            responseUpdatedAt: responseUpdatedAt,
            isRunning: isRunning
        ) {
            ClaudeTranscriptPresentation.make(
                turnID: turnID,
                activities: activities,
                response: response,
                responseUpdatedAt: responseUpdatedAt,
                isRunning: isRunning
            )
        }
        let hiddenCount = max(
            0,
            presentation.entries.count - Self.compactEntryLimit
        )
        let visibleEntries = showsAllEntries
            ? presentation.entries
            : Array(presentation.entries.suffix(Self.compactEntryLimit))
        let conclusionMessageID = isCompleted
            ? presentation.latestMessage?.id
            : nil

        VStack(alignment: .leading, spacing: 13) {
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
                    isConclusion: entry.id == conclusionMessageID,
                    isStreaming: entry.id == presentation.streamingMessageID
                )
            }

            if presentation.showsWaiting {
                ClaudeWaitingView()
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
            guard
                animatesResponse,
                !isRunning,
                !response.isEmpty
            else {
                return
            }
            onResponsePresented()
        }
    }

    @ViewBuilder
    private func transcriptEntry(
        _ entry: ClaudeTranscriptEntry,
        isConclusion: Bool,
        isStreaming: Bool
    ) -> some View {
        switch entry {
        case .thoughts(let run):
            ClaudeThoughtRunView(run: run)
                .equatable()
        case .tools(let run):
            ClaudeToolRunView(run: run)
                .equatable()
        case .edits(let run):
            ClaudeEditRunView(
                run: run,
                workspaceDirectory: workspaceDirectory
            )
        case .plan(let board):
            ClaudePlanBoardView(board: board)
        case .message(let message):
            ClaudeMessageView(
                turnID: turnID,
                workspaceDirectory: workspaceDirectory,
                message: message,
                isConclusion: isConclusion,
                needsInput: isConclusion && needsInput,
                isStreaming: isStreaming,
                animates: animatesResponse,
                responseFeedback: responseFeedback,
                updateResponseFeedback: updateResponseFeedback,
                onFinishedTyping: onResponsePresented
            )
        }
    }
}

private struct ClaudeWaitingView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(spacing: 9) {
            CoreAnimationDotsView(
                dotSize: 4,
                spacing: 2.5,
                travel: 2.5,
                color: NSColor(
                    calibratedRed: 0.78,
                    green: 0.42,
                    blue: 0.23,
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
            ClaudePalette.accent.opacity(0.06),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("생각 중")
    }
}

/// 추론은 Claude Code의 강점이라 최신 원문은 접지 않고 이전 기록만 접는다.
private struct ClaudeThoughtRunView: View, Equatable {
    let run: ClaudeThoughtRun

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var showsAllHistory = false

    private static let compactHistoryLimit = 20

    static func == (
        lhs: ClaudeThoughtRunView,
        rhs: ClaudeThoughtRunView
    ) -> Bool {
        lhs.run == rhs.run
    }

    var body: some View {
        let historyCount = max(0, run.thoughts.count - 1)
        let hiddenCount = run.hiddenHistoryThoughtCount(
            limit: Self.compactHistoryLimit
        )

        VStack(alignment: .leading, spacing: 8) {
            groupHeader

            if let latestThought = run.latestThought {
                thoughtRow(latestThought, isLatest: true)
            }

            if historyCount > 0 {
                DisclosureGroup(isExpanded: $isExpanded) {
                    if isExpanded {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            if hiddenCount > 0, !showsAllHistory {
                                Button {
                                    showsAllHistory = true
                                } label: {
                                    Label(
                                        "더 이전 추론 \(hiddenCount)개 보기",
                                        systemImage: "clock.arrow.circlepath"
                                    )
                                    .font(
                                        .system(size: 9.5, weight: .semibold)
                                    )
                                    .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 5)
                            }

                            ForEach(visibleHistory) { thought in
                                thoughtRow(thought, isLatest: false)
                            }
                        }
                        .padding(.top, 5)
                    }
                } label: {
                    Text(
                        isExpanded
                            ? "이전 추론 숨기기"
                            : "이전 추론 \(historyCount)개 보기"
                    )
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .tint(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            ClaudePalette.accent.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(ClaudePalette.accent.opacity(0.14))
        }
        .onChange(of: run.isRunning) { _, running in
            isExpanded = transcriptGroupExpansionState(
                current: isExpanded,
                isRunning: running
            )
        }
    }

    private var groupHeader: some View {
        HStack(spacing: 8) {
            if run.isRunning {
                CoreAnimationDotsView(
                    dotSize: 3,
                    spacing: 2,
                    travel: 2,
                    color: NSColor(
                        calibratedRed: 0.78,
                        green: 0.42,
                        blue: 0.23,
                        alpha: 1
                    ),
                    isAnimated: !reduceMotion
                )
                .frame(width: 18, height: 14)
                .accessibilityHidden(true)
            } else {
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
            }

            Text("추론")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            Spacer(minLength: 6)

            Text(OfficeLocalization.format("%d개", run.thoughts.count))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func thoughtRow(
        _ thought: ClaudeThought,
        isLatest: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "sparkle")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(ClaudePalette.accent.opacity(0.65))
                .frame(width: 15, height: 15)

            Text(displayText(thought))
                .font(.system(size: 12.5, weight: .regular))
                .italic()
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(isLatest ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(thought.occurredAt.formatted(
                date: .omitted,
                time: .standard
            ))
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, isLatest ? 4 : 3)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("추론, \(displayText(thought))")
    }

    private var visibleHistory: [ClaudeThought] {
        run.visibleHistoryThoughts(
            showsAll: showsAllHistory,
            limit: Self.compactHistoryLimit
        )
    }

    private func displayText(_ thought: ClaudeThought) -> String {
        thought.isPlaceholder ? "생각을 정리하는 중" : thought.text
    }
}

/// 연속된 도구 호출은 실제로 사용한 도구 이름을 제목으로 묶는다.
private struct ClaudeToolRunView: View, Equatable {
    let run: ClaudeToolRun

    @State private var isExpanded = false
    @State private var showsAllSteps = false

    private static let compactStepLimit = 20

    static func == (
        lhs: ClaudeToolRunView,
        rhs: ClaudeToolRunView
    ) -> Bool {
        lhs.run == rhs.run
    }

    var body: some View {
        let historyCount = max(0, run.steps.count - 1)
        let hiddenCount = run.hiddenHistoryStepCount(
            limit: Self.compactStepLimit
        )

        VStack(alignment: .leading, spacing: 8) {
            groupHeader

            if let latestStep = run.latestStep {
                stepRow(latestStep)
            }

            if historyCount > 0 {
                DisclosureGroup(isExpanded: $isExpanded) {
                    if isExpanded {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            if hiddenCount > 0, !showsAllSteps {
                                Button {
                                    showsAllSteps = true
                                } label: {
                                    Label(
                                        "더 이전 호출 \(hiddenCount)개 보기",
                                        systemImage: "clock.arrow.circlepath"
                                    )
                                    .font(
                                        .system(size: 9.5, weight: .semibold)
                                    )
                                    .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .padding(.vertical, 6)
                            }

                            ForEach(visibleHistory) { step in
                                stepRow(step)
                            }
                        }
                        .padding(.top, 5)
                    }
                } label: {
                    Text(
                        isExpanded
                            ? "이전 \(run.kind.historyNoun) 숨기기"
                            : "이전 \(run.kind.historyNoun) \(historyCount)개 보기"
                    )
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .contentShape(Rectangle())
                }
                .tint(.secondary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.06))
        }
        .onChange(of: run.isRunning) { _, running in
            isExpanded = transcriptGroupExpansionState(
                current: isExpanded,
                isRunning: running
            )
        }
    }

    private var groupHeader: some View {
        HStack(spacing: 8) {
            Image(systemName: ClaudePalette.icon(for: run.kind))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(
                    run.isRunning
                        ? ClaudePalette.color(for: run.kind)
                        : .secondary
                )
                .frame(width: 18)

            Text(run.kind.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            // 어떤 도구를 실제로 썼는지는 Claude 기록의 핵심이라 함께 남긴다.
            Text(run.title)
                .font(.system(size: 9.5, weight: .semibold, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1)

            Spacer(minLength: 6)

            Text(OfficeLocalization.format("%d개", run.steps.count))
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
        }
    }

    private func stepRow(_ step: ClaudeToolStep) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Group {
                if step.status == .running {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(ClaudePalette.color(for: step.call.family))
                } else {
                    Image(
                        systemName: step.status == .failed
                            ? "xmark.circle.fill"
                            : "checkmark.circle.fill"
                    )
                    .foregroundStyle(
                        step.status == .failed
                            ? Color.red
                            : ClaudePalette.color(for: step.call.family)
                    )
                }
            }
            .frame(width: 15, height: 15)

            ClaudeToolBadge(call: step.call, isCompact: false)

            Text(detailText(step))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(4)
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(step.occurredAt.formatted(
                date: .omitted,
                time: .standard
            ))
                .font(.system(size: 8.5, design: .monospaced))
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            "\(step.call.displayName), \(detailText(step))"
        )
    }

    private var visibleHistory: [ClaudeToolStep] {
        run.visibleHistorySteps(
            showsAll: showsAllSteps,
            limit: Self.compactStepLimit
        )
    }

    /// Bash만 셸 프롬프트를 붙여 명령임을 드러낸다.
    private func detailText(_ step: ClaudeToolStep) -> String {
        guard !step.call.detail.isEmpty else {
            return "실행"
        }
        return step.call.family == .shell
            ? "$ \(step.call.detail)"
            : step.call.detail
    }
}

private struct ClaudeToolBadge: View {
    let call: ClaudeToolCall
    let isCompact: Bool

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: ClaudePalette.icon(for: call.family))
                .font(.system(size: 9, weight: .bold))

            if !isCompact {
                Text(call.displayName)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .lineLimit(1)
            }
        }
        .foregroundStyle(ClaudePalette.color(for: call.family))
        .padding(.horizontal, isCompact ? 5 : 6)
        .frame(height: 17)
        .background(
            ClaudePalette.color(for: call.family).opacity(0.12),
            in: RoundedRectangle(cornerRadius: 5, style: .continuous)
        )
        .accessibilityHidden(isCompact)
    }
}

/// Claude는 편집 통계를 주지 않으므로 어떤 파일을 고쳤는지만 카드로 보여준다.
private struct ClaudeEditRunView: View {
    let run: ClaudeEditRun
    let workspaceDirectory: String

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

                Text(run.title)
                    .font(.system(size: 12.5, weight: .bold))

                if run.status == .running {
                    ProgressView()
                        .controlSize(.mini)
                        .tint(ClaudePalette.accent)
                }

                Spacer(minLength: 6)

                Button {
                    copySummary()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(
                            copied ? ClaudePalette.accent : Color.secondary
                        )
                }
                .buttonStyle(.plain)
                .help(copied ? "편집 목록 복사됨" : "편집 목록 복사")
                .accessibilityLabel(
                    copied ? "편집 목록 복사됨" : "편집 목록 복사"
                )
                .accessibilityIdentifier("copyEdits-\(run.id)")
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(run.steps) { step in
                    HStack(spacing: 7) {
                        ClaudeToolBadge(call: step.call, isCompact: false)

                        WorkspaceFileRevealButton(
                            title: step.call.detail.isEmpty
                                ? "파일"
                                : step.call.detail,
                            path: step.call.detail.isEmpty
                                ? nil
                                : step.call.detail,
                            workspaceDirectory: workspaceDirectory,
                            foregroundColor: step.status == .failed
                                ? .red
                                : .secondary,
                            accessibilityIdentifier:
                                "revealEdit-\(run.id)-\(step.id)"
                        )
                    }
                }
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
        .onChange(of: run.copyText) { _, _ in
            copyResetTask?.cancel()
            copied = false
        }
        .onDisappear {
            copyResetTask?.cancel()
        }
    }

    private var statusColor: Color {
        switch run.status {
        case .running:
            ClaudePalette.accent
        case .completed:
            .green
        case .failed:
            .red
        }
    }

    private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(run.copyText, forType: .string)
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

/// Claude Code의 할 일 목록은 진행 상황을 그대로 드러내는 것이 핵심이다.
private struct ClaudePlanBoardView: View {
    let board: ClaudePlanBoard

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "checklist")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.orange)

                Text("작업 계획")
                    .font(.system(size: 12, weight: .bold))

                Text("\(board.doneCount)/\(board.steps.count)")
                    .font(
                        .system(
                            size: 9.5,
                            weight: .bold,
                            design: .monospaced
                        )
                    )
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .frame(height: 17)
                    .background(
                        Color.orange.opacity(0.12),
                        in: Capsule()
                    )

                Spacer(minLength: 6)

                Text(board.occurredAt.formatted(
                    date: .omitted,
                    time: .standard
                ))
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 5) {
                ForEach(board.steps) { step in
                    HStack(alignment: .top, spacing: 7) {
                        Image(systemName: icon(for: step.state))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(color(for: step.state))
                            .frame(width: 14)

                        Text(step.text)
                            .font(
                                .system(
                                    size: 11,
                                    weight: step.state == .active
                                        ? .semibold
                                        : .regular
                                )
                            )
                            .foregroundStyle(color(for: step.state))
                            .strikethrough(step.state == .done, color: .secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(11)
        .background(
            Color.orange.opacity(0.05),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.orange.opacity(0.16))
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(
            "작업 계획 \(board.steps.count)단계 중 \(board.doneCount)단계 완료"
                + (board.activeStep.map { ", 진행 중 \($0.text)" } ?? "")
        )
    }

    private func icon(for state: ClaudePlanStep.State) -> String {
        switch state {
        case .done:
            "checkmark.square.fill"
        case .active:
            "arrow.right.square.fill"
        case .todo:
            "square"
        }
    }

    private func color(for state: ClaudePlanStep.State) -> Color {
        switch state {
        case .done:
            .secondary
        case .active:
            .orange
        case .todo:
            .primary
        }
    }
}

/// 진행 중인 마지막 응답만 Claude가 주는 글자 단위 흐름으로 표시한다.
private struct ClaudeMessageView: View {
    let turnID: String
    let workspaceDirectory: String
    let message: ClaudeTranscriptMessage
    let isConclusion: Bool
    let needsInput: Bool
    let isStreaming: Bool
    let animates: Bool
    let responseFeedback: TurnResponseFeedback?
    let updateResponseFeedback: (TurnResponseFeedback?) async -> Void
    let onFinishedTyping: () -> Void

    @State private var copied = false
    @State private var copyResetTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if isConclusion || needsInput || isStreaming {
                Label(
                    headerTitle,
                    systemImage: headerIcon
                )
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(
                    needsInput ? Color.orange : ClaudePalette.accent
                )
            }

            if isStreaming {
                EquatableLiveTypingResponseView(
                    turnID: turnID,
                    backend: .claude,
                    source: message.text,
                    fileBaseDirectory: workspaceDirectory,
                    animates: animates,
                    isStreaming: true,
                    onFinishedTyping: onFinishedTyping
                )
                .equatable()
            } else {
                ConversationMarkdownView(
                    source: message.text,
                    fontSize: 14,
                    fileBaseDirectory: workspaceDirectory
                )
                .textSelection(.enabled)
            }

            ResponseMessageFooter(
                occurredAt: message.occurredAt,
                copied: copied,
                accentColor: ClaudePalette.accent,
                accessibilityID: "copyMessage-\(message.id)",
                showsFeedback: isConclusion && !needsInput,
                feedback: responseFeedback,
                feedbackAccessibilityIDPrefix: turnID,
                copy: copyMessage,
                feedbackChanged: updateResponseFeedback
            )
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

    private var headerTitle: String {
        if needsInput {
            return "답변 필요"
        }
        return isStreaming ? "작성 중인 응답" : "최종 응답"
    }

    private var headerIcon: String {
        if needsInput {
            return "questionmark.bubble.fill"
        }
        return isStreaming ? "text.cursor" : "checkmark.bubble.fill"
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
