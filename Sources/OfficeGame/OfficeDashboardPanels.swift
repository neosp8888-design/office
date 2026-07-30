// 이 파일은 모던 대시보드의 좌측 정보 패널과 우측 실시간 업무 피드를 구성한다.

import AppKit
import OfficeCore
import SwiftUI

enum OfficeDetailSelection: String {
    case archive
    case usage

    var title: String {
        switch self {
        case .archive:
            "대화 보관함"
        case .usage:
            "화이트보드"
        }
    }

    var subtitle: String {
        switch self {
        case .archive:
            "검색하고 빠르게 여는 직원 업무 기록"
        case .usage:
            "Codex와 Claude의 현재 사용 가능량"
        }
    }

    var icon: String {
        switch self {
        case .archive:
            "books.vertical.fill"
        case .usage:
            "rectangle.and.pencil.and.ellipsis"
        }
    }
}

struct OfficeDetailPanel: View {
    @ObservedObject private var archiveFeedStore: ArchiveFeedStore
    let selection: OfficeDetailSelection

    init(
        director: AgentDirector,
        selection: OfficeDetailSelection
    ) {
        _archiveFeedStore = ObservedObject(
            wrappedValue: director.archiveFeedStore
        )
        self.selection = selection
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 11) {
                Image(systemName: selection.icon)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(DashboardPalette.accent)
                    .frame(width: 34, height: 34)
                    .background(
                        DashboardPalette.accent.opacity(0.10),
                        in: RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        )
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(selection.title)
                        .font(.system(size: 15, weight: .bold))
                    Text(selection.subtitle)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()
                .opacity(0.55)

            Group {
                switch selection {
                case .archive:
                    ArchiveShelfContent(turns: archiveFeedStore.turns)
                case .usage:
                    UsageBoardContent()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .officePanelStyle()
    }
}

private struct ArchiveShelfContent: View {
    let turns: [LiveFeedTurn]
    @State private var searchText = ""
    @State private var selectedTurnID: String?
    @State private var displayedTurns: [LiveFeedTurn]
    @State private var visibleTurnCount = Self.pageSize

    private static let pageSize = 12

    init(turns: [LiveFeedTurn]) {
        self.turns = turns
        _displayedTurns = State(initialValue: turns)
    }

    var body: some View {
        Group {
            if let selectedTurn {
                ArchiveOpenBook(turn: selectedTurn) {
                    withAnimation(
                        .spring(response: 0.3, dampingFraction: 0.88)
                    ) {
                        selectedTurnID = nil
                    }
                }
                .transition(
                    .scale(scale: 0.97).combined(with: .opacity)
                )
            } else {
                VStack(spacing: 0) {
                    searchBar

                    if displayedTurns.isEmpty {
                        ContentUnavailableView(
                            "아직 저장된 기록이 없습니다",
                            systemImage: "tray",
                            description: Text(
                                "직원에게 업무를 보내면 여기에 쌓입니다."
                            )
                        )
                    } else if filteredTurns.isEmpty {
                        ContentUnavailableView(
                            "검색 결과가 없습니다",
                            systemImage: "text.magnifyingglass",
                            description: Text(
                                "다른 이름이나 대화 내용으로 검색해보세요."
                            )
                        )
                    } else if isSearching {
                        VStack(spacing: 0) {
                            HStack(spacing: 6) {
                                Image(systemName: "magnifyingglass")
                                Text("검색 결과")
                                Text("\(filteredTurns.count)건")
                                    .foregroundStyle(.tertiary)
                                Spacer()
                            }
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 14)
                            .padding(.bottom, 6)

                            ScrollView {
                                LazyVStack(spacing: 7) {
                                    ForEach(visibleTurns) { turn in
                                        ArchiveShelfRow(turn: turn)
                                    }

                                    if hasMoreTurns {
                                        loadMoreButton
                                    }
                                }
                                .padding(.horizontal, 12)
                                .padding(.bottom, 12)
                            }
                        }
                    } else {
                        ScrollView {
                            VStack(spacing: 10) {
                                ArchiveRecordGrid(
                                    turns: visibleTurns
                                ) { turn in
                                    withAnimation(
                                        .easeInOut(duration: 0.16)
                                    ) {
                                        selectedTurnID = turn.id
                                    }
                                }

                                if hasMoreTurns {
                                    loadMoreButton
                                }
                            }
                            .padding(.horizontal, 12)
                            .padding(.bottom, 12)
                        }
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isSearching)
        .onChange(of: turnsRefreshToken) {
            _, _ in
            displayedTurns = turns
            visibleTurnCount = Self.pageSize
        }
        .onChange(of: normalizedSearchText) {
            _, _ in
            visibleTurnCount = Self.pageSize
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(
                "기록 검색 · 업무, 응답, 세션, 모델",
                text: $searchText
            )
            .textFieldStyle(.plain)
            .font(.system(size: 11, weight: .semibold))

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("검색어 지우기")
            }

            Text("\(filteredTurns.count)건")
                .font(.system(size: 9, weight: .bold, design: .rounded))
                .foregroundStyle(DashboardPalette.accent)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(
                    DashboardPalette.accent.opacity(0.09),
                    in: Capsule()
                )
        }
        .padding(.horizontal, 11)
        .frame(height: 38)
        .background(
            Color.primary.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 11, style: .continuous)
                .stroke(Color.primary.opacity(0.055))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var filteredTurns: [LiveFeedTurn] {
        let query = normalizedSearchText
        guard !query.isEmpty else {
            return displayedTurns
        }

        return displayedTurns.filter { turn in
            var fields = [
                turn.characterName,
                turn.prompt,
                turn.response,
                turn.externalSessionId ?? "",
                turn.model ?? "",
                turn.effort ?? "",
                turn.backend?.title ?? "",
            ]
            if let backend = turn.backend, let model = turn.model {
                fields.append(backend.modelTitle(model))
            }
            return fields.contains {
                $0.localizedCaseInsensitiveContains(query)
            }
        }
    }

    private var visibleTurns: [LiveFeedTurn] {
        Array(filteredTurns.prefix(visibleTurnCount))
    }

    private var hasMoreTurns: Bool {
        visibleTurnCount < filteredTurns.count
    }

    private var loadMoreButton: some View {
        Button {
            visibleTurnCount = min(
                visibleTurnCount + Self.pageSize,
                filteredTurns.count
            )
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "chevron.down")
                Text("다음 12건 보기")
                Text(
                    "\(visibleTurns.count)/\(filteredTurns.count)"
                )
                .foregroundStyle(.tertiary)
            }
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(DashboardPalette.accent)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(
                DashboardPalette.accent.opacity(0.07),
                in: RoundedRectangle(
                    cornerRadius: 9,
                    style: .continuous
                )
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("다음 12개 기록 보기")
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var isSearching: Bool {
        !normalizedSearchText.isEmpty
    }

    private var selectedTurn: LiveFeedTurn? {
        guard let selectedTurnID else {
            return nil
        }
        return displayedTurns.first { $0.id == selectedTurnID }
    }

    private var turnsRefreshToken: String {
        turns.map {
            "\($0.id)|\($0.status.rawValue)"
        }
        .joined(separator: ";")
    }
}

private struct ArchiveShelfRow: View {
    let turn: LiveFeedTurn
    @State private var isExpanded = false

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded) {
            VStack(alignment: .leading, spacing: 10) {
                executionDetails

                transcriptHeader(
                    title: "업무",
                    systemImage: "text.quote"
                )
                Text(turn.prompt)
                    .font(.system(size: 10, weight: .medium))
                    .textSelection(.enabled)

                if !turn.response.isEmpty {
                    transcriptHeader(
                        title: "응답",
                        systemImage: "checkmark.bubble.fill",
                        copyText: turn.response
                    )
                    ConversationMarkdownView(
                        source: turn.response,
                        fontSize: 14
                    )
                } else if let error = turn.errorMessage {
                    transcriptHeader(
                        title: "중단 원인",
                        systemImage: "exclamationmark.triangle.fill",
                        copyText: error
                    )
                    Text(error)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.red.opacity(0.86))
                        .textSelection(.enabled)
                } else {
                    Text("업무가 진행 중입니다.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(alignment: .top, spacing: 10) {
                CharacterBadge(
                    name: turn.characterName,
                    characterID: turn.characterId,
                    size: 30
                )

                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 5) {
                        Text(turn.characterName)
                            .font(.system(size: 11, weight: .bold))
                        Text(
                            turn.startedAt.formatted(
                                date: .omitted,
                                time: .shortened
                            )
                        )
                        .font(.system(size: 10, weight: .regular))
                        .foregroundStyle(.tertiary)
                    }
                    Text(turn.prompt)
                        .font(.system(size: 12, weight: .semibold))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Text(executionSummary)
                        .font(.system(size: 9.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)

                    Text(
                        turn.externalSessionId.map {
                            "세션 \($0)"
                        } ?? "세션 ID 기록 없음"
                    )
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                }
            }
        }
        .tint(.secondary)
        .padding(10)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
    }

    private var executionSummary: String {
        guard let backend = turn.backend else {
            return "이전 기록 · 모델/추론 정보 없음"
        }

        var parts = [backend.title]
        if let model = turn.model {
            parts.append(backend.modelTitle(model))
        } else {
            parts.append("모델 정보 없음")
        }
        parts.append(
            turn.effort.map { "추론 \($0)" }
                ?? "추론 정보 없음"
        )
        return parts.joined(separator: " · ")
    }

    private var executionDetails: some View {
        VStack(alignment: .leading, spacing: 6) {
            detailRow(
                label: "세션 ID",
                value: turn.externalSessionId ?? "기록 없음",
                monospaced: true,
                copyText: turn.externalSessionId
            )
            detailRow(
                label: "모델",
                value: modelTitle
            )
            detailRow(
                label: "추론 레벨",
                value: turn.effort ?? "기록 없음"
            )
        }
        .padding(9)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private var modelTitle: String {
        guard let backend = turn.backend, let model = turn.model else {
            return "기록 없음"
        }
        return "\(backend.title) · \(backend.modelTitle(model))"
    }

    private func detailRow(
        label: String,
        value: String,
        monospaced: Bool = false,
        copyText: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(label)
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 48, alignment: .leading)

            Text(value)
                .font(
                    monospaced
                        ? .system(size: 9, design: .monospaced)
                        : .system(size: 10, weight: .medium)
                )
                .textSelection(.enabled)
                .lineLimit(monospaced ? 1 : 2)
                .truncationMode(.middle)

            Spacer(minLength: 4)

            if let copyText {
                Button {
                    copyToPasteboard(copyText)
                } label: {
                    Image(systemName: "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(label) 복사")
                .help("\(label) 복사")
            }
        }
    }

    private func transcriptHeader(
        title: String,
        systemImage: String,
        copyText: String? = nil
    ) -> some View {
        HStack(spacing: 6) {
            Label(title, systemImage: systemImage)
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.secondary)

            Spacer()

            if let copyText {
                Button {
                    copyToPasteboard(copyText)
                } label: {
                    Label("복사", systemImage: "doc.on.doc")
                        .font(.system(size: 9, weight: .semibold))
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("\(title) 복사")
                .help("\(title) 복사")
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

private struct UsageBoardContent: View {
    @State private var snapshot: AIUsageSnapshot?
    @State private var errorMessage: String?
    @State private var isRefreshing = false

    var body: some View {
        Group {
            if let snapshot {
                VStack(spacing: 12) {
                    HStack(alignment: .top, spacing: 12) {
                        UsageProviderColumn(
                            name: "Claude",
                            icon: "sparkles",
                            fiveHour: snapshot.claudeFiveHour,
                            weekly: snapshot.claudeWeekly,
                            plan: snapshot.claudePlan,
                            activity: snapshot.claudeActivity,
                            tint: Color(
                                red: 0.77,
                                green: 0.43,
                                blue: 0.25
                            )
                        )
                        UsageProviderColumn(
                            name: "Codex",
                            icon: "terminal.fill",
                            fiveHour: snapshot.codexFiveHour,
                            weekly: snapshot.codexWeekly,
                            plan: snapshot.codexPlan,
                            activity: snapshot.codexActivity,
                            tint: DashboardPalette.accent
                        )
                    }
                    HStack(spacing: 5) {
                        Spacer()

                        Label(
                            "마지막 갱신",
                            systemImage: "clock"
                        )
                        .font(.system(size: 10, weight: .medium))

                        Text(
                            snapshot.fetchedAt.formatted(
                                date: .omitted,
                                time: .standard
                            )
                        )
                        .font(.system(size: 10, weight: .medium))

                        Button {
                            Task {
                                await refresh(force: true)
                            }
                        } label: {
                            if isRefreshing {
                                ProgressView()
                                    .controlSize(.mini)
                            } else {
                                Image(systemName: "arrow.clockwise")
                            }
                        }
                        .buttonStyle(.borderless)
                        .disabled(isRefreshing)
                        .accessibilityLabel("한도 새로고침")
                        .help("한도 새로고침")
                    }
                    .foregroundStyle(.tertiary)
                }
                .padding(14)
            } else if let errorMessage {
                VStack(spacing: 10) {
                    ContentUnavailableView(
                        "한도를 불러오지 못했습니다",
                        systemImage: "wifi.exclamationmark",
                        description: Text(errorMessage)
                    )
                    Button {
                        Task {
                            await refresh(force: true)
                        }
                    } label: {
                        Label(
                            "다시 시도",
                            systemImage: "arrow.clockwise"
                        )
                    }
                    .disabled(isRefreshing)
                }
            } else {
                ProgressView("CLI 한도를 확인하는 중")
            }
        }
        .task {
            await refresh()
        }
    }

    @MainActor
    private func refresh(
        force: Bool = false
    ) async {
        guard !isRefreshing else {
            return
        }
        isRefreshing = true
        defer {
            isRefreshing = false
        }

        do {
            snapshot = try await CodexBarUsageReader.fetch(force: force)
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

private struct UsageProviderColumn: View {
    let name: String
    let icon: String
    let fiveHour: Int?
    let weekly: Int?
    let plan: String?
    let activity: AIUsageActivitySnapshot?
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            UsageProviderCard(
                name: name,
                icon: icon,
                fiveHour: fiveHour,
                weekly: weekly,
                plan: plan,
                tint: tint
            )
            UsageActivityCard(
                activity: activity,
                tint: tint
            )
        }
        .frame(maxWidth: .infinity)
    }
}

private struct UsageProviderCard: View {
    let name: String
    let icon: String
    let fiveHour: Int?
    let weekly: Int?
    let plan: String?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(spacing: 6) {
                Label(name, systemImage: icon)
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)

                if let plan, !plan.isEmpty {
                    Text(plan)
                        .font(.system(size: 8.5, weight: .bold))
                        .foregroundStyle(tint)
                        .lineLimit(1)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 3)
                        .background(tint.opacity(0.10), in: Capsule())
                }

                Spacer()

                Text(availabilityText)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            UsageMeter(label: "5시간", value: fiveHour, tint: tint)
            UsageMeter(label: "7일", value: weekly, tint: tint)
        }
        .padding(13)
        .background(
            tint.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.13))
        }
    }

    private var availabilityText: String {
        guard let lowest = [fiveHour, weekly].compactMap({ $0 }).min()
        else {
            return "정보 없음"
        }
        return lowest > 25 ? "사용 가능" : "잔여량 낮음"
    }
}

private struct UsageActivityCard: View {
    let activity: AIUsageActivitySnapshot?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(
                "사용 통계(API 요금 추정 환산)",
                systemImage: "chart.bar.xaxis"
            )
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(tint)

            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                GridRow {
                    UsageMetricCell(
                        label: "오늘",
                        value: costText(activity?.todayCostUSD),
                        tint: tint
                    )
                    UsageMetricCell(
                        label: "30일 비용",
                        value: costText(activity?.last30DaysCostUSD),
                        tint: tint
                    )
                }
                GridRow {
                    UsageMetricCell(
                        label: "최근 토큰",
                        value: tokenText(activity?.recentTokens),
                        tint: tint
                    )
                    UsageMetricCell(
                        label: "30일 토큰",
                        value: tokenText(activity?.last30DaysTokens),
                        tint: tint
                    )
                }
            }
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.022),
            in: RoundedRectangle(cornerRadius: 14, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.10))
        }
    }

    private func costText(_ value: Double?) -> String {
        guard let value else {
            return "–"
        }
        return String(format: "$%.2f", value)
    }

    private func tokenText(_ value: Int64?) -> String {
        guard let value else {
            return "–"
        }

        let count = Double(value)
        if value >= 1_000_000_000 {
            return String(format: "%.1fB", count / 1_000_000_000)
        }
        if value >= 1_000_000 {
            let format = value >= 100_000_000 ? "%.0fM" : "%.1fM"
            return String(format: format, count / 1_000_000)
        }
        if value >= 1_000 {
            return String(format: "%.0fK", count / 1_000)
        }
        return "\(value)"
    }
}

