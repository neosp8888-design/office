// 이 파일은 승인된 사내 지식과 사용자 확인 대기 제안을 독립 패널로 표시한다.

import SwiftUI

enum WikiKnowledgeSection: String, CaseIterable, Identifiable {
    case knowledge
    case pending

    var id: String {
        rawValue
    }

    var title: String {
        switch self {
        case .knowledge:
            "현재 지식"
        case .pending:
            "확인 대기"
        }
    }

    var icon: String {
        switch self {
        case .knowledge:
            "doc.text.magnifyingglass"
        case .pending:
            "checkmark.seal"
        }
    }
}

enum WikiKnowledgeLayout {
    static let stackedThreshold: CGFloat = 470

    static func usesStackedLayout(for width: CGFloat) -> Bool {
        width < stackedThreshold
    }
}

enum WikiKnowledgeSelection {
    static func resolvedPageID(
        current: String?,
        pages: [WikiPage]
    ) -> String? {
        if let current, pages.contains(where: { $0.id == current }) {
            return current
        }
        return pages.first?.id
    }

    static func normalizedRejectionReason(_ reason: String) -> String {
        reason.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private struct WikiKnowledgeLoadIdentity: Hashable {
    let section: WikiKnowledgeSection
    let query: String
    let reloadID: UUID
}

struct WikiKnowledgeView: View {
    let databaseBaseURL: URL

    @State private var section = WikiKnowledgeSection.knowledge
    @State private var searchText = ""
    @State private var pages: [WikiPage] = []
    @State private var selectedPageID: String?
    @State private var proposals: [WikiProposal] = []
    @State private var isLoading = true
    @State private var loadError: String?
    @State private var reloadID = UUID()
    @State private var submittingProposalIDs: Set<String> = []
    @State private var rejectionReasons: [String: String] = [:]
    @State private var proposalErrors: [String: String] = [:]
    @State private var actionNotice: String?

    private static let pageLimit = 60

    var body: some View {
        VStack(spacing: 0) {
            toolbar

            Divider()
                .opacity(0.45)

            content
        }
        .accessibilityIdentifier("wikiKnowledgeView")
        .task(id: loadIdentity) {
            if section == .knowledge && !normalizedSearchText.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
            }
            guard !Task.isCancelled else {
                return
            }
            await load(section: section, query: normalizedSearchText)
        }
    }

    private var toolbar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 6) {
                ForEach(WikiKnowledgeSection.allCases) { item in
                    Button {
                        withAnimation(.easeInOut(duration: 0.16)) {
                            section = item
                            actionNotice = nil
                            loadError = nil
                        }
                    } label: {
                        Label(item.title, systemImage: item.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .padding(.horizontal, 9)
                            .frame(height: 27)
                            .background(
                                section == item
                                    ? DashboardPalette.accent.opacity(0.14)
                                    : Color.clear,
                                in: Capsule()
                            )
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(
                        section == item
                            ? DashboardPalette.accent
                            : Color.secondary
                    )
                    .accessibilityLabel(item.title)
                    .accessibilityValue(
                        section == item ? "선택됨" : ""
                    )
                    .accessibilityIdentifier("wikiSection-\(item.rawValue)")
                }

                Spacer(minLength: 4)

                Button {
                    reloadID = UUID()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 26, height: 26)
                }
                .buttonStyle(.plain)
                .disabled(isLoading)
                .accessibilityLabel("위키 새로고침")
                .accessibilityIdentifier("wikiRefreshButton")
                .help("위키 새로고침")
            }

            if section == .knowledge {
                searchBar
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    private var searchBar: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("제목·본문 검색", text: $searchText)
                .textFieldStyle(.plain)
                .font(.system(size: 12))
                .accessibilityLabel("위키 검색")
                .accessibilityIdentifier("wikiSearchField")

            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("위키 검색어 지우기")
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(
            Color.primary.opacity(0.045),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView(
                section == .knowledge
                    ? "지식을 불러오는 중"
                    : "확인 대상을 불러오는 중"
            )
            .font(.system(size: 11, weight: .medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityIdentifier("wikiLoadingState")
        } else if let loadError {
            WikiUnavailableState(
                title: "위키를 불러오지 못했습니다",
                systemImage: "exclamationmark.triangle",
                description: loadError,
                actionTitle: "다시 시도"
            ) {
                reloadID = UUID()
            }
            .accessibilityIdentifier("wikiErrorState")
        } else {
            switch section {
            case .knowledge:
                knowledgeContent
            case .pending:
                pendingContent
            }
        }
    }

    @ViewBuilder
    private var knowledgeContent: some View {
        if pages.isEmpty {
            WikiUnavailableState(
                title: normalizedSearchText.isEmpty
                    ? "아직 승인된 지식이 없습니다"
                    : "검색 결과가 없습니다",
                systemImage: normalizedSearchText.isEmpty
                    ? "books.vertical"
                    : "text.magnifyingglass",
                description: normalizedSearchText.isEmpty
                    ? "승인된 제안이 이곳에 축적됩니다."
                    : "다른 검색어로 다시 찾아보세요."
            )
            .accessibilityIdentifier("wikiKnowledgeEmptyState")
        } else {
            GeometryReader { geometry in
                if WikiKnowledgeLayout.usesStackedLayout(
                    for: geometry.size.width
                ) {
                    VStack(spacing: 0) {
                        pageList
                            .frame(
                                height: min(
                                    145,
                                    max(92, geometry.size.height * 0.34)
                                )
                            )
                        Divider().opacity(0.5)
                        pageDetail
                    }
                } else {
                    HStack(spacing: 0) {
                        pageList
                            .frame(width: min(210, geometry.size.width * 0.36))
                        Divider().opacity(0.5)
                        pageDetail
                    }
                }
            }
        }
    }

    private var pageList: some View {
        ScrollView {
            LazyVStack(spacing: 5) {
                ForEach(pages) { page in
                    Button {
                        selectedPageID = page.id
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .firstTextBaseline, spacing: 5) {
                                Text(page.title)
                                    .font(.system(size: 12, weight: .semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)

                                Spacer(minLength: 2)

                                if selectedPageID == page.id {
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 8, weight: .bold))
                                        .foregroundStyle(
                                            DashboardPalette.accent
                                        )
                                }
                            }

                            Text(page.pageKey)
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)

                            Text(
                                page.updatedAt.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                        }
                        .padding(9)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            selectedPageID == page.id
                                ? DashboardPalette.accent.opacity(0.10)
                                : Color.primary.opacity(0.025),
                            in: RoundedRectangle(
                                cornerRadius: 9,
                                style: .continuous
                            )
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(page.title)
                    .accessibilityValue(
                        selectedPageID == page.id ? "선택됨" : ""
                    )
                    .accessibilityIdentifier("wikiPage-\(page.id)")
                }
            }
            .padding(9)
        }
        .accessibilityIdentifier("wikiPageList")
    }

    @ViewBuilder
    private var pageDetail: some View {
        if let selectedPage {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(selectedPage.title)
                            .font(.system(size: 17, weight: .bold))
                            .textSelection(.enabled)

                        HStack(spacing: 7) {
                            Text(selectedPage.pageKey)
                                .font(.system(size: 10, design: .monospaced))
                            Text("·")
                            Text(
                                selectedPage.updatedAt.formatted(
                                    date: .abbreviated,
                                    time: .shortened
                                )
                            )
                        }
                        .foregroundStyle(.secondary)
                        .font(.system(size: 10))
                        .textSelection(.enabled)
                    }

                    ConversationMarkdownView(
                        source: selectedPage.body,
                        fontSize: 12
                    )
                    .textSelection(.enabled)

                    Divider().opacity(0.5)

                    VStack(alignment: .leading, spacing: 8) {
                        Label(
                            "근거 \(selectedPage.sources.count)건",
                            systemImage: "link"
                        )
                        .font(.system(size: 11, weight: .bold))

                        if selectedPage.sources.isEmpty {
                            Text("연결된 업무 기록이 없습니다.")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            ForEach(selectedPage.sources) { source in
                                WikiSourceCard(source: source)
                            }
                        }
                    }
                    .accessibilityIdentifier("wikiPageSources")
                }
                .padding(14)
            }
            .accessibilityIdentifier("wikiPageDetail")
        } else {
            WikiUnavailableState(
                title: "지식을 선택하세요",
                systemImage: "doc.text",
                description: "목록에서 문서를 선택하면 본문과 근거가 열립니다."
            )
        }
    }

    @ViewBuilder
    private var pendingContent: some View {
        if proposals.isEmpty {
            WikiUnavailableState(
                title: "확인할 제안이 없습니다",
                systemImage: "checkmark.circle",
                description: "사용자 승인이 필요한 지식 제안이 여기에 표시됩니다."
            )
            .accessibilityIdentifier("wikiPendingEmptyState")
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let actionNotice {
                        Label(actionNotice, systemImage: "checkmark.circle.fill")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(DashboardPalette.accent)
                            .padding(.horizontal, 4)
                            .accessibilityIdentifier("wikiActionNotice")
                    }

                    ForEach(proposals) { proposal in
                        WikiProposalCard(
                            proposal: proposal,
                            rejectionReason: rejectionReasonBinding(
                                for: proposal.id
                            ),
                            isSubmitting: submittingProposalIDs.contains(
                                proposal.id
                            ),
                            errorMessage: proposalErrors[proposal.id],
                            approve: {
                                Task {
                                    await decide(
                                        proposal,
                                        decision: .approve
                                    )
                                }
                            },
                            reject: {
                                Task {
                                    await decide(
                                        proposal,
                                        decision: .reject
                                    )
                                }
                            }
                        )
                    }
                }
                .padding(12)
            }
            .accessibilityIdentifier("wikiProposalList")
        }
    }

    private var selectedPage: WikiPage? {
        guard let selectedPageID else {
            return nil
        }
        return pages.first(where: { $0.id == selectedPageID })
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var loadIdentity: WikiKnowledgeLoadIdentity {
        WikiKnowledgeLoadIdentity(
            section: section,
            query: section == .knowledge ? normalizedSearchText : "",
            reloadID: reloadID
        )
    }

    private func rejectionReasonBinding(for id: String) -> Binding<String> {
        Binding(
            get: { rejectionReasons[id, default: ""] },
            set: { rejectionReasons[id] = $0 }
        )
    }

    @MainActor
    private func load(
        section requestedSection: WikiKnowledgeSection,
        query: String
    ) async {
        isLoading = true
        loadError = nil
        let client = OfficeDatabaseClient(baseURL: databaseBaseURL)

        do {
            switch requestedSection {
            case .knowledge:
                let nextPages = try await client.fetchWikiPages(
                    query: query,
                    limit: Self.pageLimit
                )
                guard !Task.isCancelled, section == requestedSection else {
                    return
                }
                pages = nextPages
                selectedPageID = WikiKnowledgeSelection.resolvedPageID(
                    current: selectedPageID,
                    pages: nextPages
                )
            case .pending:
                let nextProposals = try await client.fetchWikiProposals()
                guard !Task.isCancelled, section == requestedSection else {
                    return
                }
                proposals = nextProposals
                proposalErrors = proposalErrors.filter { id, _ in
                    nextProposals.contains(where: { $0.id == id })
                }
                rejectionReasons = rejectionReasons.filter { id, _ in
                    nextProposals.contains(where: { $0.id == id })
                }
            }
            isLoading = false
        } catch {
            guard !Task.isCancelled, section == requestedSection else {
                return
            }
            isLoading = false
            loadError = error.localizedDescription
        }
    }

    @MainActor
    private func decide(
        _ proposal: WikiProposal,
        decision: WikiProposalDecision
    ) async {
        guard !submittingProposalIDs.contains(proposal.id) else {
            return
        }

        submittingProposalIDs.insert(proposal.id)
        proposalErrors[proposal.id] = nil
        actionNotice = nil
        let client = OfficeDatabaseClient(baseURL: databaseBaseURL)

        do {
            switch decision {
            case .approve:
                _ = try await client.approveWikiProposal(id: proposal.id)
                actionNotice = "‘\(proposal.title)’ 제안을 승인했습니다."
            case .reject:
                let reason = WikiKnowledgeSelection.normalizedRejectionReason(
                    rejectionReasons[proposal.id, default: ""]
                )
                _ = try await client.rejectWikiProposal(
                    id: proposal.id,
                    reason: reason
                )
                actionNotice = "‘\(proposal.title)’ 제안을 거절했습니다."
            }

            proposals.removeAll(where: { $0.id == proposal.id })
            rejectionReasons[proposal.id] = nil
            proposalErrors[proposal.id] = nil
        } catch {
            proposalErrors[proposal.id] = error.localizedDescription
        }

        submittingProposalIDs.remove(proposal.id)
    }
}

