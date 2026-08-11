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
    let director: AgentDirector
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
            fiveHourResetAt: snapshot.claudeFiveHourResetAt,
            weekly: snapshot.claudeWeekly,
            weeklyResetAt: snapshot.claudeWeeklyResetAt,
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
            fiveHourResetAt: snapshot.codexFiveHourResetAt,
            weekly: snapshot.codexWeekly,
            weeklyResetAt: snapshot.codexWeeklyResetAt,
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
            snapshot = try await CodexBarUsageReader.fetch(
                force: force,
                scope: .limitsAndActivity
            )
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
    let fiveHourResetAt: Date?
    let weekly: Int?
    let weeklyResetAt: Date?
    let plan: String?
    let activity: AIUsageActivitySnapshot?
    let tint: Color

    var body: some View {
        VStack(spacing: 10) {
            UsageProviderCard(
                name: name,
                icon: icon,
                fiveHour: fiveHour,
                fiveHourResetAt: fiveHourResetAt,
                weekly: weekly,
                weeklyResetAt: weeklyResetAt,
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
    let fiveHourResetAt: Date?
    let weekly: Int?
    let weeklyResetAt: Date?
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
            UsageMeter(
                label: "5시간",
                value: fiveHour,
                resetAt: fiveHourResetAt,
                tint: tint
            )
            UsageMeter(
                label: "7일",
                value: weekly,
                resetAt: weeklyResetAt,
                tint: tint
            )
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
    let resetAt: Date?
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                    .font(
                        .system(size: 10, weight: .bold, design: .rounded)
                    )
                    .frame(width: 34, alignment: .trailing)
            }

            if let reset = usageResetTimeText(resetAt) {
                Label("초기화 \(reset)", systemImage: "clock.arrow.circlepath")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
    }
}

struct LiveWorkspaceFeedFollowState: Equatable {
    private(set) var isFollowingLatest = true

    mutating func userWillScroll() {
        guard isFollowingLatest else {
            return
        }
        isFollowingLatest = false
    }

    mutating func userDidScroll(
        distanceFromBottom: CGFloat,
        tolerance: CGFloat
    ) {
        let shouldFollowLatest = distanceFromBottom <= tolerance
        guard isFollowingLatest != shouldFollowLatest else {
            return
        }
        isFollowingLatest = shouldFollowLatest
    }

    mutating func resume() {
        guard !isFollowingLatest else {
            return
        }
        isFollowingLatest = true
    }
}

enum LiveWorkspaceFeedContentRevisionAction: Equatable {
    case settleInitialAnchor
    case followLatest
    case revealContentBelow
}

struct LiveWorkspaceFeedContentRevisionPolicy: Equatable {
    static func action(
        didPerformInitialScroll: Bool,
        isFollowingLatest: Bool
    ) -> LiveWorkspaceFeedContentRevisionAction {
        guard didPerformInitialScroll else {
            return .settleInitialAnchor
        }
        return isFollowingLatest ? .followLatest : .revealContentBelow
    }
}

struct LiveWorkspaceFeedPagingPolicy: Equatable {
    // 직원 전환 때 NSHostingView를 새로 만드는 CPU 방어는 유지하되,
    // 첫 mount에서 과거 10턴의 Markdown과 활동 트리를 한꺼번에 만들지
    // 않는다. 최신 대화 두 건을 먼저 안정적으로 표시하고 사용자가
    // 위로 올릴 때 기존 단위대로 과거 기록을 추가한다.
    static let initialVisibleTurnCount = 2
    static let pageSize = 10
    static let maximumVisibleTurnCount = 30

    static func includesTurn(
        at index: Int,
        visibleTurnLimit: Int,
        isRunning: Bool,
        isLatestTerminalTurn: Bool
    ) -> Bool {
        index < visibleTurnLimit
            || isRunning
            || isLatestTerminalTurn
    }

    static func nextVisibleTurnLimit(
        current: Int,
        total: Int
    ) -> Int {
        min(
            current + pageSize,
            maximumVisibleTurnCount,
            total
        )
    }
}

struct LiveWorkspaceFeedScrollPolicy: Equatable {
    static let submittedMaximumAttempts = 3
    static let stablePassesRequired = 2

    private(set) var stablePassCount = 0

    mutating func shouldStop(
        distanceFromBottom: CGFloat,
        tolerance: CGFloat
    ) -> Bool {
        if distanceFromBottom <= tolerance {
            stablePassCount += 1
        } else {
            stablePassCount = 0
        }
        return stablePassCount >= Self.stablePassesRequired
    }
}

struct LiveWorkspaceFeedTopLoadGate: Equatable {
    private(set) var didLoadDuringCurrentScroll = false

    mutating func userScrollStarted() {
        didLoadDuringCurrentScroll = false
    }

    mutating func shouldLoad(
        distanceFromTop: CGFloat,
        threshold: CGFloat,
        isProgrammaticScrollInFlight: Bool
    ) -> Bool {
        if distanceFromTop > threshold {
            didLoadDuringCurrentScroll = false
            return false
        }
        guard
            !isProgrammaticScrollInFlight,
            !didLoadDuringCurrentScroll
        else {
            return false
        }
        didLoadDuringCurrentScroll = true
        return true
    }
}

struct CachedLiveWorkspaceFeeds: NSViewRepresentable {
    @ObservedObject private var characterSelectionStore:
        CharacterSelectionStore
    private let director: AgentDirector

    @MainActor
    init(director: AgentDirector) {
        self.director = director
        _characterSelectionStore = ObservedObject(
            wrappedValue: director.characterSelectionStore
        )
    }

    func makeNSView(context: Context) -> CachedLiveWorkspaceFeedsNSView {
        let view = CachedLiveWorkspaceFeedsNSView()
        view.configure(
            director: director,
            selectedCharacterID:
                characterSelectionStore.selectedCharacterID
        )
        return view
    }

    func updateNSView(
        _ nsView: CachedLiveWorkspaceFeedsNSView,
        context: Context
    ) {
        nsView.configure(
            director: director,
            selectedCharacterID:
                characterSelectionStore.selectedCharacterID
        )
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: CachedLiveWorkspaceFeedsNSView,
        context: Context
    ) -> CGSize? {
        guard
            let width = resolvedDimension(
                proposal.width,
                fallback: nsView.bounds.width
            ),
            let height = resolvedDimension(
                proposal.height,
                fallback: nsView.bounds.height
            )
        else {
            return nil
        }
        return CGSize(width: width, height: height)
    }

    static func dismantleNSView(
        _ nsView: CachedLiveWorkspaceFeedsNSView,
        coordinator: ()
    ) {
        nsView.tearDown()
    }

    private func resolvedDimension(
        _ proposed: CGFloat?,
        fallback: CGFloat
    ) -> CGFloat? {
        if let proposed, proposed.isFinite, proposed > 0 {
            return proposed
        }
        guard fallback.isFinite, fallback > 0 else {
            return nil
        }
        return fallback
    }
}

struct LiveWorkspaceFeedMetadata: Equatable {
    let latestTerminalTurnID: String?
    let latestSubmittedCommandID: UUID?
    let latestStartedCommandID: UUID?

    init(
        latestTerminalTurnID: String?,
        latestSubmittedCommandID: UUID?,
        latestStartedCommandID: UUID?
    ) {
        self.latestTerminalTurnID = latestTerminalTurnID
        self.latestSubmittedCommandID = latestSubmittedCommandID
        self.latestStartedCommandID = latestStartedCommandID
    }

    @MainActor
    init(director: AgentDirector) {
        latestTerminalTurnID = director.latestTerminalTurnID
        latestSubmittedCommandID = director.latestSubmittedCommandID
        latestStartedCommandID = director.latestStartedCommandID
    }
}

@MainActor
final class LiveWorkspaceFeedMetadataStore: ObservableObject {
    @Published private(set) var metadata: LiveWorkspaceFeedMetadata
    private var desiredMetadata: LiveWorkspaceFeedMetadata
    private var publicationTask: Task<Void, Never>?

    init(metadata: LiveWorkspaceFeedMetadata) {
        self.metadata = metadata
        desiredMetadata = metadata
    }

    func setMetadata(_ metadata: LiveWorkspaceFeedMetadata) {
        guard desiredMetadata != metadata else {
            return
        }
        desiredMetadata = metadata
        publicationTask?.cancel()
        publicationTask = Task { [weak self] in
            // updateNSView 안에서 ObservableObject를 즉시 발행하면 SwiftUI가
            // 호스트 갱신 도중 다시 무효화될 수 있으므로 다음 MainActor
            // 차례에 마지막 snapshot만 한 번 전달한다.
            await Task.yield()
            guard
                let self,
                !Task.isCancelled,
                self.desiredMetadata == metadata
            else {
                return
            }
            if self.metadata != metadata {
                self.metadata = metadata
            }
            self.publicationTask = nil
        }
    }
}

@MainActor
final class LiveWorkspaceFeedPresentationStore: ObservableObject {
    @Published private(set) var isPresented: Bool
    private var desiredIsPresented: Bool
    private var publicationTask: Task<Void, Never>?

    var isPresentationRequested: Bool {
        desiredIsPresented
    }

    init(isPresented: Bool) {
        self.isPresented = isPresented
        desiredIsPresented = isPresented
    }

    func setPresented(_ isPresented: Bool) {
        guard desiredIsPresented != isPresented else {
            return
        }
        desiredIsPresented = isPresented
        publicationTask?.cancel()
        publicationTask = Task { [weak self] in
            await Task.yield()
            guard
                let self,
                !Task.isCancelled,
                self.desiredIsPresented == isPresented
            else {
                return
            }
            if self.isPresented != isPresented {
                self.isPresented = isPresented
            }
            self.publicationTask = nil
        }
    }
}

private struct HostedLiveWorkspaceFeed: View {
    let director: AgentDirector
    let characterID: OfficeCharacter
    @ObservedObject var metadataStore: LiveWorkspaceFeedMetadataStore
    let presentationStore: LiveWorkspaceFeedPresentationStore

    var body: some View {
        LiveWorkspaceFeed(
            director: director,
            characterID: characterID,
            presentationStore: presentationStore,
            metadata: metadataStore.metadata
        )
        .equatable()
        .environment(
            \.liveWorkspaceFeedPresentationStore,
            presentationStore
        )
        .environment(\.locale, OfficeLocalization.locale)
    }
}

@MainActor
final class CachedLiveWorkspaceFeedsNSView: NSView {
    @MainActor
    private final class Entry {
        let characterID: OfficeCharacter
        let metadataStore: LiveWorkspaceFeedMetadataStore
        let presentationStore: LiveWorkspaceFeedPresentationStore
        // NSView로 타입을 소거해 생성 이후 rootView 재할당을 컴파일 단계에서
        // 막는다. 메타데이터 갱신은 metadataStore만 담당한다.
        let hostingView: NSView

        init(
            director: AgentDirector,
            characterID: OfficeCharacter,
            metadata: LiveWorkspaceFeedMetadata
        ) {
            self.characterID = characterID
            let metadataStore = LiveWorkspaceFeedMetadataStore(
                metadata: metadata
            )
            self.metadataStore = metadataStore
            // Entry는 선택된 직원에게만 처음 생성된다. 첫 mount부터 표시
            // 상태로 만들면 재시작 뒤 첫 직원 진입에서 false→true 발행을
            // 기다리는 동안 빈 호스트가 노출되지 않는다.
            let presentationStore = LiveWorkspaceFeedPresentationStore(
                isPresented: true
            )
            self.presentationStore = presentationStore
            hostingView = NSHostingView(
                rootView: HostedLiveWorkspaceFeed(
                    director: director,
                    characterID: characterID,
                    metadataStore: metadataStore,
                    presentationStore: presentationStore
                )
            )
        }

        func updateMetadata(_ metadata: LiveWorkspaceFeedMetadata) {
            metadataStore.setMetadata(metadata)
        }
    }

    private weak var director: AgentDirector?
    private var activeEntry: Entry?
    private var selectedCharacterID: OfficeCharacter?
    private var postMountRefreshTask: Task<Void, Never>?
    private var selectionGeneration = 0
    private var pendingPostMountRefreshGeneration: Int?

    private static let postMountRefreshMaximumAttempts = 12

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        nil
    }

    override func layout() {
        super.layout()
        for subview in subviews where subview.frame != bounds {
            subview.frame = bounds
        }
        schedulePostMountRefreshIfNeeded()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        schedulePostMountRefreshIfNeeded()
    }

    func configure(
        director: AgentDirector,
        selectedCharacterID: OfficeCharacter?
    ) {
        if self.director !== director {
            tearDown()
            self.director = director
        }

        let previousCharacterID = self.selectedCharacterID
        let didChangeSelection = previousCharacterID != selectedCharacterID
        self.selectedCharacterID = selectedCharacterID
        if didChangeSelection {
            postMountRefreshTask?.cancel()
            postMountRefreshTask = nil
            selectionGeneration &+= 1
            pendingPostMountRefreshGeneration = selectedCharacterID == nil
                ? nil
                : selectionGeneration
        }

        if didChangeSelection {
            releaseActiveEntry()
        }

        guard let selectedCharacterID else {
            return
        }

        let metadata = LiveWorkspaceFeedMetadata(director: director)
        let selectedEntry: Entry
        if
            let activeEntry,
            activeEntry.characterID == selectedCharacterID
        {
            selectedEntry = activeEntry
        } else {
            releaseActiveEntry()
            let entry = Entry(
                director: director,
                characterID: selectedCharacterID,
                metadata: metadata
            )
            entry.hostingView.frame = bounds
            entry.hostingView.autoresizingMask = [.width, .height]
            activeEntry = entry
            selectedEntry = entry
        }
        selectedEntry.updateMetadata(metadata)
        if selectedEntry.hostingView.superview !== self {
            selectedEntry.hostingView.removeFromSuperview()
            selectedEntry.hostingView.frame = bounds
            addSubview(selectedEntry.hostingView)
        }
        selectedEntry.presentationStore.setPresented(true)
        selectedEntry.hostingView.isHidden = false
        if didChangeSelection {
            needsLayout = true
            schedulePostMountRefreshIfNeeded()
        }
    }

    func tearDown() {
        postMountRefreshTask?.cancel()
        postMountRefreshTask = nil
        selectionGeneration &+= 1
        pendingPostMountRefreshGeneration = nil
        releaseActiveEntry()
        selectedCharacterID = nil
        director = nil
    }

    private func releaseActiveEntry() {
        guard let activeEntry else {
            return
        }
        activeEntry.presentationStore.setPresented(false)
        activeEntry.hostingView.removeFromSuperview()
        self.activeEntry = nil
    }

    private func schedulePostMountRefreshIfNeeded() {
        guard
            postMountRefreshTask == nil,
            window != nil,
            let director,
            let characterID = selectedCharacterID,
            let generation = pendingPostMountRefreshGeneration,
            generation == selectionGeneration
        else {
            return
        }

        postMountRefreshTask = Task { [weak self, weak director] in
            // NSHostingView가 window와 크기를 얻은 뒤 SwiftUI 구독이 붙을
            // 시간을 준다. 단일 Task.yield()는 updateNSView와 window attach
            // 순서에 따라 구독 전에 끝날 수 있으므로 짧고 제한된 횟수만
            // 준비 상태를 확인한다.
            for attempt in 0..<Self.postMountRefreshMaximumAttempts {
                await Task.yield()
                if attempt > 0 {
                    try? await Task.sleep(for: .milliseconds(16))
                }
                guard
                    let self,
                    let director,
                    !Task.isCancelled,
                    self.selectionGeneration == generation,
                    self.selectedCharacterID == characterID,
                    self.pendingPostMountRefreshGeneration == generation,
                    let activeEntry = self.activeEntry,
                    activeEntry.characterID == characterID
                else {
                    return
                }

                guard
                    let window = self.window,
                    activeEntry.hostingView.superview === self,
                    activeEntry.hostingView.window === window,
                    self.bounds.width > 0,
                    self.bounds.height > 0,
                    activeEntry.hostingView.bounds.width > 0,
                    activeEntry.hostingView.bounds.height > 0
                else {
                    continue
                }

                activeEntry.hostingView.needsLayout = true
                activeEntry.hostingView.layoutSubtreeIfNeeded()
                activeEntry.hostingView.needsDisplay = true
                director.liveFeedStore.refreshSelectedCharacterFeedAfterMount(
                    characterID.rawValue
                )
                self.pendingPostMountRefreshGeneration = nil
                self.postMountRefreshTask = nil
                return
            }

            guard
                let self,
                self.selectionGeneration == generation,
                self.selectedCharacterID == characterID
            else {
                return
            }
            // 아직 준비되지 않았으면 pending 상태를 남긴다. 다음 실제
            // window/layout 콜백에서 다시 시도하며 자체 반복은 만들지 않는다.
            self.postMountRefreshTask = nil
        }
    }
}