private struct UsageMetricCell: View {
    let label: String
    let value: String
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 14, weight: .bold, design: .rounded))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 9)
        .padding(.vertical, 8)
        .background(
            tint.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }
}

private struct UsageMeter: View {
    let label: String
    let value: Int?
    let tint: Color

    var body: some View {
        HStack(spacing: 9) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 32, alignment: .leading)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.primary.opacity(0.075))
                    Capsule()
                        .fill(tint)
                        .frame(
                            width: geometry.size.width
                                * CGFloat(value ?? 0) / 100
                        )
                }
            }
            .frame(height: 6)

            Text(value.map { "\($0)%" } ?? "–")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .frame(width: 34, alignment: .trailing)
        }
    }
}

struct LiveWorkspaceFeed: View {
    @ObservedObject var director: AgentDirector
    @ObservedObject private var liveFeedStore: LiveFeedStore
    @State private var isAtBottom = false
    @State private var hasContentBelow = false
    @State private var scrollMetrics = LiveWorkspaceFeedScrollMetrics()
    @State private var visibleTurnLimit = Self.pageSize
    @State private var didPerformInitialScroll = false
    @State private var isLoadingOlderTurns = false

    private static let bottomTolerance = CGFloat(20)
    private static let bottomMarkerID = "live-workspace-feed-bottom"
    private static let pageSize = 10
    private static let maximumVisibleTurnCount = 30