private enum WikiProposalDecision {
    case approve
    case reject
}

private struct WikiSourceCard: View {
    let source: WikiPageSource

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(source.title)
                .font(.system(size: 11, weight: .semibold))
                .textSelection(.enabled)

            Text(source.excerpt)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .lineLimit(5)
                .textSelection(.enabled)

            Text(source.workRecordId)
                .font(.system(size: 9, design: .monospaced))
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("wikiSource-\(source.workRecordId)")
    }
}

private struct WikiProposalCard: View {
    let proposal: WikiProposal
    @Binding var rejectionReason: String
    let isSubmitting: Bool
    let errorMessage: String?
    let approve: () -> Void
    let reject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                VStack(alignment: .leading, spacing: 3) {
                    Text(proposal.title)
                        .font(.system(size: 14, weight: .bold))
                        .textSelection(.enabled)

                    Text(proposal.pageKey)
                        .font(.system(size: 9.5, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }

                Spacer(minLength: 6)

                Text(proposal.approvalTier)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DashboardPalette.accent)
                    .padding(.horizontal, 7)
                    .frame(height: 21)
                    .background(
                        DashboardPalette.accent.opacity(0.11),
                        in: Capsule()
                    )
            }

            ConversationMarkdownView(source: proposal.body, fontSize: 11.5)
                .textSelection(.enabled)