struct LiveWorkspaceFeed: View, Equatable {
    @ObservedObject private var characterFeedStore: CharacterLiveFeedStore
    private let director: AgentDirector
    private let liveFeedStore: LiveFeedStore
    private let characterID: OfficeCharacter
    private let presentationStore: LiveWorkspaceFeedPresentationStore
    private let workspaceDirectory: String
    private let latestTerminalTurnID: String?
    private let latestSubmittedCommandID: UUID?
    private let latestStartedCommandID: UUID?
    private let fetchWorkspaceReview: WorkspaceReviewFetcher
    private let resolveWorkspaceReview: WorkspaceReviewResolver
    private let updateResponseFeedback:
        (String, TurnResponseFeedback?) async -> Void
    @State private var followState = LiveWorkspaceFeedFollowState()
    @State private var hasContentBelow = false
    @State private var scrollMetrics = LiveWorkspaceFeedScrollMetrics()
    @State private var visibleTurnLimit =
        LiveWorkspaceFeedPagingPolicy.initialVisibleTurnCount
    @State private var didPerformInitialScroll = false
    @State private var isLoadingOlderTurns = false
    @State private var topLoadGate = LiveWorkspaceFeedTopLoadGate()

    private static let bottomTolerance = CGFloat(20)
    private static let topLoadThreshold = CGFloat(120)
    private static let bottomMarkerID = "live-workspace-feed-bottom"