    init(director: AgentDirector) {
        self.director = director
        _liveFeedStore = ObservedObject(
            wrappedValue: director.liveFeedStore
        )
    }

    private var displayTurns: [LiveFeedTurn] {
        Array(
            liveFeedStore.turns.enumerated().compactMap { index, turn in
                index < visibleTurnLimit
                    || turn.status.isRunning
                    || turn.id == director.latestTerminalTurnID
                    ? turn
                    : nil
            }
            .reversed()
        )
    }

    private var hiddenTurnCount: Int {
        max(0, liveFeedStore.turns.count - displayTurns.count)
    }

    private var canLoadOlderTurns: Bool {
        visibleTurnLimit
            < min(
                Self.maximumVisibleTurnCount,
                liveFeedStore.turns.count
            )
    }

    private var latestActivityUpdate: Date? {
        liveFeedStore.turns.map(\.updatedAt).max()
    }

    private var isResponsePreparing: Bool {
        displayTurns.contains { $0.status.isRunning }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if displayTurns.isEmpty {
                    if liveFeedStore.isLoadingInitialFeed {
                        VStack(spacing: 10) {
                            ProgressView()
                                .controlSize(.small)
                            Text("대화를 불러오는 중")
                                .font(
                                    .system(
                                        size: 12,
                                        weight: .semibold,
                                        design: .rounded
                                    )
                                )
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement(children: .combine)
                        .accessibilityLabel("대화를 불러오는 중")
                    } else {
                        ContentUnavailableView(
                            "아직 업무 대화가 없습니다",
                            systemImage:
                                "bubble.left.and.text.bubble.right",
                            description: Text(
                                "오피스에서 직원을 선택하고 첫 업무를 보내보세요."
                            )
                        )
                    }
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            LazyVStack(spacing: 14) {
                                if hiddenTurnCount > 0 {
                                    archivedTurnsNotice
                                        .onAppear {
                                            guard
                                                didPerformInitialScroll
                                            else {
                                                return
                                            }
                                            loadMoreTurnsIfNeeded(proxy: proxy)
                                        }
                                }

                                ForEach(displayTurns) { turn in
                                    EquatableLiveTurnCard(
                                        turn: turn,
                                        shouldAnimateResponse:
                                            liveFeedStore
                                            .shouldAnimateResponse(for: turn)
                                    ) {
                                        liveFeedStore
                                            .finishResponseAnimation(
                                                for: turn.id
                                            )
                                    }
                                        .equatable()
                                        .id(turn.id)
                                }
                            }

                            LiveWorkspaceFeedBottomMarker()
                                .frame(height: 16)
                                .id(Self.bottomMarkerID)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                    }
                    .defaultScrollAnchor(.bottom)
                    .coordinateSpace(name: LiveWorkspaceFeedScrollSpace.name)
                    .onAppear {
                        performInitialScrollIfNeeded(proxy: proxy)
                    }
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear {
                                    scrollMetrics.viewportHeight =
                                        geometry.size.height
                                    if didPerformInitialScroll {
                                        updateBottomState()
                                    } else {
                                        performInitialScrollIfNeeded(
                                            proxy: proxy
                                        )
                                    }
                                }
                                .onChange(of: geometry.size) {
                                    _, size in
                                    scrollMetrics.viewportHeight = size.height
                                    if !didPerformInitialScroll {
                                        performInitialScrollIfNeeded(
                                            proxy: proxy
                                        )
                                    } else if isAtBottom {
                                        scrollToLatest(
                                            proxy,
                                            animated: false
                                        )
                                    }
                                }
                        }
                    }
                    .onPreferenceChange(
                        LiveWorkspaceFeedBottomOffsetKey.self
                    ) { bottomOffset in
                        scrollMetrics.bottomMarkerOffset = bottomOffset
                        if didPerformInitialScroll {
                            updateBottomState()
                        } else {
                            performInitialScrollIfNeeded(
                                proxy: proxy
                            )
                        }
                    }
                    .onPreferenceChange(
                        LiveWorkspaceFeedStreamingHeightKey.self
                    ) { height in
                        let didGrow =
                            height
                                > scrollMetrics.streamingResponseHeight
                                    + 0.5
                        scrollMetrics.streamingResponseHeight = height
                        guard
                            didGrow,
                            didPerformInitialScroll,
                            isAtBottom
                        else {
                            return
                        }
                        scrollToLatest(proxy, animated: false)
                    }
                    .onChange(of: latestActivityUpdate) {
                        _, _ in
                        guard isAtBottom else {
                            return
                        }
                        scrollToLatest(proxy, animated: false)
                    }
                    .onChange(of: director.latestSubmittedCommandID) {
                        _, commandID in
                        guard commandID != nil else {
                            return
                        }
                        scrollToLatest(proxy, animated: false)
                    }
                    .onChange(of: director.latestStartedCommandID) {
                        _, commandID in
                        guard commandID != nil else {
                            return
                        }
                        scrollToLatest(proxy, animated: false)
                    }
                    .onChange(of: director.selectedCharacterID) {
                        oldCharacterID, newCharacterID in
                        guard
                            oldCharacterID == nil,
                            newCharacterID != nil
                        else {
                            return
                        }
                        pinToBottomAfterSettingsAppear(proxy: proxy)
                    }
                    .overlay(alignment: .bottom) {
                        Group {
                            if hasContentBelow {
                                jumpToLatestButton(proxy: proxy)
                                    .padding(.bottom, 12)
                                    .transition(
                                        .scale(scale: 0.82)
                                            .combined(with: .opacity)
                                    )
                            }
                        }
                        .animation(
                            .easeInOut(duration: 0.16),
                            value: hasContentBelow
                        )
                    }
                    .onDisappear {
                        scrollMetrics.bottomExitTask?.cancel()
                        scrollMetrics.bottomExitTask = nil
                        scrollMetrics.initialScrollTask?.cancel()
                        scrollMetrics.initialScrollTask = nil
                        scrollMetrics.selectionScrollTask?.cancel()
                        scrollMetrics.selectionScrollTask = nil
                    }
                }
            }
        }
    }

    private func scrollToLatest(
        _ proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        markAtBottom()
        DispatchQueue.main.async {
            guard animated else {
                proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
                return
            }
            withAnimation(.easeOut(duration: 0.20)) {
                proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
            }
        }
    }

    private func performInitialScrollIfNeeded(
        proxy: ScrollViewProxy
    ) {
        guard
            !didPerformInitialScroll,
            scrollMetrics.initialScrollTask == nil,
            scrollMetrics.viewportHeight > 0,
            scrollMetrics.bottomMarkerOffset > 0
        else {
            return
        }

        markAtBottom()
        scrollMetrics.initialScrollTask = Task { @MainActor in
            var stablePassCount = 0
            for _ in 0..<8 {
                guard !Task.isCancelled else {
                    return
                }
                proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(100))
                let distanceFromBottom = max(
                    0,
                    scrollMetrics.bottomMarkerOffset
                        - scrollMetrics.viewportHeight
                )
                if distanceFromBottom <= Self.bottomTolerance {
                    stablePassCount += 1
                    if stablePassCount >= 4 {
                        break
                    }
                } else {
                    stablePassCount = 0
                }
            }
            guard !Task.isCancelled else {
                return
            }
            markAtBottom()
            didPerformInitialScroll = true
            scrollMetrics.initialScrollTask = nil
        }
    }

    private func pinToBottomAfterSettingsAppear(
        proxy: ScrollViewProxy
    ) {
        scrollMetrics.selectionScrollTask?.cancel()
        markAtBottom()
        scrollMetrics.selectionScrollTask = Task { @MainActor in
            // 직원 선택 뒤 나타나는 설정 줄의 높이가 확정될 때까지 끝을 다시 맞춘다.
            for _ in 0..<5 {
                guard !Task.isCancelled else {
                    return
                }
                proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard !Task.isCancelled else {
                return
            }
            markAtBottom()
            scrollMetrics.selectionScrollTask = nil
        }
    }

    private func loadMoreTurnsIfNeeded(
        proxy: ScrollViewProxy
    ) {
        guard
            didPerformInitialScroll,
            canLoadOlderTurns,
            !isLoadingOlderTurns
        else {
            return
        }

        let readingAnchorID = displayTurns.first?.id
        let nextLimit = min(
            visibleTurnLimit + Self.pageSize,
            Self.maximumVisibleTurnCount,
            liveFeedStore.turns.count
        )
        guard nextLimit > visibleTurnLimit else {
            return
        }

        isLoadingOlderTurns = true
        visibleTurnLimit = nextLimit
        DispatchQueue.main.async {
            if let readingAnchorID {
                proxy.scrollTo(readingAnchorID, anchor: .top)
            }
            DispatchQueue.main.async {
                isLoadingOlderTurns = false
            }
        }
    }

    private func jumpToLatestButton(
        proxy: ScrollViewProxy
    ) -> some View {
        Button {
            scrollToLatest(proxy)
        } label: {
            Group {
                if isResponsePreparing {
                    LiveWorkspacePreparingDots()
                } else {
                    Image(systemName: "arrow.down")
                        .font(.system(size: 13, weight: .black))
                }
            }
            .foregroundStyle(DashboardPalette.accent)
            .frame(width: 32, height: 32)
            .background {
                Circle()
                    .fill(.ultraThinMaterial)
                    .overlay {
                        Circle()
                            .stroke(
                                DashboardPalette.accent.opacity(0.62),
                                lineWidth: 1.4
                            )
                    }
            }
            .shadow(
                color: DashboardPalette.accent.opacity(0.28),
                radius: 7,
                y: 3
            )
            .shadow(color: .black.opacity(0.12), radius: 3, y: 2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(
            isResponsePreparing
                ? "응답 준비 중, 맨 아래로 이동"
                : "맨 아래로 이동"
        )
        .help(
            isResponsePreparing
                ? "응답 준비 중 · 맨 아래로 이동"
                : "맨 아래로 이동"
        )
    }

    private var archivedTurnsNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "books.vertical")
            if canLoadOlderTurns {
                Text(
                    "위로 더 올리면 이전 "
                        + "\(min(Self.pageSize, hiddenTurnCount))건 추가"
                )
            } else {
                Text(
                    "이전 \(hiddenTurnCount)건은 대화 책꽂이에서 확인"
                )
            }
        }
        .font(.system(size: 10, weight: .bold))
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity)
        .frame(height: 30)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private func updateBottomState() {
        let distanceFromBottom = max(
            0,
            scrollMetrics.bottomMarkerOffset
                - scrollMetrics.viewportHeight
        )
        let contentRemainsBelow =
            distanceFromBottom > Self.bottomTolerance
        if hasContentBelow != contentRemainsBelow {
            hasContentBelow = contentRemainsBelow
        }
        if !contentRemainsBelow {
            markAtBottom()
            return
        }

        guard
            isAtBottom,
            scrollMetrics.bottomExitTask == nil
        else {
            return
        }
        scrollMetrics.bottomExitTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else {
                return
            }
            scrollMetrics.bottomExitTask = nil
            let currentDistance = max(
                0,
                scrollMetrics.bottomMarkerOffset
                    - scrollMetrics.viewportHeight
            )
            if currentDistance > Self.bottomTolerance {
                if isAtBottom {
                    isAtBottom = false
                }
            }
        }
    }

    private func markAtBottom() {
        scrollMetrics.bottomExitTask?.cancel()
        scrollMetrics.bottomExitTask = nil
        if hasContentBelow {
            hasContentBelow = false
        }
        if !isAtBottom {
            isAtBottom = true
        }
    }
}

