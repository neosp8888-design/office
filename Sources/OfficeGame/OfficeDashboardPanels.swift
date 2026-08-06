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
            OfficeLocalization.string("대화 보관함")
        case .usage:
            OfficeLocalization.string("화이트보드")
        }
    }

    var subtitle: String {
        switch self {
        case .archive:
            OfficeLocalization.string("검색하고 빠르게 여는 직원 업무 기록")
        case .usage:
            OfficeLocalization.string("Codex와 Claude의 현재 사용 가능량")
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

enum UsageBoardLayout {
    static let singleColumnThreshold: CGFloat = 560

    static func usesSingleColumn(for width: CGFloat) -> Bool {
        width < singleColumnThreshold
    }
}

struct OfficeDetailPanel: View {
    let director: AgentDirector
    let selection: OfficeDetailSelection
    @State private var usageRefreshRequestID = UUID()
    @State private var usageIsRefreshing = false

    init(
        director: AgentDirector,
        selection: OfficeDetailSelection
    ) {
        self.director = director
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
                    HStack(spacing: 4) {
                        Text(selection.subtitle)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(.secondary)

                        if selection == .usage {
                            Button {
                                usageRefreshRequestID = UUID()
                            } label: {
                                if usageIsRefreshing {
                                    ProgressView()
                                        .controlSize(.mini)
                                } else {
                                    Image(systemName: "arrow.clockwise")
                                }
                            }
                            .buttonStyle(.borderless)
                            .disabled(usageIsRefreshing)
                            .accessibilityLabel("한도 새로고침")
                            .accessibilityValue(
                                usageIsRefreshing ? "새로고침 중" : ""
                            )
                            .help("한도 새로고침")
                        }
                    }
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
                    ArchiveShelfContent(director: director)
                case .usage:
                    UsageBoardContent(
                        refreshRequestID: usageRefreshRequestID,
                        isRefreshing: $usageIsRefreshing
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .officePanelStyle()
    }
}

private struct ArchiveShelfContent: View {
    @ObservedObject var director: AgentDirector
    @State private var searchText = ""
    @State private var selectedTurnID: String?
    @State private var turns: [LiveFeedTurn] = []
    @State private var totalTurnCount = 0
    @State private var errorMessage: String?
    @State private var isLoading = true
    @State private var isLoadingMore = false

    private static let pageSize = 12

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

                    if isLoading && turns.isEmpty {
                        ProgressView("기록을 불러오는 중")
                            .font(.system(size: 11, weight: .medium))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else if let errorMessage, turns.isEmpty {
                        ContentUnavailableView(
                            "기록을 불러오지 못했습니다",
                            systemImage: "exclamationmark.triangle",
                            description: Text(errorMessage)
                        )
                    } else if turns.isEmpty && normalizedSearchText.isEmpty {
                        ContentUnavailableView(
                            "아직 저장된 기록이 없습니다",
                            systemImage: "tray",
                            description: Text(
                                "직원에게 업무를 보내면 여기에 쌓입니다."
                            )
                        )
                    } else if turns.isEmpty {
                        ContentUnavailableView(
                            "검색 결과가 없습니다",
                            systemImage: "text.magnifyingglass",
                            description: Text(
                                "다른 이름이나 대화 내용으로 검색해보세요."
                            )
                        )
                    } else {
                        ScrollView {
                            VStack(spacing: 10) {
                                ArchiveRecordGrid(
                                    turns: turns
                                ) { turn in
                                    withAnimation(
                                        .easeInOut(duration: 0.16)
                                    ) {
                                        selectedTurnID = turn.id
                                    }
                                }

                                if turns.count < totalTurnCount {
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
        .task(id: normalizedSearchText) {
            if !normalizedSearchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else {
                return
            }
            await reload()
        }
    }

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(
                "전체 기록 검색 · 업무, 응답, 세션, 모델",
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

            if isLoading {
                ProgressView()
                    .controlSize(.mini)
                    .frame(width: 22, height: 22)
            } else {
                Text(OfficeLocalization.format("%d건", totalTurnCount))
                    .font(.system(size: 9, weight: .bold, design: .rounded))
                    .foregroundStyle(DashboardPalette.accent)
                    .padding(.horizontal, 7)
                    .frame(height: 22)
                    .background(
                        DashboardPalette.accent.opacity(0.09),
                        in: Capsule()
                    )
            }
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

    private var loadMoreButton: some View {
        Button {
            Task {
                await loadMore()
            }
        } label: {
            HStack(spacing: 7) {
                if isLoadingMore {
                    ProgressView()
                        .controlSize(.mini)
                } else {
                    Image(systemName: "chevron.down")
                    Text("다음 12건 보기")
                    Text("\(turns.count)/\(totalTurnCount)")
                        .foregroundStyle(.tertiary)
                }
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
        .disabled(isLoadingMore)
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
        return turns.first { $0.id == selectedTurnID }
    }

    private func reload() async {
        let query = normalizedSearchText
        isLoading = true
        errorMessage = nil
        do {
            let page = try await director.archiveFeed(
                query: query.isEmpty ? nil : query,
                limit: Self.pageSize,
                offset: 0
            )
            guard !Task.isCancelled, query == normalizedSearchText else {
                return
            }
            turns = page.turns
            totalTurnCount = page.total
        } catch {
            guard !Task.isCancelled, query == normalizedSearchText else {
                return
            }
            turns = []
            totalTurnCount = 0
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func loadMore() async {
        guard !isLoadingMore, turns.count < totalTurnCount else {
            return
        }
        let query = normalizedSearchText
        isLoadingMore = true
        defer {
            isLoadingMore = false
        }
        do {
            let page = try await director.archiveFeed(
                query: query.isEmpty ? nil : query,
                limit: Self.pageSize,
                offset: turns.count
            )
            guard query == normalizedSearchText else {
                return
            }
            let existingIDs = Set(turns.map(\.id))
            turns.append(contentsOf: page.turns.filter {
                !existingIDs.contains($0.id)
            })
            totalTurnCount = page.total
        } catch {
            guard query == normalizedSearchText else {
                return
            }
            errorMessage = error.localizedDescription
        }
    }
}

private struct UsageBoardContent: View {
    let refreshRequestID: UUID
    @Binding var isRefreshing: Bool
    @State private var snapshot: AIUsageSnapshot?
    @State private var errorMessage: String?

    var body: some View {
        Group {
            if let snapshot {
                GeometryReader { proxy in
                    ScrollView {
                        VStack(spacing: 12) {
                            if UsageBoardLayout.usesSingleColumn(
                                for: proxy.size.width
                            ) {
                                VStack(spacing: 12) {
                                    providerColumns(snapshot)
                                }
                            } else {
                                HStack(alignment: .top, spacing: 12) {
                                    providerColumns(snapshot)
                                }
                            }
                        }
                        .padding(14)
                    }
                }
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
        .task(id: refreshRequestID) {
            await refresh(force: true)
        }
    }

    @ViewBuilder
    private func providerColumns(
        _ snapshot: AIUsageSnapshot
    ) -> some View {
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

struct LiveWorkspaceFeedFollowState: Equatable {
    private(set) var isFollowingLatest = true

    mutating func userWillScroll() {
        isFollowingLatest = false
    }

    mutating func userDidScroll(
        distanceFromBottom: CGFloat,
        tolerance: CGFloat
    ) {
        isFollowingLatest = distanceFromBottom <= tolerance
    }

    mutating func resume() {
        isFollowingLatest = true
    }
}

struct LiveWorkspaceFeed: View, Equatable {
    @ObservedObject private var liveFeedStore: LiveFeedStore
    private let workspaceDirectory: String
    private let selectedCharacterID: OfficeCharacter?
    private let latestTerminalTurnID: String?
    private let latestSubmittedTurnID: String?
    private let latestStartedCommandID: UUID?
    private let fetchWorkspaceReview: WorkspaceReviewFetcher
    private let resolveWorkspaceReview: WorkspaceReviewResolver
    private let updateResponseFeedback:
        (String, TurnResponseFeedback?) async -> Void
    @State private var followState = LiveWorkspaceFeedFollowState()
    @State private var hasContentBelow = false
    @State private var scrollMetrics = LiveWorkspaceFeedScrollMetrics()
    @State private var visibleTurnLimit = Self.pageSize
    @State private var didPerformInitialScroll = false
    @State private var isLoadingOlderTurns = false

    private static let bottomTolerance = CGFloat(20)
    private static let topLoadThreshold = CGFloat(120)
    private static let bottomMarkerID = "live-workspace-feed-bottom"
    private static let pageSize = 10
    private static let maximumVisibleTurnCount = 30

    init(director: AgentDirector) {
        _liveFeedStore = ObservedObject(
            wrappedValue: director.liveFeedStore
        )
        workspaceDirectory = director.workspaceDirectory
        selectedCharacterID = director.selectedCharacterID
        latestTerminalTurnID = director.latestTerminalTurnID
        latestSubmittedTurnID = director.latestSubmittedTurnID
        latestStartedCommandID = director.latestStartedCommandID
        fetchWorkspaceReview = { turnID in
            try await director.fetchWorkspaceReview(turnID: turnID)
        }
        resolveWorkspaceReview = { turnID, decision in
            try await director.resolveWorkspaceReview(
                turnID: turnID,
                decision: decision
            )
        }
        updateResponseFeedback = { turnID, feedback in
            await director.updateResponseFeedback(
                turnID: turnID,
                feedback: feedback
            )
        }
    }

    static func == (
        lhs: LiveWorkspaceFeed,
        rhs: LiveWorkspaceFeed
    ) -> Bool {
        lhs.liveFeedStore === rhs.liveFeedStore
            && lhs.workspaceDirectory == rhs.workspaceDirectory
            && lhs.selectedCharacterID == rhs.selectedCharacterID
            && lhs.latestTerminalTurnID == rhs.latestTerminalTurnID
            && lhs.latestSubmittedTurnID == rhs.latestSubmittedTurnID
            && lhs.latestStartedCommandID == rhs.latestStartedCommandID
    }

    private var selectedTurns: [LiveFeedTurn] {
        guard let selectedCharacterID else {
            return []
        }
        return liveFeedStore.turns.filter {
            $0.characterId == selectedCharacterID.rawValue
        }
    }

    private var displayTurns: [LiveFeedTurn] {
        Array(
            selectedTurns.enumerated().compactMap { index, turn in
                index < visibleTurnLimit
                    || turn.status.isRunning
                    || turn.id == latestTerminalTurnID
                    ? turn
                    : nil
            }
            .reversed()
        )
    }

    private var hiddenTurnCount: Int {
        max(0, selectedTurns.count - displayTurns.count)
    }

    private var canLoadOlderTurns: Bool {
        visibleTurnLimit
            < min(
                Self.maximumVisibleTurnCount,
                selectedTurns.count
            )
    }

    private var latestActivityUpdate: Date? {
        selectedTurns.first?.updatedAt
    }

    private var initialLayoutRevision:
        [LiveWorkspaceFeedTurnRevision]
    {
        displayTurns.map { turn in
            LiveWorkspaceFeedTurnRevision(
                id: turn.id,
                updatedAt: turn.updatedAt,
                status: turn.status,
                activityCount: turn.activities.count,
                responseLength: turn.response.count,
                workspaceStatus: turn.workspace?.status,
                changedFileCount: turn.workspace?.changedFiles.count ?? 0
            )
        }
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
                            LiveWorkspaceFeedScrollObserver(
                                onScroll: { distanceFromTop in
                                    guard
                                        distanceFromTop
                                            <= Self.topLoadThreshold
                                    else {
                                        return
                                    }
                                    loadMoreTurnsIfNeeded(proxy: proxy)
                                },
                                onUserScrollStarted: {
                                    pauseFollowingLatest()
                                },
                                onUserScroll: { distanceFromBottom in
                                    followState.userDidScroll(
                                        distanceFromBottom:
                                            distanceFromBottom,
                                        tolerance: Self.bottomTolerance
                                    )
                                    updateBottomState()
                                }
                            )
                            .frame(height: 1)

                            VStack(spacing: 14) {
                                if hiddenTurnCount > 0 {
                                    archivedTurnsNotice
                                }

                                ForEach(displayTurns) { turn in
                                    EquatableLiveTurnCard(
                                        turn: turn,
                                        workspaceDirectory: workspaceDirectory,
                                        shouldAnimateResponse:
                                            liveFeedStore
                                            .shouldAnimateResponse(for: turn),
                                        fetchWorkspaceReview:
                                            fetchWorkspaceReview,
                                        resolveWorkspaceReview:
                                            resolveWorkspaceReview,
                                        updateResponseFeedback:
                                            updateResponseFeedback
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
                    .onChange(
                        of: liveFeedStore.isLoadingInitialFeed
                    ) { _, isLoading in
                        guard !isLoading else {
                            return
                        }
                        restartInitialScroll(proxy: proxy)
                    }
                    .onChange(of: initialLayoutRevision) { _, _ in
                        if !didPerformInitialScroll {
                            restartInitialScroll(proxy: proxy)
                        } else if followState.isFollowingLatest {
                            scheduleScrollToLatest(proxy)
                        }
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
                                    } else if followState.isFollowingLatest {
                                        scheduleScrollToLatest(proxy)
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
                            if
                                followState.isFollowingLatest,
                                distanceFromBottom
                                    > Self.bottomTolerance
                            {
                                scheduleScrollToLatest(proxy)
                            }
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
                            followState.isFollowingLatest
                        else {
                            return
                        }
                        scheduleScrollToLatest(proxy)
                    }
                    .onChange(of: latestActivityUpdate) {
                        _, _ in
                        guard followState.isFollowingLatest else {
                            return
                        }
                        scheduleScrollToLatest(proxy)
                    }
                    .onChange(of: latestSubmittedTurnID) {
                        _, turnID in
                        guard let turnID else {
                            return
                        }
                        revealSubmittedTurn(
                            turnID: turnID,
                            proxy: proxy
                        )
                    }
                    .onChange(of: latestStartedCommandID) {
                        _, commandID in
                        guard commandID != nil else {
                            return
                        }
                        scheduleScrollToLatest(proxy)
                    }
                    .onChange(of: selectedCharacterID) {
                        _, _ in
                        resetForSelectedCharacter(proxy: proxy)
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
                        scrollMetrics.followScrollTask?.cancel()
                        scrollMetrics.followScrollTask = nil
                        scrollMetrics.initialScrollTask?.cancel()
                        scrollMetrics.initialScrollTask = nil
                        scrollMetrics.submittedScrollTask?.cancel()
                        scrollMetrics.submittedScrollTask = nil
                    }
                }
            }
        }
    }

    private func scrollToLatest(
        _ proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        scrollMetrics.followScrollTask?.cancel()
        scrollMetrics.followScrollTask = nil
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

    private func scheduleScrollToLatest(
        _ proxy: ScrollViewProxy
    ) {
        guard followState.isFollowingLatest else {
            return
        }
        scrollMetrics.followScrollTask?.cancel()
        markAtBottom()
        scrollMetrics.followScrollTask = Task { @MainActor in
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(16))
            guard !Task.isCancelled else {
                return
            }
            proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
            scrollMetrics.followScrollTask = nil
        }
    }

    private func performInitialScrollIfNeeded(
        proxy: ScrollViewProxy
    ) {
        guard
            !didPerformInitialScroll,
            !liveFeedStore.isLoadingInitialFeed,
            !displayTurns.isEmpty,
            scrollMetrics.initialScrollTask == nil,
            scrollMetrics.viewportHeight > 0,
            scrollMetrics.bottomMarkerOffset > 0
        else {
            return
        }

        markAtBottom()
        scrollMetrics.initialScrollTask = Task { @MainActor in
            var stablePassCount = 0
            for pass in 0..<12 {
                guard !Task.isCancelled else {
                    return
                }
                proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(90))
                let distanceFromBottom = max(
                    0,
                    scrollMetrics.bottomMarkerOffset
                        - scrollMetrics.viewportHeight
                )
                if distanceFromBottom <= Self.bottomTolerance {
                    stablePassCount += 1
                    if pass >= 6, stablePassCount >= 4 {
                        break
                    }
                } else {
                    stablePassCount = 0
                }
            }
            guard !Task.isCancelled else {
                return
            }
            proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
            await Task.yield()
            markAtBottom()
            didPerformInitialScroll = true
            scrollMetrics.initialScrollTask = nil
        }
    }

    private func restartInitialScroll(proxy: ScrollViewProxy) {
        guard !didPerformInitialScroll else {
            return
        }
        scrollMetrics.initialScrollTask?.cancel()
        scrollMetrics.initialScrollTask = nil
        DispatchQueue.main.async {
            performInitialScrollIfNeeded(proxy: proxy)
        }
    }

    private func resetForSelectedCharacter(
        proxy: ScrollViewProxy
    ) {
        visibleTurnLimit = Self.pageSize
        isLoadingOlderTurns = false
        didPerformInitialScroll = false
        scrollMetrics.initialScrollTask?.cancel()
        scrollMetrics.initialScrollTask = nil
        scrollMetrics.submittedScrollTask?.cancel()
        scrollMetrics.submittedScrollTask = nil
        markAtBottom()
        DispatchQueue.main.async {
            performInitialScrollIfNeeded(proxy: proxy)
        }
    }

    private func revealSubmittedTurn(
        turnID: String,
        proxy: ScrollViewProxy
    ) {
        scrollMetrics.followScrollTask?.cancel()
        scrollMetrics.followScrollTask = nil
        scrollMetrics.submittedScrollTask?.cancel()
        markAtBottom()
        scrollMetrics.submittedScrollTask = Task { @MainActor in
            for _ in 0..<10 {
                guard !Task.isCancelled else {
                    return
                }
                await Task.yield()
                proxy.scrollTo(turnID, anchor: .bottom)
                proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(40))
            }
            guard !Task.isCancelled else {
                return
            }
            proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
            markAtBottom()
            scrollMetrics.submittedScrollTask = nil
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
            selectedTurns.count
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
        let contentRemainsBelow =
            distanceFromBottom > Self.bottomTolerance
        if hasContentBelow != contentRemainsBelow {
            hasContentBelow = contentRemainsBelow
        }
    }

    private var distanceFromBottom: CGFloat {
        max(
            0,
            scrollMetrics.bottomMarkerOffset
                - scrollMetrics.viewportHeight
        )
    }

    private func markAtBottom() {
        followState.resume()
        if hasContentBelow {
            hasContentBelow = false
        }
    }

    private func pauseFollowingLatest() {
        followState.userWillScroll()
        scrollMetrics.followScrollTask?.cancel()
        scrollMetrics.followScrollTask = nil
        scrollMetrics.submittedScrollTask?.cancel()
        scrollMetrics.submittedScrollTask = nil
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

private struct LiveWorkspaceFeedTurnRevision: Equatable {
    let id: String
    let updatedAt: Date
    let status: LiveTurnStatus
    let activityCount: Int
    let responseLength: Int
    let workspaceStatus: WorkspaceReviewStatus?
    let changedFileCount: Int
}

private final class LiveWorkspaceFeedScrollMetrics {
    var bottomMarkerOffset = CGFloat.zero
    var viewportHeight = CGFloat.zero
    var streamingResponseHeight = CGFloat.zero
    var followScrollTask: Task<Void, Never>?
    var initialScrollTask: Task<Void, Never>?
    var submittedScrollTask: Task<Void, Never>?
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

private struct LiveWorkspaceFeedScrollObserver: NSViewRepresentable {
    let onScroll: (CGFloat) -> Void
    let onUserScrollStarted: () -> Void
    let onUserScroll: (CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onScroll: onScroll,
            onUserScrollStarted: onUserScrollStarted,
            onUserScroll: onUserScroll
        )
    }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.onHierarchyChange = {
            [weak view, weak coordinator = context.coordinator] in
            coordinator?.attach(to: view?.enclosingScrollView)
        }
        return view
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {
        context.coordinator.onScroll = onScroll
        context.coordinator.onUserScrollStarted = onUserScrollStarted
        context.coordinator.onUserScroll = onUserScroll
        context.coordinator.attach(to: nsView.enclosingScrollView)
    }

    static func dismantleNSView(
        _ nsView: AttachmentView,
        coordinator: Coordinator
    ) {
        nsView.onHierarchyChange = nil
        coordinator.detach()
    }

    final class Coordinator {
        var onScroll: (CGFloat) -> Void
        var onUserScrollStarted: () -> Void
        var onUserScroll: (CGFloat) -> Void
        private weak var scrollView: NSScrollView?
        private var boundsObserver: NSObjectProtocol?
        private var liveScrollStartObserver: NSObjectProtocol?
        private var liveScrollObserver: NSObjectProtocol?

        init(
            onScroll: @escaping (CGFloat) -> Void,
            onUserScrollStarted: @escaping () -> Void,
            onUserScroll: @escaping (CGFloat) -> Void
        ) {
            self.onScroll = onScroll
            self.onUserScrollStarted = onUserScrollStarted
            self.onUserScroll = onUserScroll
        }

        func attach(to scrollView: NSScrollView?) {
            guard self.scrollView !== scrollView else {
                return
            }
            detach()
            guard let scrollView else {
                return
            }
            self.scrollView = scrollView
            scrollView.contentView.postsBoundsChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.reportDistanceFromTop()
            }
            liveScrollStartObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.onUserScrollStarted()
            }
            liveScrollObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                self?.reportUserDistanceFromBottom()
            }
            DispatchQueue.main.async { [weak self] in
                self?.reportDistanceFromTop()
            }
        }

        func detach() {
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let liveScrollStartObserver {
                NotificationCenter.default.removeObserver(
                    liveScrollStartObserver
                )
            }
            if let liveScrollObserver {
                NotificationCenter.default.removeObserver(liveScrollObserver)
            }
            boundsObserver = nil
            liveScrollStartObserver = nil
            liveScrollObserver = nil
            scrollView = nil
        }

        private func reportDistanceFromTop() {
            guard
                let scrollView,
                let documentView = scrollView.documentView
            else {
                return
            }
            let scrollableHeight = max(
                0,
                documentView.bounds.height
                    - scrollView.contentView.bounds.height
            )
            let scrollFraction = CGFloat(
                scrollView.verticalScroller?.floatValue ?? 0
            )
            onScroll(scrollFraction * scrollableHeight)
        }

        private func reportUserDistanceFromBottom() {
            guard
                let scrollView,
                let documentView = scrollView.documentView
            else {
                return
            }
            let scrollableHeight = max(
                0,
                documentView.bounds.height
                    - scrollView.contentView.bounds.height
            )
            let scrollFraction = CGFloat(
                scrollView.verticalScroller?.floatValue ?? 0
            )
            onUserScroll((1 - scrollFraction) * scrollableHeight)
        }
    }

    final class AttachmentView: NSView {
        var onHierarchyChange: (() -> Void)?

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            onHierarchyChange?()
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            onHierarchyChange?()
        }
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
    let workspaceDirectory: String
    let shouldAnimateResponse: Bool
    let fetchWorkspaceReview: WorkspaceReviewFetcher
    let resolveWorkspaceReview: WorkspaceReviewResolver
    let updateResponseFeedback:
        (String, TurnResponseFeedback?) async -> Void
    let finishResponseAnimation: () -> Void

    static func == (
        lhs: EquatableLiveTurnCard,
        rhs: EquatableLiveTurnCard
    ) -> Bool {
        lhs.turn == rhs.turn
            && lhs.workspaceDirectory == rhs.workspaceDirectory
            && lhs.shouldAnimateResponse == rhs.shouldAnimateResponse
    }

    var body: some View {
        LiveTurnCard(
            turn: turn,
            workspaceDirectory: workspaceDirectory,
            shouldAnimateResponse: shouldAnimateResponse,
            fetchWorkspaceReview: fetchWorkspaceReview,
            resolveWorkspaceReview: resolveWorkspaceReview,
            updateResponseFeedback: updateResponseFeedback,
            finishResponseAnimation: finishResponseAnimation
        )
    }
}

struct LiveTurnPromptBlock: View {
    let presentation: TaskPromptPresentation

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            if !presentation.text.isEmpty {
                Text(presentation.text)
                    .font(.system(size: 13, weight: .semibold))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if !presentation.attachments.isEmpty {
                TaskPromptAttachmentList(
                    attachments: presentation.attachments
                )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.leading, 11)
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(DashboardPalette.accent.opacity(0.75))
                .frame(width: 3)
        }
        .padding(10)
        .background(
            DashboardPalette.accent.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
    }
}

private struct LiveTurnCard: View {
    let turn: LiveFeedTurn
    let workspaceDirectory: String
    let shouldAnimateResponse: Bool
    let fetchWorkspaceReview: WorkspaceReviewFetcher
    let resolveWorkspaceReview: WorkspaceReviewResolver
    let updateResponseFeedback:
        (String, TurnResponseFeedback?) async -> Void
    let finishResponseAnimation: () -> Void
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            CharacterBadge(
                name: OfficeLocalization.string(turn.characterName),
                characterID: turn.characterId,
                size: 38
            )

            VStack(alignment: .leading, spacing: 11) {
                metadata
                promptBlock

                if
                    turn.status.isRunning
                        || !turn.activities.isEmpty
                        || !turn.response.isEmpty
                {
                    switch effectiveBackend {
                    case .codex:
                        codexTranscript
                    case .claude:
                        claudeTranscript
                    }
                }

                if let warning = turn.responseSourceWarning, !warning.isEmpty {
                    ResponseSourceWarningView(message: warning)
                }

                if !turn.responseSources.isEmpty {
                    ResponseSourceList(
                        sources: turn.responseSources,
                        workspaceDirectory: effectiveWorkspaceDirectory
                    )
                }

                if let workspace = turn.workspace,
                    workspace.status.showsReviewPanel
                {
                    WorkspaceReviewPanel(
                        turnID: turn.id,
                        workspace: workspace,
                        fetchReview: fetchWorkspaceReview,
                        resolveReview: resolveWorkspaceReview
                    )
                }

                if let error = turn.errorMessage,
                    turn.response.isEmpty
                        || turn.status == .failed
                        || turn.status == .interrupted
                {
                    errorBlock(error)
                }

                if turn.status.isRunning || turn.endedAt != nil {
                    LiveTurnElapsedStatusView(
                        startedAt: turn.startedAt,
                        endedAt: turn.endedAt,
                        status: turn.status,
                        estimatedCostUsd: turn.estimatedCostUsd,
                        sessionContext: turn.sessionContext
                    )
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .animation(
                .easeOut(duration: 0.22),
                value: turn.response.isEmpty
            )
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
            Text(OfficeLocalization.string(turn.characterName))
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

            Text(agentExecutionModeTitle(turn.fastMode))
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(
                    turn.fastMode == true
                        ? DashboardPalette.accent
                        : Color(nsColor: .secondaryLabelColor)
                )

            Spacer()

            if !turn.status.isRunning {
                statusBadge
            }

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
        LiveTurnPromptBlock(presentation: promptPresentation)
    }

    private var claudeTranscript: some View {
        ClaudeTranscriptView(
            turnID: turn.id,
            workspaceDirectory: effectiveWorkspaceDirectory,
            activities: turn.activities,
            response: turn.response,
            responseUpdatedAt: turn.updatedAt,
            isRunning: turn.status.isRunning,
            isCompleted: turn.status == .completed,
            needsInput: turn.needsInput,
            animatesResponse: shouldAnimateResponse,
            responseFeedback: turn.feedback,
            updateResponseFeedback: { feedback in
                await updateResponseFeedback(turn.id, feedback)
            },
            onResponsePresented: finishResponseAnimation
        )
    }

    private var codexTranscript: some View {
        CodexTranscriptView(
            turnID: turn.id,
            workspaceDirectory: effectiveWorkspaceDirectory,
            activities: turn.activities,
            response: turn.response,
            responseUpdatedAt: turn.updatedAt,
            isRunning: turn.status.isRunning,
            isCompleted: turn.status == .completed,
            needsInput: turn.needsInput,
            animatesResponse: shouldAnimateResponse,
            responseFeedback: turn.feedback,
            updateResponseFeedback: { feedback in
                await updateResponseFeedback(turn.id, feedback)
            },
            onResponsePresented: finishResponseAnimation
        )
    }

    private var effectiveBackend: AgentBackend {
        turn.backend ?? turn.characterBackend
    }

    private var promptPresentation: TaskPromptPresentation {
        TaskPromptPresentation(prompt: turn.prompt)
    }

    private var effectiveWorkspaceDirectory: String {
        turn.workspace?.fileBaseDirectory(
            fallback: turn.conversationWorkdir ?? workspaceDirectory
        )
            ?? turn.conversationWorkdir
            ?? workspaceDirectory
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
            OfficeLocalization.string("대기")
        case .running:
            OfficeLocalization.string("업무 중")
        case .completed:
            turn.needsInput
                ? OfficeLocalization.string("답변 필요")
                : OfficeLocalization.string("완료")
        case .failed:
            OfficeLocalization.string("중단")
        case .interrupted:
            OfficeLocalization.string("연결 종료")
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

}

private struct LiveTurnElapsedStatusView: View {
    let startedAt: Date
    let endedAt: Date?
    let status: LiveTurnStatus
    let estimatedCostUsd: Double?
    let sessionContext: SessionContextUsage?

    @ViewBuilder
    var body: some View {
        VStack(alignment: .trailing, spacing: 2) {
            if status.isRunning {
                TimelineView(.periodic(from: .now, by: 5)) { context in
                    Text(OfficeLocalization.format(
                        "%@째 진행 중",
                        elapsedText(at: context.date)
                    ))
                        .font(statusFont)
                        .foregroundStyle(DashboardPalette.accent)
                        .accessibilityLabel(
                            OfficeLocalization.format(
                                "%@째 진행 중",
                                elapsedText(at: context.date)
                            )
                        )
                }
            } else if let endedAt {
                Text(OfficeLocalization.format(
                    "%@에 %@",
                    elapsedText(at: endedAt),
                    terminalTitle
                ))
                    .font(statusFont)
                    .foregroundStyle(terminalColor)
                    .accessibilityLabel(
                        OfficeLocalization.format(
                            "%@에 %@",
                            elapsedText(at: endedAt),
                            terminalTitle
                        )
                    )

                if let estimatedCostUsd {
                    Text(estimatedTokenCostText(estimatedCostUsd))
                        .font(supplementFont)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel(
                            estimatedTokenCostText(estimatedCostUsd)
                        )
                }

                if let sessionContext {
                    Text(sessionContextRemainingText(sessionContext))
                        .font(supplementFont)
                        .foregroundStyle(
                            sessionContextColor(sessionContext)
                        )
                        .accessibilityLabel(
                            sessionContextRemainingText(sessionContext)
                        )
                }
            }
        }
    }

    private var supplementFont: Font {
        .system(size: 9.5, weight: .medium, design: .monospaced)
    }

    private func sessionContextColor(
        _ usage: SessionContextUsage
    ) -> Color {
        if usage.remainingRatio <= 0.1 {
            return .red
        }
        if usage.remainingRatio <= 0.25 {
            return .orange
        }
        return .secondary
    }

    private var statusFont: Font {
        .system(
            size: 10.5,
            weight: .bold,
            design: .monospaced
        )
    }

    private var terminalTitle: String {
        switch status {
        case .completed:
            OfficeLocalization.string("완료")
        case .failed:
            OfficeLocalization.string("실패")
        case .interrupted:
            OfficeLocalization.string("중단")
        case .pending, .running:
            OfficeLocalization.string("진행 중")
        }
    }

    private var terminalColor: Color {
        switch status {
        case .completed:
            .green
        case .failed, .interrupted:
            .red
        case .pending, .running:
            DashboardPalette.accent
        }
    }

    private func elapsedText(at date: Date) -> String {
        let seconds = max(0, Int(date.timeIntervalSince(startedAt)))
        if seconds < 60 {
            return OfficeLocalization.format("%d초", seconds)
        }

        let minutes = seconds / 60
        if minutes < 60 {
            return OfficeLocalization.format(
                "%d분 %d초",
                minutes,
                seconds % 60
            )
        }

        return OfficeLocalization.format(
            "%d시간 %d분",
            minutes / 60,
            minutes % 60
        )
    }
}

func estimatedTokenCostText(_ costUsd: Double) -> String {
    let precision = costUsd < 0.0001 ? 8 : costUsd < 1 ? 6 : 4
    return OfficeLocalization.format(
        "토큰 환산 비용(추정) %@",
        String(format: "$%.\(precision)f", costUsd)
    )
}

func sessionContextRemainingText(_ usage: SessionContextUsage) -> String {
    let percent = String(
        format: "%.1f",
        usage.remainingRatio * 100
    )
    return OfficeLocalization.format(
        "컨텍스트 잔량 %@ / %@ (%@%%)",
        groupedTokenCount(usage.remainingTokens),
        groupedTokenCount(usage.limitTokens),
        percent
    )
}

private func groupedTokenCount(_ value: Int) -> String {
    let digits = Array(String(max(0, value)))
    var grouped: [String] = []
    var index = digits.count
    while index > 3 {
        grouped.insert(String(digits[(index - 3)..<index]), at: 0)
        index -= 3
    }
    grouped.insert(String(digits[0..<index]), at: 0)
    return grouped.joined(separator: ",")
}

struct EquatableLiveTypingResponseView: View, Equatable {
    let turnID: String
    let backend: AgentBackend
    let source: String
    let fileBaseDirectory: String?
    let animates: Bool
    let isStreaming: Bool
    let onFinishedTyping: () -> Void

    static func == (
        lhs: EquatableLiveTypingResponseView,
        rhs: EquatableLiveTypingResponseView
    ) -> Bool {
        lhs.turnID == rhs.turnID
            && lhs.backend == rhs.backend
            && lhs.source == rhs.source
            && lhs.fileBaseDirectory == rhs.fileBaseDirectory
            && lhs.animates == rhs.animates
            && lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        LiveTypingResponseView(
            turnID: turnID,
            backend: backend,
            source: source,
            fileBaseDirectory: fileBaseDirectory,
            animates: animates,
            isStreaming: isStreaming,
            onFinishedTyping: onFinishedTyping
        )
    }
}

struct LiveTypingResponseView: View {
    let turnID: String
    let backend: AgentBackend
    let source: String
    let fileBaseDirectory: String?
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
        fileBaseDirectory: String? = nil,
        animates: Bool,
        isStreaming: Bool,
        onFinishedTyping: @escaping () -> Void
    ) {
        self.turnID = turnID
        self.backend = backend
        self.source = source
        self.fileBaseDirectory = fileBaseDirectory
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
                        fontSize: Self.responseFontSize,
                        fileBaseDirectory: fileBaseDirectory
                    )
                    .textSelection(.enabled)
                    .task { onFinishedTyping() }
                } else {
                    WaterfallResponseRevealView(
                        source: source,
                        fontSize: Self.responseFontSize,
                        fileBaseDirectory: fileBaseDirectory,
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
                            fontSize: Self.responseFontSize,
                            fileBaseDirectory: fileBaseDirectory
                        )
                        .textSelection(.enabled)
                    }

                    // 작성 중 블록은 줄이 완성될 때마다 Markdown으로 갱신한다.
                    if !segments.activeMarkdown.isEmpty {
                        ConversationMarkdownView(
                            source: segments.activeMarkdown,
                            fontSize: Self.responseFontSize,
                            fileBaseDirectory: fileBaseDirectory
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
                    fontSize: Self.responseFontSize,
                    fileBaseDirectory: fileBaseDirectory
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

private struct WaterfallResponseSegment: Identifiable, Equatable {
    let id = UUID()
    let source: String
}

struct WaterfallResponseRevealView: View {
    let source: String
    let fontSize: CGFloat
    let fileBaseDirectory: String?
    let onFinished: () -> Void

    @State private var segments: [WaterfallResponseSegment]
    @State private var cumulativeSource: String
    @State private var revealingSegmentID: UUID?

    init(
        source: String,
        fontSize: CGFloat,
        fileBaseDirectory: String? = nil,
        onFinished: @escaping () -> Void
    ) {
        self.source = source
        self.fontSize = fontSize
        self.fileBaseDirectory = fileBaseDirectory
        self.onFinished = onFinished

        let initialSegment = WaterfallResponseSegment(source: source)
        _segments = State(initialValue: [initialSegment])
        _cumulativeSource = State(initialValue: source)
        _revealingSegmentID = State(initialValue: initialSegment.id)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(segments) { segment in
                if segment.id == revealingSegmentID {
                    WaterfallResponseSegmentView(
                        animationID: segment.id,
                        source: segment.source,
                        fontSize: fontSize,
                        fileBaseDirectory: fileBaseDirectory
                    ) {
                        finishReveal(for: segment.id)
                    }
                } else {
                    ConversationMarkdownView(
                        source: segment.source,
                        fontSize: fontSize,
                        fileBaseDirectory: fileBaseDirectory
                    )
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: source) { _, updatedSource in
            appendNewSource(updatedSource)
        }
    }

    private func appendNewSource(_ updatedSource: String) {
        guard updatedSource != cumulativeSource else {
            return
        }

        guard updatedSource.hasPrefix(cumulativeSource) else {
            let replacement = WaterfallResponseSegment(
                source: updatedSource
            )
            segments = [replacement]
            cumulativeSource = updatedSource
            revealingSegmentID = replacement.id
            return
        }

        let suffix = String(
            updatedSource.dropFirst(cumulativeSource.count)
        )
        cumulativeSource = updatedSource
        guard !suffix.trimmingCharacters(
            in: .whitespacesAndNewlines
        ).isEmpty else {
            return
        }

        let segment = WaterfallResponseSegment(source: suffix)
        segments.append(segment)
        revealingSegmentID = segment.id
    }

    private func finishReveal(for segmentID: UUID) {
        guard revealingSegmentID == segmentID else {
            return
        }
        revealingSegmentID = nil
        onFinished()
    }
}

private struct WaterfallResponseSegmentView: View {
    let animationID: UUID
    let source: String
    let fontSize: CGFloat
    let fileBaseDirectory: String?
    let onFinished: () -> Void

    var body: some View {
        ConversationMarkdownView(
            source: source,
            fontSize: fontSize,
            fileBaseDirectory: fileBaseDirectory
        )
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
        .mask {
            CoreAnimationWaterfallMaskView(
                animationID: animationID,
                onFinished: onFinished
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onDisappear {
            onFinished()
        }
    }
}

// Markdown은 고정한 채 하나의 마스크 위치만 움직여 렌더링 부하를 제한한다.
enum CodexWaterfallRevealPacing {
    static let startDelayMilliseconds = 40
    static let minimumDuration = TimeInterval(1.35)
    static let maximumDuration = TimeInterval(2.8)
    static let pointsPerSecond = CGFloat(320)
    static let maximumFeatherHeight = CGFloat(72)
    static let featherHeightFraction = CGFloat(0.48)
    static let pendingContentOpacity = Double(0.12)

    static func revealDuration(
        forContentHeight height: CGFloat
    ) -> TimeInterval {
        min(
            maximumDuration,
            max(
                minimumDuration,
                TimeInterval(max(0, height) / pointsPerSecond)
            )
        )
    }

    static func featherHeight(
        forVisibleHeight height: CGFloat
    ) -> CGFloat {
        guard height > 0 else {
            return 0
        }
        return min(
            maximumFeatherHeight,
            max(1, height * featherHeightFraction)
        )
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

    static func canvas(isNight: Bool) -> Color {
        isNight
            ? Color(red: 0.065, green: 0.073, blue: 0.09)
            : Color(red: 0.94, green: 0.945, blue: 0.955)
    }

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

private struct OfficePanelStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme

    func body(content: Content) -> some View {
        content
            .background(
                Color(nsColor: .windowBackgroundColor).opacity(0.94),
                in: RoundedRectangle(
                    cornerRadius: 20,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(
                    cornerRadius: 20,
                    style: .continuous
                )
                .stroke(
                    colorScheme == .dark
                        ? Color.white.opacity(0.12)
                        : Color.white.opacity(0.74)
                )
            }
            .shadow(
                color: .black.opacity(
                    colorScheme == .dark ? 0.28 : 0.075
                ),
                radius: 18,
                y: 7
            )
    }
}

extension View {
    func officePanelStyle() -> some View {
        modifier(OfficePanelStyle())
    }
}