    fileprivate init(
        director: AgentDirector,
        characterID: OfficeCharacter,
        presentationStore: LiveWorkspaceFeedPresentationStore,
        metadata: LiveWorkspaceFeedMetadata
    ) {
        let liveFeedStore = director.liveFeedStore
        _characterFeedStore = ObservedObject(
            wrappedValue: liveFeedStore.characterStore(
                for: characterID.rawValue
            )
        )
        self.director = director
        self.liveFeedStore = liveFeedStore
        self.characterID = characterID
        self.presentationStore = presentationStore
        workspaceDirectory = director.workspaceDirectory
        latestTerminalTurnID = metadata.latestTerminalTurnID
        latestSubmittedCommandID = metadata.latestSubmittedCommandID
        latestStartedCommandID = metadata.latestStartedCommandID
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
        lhs.director === rhs.director
            && lhs.liveFeedStore === rhs.liveFeedStore
            && lhs.characterFeedStore === rhs.characterFeedStore
            && lhs.characterID == rhs.characterID
            && lhs.presentationStore === rhs.presentationStore
            && lhs.workspaceDirectory == rhs.workspaceDirectory
            && lhs.latestTerminalTurnID == rhs.latestTerminalTurnID
            && lhs.latestSubmittedCommandID == rhs.latestSubmittedCommandID
            && lhs.latestStartedCommandID == rhs.latestStartedCommandID
    }

    private var selectedTurns: [LiveFeedTurn] {
        characterFeedStore.turns
    }

    private var displayTurns: [LiveFeedTurn] {
        Array(
            selectedTurns.enumerated().compactMap { index, turn in
                LiveWorkspaceFeedPagingPolicy.includesTurn(
                    at: index,
                    visibleTurnLimit: visibleTurnLimit,
                    isRunning: turn.status.isRunning,
                    isLatestTerminalTurn:
                        turn.id == latestTerminalTurnID
                )
                    ? turn
                    : nil
            }
            .reversed()
        )
    }

    private var displayItems: [LiveWorkspaceFeedTurnItem] {
        displayTurns.map { turn in
            LiveWorkspaceFeedTurnItem(
                id: liveFeedStore.presentationID(forTurnID: turn.id),
                turn: turn
            )
        }
    }

    private var hiddenTurnCount: Int {
        max(0, selectedTurns.count - displayTurns.count)
    }

    private var canLoadOlderTurns: Bool {
        visibleTurnLimit
            < min(
                LiveWorkspaceFeedPagingPolicy.maximumVisibleTurnCount,
                selectedTurns.count
            )
    }

    private var nextArchivedTurnCount: Int {
        min(
            LiveWorkspaceFeedPagingPolicy.pageSize,
            hiddenTurnCount
        )
    }