private struct LiveWorkspacePreparingDots: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
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
        .frame(width: 20, height: 14)
    }
}

private enum LiveWorkspaceFeedScrollSpace {
    static let name = "live-workspace-feed"
}

private final class LiveWorkspaceFeedScrollMetrics {
    var bottomMarkerOffset = CGFloat.zero
    var viewportHeight = CGFloat.zero
    var streamingResponseHeight = CGFloat.zero
    var bottomExitTask: Task<Void, Never>?
    var initialScrollTask: Task<Void, Never>?
    var selectionScrollTask: Task<Void, Never>?
}

private struct LiveWorkspaceFeedBottomMarker: View {
    var body: some View {
        GeometryReader { geometry in
            Color.clear.preference(
                key: LiveWorkspaceFeedBottomOffsetKey.self,
                value: geometry.frame(
                    in: .named(LiveWorkspaceFeedScrollSpace.name)
                ).maxY
            )
        }
    }
}

private struct LiveWorkspaceFeedBottomOffsetKey: PreferenceKey {
    static var defaultValue = CGFloat.zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct LiveWorkspaceFeedStreamingHeightKey: PreferenceKey {
    static var defaultValue = CGFloat.zero

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value += nextValue()
    }
}

private struct EquatableLiveTurnCard: View, Equatable {
    let turn: LiveFeedTurn
    let shouldAnimateResponse: Bool
    let finishResponseAnimation: () -> Void

