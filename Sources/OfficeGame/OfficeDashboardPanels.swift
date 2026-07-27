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
    @ObservedObject var director: AgentDirector
    let selection: OfficeDetailSelection

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
                    ArchiveShelfContent(turns: director.liveTurns)
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
                    }
                    .foregroundStyle(.tertiary)
                }
                .padding(14)
            } else if let errorMessage {
                ContentUnavailableView(
                    "한도를 불러오지 못했습니다",
                    systemImage: "wifi.exclamationmark",
                    description: Text(errorMessage)
                )
            } else {
                ProgressView("CLI 한도를 확인하는 중")
            }
        }
        .task {
            await refresh()
        }
    }

    @MainActor
    private func refresh() async {
        do {
            snapshot = try await CodexBarUsageReader.fetch()
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
    @State private var isFollowingLatest = true
    @State private var bottomMarkerOffset = CGFloat.zero
    @State private var scrollViewportHeight = CGFloat.zero
    @State private var visibleTurnAnchorID: String?

    private static let followDistance = CGFloat(400)
    private static let bottomMarkerID = "live-workspace-feed-bottom"

    private var displayTurns: [LiveFeedTurn] {
        Array(director.liveTurns.reversed())
    }

    private var latestActivityUpdate: Date? {
        director.liveTurns.map(\.updatedAt).max()
    }

    var body: some View {
        ScrollViewReader { proxy in
            Group {
                if displayTurns.isEmpty {
                    ContentUnavailableView(
                        "아직 업무 대화가 없습니다",
                        systemImage: "bubble.left.and.text.bubble.right",
                        description: Text(
                            "오피스에서 직원을 선택하고 첫 업무를 보내보세요."
                        )
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 0) {
                            LazyVStack(spacing: 14) {
                                ForEach(displayTurns) { turn in
                                    LiveTurnCard(turn: turn)
                                        .id(turn.id)
                                        .background {
                                            GeometryReader { geometry in
                                                Color.clear.preference(
                                                    key: LiveWorkspaceFeedTurnFrameKey.self,
                                                    value: [
                                                        turn.id: geometry.frame(
                                                            in: .named(
                                                                LiveWorkspaceFeedScrollSpace.name
                                                            )
                                                        ),
                                                    ]
                                                )
                                            }
                                        }
                                }
                            }

                            LiveWorkspaceFeedBottomMarker()
                                .frame(height: 16)
                                .id(Self.bottomMarkerID)
                        }
                        .padding(.horizontal, 18)
                        .padding(.top, 16)
                    }
                    .coordinateSpace(name: LiveWorkspaceFeedScrollSpace.name)
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .onAppear {
                                    scrollViewportHeight = geometry.size.height
                                    updateFollowingLatest()
                                }
                                .onChange(of: geometry.size) {
                                    _, size in
                                    let wasFollowingLatest =
                                        isFollowingLatest
                                    let readingAnchorID = visibleTurnAnchorID
                                    scrollViewportHeight = size.height
                                    if wasFollowingLatest {
                                        scrollToLatest(
                                            proxy,
                                            animated: false
                                        )
                                    } else if let readingAnchorID {
                                        restoreReadingPosition(
                                            readingAnchorID,
                                            proxy: proxy
                                        )
                                    }
                                }
                        }
                    }
                    .onPreferenceChange(
                        LiveWorkspaceFeedBottomOffsetKey.self
                    ) { bottomOffset in
                        bottomMarkerOffset = bottomOffset
                        updateFollowingLatest()
                    }
                    .onPreferenceChange(
                        LiveWorkspaceFeedTurnFrameKey.self
                    ) { frames in
                        visibleTurnAnchorID = readingAnchorID(in: frames)
                            ?? visibleTurnAnchorID
                    }
                    .onAppear {
                        scrollToLatest(proxy)
                    }
                    .onChange(of: latestActivityUpdate) {
                        _, _ in
                        guard isFollowingLatest else {
                            return
                        }
                        scrollToLatest(proxy)
                    }
                    .onChange(of: director.latestSubmittedCommandID) {
                        _, _ in
                        scrollToLatest(proxy)
                    }
                    .onChange(of: director.latestStartedCommandID) {
                        _, _ in
                        scrollToLatest(proxy)
                    }
                    .onChange(of: director.latestCompletedTurnID) {
                        _, turnID in
                        guard let turnID else {
                            return
                        }
                        scrollToTurn(
                            turnID,
                            proxy: proxy,
                            anchor: .bottom
                        )
                    }
                    .onChange(of: director.selectedCharacterID) {
                        _, character in
                        guard
                            let character,
                            let turnID = latestTurnID(for: character)
                        else {
                            return
                        }
                        scrollToTurn(
                            turnID,
                            proxy: proxy,
                            anchor: .bottom
                        )
                    }
                }
            }
        }
    }

    private func scrollToLatest(
        _ proxy: ScrollViewProxy,
        animated: Bool = true
    ) {
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

    private func restoreReadingPosition(
        _ turnID: String,
        proxy: ScrollViewProxy
    ) {
        DispatchQueue.main.async {
            proxy.scrollTo(turnID, anchor: .top)
        }
    }

    private func readingAnchorID(in frames: [String: CGRect]) -> String? {
        displayTurns.first { turn in
            guard let frame = frames[turn.id] else {
                return false
            }
            return frame.maxY > 0
        }?.id
    }

    private func latestTurnID(for character: OfficeCharacter) -> String? {
        director.liveTurns.first {
            $0.characterId == character.rawValue
        }?.id
    }

    private func scrollToTurn(
        _ turnID: String,
        proxy: ScrollViewProxy,
        anchor: UnitPoint
    ) {
        isFollowingLatest = false
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.24)) {
                proxy.scrollTo(turnID, anchor: anchor)
            }
        }
    }

    private func updateFollowingLatest() {
        let distanceFromBottom = max(
            0,
            bottomMarkerOffset - scrollViewportHeight
        )
        isFollowingLatest = distanceFromBottom < Self.followDistance
    }
}