    private var initialLayoutRevision:
        [LiveWorkspaceFeedTurnRevision]
    {
        displayItems.map { item in
            let turn = item.turn
            return LiveWorkspaceFeedTurnRevision(
                id: item.id,
                updatedAt: turn.updatedAt,
                status: turn.status,
                activityCount: turn.activities.count,
                responseLength: turn.response.count,
                workspaceStatus: turn.workspace?.status,
                changedFileCount: turn.workspace?.changedFiles.count ?? 0
            )
        }
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if displayTurns.isEmpty {
                    if characterFeedStore.isLoadingInitialFeed {
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
                                onMetrics: { metrics in
                                    handleScrollMetrics(
                                        metrics,
                                        proxy: proxy
                                    )
                                },
                                onUserScrollStarted: {
                                    topLoadGate.userScrollStarted()
                                    if !didPerformInitialScroll {
                                        didPerformInitialScroll = true
                                    }
                                    pauseFollowingLatest()
                                },
                                onUserScrollActivity: {
                                    if !didPerformInitialScroll {
                                        didPerformInitialScroll = true
                                    }
                                    pauseFollowingLatest()
                                },
                                onUserScroll: { metrics in
                                    handleUserScroll(
                                        metrics,
                                        proxy: proxy
                                    )
                                }
                            )
                            .frame(height: 1)

                            LazyVStack(spacing: 14) {
                                if hiddenTurnCount > 0 {
                                    archivedTurnsNotice
                                }

                                ForEach(displayItems) { item in
                                    let turn = item.turn
                                    EquatableLiveTurnCard(
                                        director: director,
                                        turn: turn,
                                        workspaceDirectory: workspaceDirectory,
                                        shouldAnimateResponse:
                                            liveFeedStore
                                            .shouldAnimateResponse(for: turn),
                                        shouldAnimateInitialResponse:
                                            liveFeedStore
                                            .shouldAnimateInitialResponse(
                                                for: turn
                                            ),
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
                                        .id(item.id)
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
                    .onAppear {
                        settleInitialAnchorIfNeeded()
                    }
                    .onChange(
                        of: characterFeedStore.isLoadingInitialFeed
                    ) { _, isLoading in
                        guard !isLoading else {
                            return
                        }
                        settleInitialAnchorIfNeeded()
                    }
                    .onChange(of: initialLayoutRevision) { _, _ in
                        switch LiveWorkspaceFeedContentRevisionPolicy.action(
                            didPerformInitialScroll: didPerformInitialScroll,
                            isFollowingLatest: followState.isFollowingLatest
                        ) {
                        case .settleInitialAnchor:
                            settleInitialAnchorIfNeeded()
                        case .followLatest:
                            scheduleScrollToLatest(proxy)
                        case .revealContentBelow:
                            if !hasContentBelow {
                                hasContentBelow = true
                            }
                        }
                    }
                    .onChange(of: latestSubmittedCommandID) {
                        _, commandID in
                        guard commandID != nil else {
                            return
                        }
                        revealSubmittedTurn(proxy: proxy)
                    }
                    .onChange(of: latestStartedCommandID) {
                        _, commandID in
                        guard commandID != nil else {
                            return
                        }
                        scheduleScrollToLatest(proxy)
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
                        cancelScheduledScrolls()
                    }
                }
            }
            .onReceive(presentationStore.$isPresented) { isPresented in
                if !isPresented {
                    cancelScheduledScrolls()
                }
            }
        }
    }

    private func handleScrollMetrics(
        _ metrics: LiveWorkspaceFeedScrollSnapshot,
        proxy: ScrollViewProxy
    ) {
        guard presentationStore.isPresentationRequested else {
            return
        }
        scrollMetrics.hasSnapshot = true
        scrollMetrics.distanceFromBottom = metrics.distanceFromBottom
        scrollMetrics.viewportHeight = metrics.viewportHeight
        scrollMetrics.contentHeight = metrics.contentHeight

        settleInitialAnchorIfNeeded()
        if !didPerformInitialScroll {
            return
        }

        updateBottomState()
    }

    private func handleUserScroll(
        _ metrics: LiveWorkspaceFeedScrollSnapshot,
        proxy: ScrollViewProxy
    ) {
        guard presentationStore.isPresentationRequested else {
            return
        }
        let shouldFollowLatest =
            metrics.distanceFromBottom <= Self.bottomTolerance
        if followState.isFollowingLatest != shouldFollowLatest {
            followState.userDidScroll(
                distanceFromBottom: metrics.distanceFromBottom,
                tolerance: Self.bottomTolerance
            )
        }
        updateBottomState()
        if topLoadGate.shouldLoad(
            distanceFromTop: metrics.distanceFromTop,
            threshold: Self.topLoadThreshold,
            isProgrammaticScrollInFlight:
                scrollMetrics.isProgrammaticScrollInFlight
        ) {
            loadMoreTurnsIfNeeded(proxy: proxy)
        }
    }

    private func scrollToLatest(
        _ proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
        cancelScheduledScrolls()
        let generation = beginProgrammaticScroll()
        markAtBottom()
        scrollMetrics.followScrollTask = Task { @MainActor in
            defer {
                if scrollMetrics.scrollGeneration == generation {
                    scrollMetrics.followScrollTask = nil
                    finishProgrammaticScroll(generation: generation)
                }
            }
            await Task.yield()
            guard
                !Task.isCancelled,
                presentationStore.isPresentationRequested,
                scrollMetrics.scrollGeneration == generation
            else {
                return
            }
            guard animated else {
                proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
                return
            }
            withAnimation(.easeOut(duration: 0.20)) {
                proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
            }
            try? await Task.sleep(for: .milliseconds(220))
        }
    }

    private func scheduleScrollToLatest(
        _ proxy: ScrollViewProxy
    ) {
        guard
            presentationStore.isPresentationRequested,
            didPerformInitialScroll,
            followState.isFollowingLatest,
            scrollMetrics.submittedScrollTask == nil
        else {
            return
        }
        guard scrollMetrics.followScrollTask == nil else {
            return
        }
        markAtBottom()
        let generation = beginProgrammaticScroll()
        scrollMetrics.followScrollTask = Task { @MainActor in
            defer {
                if scrollMetrics.scrollGeneration == generation {
                    scrollMetrics.followScrollTask = nil
                    finishProgrammaticScroll(generation: generation)
                }
            }
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(16))
            guard
                !Task.isCancelled,
                presentationStore.isPresentationRequested,
                scrollMetrics.scrollGeneration == generation
            else {
                return
            }
            proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
        }
    }

    private func settleInitialAnchorIfNeeded() {
        guard
            !didPerformInitialScroll,
            !characterFeedStore.isLoadingInitialFeed,
            !displayTurns.isEmpty,
            scrollMetrics.hasSnapshot,
            scrollMetrics.viewportHeight > 0,
            scrollMetrics.contentHeight > 0
        else {
            return
        }

        didPerformInitialScroll = true
        // 기본 하단 앵커가 적용되기 전의 첫 측정값만으로 자동 추적을
        // 끄지 않는다. 추적 중단은 실제 사용자 스크롤 콜백만 담당한다.
        updateBottomState()
    }

    private func cancelScheduledScrolls() {
        scrollMetrics.scrollGeneration &+= 1
        scrollMetrics.isProgrammaticScrollInFlight = false
        scrollMetrics.followScrollTask?.cancel()
        scrollMetrics.followScrollTask = nil
        scrollMetrics.submittedScrollTask?.cancel()
        scrollMetrics.submittedScrollTask = nil
    }

    private func beginProgrammaticScroll() -> Int {
        scrollMetrics.scrollGeneration &+= 1
        scrollMetrics.isProgrammaticScrollInFlight = true
        return scrollMetrics.scrollGeneration
    }

    private func finishProgrammaticScroll(generation: Int) {
        guard scrollMetrics.scrollGeneration == generation else {
            return
        }
        scrollMetrics.isProgrammaticScrollInFlight = false
    }