    static func == (
        lhs: EquatableLiveTurnCard,
        rhs: EquatableLiveTurnCard
    ) -> Bool {
        lhs.turn == rhs.turn
            && lhs.shouldAnimateResponse == rhs.shouldAnimateResponse
    }

    var body: some View {
        LiveTurnCard(
            turn: turn,
            shouldAnimateResponse: shouldAnimateResponse,
            finishResponseAnimation: finishResponseAnimation
        )
    }
}

private struct LiveTurnCard: View {
    let turn: LiveFeedTurn
    let shouldAnimateResponse: Bool
    let finishResponseAnimation: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var activitiesExpanded: Bool
    @State private var responseCopied: Bool

    init(
        turn: LiveFeedTurn,
        shouldAnimateResponse: Bool,
        finishResponseAnimation: @escaping () -> Void
    ) {
        self.turn = turn
        self.shouldAnimateResponse = shouldAnimateResponse
        self.finishResponseAnimation = finishResponseAnimation
        _activitiesExpanded = State(initialValue: false)
        _responseCopied = State(initialValue: false)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CharacterBadge(
                name: turn.characterName,
                characterID: turn.characterId,
                size: 38
            )

            VStack(alignment: .leading, spacing: 11) {
                metadata
                promptBlock

                if !turn.activities.isEmpty {
                    activityDisclosure
                }

                if !turn.response.isEmpty {
                    responseBlock
                } else if let error = turn.errorMessage {
                    errorBlock(error)
                }
            }
            .padding(14)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.72),
                in: RoundedRectangle(cornerRadius: 17, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 17, style: .continuous)
                    .stroke(Color.primary.opacity(0.07))
            }
        }
    }

    private var metadata: some View {
        HStack(spacing: 7) {
            Text(turn.characterName)
                .font(.system(size: 13, weight: .bold))

            if let backend = turn.backend {
                Text(backend.title)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)

                if let model = turn.model {
                    Text(backend.modelTitle(model))
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            } else {
                Text("이전 기록")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            if let effort = turn.effort {
                Text(effort)
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            statusBadge

            Text(
                turn.startedAt.formatted(
                    date: .omitted,
                    time: .shortened
                )
            )
            .font(.system(size: 10, weight: .medium))
            .foregroundStyle(.tertiary)
        }
    }

    private var promptBlock: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 2)
                .fill(DashboardPalette.accent.opacity(0.75))
                .frame(width: 3)
            Text(turn.prompt)
                .font(.system(size: 13, weight: .semibold))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(10)
        .background(
            DashboardPalette.accent.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }

    private var activityDisclosure: some View {
        DisclosureGroup(isExpanded: $activitiesExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(turn.activities) { activity in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: activityIcon(activity.kind))
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(activityColor(activity.kind))
                            .frame(width: 15)
                        Text(activity.text)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                        Spacer(minLength: 8)
                        Text(
                            activity.occurredAt.formatted(
                                date: .omitted,
                                time: .standard
                            )
                        )
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.top, 8)
        } label: {
            HStack(spacing: 6) {
                if turn.status.isRunning {
                    CoreAnimationDotsView(
                        dotSize: 2.5,
                        spacing: 1.4,
                        travel: 1.5,
                        color: .secondaryLabelColor,
                        isAnimated: !reduceMotion
                    )
                    .frame(width: 15, height: 10)
                    .accessibilityLabel("추론 중")
                } else {
                    Image(systemName: "list.bullet.indent")
                }
                Text("추론 및 진행 \(turn.activities.count)")
                    .font(.system(size: 11, weight: .bold))
            }
            .foregroundStyle(.secondary)
        }
        .tint(.secondary)
    }

    private var responseBlock: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Image(
                    systemName: turn.status.isRunning
                        ? "text.cursor"
                        : "checkmark.bubble.fill"
                )
                Text(
                    turn.status.isRunning
                        ? "작성 중인 응답"
                        : turn.needsInput
                        ? "답변 필요"
                        : "응답"
                )

                Spacer()

                Button {
                    copyResponse()
                } label: {
                    Label(
                        responseCopied ? "복사됨" : "복사",
                        systemImage:
                            responseCopied
                            ? "checkmark"
                            : "doc.on.doc"
                    )
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(
                        responseCopied
                            ? DashboardPalette.accent
                            : Color.secondary
                    )
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .background(
                        Color.primary.opacity(0.055),
                        in: Capsule()
                    )
                }
                .buttonStyle(.plain)
                .help(responseCopied ? "응답 복사됨" : "응답 복사")
                .accessibilityIdentifier("copyResponse-\(turn.id)")
            }
            .font(.system(size: 11, weight: .bold))
            .foregroundStyle(
                turn.needsInput
                    ? Color.orange
                    : DashboardPalette.accent
            )
            LiveTypingResponseView(
                turnID: turn.id,
                backend: turn.backend ?? turn.characterBackend,
                source: turn.response,
                animates: shouldAnimateResponse,
                isStreaming: shouldAnimateResponse,
                onFinishedTyping: finishResponseAnimation
            )
        }
        .padding(.top, 2)
    }

    private func copyResponse() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(turn.response, forType: .string)
        responseCopied = true

        Task {
            try? await Task.sleep(for: .seconds(1.4))
            if !Task.isCancelled {
                responseCopied = false
            }
        }
    }

    private func errorBlock(_ error: String) -> some View {
        Label(error, systemImage: "exclamationmark.triangle.fill")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.red.opacity(0.88))
            .textSelection(.enabled)
    }

    private var statusBadge: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(statusColor)
                .frame(width: 6, height: 6)
            Text(statusTitle)
        }
        .font(.system(size: 9, weight: .bold))
        .foregroundStyle(statusColor)
        .padding(.horizontal, 7)
        .padding(.vertical, 4)
        .background(
            statusColor.opacity(0.10),
            in: Capsule()
        )
    }

    private var statusTitle: String {
        switch turn.status {
        case .pending:
            "대기"
        case .running:
            "업무 중"
        case .completed:
            turn.needsInput ? "답변 필요" : "완료"
        case .failed:
            "중단"
        case .interrupted:
            "연결 종료"
        }
    }

    private var statusColor: Color {
        switch turn.status {
        case .pending, .running:
            DashboardPalette.accent
        case .completed:
            turn.needsInput ? .orange : .green
        case .failed, .interrupted:
            .red
        }
    }

    private func activityIcon(_ kind: String) -> String {
        switch kind {
        case "command":
            "terminal"
        case "tool":
            "wrench.and.screwdriver"
        case "message":
            "text.bubble"
        default:
            "brain.head.profile"
        }
    }

    private func activityColor(_ kind: String) -> Color {
        switch kind {
        case "command":
            Color.indigo
        case "tool":
            Color.orange
        case "message":
            DashboardPalette.accent
        default:
            Color.purple
        }
    }
}

