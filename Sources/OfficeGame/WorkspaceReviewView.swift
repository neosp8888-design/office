// 이 파일은 격리 작업공간의 변경 비교와 승인·거절 및 병합 결과를 표시한다.

import AppKit
import SwiftUI

typealias WorkspaceReviewFetcher =
    @MainActor (String) async throws -> TurnWorkspaceReview
typealias WorkspaceReviewResolver =
    @MainActor (
        String,
        WorkspaceReviewDecision
    ) async throws -> TurnWorkspaceReview

struct WorkspaceReviewPanel: View {
    let turnID: String
    let workspace: TurnWorkspaceReview
    let fetchReview: WorkspaceReviewFetcher
    let resolveReview: WorkspaceReviewResolver

    @State private var detailedReview: TurnWorkspaceReview?
    @State private var isDiffExpanded = false
    @State private var isWorkRecordListExpanded = false
    @State private var isRawDiffExpanded = false
    @State private var isWorkRecordDiffExpanded = false
    @State private var isLoadingDiff = false
    @State private var isResolving = false
    @State private var diffRequestGeneration = 0
    @State private var showsApprovalConfirmation = false
    @State private var requestError: String?

    private static let visibleFileLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !currentReview.changedFiles.isEmpty {
                changedFileSummary
                diffSection
            }

            if let message = requestError ?? currentReview.errorMessage {
                Label(
                    message,
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.red)
            }