    private func revealSubmittedTurn(proxy: ScrollViewProxy) {
        cancelScheduledScrolls()
        markAtBottom()
        let generation = beginProgrammaticScroll()
        scrollMetrics.submittedScrollTask = Task { @MainActor in
            defer {
                if scrollMetrics.scrollGeneration == generation {
                    scrollMetrics.submittedScrollTask = nil
                    finishProgrammaticScroll(generation: generation)
                }
            }
            await Task.yield()
            guard
                !Task.isCancelled,
                presentationStore.isPresentationRequested,
                scrollMetrics.scrollGeneration == generation
            else {
                return
            }
            var policy = LiveWorkspaceFeedScrollPolicy()
            for _ in 0..<LiveWorkspaceFeedScrollPolicy.submittedMaximumAttempts {
                guard
                    !Task.isCancelled,
                    presentationStore.isPresentationRequested,
                    scrollMetrics.scrollGeneration == generation
                else {
                    return
                }
                proxy.scrollTo(Self.bottomMarkerID, anchor: .bottom)
                try? await Task.sleep(for: .milliseconds(40))
                if policy.shouldStop(
                    distanceFromBottom:
                        scrollMetrics.distanceFromBottom,
                    tolerance: Self.bottomTolerance
                ) {
                    break
                }
            }
            guard
                !Task.isCancelled,
                presentationStore.isPresentationRequested,
                scrollMetrics.scrollGeneration == generation
            else {
                return
            }
            markAtBottom()
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

        let readingAnchorID = displayItems.first?.id
        let nextLimit = LiveWorkspaceFeedPagingPolicy.nextVisibleTurnLimit(
            current: visibleTurnLimit,
            total: selectedTurns.count
        )
        guard nextLimit > visibleTurnLimit else {
            return
        }

        isLoadingOlderTurns = true
        visibleTurnLimit = nextLimit
        DispatchQueue.main.async {
            guard presentationStore.isPresentationRequested else {
                isLoadingOlderTurns = false
                return
            }
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
            Image(systemName: "arrow.down")
                .font(.system(size: 13, weight: .black))
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
        .accessibilityLabel("맨 아래로 이동")
        .help("맨 아래로 이동")
    }

    private var archivedTurnsNotice: some View {
        HStack(spacing: 7) {
            Image(systemName: "books.vertical")
            if canLoadOlderTurns {
                Text(
                    "위로 더 올리면 이전 "
                        + "\(nextArchivedTurnCount)건 추가"
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
        scrollMetrics.distanceFromBottom
    }

    private func markAtBottom() {
        if !followState.isFollowingLatest {
            followState.resume()
        }
        if hasContentBelow {
            hasContentBelow = false
        }
    }

    private func pauseFollowingLatest() {
        if followState.isFollowingLatest {
            followState.userWillScroll()
        }
        cancelScheduledScrolls()
    }
}

private struct LiveWorkspaceFeedTurnItem: Identifiable {
    let id: String
    let turn: LiveFeedTurn
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
    var hasSnapshot = false
    var distanceFromBottom = CGFloat.zero
    var viewportHeight = CGFloat.zero
    var contentHeight = CGFloat.zero
    var isProgrammaticScrollInFlight = false
    var scrollGeneration = 0
    var followScrollTask: Task<Void, Never>?
    var submittedScrollTask: Task<Void, Never>?
}

private struct LiveWorkspaceFeedBottomMarker: View {
    var body: some View {
        Color.clear
    }
}

struct LiveWorkspaceFeedScrollSnapshot: Equatable {
    let distanceFromTop: CGFloat
    let distanceFromBottom: CGFloat
    let viewportHeight: CGFloat
    let contentHeight: CGFloat

    func isApproximatelyEqual(
        to other: LiveWorkspaceFeedScrollSnapshot,
        tolerance: CGFloat = 0.5
    ) -> Bool {
        abs(distanceFromTop - other.distanceFromTop) <= tolerance
            && abs(distanceFromBottom - other.distanceFromBottom) <= tolerance
            && abs(viewportHeight - other.viewportHeight) <= tolerance
            && abs(contentHeight - other.contentHeight) <= tolerance
    }
}

struct LiveWorkspaceFeedScrollGeometry {
    static func snapshot(
        documentBounds: CGRect,
        visibleRect: CGRect,
        isFlipped: Bool
    ) -> LiveWorkspaceFeedScrollSnapshot {
        let viewportHeight = max(0, visibleRect.height)
        let contentHeight = max(0, documentBounds.height)
        let scrollableHeight = max(0, contentHeight - viewportHeight)
        let rawDistanceFromTop =
            isFlipped
            ? visibleRect.minY - documentBounds.minY
            : documentBounds.maxY - visibleRect.maxY
        let distanceFromTop = min(
            scrollableHeight,
            max(0, rawDistanceFromTop)
        )
        return LiveWorkspaceFeedScrollSnapshot(
            distanceFromTop: distanceFromTop,
            distanceFromBottom: max(
                0,
                scrollableHeight - distanceFromTop
            ),
            viewportHeight: viewportHeight,
            contentHeight: contentHeight
        )
    }
}

struct LiveWorkspaceFeedScrollObserver: NSViewRepresentable {
    let onMetrics: (LiveWorkspaceFeedScrollSnapshot) -> Void
    let onUserScrollStarted: () -> Void
    let onUserScrollActivity: () -> Void
    let onUserScroll: (LiveWorkspaceFeedScrollSnapshot) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMetrics: onMetrics,
            onUserScrollStarted: onUserScrollStarted,
            onUserScrollActivity: onUserScrollActivity,
            onUserScroll: onUserScroll
        )
    }

    func makeNSView(context: Context) -> AttachmentView {
        let view = AttachmentView()
        view.onHierarchyChange = {
            [weak view, weak coordinator = context.coordinator] in
            coordinator?.attach(
                to: view?.window == nil
                    ? nil
                    : view?.enclosingScrollView
            )
        }
        return view
    }

    func updateNSView(_ nsView: AttachmentView, context: Context) {
        context.coordinator.onMetrics = onMetrics
        context.coordinator.onUserScrollStarted = onUserScrollStarted
        context.coordinator.onUserScrollActivity = onUserScrollActivity
        context.coordinator.onUserScroll = onUserScroll
        context.coordinator.attach(
            to: nsView.window == nil
                ? nil
                : nsView.enclosingScrollView
        )
    }

    static func dismantleNSView(
        _ nsView: AttachmentView,
        coordinator: Coordinator
    ) {
        nsView.onHierarchyChange = nil
        coordinator.detach()
    }

    final class Coordinator {
        var onMetrics: (LiveWorkspaceFeedScrollSnapshot) -> Void
        var onUserScrollStarted: () -> Void
        var onUserScrollActivity: () -> Void
        var onUserScroll: (LiveWorkspaceFeedScrollSnapshot) -> Void
        private weak var scrollView: NSScrollView?
        private weak var documentView: NSView?
        private var boundsObserver: NSObjectProtocol?
        private var clipFrameObserver: NSObjectProtocol?
        private var liveScrollStartObserver: NSObjectProtocol?
        private var liveScrollUpdateObserver: NSObjectProtocol?
        private var liveScrollEndObserver: NSObjectProtocol?
        private var isReportScheduled = false
        private var reportsUserScroll = false
        private var reportsUserScrollActivity = false
        private var lastReportedSnapshot: LiveWorkspaceFeedScrollSnapshot?
        private var attachmentGeneration = 0
        private var isLiveScrollActive = false
        private var didReportLiveScrollActivity = false

        init(
            onMetrics: @escaping (LiveWorkspaceFeedScrollSnapshot) -> Void,
            onUserScrollStarted: @escaping () -> Void,
            onUserScrollActivity: @escaping () -> Void,
            onUserScroll: @escaping (LiveWorkspaceFeedScrollSnapshot) -> Void
        ) {
            self.onMetrics = onMetrics
            self.onUserScrollStarted = onUserScrollStarted
            self.onUserScrollActivity = onUserScrollActivity
            self.onUserScroll = onUserScroll
        }

        deinit {
            // SwiftUI가 빠른 직원 전환 중 dismantle 콜백을 건너뛰더라도
            // NotificationCenter observer가 다음 호스트까지 남지 않게 한다.
            detach()
        }

        func attach(to scrollView: NSScrollView?) {
            let documentView = scrollView?.documentView
            guard
                self.scrollView !== scrollView
                    || self.documentView !== documentView
            else {
                return
            }
            detach()
            guard let scrollView, let documentView else {
                return
            }
            self.scrollView = scrollView
            self.documentView = documentView
            scrollView.contentView.postsBoundsChangedNotifications = true
            scrollView.contentView.postsFrameChangedNotifications = true
            boundsObserver = NotificationCenter.default.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleMetricsReport()
            }
            clipFrameObserver = NotificationCenter.default.addObserver(
                forName: NSView.frameDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                self?.scheduleMetricsReport()
            }
            liveScrollStartObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.willStartLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                guard let self else {
                    return
                }
                self.isLiveScrollActive = true
                self.didReportLiveScrollActivity = false
                self.onUserScrollStarted()
            }
            liveScrollUpdateObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                guard let self else {
                    return
                }
                if !self.isLiveScrollActive {
                    self.isLiveScrollActive = true
                    self.didReportLiveScrollActivity = false
                    self.onUserScrollStarted()
                }
                if !self.didReportLiveScrollActivity {
                    self.didReportLiveScrollActivity = true
                    self.reportsUserScrollActivity = true
                }
                self.scheduleMetricsReport()
            }
            liveScrollEndObserver = NotificationCenter.default.addObserver(
                forName: NSScrollView.didEndLiveScrollNotification,
                object: scrollView,
                queue: .main
            ) { [weak self] _ in
                guard let self, self.isLiveScrollActive else {
                    return
                }
                self.isLiveScrollActive = false
                self.didReportLiveScrollActivity = false
                self.scheduleMetricsReport(reportsUserScroll: true)
            }
            scheduleMetricsReport()
        }

        func detach() {
            attachmentGeneration &+= 1
            if let boundsObserver {
                NotificationCenter.default.removeObserver(boundsObserver)
            }
            if let liveScrollStartObserver {
                NotificationCenter.default.removeObserver(
                    liveScrollStartObserver
                )
            }
            if let liveScrollUpdateObserver {
                NotificationCenter.default.removeObserver(
                    liveScrollUpdateObserver
                )
            }
            if let liveScrollEndObserver {
                NotificationCenter.default.removeObserver(liveScrollEndObserver)
            }
            if let clipFrameObserver {
                NotificationCenter.default.removeObserver(clipFrameObserver)
            }
            boundsObserver = nil
            clipFrameObserver = nil
            liveScrollStartObserver = nil
            liveScrollUpdateObserver = nil
            liveScrollEndObserver = nil
            scrollView = nil
            documentView = nil
            isReportScheduled = false
            reportsUserScroll = false
            reportsUserScrollActivity = false
            lastReportedSnapshot = nil
            isLiveScrollActive = false
            didReportLiveScrollActivity = false
        }

        private func scheduleMetricsReport(
            reportsUserScroll: Bool = false
        ) {
            if reportsUserScroll {
                self.reportsUserScroll = true
            }
            guard !isReportScheduled else {
                return
            }
            isReportScheduled = true
            let generation = attachmentGeneration
            DispatchQueue.main.asyncAfter(
                deadline: .now() + .milliseconds(16)
            ) { [weak self] in
                guard let self else {
                    return
                }
                guard self.attachmentGeneration == generation else {
                    return
                }
                self.isReportScheduled = false
                let reportsUserScroll = self.reportsUserScroll
                let reportsUserScrollActivity =
                    self.reportsUserScrollActivity
                self.reportsUserScroll = false
                self.reportsUserScrollActivity = false
                guard let snapshot = self.scrollSnapshot() else {
                    return
                }
                if reportsUserScrollActivity {
                    self.onUserScrollActivity()
                }
                if
                    self.lastReportedSnapshot?.isApproximatelyEqual(
                        to: snapshot
                    ) != true
                {
                    self.lastReportedSnapshot = snapshot
                    self.onMetrics(snapshot)
                }
                if reportsUserScroll {
                    self.onUserScroll(snapshot)
                }
            }
        }

        private func scrollSnapshot() -> LiveWorkspaceFeedScrollSnapshot? {
            guard
                let scrollView,
                let documentView,
                documentView === scrollView.documentView
            else {
                return nil
            }
            let documentBounds = documentView.bounds
            let visibleRect = scrollView.documentVisibleRect
            return LiveWorkspaceFeedScrollGeometry.snapshot(
                documentBounds: documentBounds,
                visibleRect: visibleRect,
                isFlipped: documentView.isFlipped
            )
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

private struct EquatableLiveTurnCard: View, Equatable {
    let director: AgentDirector
    let turn: LiveFeedTurn
    let workspaceDirectory: String
    let shouldAnimateResponse: Bool
    let shouldAnimateInitialResponse: Bool
    let fetchWorkspaceReview: WorkspaceReviewFetcher
    let resolveWorkspaceReview: WorkspaceReviewResolver
    let updateResponseFeedback:
        (String, TurnResponseFeedback?) async -> Void
    let finishResponseAnimation: () -> Void

    static func == (
        lhs: EquatableLiveTurnCard,
        rhs: EquatableLiveTurnCard
    ) -> Bool {
        lhs.director === rhs.director
            && lhs.turn == rhs.turn
            && lhs.workspaceDirectory == rhs.workspaceDirectory
            && lhs.shouldAnimateResponse == rhs.shouldAnimateResponse
            && lhs.shouldAnimateInitialResponse
                == rhs.shouldAnimateInitialResponse
    }

    var body: some View {
        LiveTurnCard(
            director: director,
            turn: turn,
            workspaceDirectory: workspaceDirectory,
            shouldAnimateResponse: shouldAnimateResponse,
            shouldAnimateInitialResponse:
                shouldAnimateInitialResponse,
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
    let director: AgentDirector
    let turn: LiveFeedTurn
    let workspaceDirectory: String
    let shouldAnimateResponse: Bool
    let shouldAnimateInitialResponse: Bool
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

                // 확인 질문은 팝업 대신 이 카드 안에서 바로 답변한다.
                if
                    CodexResponseDisplayPolicy
                        .showsInlineQuestionAnswer(
                            needsInput: turn.needsInput,
                            backend: effectiveBackend,
                            animatesResponse: shouldAnimateResponse
                        ),
                    let character = OfficeCharacter(
                        rawValue: turn.characterId
                    )
                {
                    InlineQuestionAnswerView(
                        director: director,
                        character: character,
                        turnID: turn.id,
                        needsInput: turn.needsInput,
                        question: turn.response
                    )
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
            animatesInitialResponse: shouldAnimateInitialResponse,
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
            animatesInitialResponse: shouldAnimateInitialResponse,
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
    let typingIdentity: String
    let source: String
    let fileBaseDirectory: String?
    let animates: Bool
    let animatesInitialSource: Bool
    let isStreaming: Bool
    let onFinishedTyping: () -> Void

    static func == (
        lhs: EquatableLiveTypingResponseView,
        rhs: EquatableLiveTypingResponseView
    ) -> Bool {
        lhs.typingIdentity == rhs.typingIdentity
            && lhs.source == rhs.source
            && lhs.fileBaseDirectory == rhs.fileBaseDirectory
            && lhs.animates == rhs.animates
            && lhs.animatesInitialSource == rhs.animatesInitialSource
            && lhs.isStreaming == rhs.isStreaming
    }

    var body: some View {
        LiveTypingResponseView(
            typingIdentity: typingIdentity,
            source: source,
            fileBaseDirectory: fileBaseDirectory,
            animates: animates,
            animatesInitialSource: animatesInitialSource,
            isStreaming: isStreaming,
            onFinishedTyping: onFinishedTyping
        )
    }
}

enum CompletedResponseLineRenderKind: Equatable {
    case markdown
    case blank
    case codeFence
    case code
    case table
}

struct CompletedResponseLine: Identifiable, Equatable {
    let index: Int
    let source: String
    let renderKind: CompletedResponseLineRenderKind

    var id: Int { index }
}

struct CompletedResponseLineSequence: Equatable {
    let lines: [CompletedResponseLine]

    init(source: String) {
        let rawLines = source.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ).map(String.init)
        var inCodeFence = false
        lines = rawLines.enumerated().map { index, line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            let isFence = trimmed.hasPrefix("```")
                || trimmed.hasPrefix("~~~")
            let renderKind: CompletedResponseLineRenderKind
            if isFence {
                renderKind = .codeFence
                inCodeFence.toggle()
            } else if inCodeFence {
                renderKind = .code
            } else if trimmed.isEmpty {
                renderKind = .blank
            } else if trimmed.hasPrefix("|"), trimmed.hasSuffix("|") {
                // 표는 여러 줄을 다시 합쳐 렌더링하면 완료된 앞줄이
                // 교체된다. 각 행을 고정 폭 한 줄로 보존한다.
                renderKind = .table
            } else {
                renderKind = .markdown
            }
            return CompletedResponseLine(
                index: index,
                source: line,
                renderKind: renderKind
            )
        }
    }

    func isLastLine(_ lineIndex: Int) -> Bool {
        lineIndex >= lines.count - 1
    }
}

enum CompletedResponseRenderPlan {
    /// 줄 단위 렌더는 타자 중 높이를 고정하려는 수단이라 표·목록·코드펜스처럼
    /// 여러 줄이 모여야 의미가 생기는 블록을 복원하지 못한다.
    /// 타자가 끝났거나 아예 재생하지 않으면 원문 전체를 한 번에 그린다.
    static func rendersWholeSourceMarkdown(
        playsSequence: Bool,
        reduceMotion: Bool,
        hasLines: Bool,
        didFinishTyping: Bool
    ) -> Bool {
        !playsSequence || reduceMotion || !hasLines || didFinishTyping
    }
}

private struct CompletedResponseCommittedLineView: View, Equatable {
    let line: CompletedResponseLine
    let fontSize: CGFloat
    let fileBaseDirectory: String?

    var body: some View {
        Group {
            switch line.renderKind {
            case .markdown:
                ConversationMarkdownView(
                    source: line.source,
                    fontSize: fontSize,
                    fileBaseDirectory: fileBaseDirectory
                )
            case .blank:
                Color.clear.frame(height: 4)
            case .codeFence:
                Color.clear.frame(height: 0)
            case .code, .table:
                Text(line.source.isEmpty ? " " : line.source)
                    .font(.system(size: fontSize, design: .monospaced))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        Color.primary.opacity(0.045),
                        in: RoundedRectangle(
                            cornerRadius: 4,
                            style: .continuous
                        )
                    )
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 완성된 Codex 응답을 한 줄씩 빠르게 타이핑하고, 끝난 줄은 Markdown으로
/// 고정한다. 긴 한 줄은 프레임당 글자 수를 늘려 1초 안에 마친다.
struct CompletedResponseLineTypingView: View {
    let typingIdentity: String
    let source: String
    let fontSize: CGFloat
    let fileBaseDirectory: String?
    let animates: Bool
    let animatesInitialSource: Bool
    let presentsTyping: Bool
    let onFinishedTyping: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var sequence: CompletedResponseLineSequence
    @State private var committedLines: [CompletedResponseLine]
    @State private var currentLineIndex = 0
    @State private var didFinish = false
    @State private var playsSequence: Bool

    init(
        typingIdentity: String,
        source: String,
        fontSize: CGFloat,
        fileBaseDirectory: String?,
        animates: Bool,
        animatesInitialSource: Bool,
        presentsTyping: Bool,
        onFinishedTyping: @escaping () -> Void
    ) {
        let sequence = CompletedResponseLineSequence(source: source)
        let playsSequence =
            presentsTyping && animates && animatesInitialSource
        self.typingIdentity = typingIdentity
        self.source = source
        self.fontSize = fontSize
        self.fileBaseDirectory = fileBaseDirectory
        self.animates = animates
        self.animatesInitialSource = animatesInitialSource
        self.presentsTyping = presentsTyping
        self.onFinishedTyping = onFinishedTyping
        _sequence = State(initialValue: sequence)
        _committedLines = State(
            initialValue: playsSequence ? [] : sequence.lines
        )
        _currentLineIndex = State(
            initialValue: playsSequence ? 0 : sequence.lines.count
        )
        _didFinish = State(initialValue: !presentsTyping)
        _playsSequence = State(initialValue: playsSequence)
    }

    var body: some View {
        Group {
            if rendersWholeSourceMarkdown {
                wholeSourceMarkdownBody
                    .task(id: "presented:\(typingIdentity):\(source.hashValue)") {
                        if presentsTyping {
                            finishSequence()
                        }
                    }
            } else {
                typingBody(sequence: sequence)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onChange(of: source) { _, newSource in
            let newSequence = CompletedResponseLineSequence(
                source: newSource
            )
            let shouldPlay =
                presentsTyping && animates && animatesInitialSource
            sequence = newSequence
            committedLines = shouldPlay ? [] : newSequence.lines
            currentLineIndex = shouldPlay ? 0 : newSequence.lines.count
            didFinish = !presentsTyping
            playsSequence = shouldPlay
        }
    }

    private var rendersWholeSourceMarkdown: Bool {
        CompletedResponseRenderPlan.rendersWholeSourceMarkdown(
            playsSequence: playsSequence,
            reduceMotion: reduceMotion,
            hasLines: !sequence.lines.isEmpty,
            didFinishTyping: didFinish
        )
    }

    /// 타자가 끝난 뒤의 최종 화면이다. 표·목록·코드블록이 여기서 복원된다.
    private var wholeSourceMarkdownBody: some View {
        ConversationMarkdownView(
            source: source,
            fontSize: fontSize,
            fileBaseDirectory: fileBaseDirectory
        )
    }

    private func committedBody(
        lines: [CompletedResponseLine]
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(lines) { line in
                CompletedResponseCommittedLineView(
                    line: line,
                    fontSize: fontSize,
                    fileBaseDirectory: fileBaseDirectory
                )
                .equatable()
            }
        }
    }

    @ViewBuilder
    private func currentLineView(
        _ line: CompletedResponseLine,
        in sequence: CompletedResponseLineSequence
    ) -> some View {
        switch line.renderKind {
        case .blank, .codeFence:
            Color.clear
                .frame(height: line.renderKind == .blank ? 4 : 0)
                .task(id: "skip:\(typingIdentity):\(line.index)") {
                    advanceLine(line.index, in: sequence)
                }
        default:
            // 최종 Markdown 줄이 처음부터 높이를 맡고, 타이핑 텍스트는
            // 크기에 관여하지 않는 overlay에서만 그린다. 줄을 치는 동안
            // ScrollView 문서 높이가 16ms마다 변하지 않는다.
            ZStack(alignment: .topLeading) {
                CompletedResponseCommittedLineView(
                    line: line,
                    fontSize: fontSize,
                    fileBaseDirectory: fileBaseDirectory
                )
                .equatable()
                .accessibilityHidden(true)
                .hidden()

                // 링크 URL처럼 원문이 최종 Markdown보다 길어도 타이핑
                // 텍스트가 잘리지 않도록 두 높이 중 큰 쪽을 예약한다.
                Text(line.source.isEmpty ? " " : line.source)
                    .font(.system(size: fontSize))
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityHidden(true)
                    .hidden()
            }
            .overlay(alignment: .topLeading) {
                StreamingPlainTextView(
                    source: line.source,
                    animates: true,
                    animatesInitialSource: true,
                    fontSize: fontSize,
                    lineSpacing: 3,
                    revealMode: .fullLine,
                    onFinishedTyping: {
                        advanceLine(line.index, in: sequence)
                    }
                )
                .id("\(typingIdentity):line:\(line.index)")
                .frame(
                    maxWidth: .infinity,
                    maxHeight: .infinity,
                    alignment: .topLeading
                )
                .clipped()
            }
        }
    }

    @ViewBuilder
    private func typingBody(
        sequence: CompletedResponseLineSequence
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            committedBody(lines: committedLines)

            if currentLineIndex >= sequence.lines.count {
                Color.clear.frame(height: 0)
            } else {
                let line = sequence.lines[currentLineIndex]
                currentLineView(line, in: sequence)
            }
        }
    }

    private func advanceLine(
        _ expectedLineIndex: Int,
        in sequence: CompletedResponseLineSequence
    ) {
        guard
            !didFinish,
            expectedLineIndex == currentLineIndex
        else {
            return
        }
        committedLines.append(sequence.lines[expectedLineIndex])
        currentLineIndex += 1
        while currentLineIndex < sequence.lines.count {
            let nextLine = sequence.lines[currentLineIndex]
            guard
                nextLine.renderKind == .blank
                    || nextLine.renderKind == .codeFence
            else {
                break
            }
            committedLines.append(nextLine)
            currentLineIndex += 1
        }
        if currentLineIndex >= sequence.lines.count {
            finishSequence()
        }
    }

    private func finishSequence() {
        guard !didFinish else {
            return
        }
        didFinish = true
        onFinishedTyping()
    }
}

struct LiveTypingResponseView: View {
    let typingIdentity: String
    let source: String
    let fileBaseDirectory: String?
    let animates: Bool
    let isStreaming: Bool
    let onFinishedTyping: () -> Void

    private static let responseFontSize = CGFloat(14)
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    private let animatesInitialSource: Bool

    init(
        typingIdentity: String,
        source: String,
        fileBaseDirectory: String? = nil,
        animates: Bool,
        animatesInitialSource: Bool = true,
        isStreaming: Bool,
        onFinishedTyping: @escaping () -> Void
    ) {
        self.typingIdentity = typingIdentity
        self.source = source
        self.fileBaseDirectory = fileBaseDirectory
        self.animates = animates
        self.isStreaming = isStreaming
        self.onFinishedTyping = onFinishedTyping
        self.animatesInitialSource =
            animates
                && animatesInitialSource
                && LiveTypingAppearanceCache.shared
                    .shouldAnimateInitialSource(for: typingIdentity)
    }

    var body: some View {
        Group {
            if isStreaming {
                let segments = StreamingMarkdownSplitter.split(source)

                VStack(alignment: .leading, spacing: 9) {
                    // 더 바뀌지 않는 앞부분은 한 번만 렌더링한다.
                    if !segments.settledMarkdown.isEmpty {
                        ConversationMarkdownView(
                            source: segments.settledMarkdown,
                            fontSize: Self.responseFontSize,
                            fileBaseDirectory: fileBaseDirectory
                        )
                    }

                    // 작성 중 블록은 줄이 완성될 때마다 Markdown으로 갱신한다.
                    if !segments.activeMarkdown.isEmpty {
                        ConversationMarkdownView(
                            source: segments.activeMarkdown,
                            fontSize: Self.responseFontSize,
                            fileBaseDirectory: fileBaseDirectory
                        )
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
                            revealMode: .trailingCharacters,
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
            }
        }
    }
}

@MainActor
private final class LiveTypingAppearanceCache {
    static let shared = LiveTypingAppearanceCache()

    private let storage = NSCache<NSString, NSNumber>()

    private init() {
        storage.countLimit = 256
    }

    func shouldAnimateInitialSource(for identity: String) -> Bool {
        let key = identity as NSString
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

    @Environment(\.presentCharacterProfile) private var presentProfile
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    @ViewBuilder
    var body: some View {
        if let presentProfile {
            Button {
                presentProfile(characterID)
            } label: {
                avatar
                    .scaleEffect(
                        isHovered
                            ? CharacterFullBodyProfilePresentationMetrics
                                .avatarHoverScale
                            : 1
                    )
                    .overlay {
                        Circle()
                            .stroke(
                                DashboardPalette.characterAccent(
                                    for: characterID
                                ).opacity(isHovered ? 0.78 : 0),
                                lineWidth: 1.5
                            )
                            .scaleEffect(isHovered ? 1.12 : 0.92)
                    }
                    .shadow(
                        color: DashboardPalette.characterAccent(
                            for: characterID
                        ).opacity(isHovered ? 0.42 : 0),
                        radius: isHovered ? 9 : 0
                    )
            }
            .buttonStyle(CharacterProfileBadgeButtonStyle())
            .onHover { hovered in
                if reduceMotion {
                    isHovered = hovered
                } else {
                    withAnimation(
                        .spring(response: 0.32, dampingFraction: 0.68)
                    ) {
                        isHovered = hovered
                    }
                }
            }
            .help("\(name) 프로필 보기")
            .accessibilityLabel("\(name) 프로필 보기")
        } else {
            avatar
        }
    }

    private var avatar: some View {
        CharacterAvatar(
            name: name,
            characterID: characterID,
            size: size
        )
    }
}

private struct CharacterProfileBadgeButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(
                configuration.isPressed
                    ? CharacterFullBodyProfilePresentationMetrics
                        .avatarPressedScale
                    : 1
            )
            .animation(
                .spring(response: 0.22, dampingFraction: 0.60),
                value: configuration.isPressed
            )
    }
}

private struct CharacterProfilePresentationActionKey: EnvironmentKey {
    static let defaultValue: ((String) -> Void)? = nil
}

extension EnvironmentValues {
    var presentCharacterProfile: ((String) -> Void)? {
        get { self[CharacterProfilePresentationActionKey.self] }
        set { self[CharacterProfilePresentationActionKey.self] = newValue }
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