private struct LiveTypingResponseView: View {
    let turnID: String
    let backend: AgentBackend
    let source: String
    let animates: Bool
    let isStreaming: Bool
    let onFinishedTyping: () -> Void

    private static let responseFontSize = CGFloat(14)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let animatesInitialSource: Bool

    init(
        turnID: String,
        backend: AgentBackend,
        source: String,
        animates: Bool,
        isStreaming: Bool,
        onFinishedTyping: @escaping () -> Void
    ) {
        self.turnID = turnID
        self.backend = backend
        self.source = source
        self.animates = animates
        self.isStreaming = isStreaming
        self.onFinishedTyping = onFinishedTyping
        animatesInitialSource =
            animates
                && LiveTypingAppearanceCache.shared
                    .shouldAnimateInitialSource(for: turnID)
    }

    var body: some View {
        Group {
            if isStreaming, backend == .codex {
                if reduceMotion {
                    ConversationMarkdownView(
                        source: source,
                        fontSize: Self.responseFontSize
                    )
                    .textSelection(.enabled)
                    .task { onFinishedTyping() }
                } else {
                    WaterfallResponseRevealView(
                        source: source,
                        fontSize: Self.responseFontSize,
                        onFinished: onFinishedTyping
                    )
                }
            } else if isStreaming {
                let segments = StreamingMarkdownSplitter.split(source)

                VStack(alignment: .leading, spacing: 9) {
                    // 더 바뀌지 않는 앞부분은 한 번만 렌더링한다.
                    if !segments.settledMarkdown.isEmpty {
                        ConversationMarkdownView(
                            source: segments.settledMarkdown,
                            fontSize: Self.responseFontSize
                        )
                        .textSelection(.enabled)
                    }

                    // 작성 중 블록은 줄이 완성될 때마다 Markdown으로 갱신한다.
                    if !segments.activeMarkdown.isEmpty {
                        ConversationMarkdownView(
                            source: segments.activeMarkdown,
                            fontSize: Self.responseFontSize
                        )
                        .textSelection(.enabled)
                    }

                    // 개행 전 마지막 조각만 평문으로 타자 출력한다.
                    if segments.openLine.isEmpty {
                        // 타자로 출력할 조각이 없으면 곧바로 완료로 알린다.
                        Color.clear
                            .frame(height: 0)
                            .task { onFinishedTyping() }
                    } else {
                        StreamingPlainTextView(
                            source: segments.openLine,
                            animates: animates && !reduceMotion,
                            animatesInitialSource:
                                animatesInitialSource && !reduceMotion,
                            fontSize: Self.responseFontSize,
                            lineSpacing: 3,
                            onFinishedTyping: onFinishedTyping
                        )
                        .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ConversationMarkdownView(
                    source: source,
                    fontSize: Self.responseFontSize
                )
                .textSelection(.enabled)
            }
        }
        .background {
            if isStreaming {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: LiveWorkspaceFeedStreamingHeightKey.self,
                        value: geometry.size.height
                    )
                }
            }
        }
    }
}