            actions
        }
        .padding(11)
        .background(
            statusColor.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(statusColor.opacity(0.22))
        }
        .onChange(of: workspace) { _, updatedWorkspace in
            requestError = nil
            guard let detailedReview else {
                return
            }
            if
                detailedReview.reviewTree != updatedWorkspace.reviewTree
                    || detailedReview.baseCommit
                        != updatedWorkspace.baseCommit
            {
                diffRequestGeneration += 1
                isLoadingDiff = false
                self.detailedReview = nil
                isDiffExpanded = false
                isWorkRecordListExpanded = false
                isRawDiffExpanded = false
                isWorkRecordDiffExpanded = false
                return
            }
            if
                detailedReview.status != updatedWorkspace.status
                    || detailedReview.headCommit
                        != updatedWorkspace.headCommit
                    || detailedReview.mergedCommit
                        != updatedWorkspace.mergedCommit
                    || detailedReview.errorMessage
                        != updatedWorkspace.errorMessage
            {
                self.detailedReview = updatedWorkspace
            }
        }
        .confirmationDialog(
            "\(currentReview.baseBranch) 브랜치에 병합할까요?",
            isPresented: $showsApprovalConfirmation,
            titleVisibility: .visible
        ) {
            Button("승인 후 \(currentReview.baseBranch) 병합") {
                approveCurrentReview()
            }
            Button("취소", role: .cancel) {}
        } message: {
            Text(
                "\(currentReview.branchName)의 변경 "
                    + "\(currentReview.changedFiles.count)개를 "
                    + "\(currentReview.baseBranch)에 병합합니다."
            )
        }
    }

    private var currentReview: TurnWorkspaceReview {
        detailedReview ?? workspace
    }

    private var fileGroups: WorkspaceReviewFileGroups {
        WorkspaceReviewFileGroups(files: currentReview.changedFiles)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: statusIcon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(statusColor)
                .frame(width: 28, height: 28)
                .background(
                    statusColor.opacity(0.11),
                    in: RoundedRectangle(cornerRadius: 8)
                )

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(statusTitle)
                        .font(.system(size: 12.5, weight: .bold))

                    if currentReview.status == .merging || isResolving {
                        ProgressView()
                            .controlSize(.mini)
                            .tint(statusColor)
                    }
                }

                Text(
                    "\(currentReview.branchName) → "
                        + currentReview.baseBranch
                )
                .font(.system(size: 9.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

                if let commit = resultCommit {
                    Text(String(commit.prefix(12)))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer(minLength: 6)

            Text("\(currentReview.changedFiles.count)개 파일")
                .font(.system(size: 9.5, weight: .bold))
                .foregroundStyle(statusColor)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(statusColor.opacity(0.10), in: Capsule())
        }
    }

    private var changedFileSummary: some View {
        VStack(alignment: .leading, spacing: 5) {
            if !fileGroups.primary.isEmpty {
                fileGroupLabel(
                    title: "검토할 변경",
                    count: fileGroups.primary.count
                )
                changedFileRows(
                    Array(fileGroups.primary.prefix(Self.visibleFileLimit))
                )
            } else {
                Label("작업 기록만 변경됨", systemImage: "doc.text")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            let hiddenFileCount = max(
                0,
                fileGroups.primary.count - Self.visibleFileLimit
            )
            if hiddenFileCount > 0 {
                Text("그 외 \(hiddenFileCount)개 파일")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 31)
            }

            if !fileGroups.workRecords.isEmpty {
                DisclosureGroup(isExpanded: $isWorkRecordListExpanded) {
                    changedFileRows(fileGroups.workRecords)
                        .padding(.top, 5)
                } label: {
                    fileGroupLabel(
                        title: "작업 기록",
                        count: fileGroups.workRecords.count,
                        systemImage: "doc.text"
                    )
                    .contentShape(Rectangle())
                }
                .tint(.secondary)
                .accessibilityIdentifier("workspaceWorkRecords-\(turnID)")
            }
        }
        .padding(9)
        .background(
            Color.primary.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
    }

    private var diffSection: some View {
        VStack(alignment: .leading, spacing: 7) {
            Button {
                toggleDiff()
            } label: {
                HStack(spacing: 6) {
                    Image(
                        systemName: isDiffExpanded
                            ? "chevron.down"
                            : "chevron.right"
                    )
                    Text("핵심 변경 요약")
                    if isLoadingDiff {
                        ProgressView()
                            .controlSize(.mini)
                    }
                }
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(statusColor)
            }
            .buttonStyle(.plain)
            .disabled(isLoadingDiff)
            .accessibilityIdentifier("workspaceDiff-\(turnID)")

            if isDiffExpanded {
                Group {
                    if let diff = currentReview.diff, !diff.isEmpty {
                        let summary = WorkspaceReviewDiffSummary(
                            diff: diff,
                            files: currentReview.changedFiles,
                            isPartial: currentReview.diffTruncated == true
                        )
                        diffSummary(summary)
                    } else if !isLoadingDiff {
                        Text("줄 단위로 요약할 텍스트 변경이 없습니다.")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                if currentReview.diffTruncated == true {
                    HStack(spacing: 8) {
                        Label(
                            "diff가 길어 표시된 범위만 요약했습니다. 승인에는 영향이 없습니다.",
                            systemImage: "scissors"
                        )
                        .font(.system(size: 9.5, weight: .semibold))
                        .foregroundStyle(.orange)

                        Spacer()

                        Button("전체 worktree 열기") {
                            openWorktreeInFinder()
                        }
                        .font(.system(size: 9.5, weight: .semibold))
                        .accessibilityIdentifier(
                            "openWorkspaceInFinder-\(turnID)"
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        switch currentReview.status {
        case .awaitingApproval:
            // 자동 병합 예정이면 확인 버튼을 아예 만들지 않는다.
            // 잠깐 나타났다 사라지면 카드 높이가 흔들린다.
            if currentReview.awaitsUserDecision {
                HStack(spacing: 8) {
                    Spacer()

                    Button("거절", role: .destructive) {
                        resolve(.reject)
                    }
                    .disabled(isResolving)
                    .accessibilityIdentifier("rejectWorkspace-\(turnID)")

                    Button("승인 후 \(currentReview.baseBranch) 병합") {
                        showsApprovalConfirmation = true
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isResolving)
                    .help("검토한 변경사항을 원본 브랜치에 병합합니다.")
                    .accessibilityIdentifier("approveWorkspace-\(turnID)")
                }
            }
        case .conflict:
            HStack(spacing: 8) {
                Spacer()
                Button("충돌 작업 거절", role: .destructive) {
                    resolve(.reject)
                }
                .disabled(isResolving)
                .accessibilityIdentifier("rejectWorkspace-\(turnID)")

                Button("다시 병합") {
                    retryCurrentReview()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isResolving || !currentReview.canRetryMerge)
                .help("같은 검토 버전을 최신 main에 다시 병합합니다.")
                .accessibilityIdentifier("retryWorkspace-\(turnID)")
            }
        case .active, .merging, .merged, .rejected, .closed, .failed:
            EmptyView()
        }
    }

    private var statusTitle: String {
        switch currentReview.status {
        case .active:
            "격리 작업공간 사용 중"
        case .awaitingApproval:
            currentReview.showsAutomaticMergeProgress
                ? "\(currentReview.baseBranch) 자동 병합 중"
                : "변경사항 검토 필요"
        case .merging:
            "승인된 변경사항 병합 중"
        case .merged:
            "\(currentReview.baseBranch) 병합 완료"
        case .rejected:
            "변경사항 거절됨"
        case .closed:
            "변경 없는 작업공간 종료됨"
        case .conflict:
            "병합 충돌"
        case .failed:
            "작업공간 처리 실패"
        }
    }

    private var statusIcon: String {
        switch currentReview.status {
        case .active:
            "hammer.fill"
        case .awaitingApproval:
            currentReview.showsAutomaticMergeProgress
                ? "arrow.triangle.merge"
                : "doc.text.magnifyingglass"
        case .merging:
            "arrow.triangle.merge"
        case .merged:
            "checkmark.seal.fill"
        case .rejected:
            "nosign"
        case .closed:
            "checkmark.circle.fill"
        case .conflict:
            "exclamationmark.triangle.fill"
        case .failed:
            "xmark.octagon.fill"
        }
    }

    private var statusColor: Color {
        switch currentReview.status {
        case .active, .merging:
            DashboardPalette.accent
        case .awaitingApproval:
            currentReview.showsAutomaticMergeProgress
                ? DashboardPalette.accent
                : .orange
        case .merged:
            .green
        case .rejected, .closed:
            .secondary
        case .conflict, .failed:
            .red
        }
    }

    private var resultCommit: String? {
        currentReview.mergedCommit ?? currentReview.headCommit
    }

    private func toggleDiff() {
        if isDiffExpanded {
            isDiffExpanded = false
            isRawDiffExpanded = false
            isWorkRecordDiffExpanded = false
            return
        }

        isDiffExpanded = true
        guard currentReview.diff == nil, !isLoadingDiff else {
            return
        }
        isLoadingDiff = true
        requestError = nil
        diffRequestGeneration += 1
        let requestGeneration = diffRequestGeneration
        Task {
            defer {
                if requestGeneration == diffRequestGeneration {
                    isLoadingDiff = false
                }
            }
            do {
                let review = try await fetchReview(turnID)
                guard requestGeneration == diffRequestGeneration else {
                    return
                }
                detailedReview = review
            } catch {
                guard requestGeneration == diffRequestGeneration else {
                    return
                }
                requestError = error.localizedDescription
            }
        }
    }

    private func resolve(_ decision: WorkspaceReviewDecision) {
        guard !isResolving else {
            return
        }
        diffRequestGeneration += 1
        isLoadingDiff = false
        isResolving = true
        requestError = nil
        Task {
            defer {
                isResolving = false
            }
            do {
                detailedReview = try await resolveReview(turnID, decision)
            } catch {
                requestError = error.localizedDescription
            }
        }
    }

    private func approveCurrentReview() {
        guard
            currentReview.canApprove,
            let reviewTree = currentReview.reviewTree
        else {
            return
        }
        resolve(.approve(reviewTree: reviewTree))
    }

    private func retryCurrentReview() {
        guard
            currentReview.canRetryMerge,
            let reviewTree = currentReview.reviewTree
        else {
            return
        }
        resolve(.approve(reviewTree: reviewTree))
    }

    private func openWorktreeInFinder() {
        let directory = currentReview.reviewFileBaseDirectory(
            fallback: currentReview.repositoryRoot
        )
        guard !directory.isEmpty else {
            return
        }
        _ = NSWorkspace.shared.open(
            URL(fileURLWithPath: directory, isDirectory: true)
        )
    }

    @ViewBuilder
    private func changedFileRows(_ files: [WorkspaceChangedFile]) -> some View {
        ForEach(files) { file in
            HStack(spacing: 7) {
                Text(file.status)
                    .font(.system(size: 9, weight: .bold, design: .monospaced))
                    .foregroundStyle(statusColor)
                    .frame(width: 24, alignment: .leading)

                WorkspaceFileRevealButton(
                    title: file.reviewDisplayPath,
                    path: file.path,
                    workspaceDirectory: currentReview
                        .reviewFileBaseDirectory(
                            fallback: currentReview.repositoryRoot
                        ),
                    foregroundColor: .secondary,
                    accessibilityIdentifier:
                        "reviewFile-\(turnID)-\(file.id)"
                )
            }
        }
    }

    private func fileGroupLabel(
        title: String,
        count: Int,
        systemImage: String? = nil
    ) -> some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
            }
            Text(title)
            Spacer(minLength: 6)
            Text("\(count)개")
                .foregroundStyle(.tertiary)
        }
        .font(.system(size: 9.5, weight: .semibold))
        .foregroundStyle(.secondary)
    }

    private func diffSummary(_ summary: WorkspaceReviewDiffSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                Text(summary.isPartial ? "표시된 범위" : "핵심 변경")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)

                Text("+\(summary.totalAdditions)줄")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.green)

                Text("-\(summary.totalDeletions)줄")
                    .font(.system(size: 10, weight: .bold, design: .monospaced))
                    .foregroundStyle(.red)

                Spacer(minLength: 4)
            }

            Text(summary.statusSummary)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(Array(summary.files.prefix(Self.visibleFileLimit))) { file in
                diffFileSummary(file)
            }

            let hiddenCount = max(
                0,
                summary.files.count - Self.visibleFileLimit
            )
            if hiddenCount > 0 {
                Text("그 외 \(hiddenCount)개 파일")
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }

            if let diff = currentReview.diff, !diff.isEmpty {
                rawDiffDisclosure(diff)
            }
        }
    }

    private func diffFileSummary(
        _ summary: WorkspaceReviewFileSummary
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Text(summary.file.reviewStatusTitle)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(reviewStatusColor(summary.file))
                    .padding(.horizontal, 6)
                    .frame(height: 19)
                    .background(
                        reviewStatusColor(summary.file).opacity(0.10),
                        in: Capsule()
                    )

                WorkspaceFileRevealButton(
                    title: summary.file.reviewDisplayPath,
                    path: summary.file.path,
                    workspaceDirectory: currentReview
                        .reviewFileBaseDirectory(
                            fallback: currentReview.repositoryRoot
                        ),
                    foregroundColor: .primary,
                    accessibilityIdentifier:
                        "reviewSummaryFile-\(turnID)-\(summary.id)"
                )

                Spacer(minLength: 4)

                if summary.additions > 0 {
                    Text("+\(summary.additions)")
                        .foregroundStyle(.green)
                }
                if summary.deletions > 0 {
                    Text("-\(summary.deletions)")
                        .foregroundStyle(.red)
                }
            }
            .font(.system(size: 9.5, weight: .bold, design: .monospaced))

            if let note = summary.note {
                Text(note)
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if !summary.removedLines.isEmpty || !summary.addedLines.isEmpty {
                HStack(alignment: .top, spacing: 6) {
                    if !summary.removedLines.isEmpty {
                        diffSnippet(
                            title: "삭제된 내용",
                            lines: summary.removedLines,
                            color: .red
                        )
                    }
                    if !summary.addedLines.isEmpty {
                        diffSnippet(
                            title: "추가된 내용",
                            lines: summary.addedLines,
                            color: .green
                        )
                    }
                }
            }
        }
        .padding(8)
        .background(
            Color.primary.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func diffSnippet(
        title: String,
        lines: [String],
        color: Color
    ) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(color)

            ForEach(Array(lines.enumerated()), id: \.offset) { _, line in
                Text(line.isEmpty ? "빈 줄" : line)
                    .font(.system(size: 8.5, design: .monospaced))
                    .foregroundStyle(color.opacity(0.92))
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(6)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(
            color.opacity(0.065),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
    }

    private func rawDiffDisclosure(_ diff: String) -> some View {
        let diffGroups = WorkspaceReviewDiffGroups(diff: diff)
        return DisclosureGroup(isExpanded: $isRawDiffExpanded) {
            VStack(alignment: .leading, spacing: 7) {
                if !diffGroups.primary.isEmpty {
                    diffText(diffGroups.primary)
                }

                if !diffGroups.workRecords.isEmpty {
                    DisclosureGroup(isExpanded: $isWorkRecordDiffExpanded) {
                        diffText(diffGroups.workRecords, maxHeight: 220)
                            .padding(.top, 6)
                    } label: {
                        fileGroupLabel(
                            title: "작업 기록 원문",
                            count: fileGroups.workRecords.count,
                            systemImage: "doc.text"
                        )
                        .contentShape(Rectangle())
                    }
                    .tint(.secondary)
                    .accessibilityIdentifier(
                        "workspaceWorkRecordDiff-\(turnID)"
                    )
                }
            }
            .padding(.top, 6)
        } label: {
            Label("Git 원문 상세 보기", systemImage: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
        }
        .tint(.secondary)
        .accessibilityIdentifier("workspaceRawDiff-\(turnID)")
    }

    private func reviewStatusColor(_ file: WorkspaceChangedFile) -> Color {
        switch file.status.first {
        case "A":
            .green
        case "D":
            .red
        case "R", "C":
            .blue
        default:
            .orange
        }
    }

    private func diffText(
        _ diff: String,
        maxHeight: CGFloat = 260
    ) -> some View {
        ScrollView([.horizontal, .vertical]) {
            Text(diff)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(Color.primary.opacity(0.82))
                .fixedSize(horizontal: true, vertical: true)
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(9)
        }
        .frame(maxHeight: maxHeight)
        .background(
            Color(nsColor: .textBackgroundColor).opacity(0.72),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }
}

struct WorkspaceReviewFileGroups: Equatable {
    let primary: [WorkspaceChangedFile]
    let workRecords: [WorkspaceChangedFile]

    init(files: [WorkspaceChangedFile]) {
        primary = files.filter { !$0.isRoutineWorkRecord }
        workRecords = files.filter(\.isRoutineWorkRecord)
    }
}

struct WorkspaceReviewDiffGroups: Equatable {
    let primary: String
    let workRecords: String

    init(diff: String) {
        let sections = Self.sections(in: diff)
        primary = sections
            .filter { !Self.isRoutineWorkRecordSection($0) }
            .joined(separator: "\n")
        workRecords = sections
            .filter(Self.isRoutineWorkRecordSection)
            .joined(separator: "\n")
    }

    private static let routineWorkRecordHeaders: Set<String> = {
        let paths = ["checklist.md", "context-notes.md"]
        return Set(paths.flatMap { previousPath in
            paths.map { path in
                "diff --git a/\(previousPath) b/\(path)"
            }
        })
    }()

    static func sections(in diff: String) -> [String] {
        guard diff.hasPrefix("diff --git ") else {
            return [diff]
        }

        var sections: [String] = []
        var currentLines: [Substring] = []
        for line in diff.split(
            separator: "\n",
            omittingEmptySubsequences: false
        ) {
            if line.hasPrefix("diff --git "), !currentLines.isEmpty {
                sections.append(currentLines.joined(separator: "\n"))
                currentLines.removeAll(keepingCapacity: true)
            }
            currentLines.append(line)
        }
        if !currentLines.isEmpty {
            sections.append(currentLines.joined(separator: "\n"))
        }
        return sections
    }

    private static func isRoutineWorkRecordSection(_ section: String) -> Bool {
        let header = section
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first
            .map(String.init) ?? ""
        return routineWorkRecordHeaders.contains(header)
    }
}

struct WorkspaceReviewDiffSummary: Equatable {
    let files: [WorkspaceReviewFileSummary]
    let totalAdditions: Int
    let totalDeletions: Int
    let isPartial: Bool

    init(diff: String, files: [WorkspaceChangedFile], isPartial: Bool) {
        let primaryFiles = WorkspaceReviewFileGroups(files: files).primary
        let primaryDiff = WorkspaceReviewDiffGroups(diff: diff).primary
        let sections: [String]
        if primaryDiff.hasPrefix("diff --git ") {
            sections = WorkspaceReviewDiffGroups.sections(in: primaryDiff)
        } else if primaryFiles.count == 1, !primaryDiff.isEmpty {
            sections = [primaryDiff]
        } else {
            sections = []
        }
        let parsedFiles = primaryFiles.enumerated().map { offset, file in
            WorkspaceReviewFileSummary(
                file: file,
                section: sections.indices.contains(offset)
                    ? sections[offset]
                    : nil,
                isPartial: isPartial
            )
        }

        self.files = parsedFiles
        totalAdditions = parsedFiles.reduce(0) { $0 + $1.additions }
        totalDeletions = parsedFiles.reduce(0) { $0 + $1.deletions }
        self.isPartial = isPartial
    }

    var statusSummary: String {
        let orderedTitles = ["추가", "수정", "삭제", "이름 변경", "복사", "변경"]
        let counts = Dictionary(grouping: files, by: { $0.file.reviewStatusTitle })
            .mapValues(\.count)
        let summary = orderedTitles.compactMap { title in
            counts[title].map { "\(title) \($0)" }
        }
        return summary.isEmpty ? "작업 기록만 변경됨" : summary.joined(separator: " · ")
    }
}

struct WorkspaceReviewFileSummary: Equatable, Identifiable {
    private static let snippetLimit = 4

    let file: WorkspaceChangedFile
    let additions: Int
    let deletions: Int
    let removedLines: [String]
    let addedLines: [String]
    let note: String?

    var id: String {
        file.id
    }

    init(
        file: WorkspaceChangedFile,
        section: String?,
        isPartial: Bool
    ) {
        let diffSection = section ?? ""
        var additionCount = 0
        var deletionCount = 0
        var additions: [String] = []
        var deletions: [String] = []
        var isInsideHunk = false
        var foundHunk = false

        let lines = diffSection.split(
            separator: "\n",
            omittingEmptySubsequences: false
        )
        for line in lines {
            if line.hasPrefix("@@") {
                isInsideHunk = true
                foundHunk = true
                continue
            }
            guard isInsideHunk, !line.hasPrefix("\\ No newline") else {
                continue
            }
            if line.hasPrefix("+") {
                additionCount += 1
                if additions.count < Self.snippetLimit {
                    additions.append(Self.snippet(from: line))
                }
            } else if line.hasPrefix("-") {
                deletionCount += 1
                if deletions.count < Self.snippetLimit {
                    deletions.append(Self.snippet(from: line))
                }
            }
        }

        self.file = file
        self.additions = additionCount
        self.deletions = deletionCount
        removedLines = deletions
        addedLines = additions
        if section == nil, isPartial {
            note = "표시 범위 밖이라 요약할 수 없습니다."
        } else {
            note = Self.note(
                for: file,
                section: diffSection,
                foundHunk: foundHunk,
                additions: additionCount,
                deletions: deletionCount
            )
        }
    }

    private static func snippet(from line: Substring) -> String {
        String(line.dropFirst())
            .trimmingCharacters(in: .whitespaces)
    }

    private static func note(
        for file: WorkspaceChangedFile,
        section: String,
        foundHunk: Bool,
        additions: Int,
        deletions: Int
    ) -> String? {
        if isBinarySection(section) {
            return "바이너리 내용은 화면에서 비교할 수 없습니다."
        }
        guard !foundHunk, additions == 0, deletions == 0 else {
            return nil
        }
        if file.status.hasPrefix("R") {
            return "파일 이름만 변경되었습니다."
        }
        if file.status.hasPrefix("C") {
            return "파일이 복사되었습니다."
        }
        if section.contains("old mode ") || section.contains("new mode ") {
            return "파일 속성만 변경되었습니다."
        }
        return "줄 단위 내용 변경이 없습니다."
    }

    private static func isBinarySection(_ section: String) -> Bool {
        for line in section.split(separator: "\n") {
            if line.hasPrefix("@@") {
                return false
            }
            if line == "GIT binary patch" || line.hasPrefix("Binary files ") {
                return true
            }
        }
        return false
    }
}

extension WorkspaceChangedFile {
    private static let routineWorkRecordPaths: Set<String> = [
        "checklist.md",
        "context-notes.md",
    ]

    var isRoutineWorkRecord: Bool {
        guard Self.routineWorkRecordPaths.contains(path) else {
            return false
        }
        guard status.hasPrefix("R") || status.hasPrefix("C") else {
            return true
        }
        guard let previousPath else {
            return false
        }
        return Self.routineWorkRecordPaths.contains(previousPath)
    }

    var reviewDisplayPath: String {
        guard
            let previousPath,
            previousPath != path,
            status.hasPrefix("R") || status.hasPrefix("C")
        else {
            return path
        }
        return "\(previousPath) → \(path)"
    }

    var reviewStatusTitle: String {
        switch status.first {
        case "A":
            "추가"
        case "M":
            "수정"
        case "D":
            "삭제"
        case "R":
            "이름 변경"
        case "C":
            "복사"
        default:
            "변경"
        }
    }
}