            if !proposal.sourceRecordIds.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    Text("근거 업무 기록")
                        .font(.system(size: 10, weight: .semibold))
                    Text(proposal.sourceRecordIds.joined(separator: " · "))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            HStack(spacing: 7) {
                TextField("거절 사유 (선택)", text: $rejectionReason)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11))
                    .disabled(isSubmitting)
                    .accessibilityIdentifier(
                        "wikiRejectReason-\(proposal.id)"
                    )

                Button("승인") {
                    approve()
                }
                .buttonStyle(.borderedProminent)
                .tint(DashboardPalette.accent)
                .disabled(isSubmitting)
                .accessibilityIdentifier("wikiApprove-\(proposal.id)")

                Button("거절", role: .destructive) {
                    reject()
                }
                .buttonStyle(.bordered)
                .disabled(isSubmitting)
                .accessibilityIdentifier("wikiReject-\(proposal.id)")

                if isSubmitting {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("처리 중")
                }
            }

            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier(
                        "wikiProposalError-\(proposal.id)"
                    )
            }

            Text(
                proposal.createdAt.formatted(
                    date: .abbreviated,
                    time: .shortened
                )
            )
            .font(.system(size: 9))
            .foregroundStyle(.tertiary)
        }
        .padding(12)
        .background(
            Color.primary.opacity(0.035),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.07))
        }
        .accessibilityIdentifier("wikiProposal-\(proposal.id)")
    }
}

private struct WikiUnavailableState: View {
    let title: String
    let systemImage: String
    let description: String
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        title: String,
        systemImage: String,
        description: String,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(.secondary)

            Text(title)
                .font(.system(size: 13, weight: .bold))

            Text(description)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 300)

            if let actionTitle, let action {
                Button(actionTitle, action: action)
                    .buttonStyle(.bordered)
                    .accessibilityIdentifier("wikiRetryButton")
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