private struct WaterfallResponseRevealView: View {
    let source: String
    let fontSize: CGFloat
    let onFinished: () -> Void

    @State private var measuredHeight = CGFloat.zero
    @State private var revealHeight = CGFloat(1)
    @State private var revealingSource = ""
    @State private var isRevealing = true
    @State private var completionTask: Task<Void, Never>?

    var body: some View {
        ConversationMarkdownView(
            source: source,
            fontSize: fontSize
        )
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .background {
            GeometryReader { geometry in
                Color.clear.preference(
                    key: WaterfallResponseFullHeightKey.self,
                    value: geometry.size.height
                )
            }
        }
        .frame(
            height: isRevealing ? revealHeight : nil,
            alignment: .top
        )
        .clipped()
        .mask {
            if isRevealing {
                WaterfallResponseMask()
            } else {
                Rectangle().fill(.white)
            }
        }
        .onPreferenceChange(
            WaterfallResponseFullHeightKey.self
        ) { height in
            guard height > 0 else {
                return
            }
            measuredHeight = height
            beginRevealIfNeeded(height: height)
        }
        .onChange(of: source) {
            _, _ in
            completionTask?.cancel()
            revealingSource = ""
            isRevealing = true
            revealHeight = 1
            if measuredHeight > 0 {
                beginRevealIfNeeded(height: measuredHeight)
            }
        }
        .onDisappear {
            completionTask?.cancel()
            completionTask = nil
            onFinished()
        }
    }