private enum LiveWorkspaceFeedScrollSpace {
    static let name = "live-workspace-feed"
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

private struct LiveWorkspaceFeedTurnFrameKey: PreferenceKey {
    static var defaultValue: [String: CGRect] = [:]

    static func reduce(
        value: inout [String: CGRect],
        nextValue: () -> [String: CGRect]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, latest in latest })
    }
}

private struct LiveTurnCard: View {
    let turn: LiveFeedTurn
    @State private var activitiesExpanded: Bool
    @State private var animatesResponse: Bool
    @State private var responseCopied: Bool

    init(turn: LiveFeedTurn) {
        self.turn = turn
        _activitiesExpanded = State(initialValue: false)
        _animatesResponse = State(initialValue: turn.status.isRunning)
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
                    ProgressView()
                        .controlSize(.mini)
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
                source: turn.response,
                animates: animatesResponse,
                isStreaming: turn.status.isRunning
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
    let source: String
    let animates: Bool
    let isStreaming: Bool

    private static let responseFontSize = CGFloat(14)

    @State private var displayedSource: String
    @State private var isTyping: Bool

    init(source: String, animates: Bool, isStreaming: Bool) {
        self.source = source
        self.animates = animates
        self.isStreaming = isStreaming
        _displayedSource = State(initialValue: animates ? "" : source)
        _isTyping = State(initialValue: animates)
    }

    var body: some View {
        Group {
            if isTyping {
                ZStack(alignment: .topLeading) {
                    ConversationMarkdownView(
                        source: source,
                        fontSize: Self.responseFontSize
                    )
                    .hidden()
                    .accessibilityHidden(true)

                    Text(displayedSource)
                        .font(
                            .system(
                                size: Self.responseFontSize
                            )
                        )
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )
                }
            } else {
                ConversationMarkdownView(
                    source: source,
                    fontSize: Self.responseFontSize
                )
                    .textSelection(.enabled)
            }
        }
        .task(
            id: LiveTypingTarget(
                source: source,
                animates: animates,
                isStreaming: isStreaming
            )
        ) {
            await updateDisplayedSource()
        }
    }

    private func updateDisplayedSource() async {
        guard animates else {
            displayedSource = source
            isTyping = false
            return
        }

        let target = Array(source)
        var displayed = Array(displayedSource)
        if !target.starts(with: displayed) {
            displayed = Array(displayed.prefix(sharedPrefixCount(
                displayed,
                target
            )))
            displayedSource = String(displayed)
        }

        isTyping = true
        var rendered = String(displayed)
        while displayed.count < target.count, !Task.isCancelled {
            let nextCharacter = target[displayed.count]
            displayed.append(nextCharacter)
            rendered.append(nextCharacter)
            displayedSource = rendered

            if displayed.count < target.count {
                try? await Task.sleep(for: .milliseconds(14))
            }
        }

        guard
            !Task.isCancelled,
            !isStreaming,
            displayedSource == source
        else {
            return
        }
        try? await Task.sleep(for: .milliseconds(60))
        if !Task.isCancelled {
            isTyping = false
        }
    }

    private func sharedPrefixCount(
        _ current: [Character],
        _ target: [Character]
    ) -> Int {
        var index = 0
        while
            index < current.count,
            index < target.count,
            current[index] == target[index]
        {
            index += 1
        }
        return index
    }
}

private struct LiveTypingTarget: Equatable {
    let source: String
    let animates: Bool
    let isStreaming: Bool
}

struct CharacterBadge: View {
    let name: String
    let characterID: String
    let size: CGFloat

    var body: some View {
        Text(String(name.prefix(1)))
            .font(.system(size: size * 0.38, weight: .bold, design: .rounded))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                DashboardPalette.characterAccent(for: characterID),
                in: Circle()
            )
            .overlay {
                Circle()
                    .stroke(.white.opacity(0.72), lineWidth: 2)
            }
            .shadow(
                color: DashboardPalette.characterAccent(
                    for: characterID
                ).opacity(0.20),
                radius: 5,
                y: 2
            )
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