    private func beginRevealIfNeeded(height: CGFloat) {
        guard revealingSource != source else {
            if
                isRevealing,
                abs(revealHeight - height) > 0.5
            {
                withAnimation(.easeOut(duration: 0.24)) {
                    revealHeight = height
                }
            }
            return
        }

        completionTask?.cancel()
        revealingSource = source
        isRevealing = true
        revealHeight = min(12, height)

        let duration = revealDuration(for: height)
        withAnimation(
            .timingCurve(
                0.18,
                0.72,
                0.24,
                1,
                duration: duration
            )
        ) {
            revealHeight = height
        }

        completionTask = Task { @MainActor in
            do {
                try await Task.sleep(
                    for: .milliseconds(Int(duration * 1_000))
                )
            } catch {
                return
            }
            isRevealing = false
            revealHeight = measuredHeight
            onFinished()
        }
    }

    private func revealDuration(for height: CGFloat) -> TimeInterval {
        min(1.8, max(0.72, TimeInterval(height / 520)))
    }
}

private struct WaterfallResponseMask: View {
    var body: some View {
        VStack(spacing: 0) {
            Color.white
            LinearGradient(
                colors: [
                    .white,
                    .white.opacity(0.72),
                    .clear,
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 24)
        }
    }
}

private struct WaterfallResponseFullHeightKey: PreferenceKey {
    static var defaultValue = CGFloat.zero

    static func reduce(
        value: inout CGFloat,
        nextValue: () -> CGFloat
    ) {
        value = max(value, nextValue())
    }
}

@MainActor
private final class LiveTypingAppearanceCache {
    static let shared = LiveTypingAppearanceCache()

    private let storage = NSCache<NSString, NSNumber>()

    private init() {
        storage.countLimit = 256
    }

    func shouldAnimateInitialSource(for turnID: String) -> Bool {
        let key = turnID as NSString
        guard storage.object(forKey: key) == nil else {
            return false
        }
        storage.setObject(NSNumber(value: true), forKey: key)
        return true
    }
}

struct CharacterBadge: View {
    let name: String
    let characterID: String
    let size: CGFloat

    var body: some View {
        CharacterAvatar(
            name: name,
            characterID: characterID,
            size: size
        )
    }
}

struct CharacterAvatar: View {
    let name: String
    let characterID: String
    let size: CGFloat

    private var avatarImage: NSImage? {
        CharacterAvatarImageCache.image(for: characterID)
    }

    private var framing: CharacterAvatarFraming {
        CharacterAvatarFraming.forCharacter(characterID)
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    DashboardPalette.characterAccent(for: characterID)
                        .opacity(0.15)
                )

            if let avatarImage {
                Image(nsImage: avatarImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .scaleEffect(framing.scale)
                    .offset(
                        y: size * (
                            framing.verticalOffset + 5.0 / 38.0
                        )
                    )
            } else {
                Text(String(name.prefix(1)))
                    .font(
                        .system(
                            size: size * 0.38,
                            weight: .bold,
                            design: .rounded
                        )
                    )
                    .foregroundStyle(.white)
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay {
            Circle()
                .stroke(.white.opacity(0.82), lineWidth: 2)
        }
        .shadow(
            color: DashboardPalette.characterAccent(for: characterID)
                .opacity(0.20),
            radius: 5,
            y: 2
        )
    }
}

private struct CharacterAvatarFraming {
    let scale: CGFloat
    let verticalOffset: CGFloat

    static func forCharacter(
        _ characterID: String
    ) -> CharacterAvatarFraming {
        switch OfficeCharacter(rawValue: characterID) {
        case .boss:
            .init(scale: 1.764, verticalOffset: 0.182)
        case .leftMan:
            .init(scale: 1.557, verticalOffset: 0.108)
        case .leftWoman:
            .init(scale: 1.620, verticalOffset: 0.080)
        case .rightWoman:
            .init(scale: 1.791, verticalOffset: 0.199)
        case .rightMan:
            .init(scale: 1.674, verticalOffset: 0.136)
        case nil:
            .init(scale: 1, verticalOffset: 0)
        }
    }
}

@MainActor
private enum CharacterAvatarImageCache {
    private static let images: [OfficeCharacter: NSImage] = Dictionary(
        uniqueKeysWithValues: OfficeCharacter.allCases.compactMap {
            character in
            guard
                let url = PixelOfficeAsset.avatarURL(for: character),
                let image = NSImage(contentsOf: url)
            else {
                return nil
            }
            return (character, image)
        }
    )

    static func image(for characterID: String) -> NSImage? {
        guard let character = OfficeCharacter(rawValue: characterID) else {
            return nil
        }
        return images[character]
    }
}

enum DashboardPalette {
    static let accent = Color(red: 0.13, green: 0.55, blue: 0.52)
    static let canvas = Color(red: 0.94, green: 0.945, blue: 0.955)

    static func characterAccent(for characterID: String) -> Color {
        switch characterID {
        case "boss":
            Color(red: 0.34, green: 0.29, blue: 0.52)
        case "left-man":
            Color(red: 0.19, green: 0.50, blue: 0.47)
        case "left-woman":
            Color(red: 0.80, green: 0.43, blue: 0.31)
        case "right-woman":
            Color(red: 0.56, green: 0.35, blue: 0.66)
        default:
            Color(red: 0.78, green: 0.57, blue: 0.22)
        }
    }
}

extension View {
    func officePanelStyle() -> some View {
        background(
            Color(nsColor: .windowBackgroundColor).opacity(0.94),
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.white.opacity(0.74))
        }
        .shadow(color: .black.opacity(0.075), radius: 18, y: 7)
    }
}
