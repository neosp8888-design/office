// 이 파일은 격리 작업공간의 변경 비교와 승인·거절 및 병합 결과를 표시한다.

import SwiftUI

typealias WorkspaceReviewResolver =
    @MainActor (
        String,
        WorkspaceReviewDecision
    ) async throws -> TurnWorkspaceReview

struct WorkspaceReviewPanel: View {
    let turnID: String
    let workspace: TurnWorkspaceReview
    let resolveReview: WorkspaceReviewResolver

    @State private var detailedReview: TurnWorkspaceReview?
    @State private var isWorkRecordListExpanded = false
    @State private var isResolving = false
    @State private var showsApprovalConfirmation = false
    @State private var requestError: String?

    private static let visibleFileLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !currentReview.changedFiles.isEmpty {
                changedFileSummary
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
                self.detailedReview = nil
                isWorkRecordListExpanded = false
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

    private func resolve(_ decision: WorkspaceReviewDecision) {
        guard !isResolving else {
            return
        }
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
}

struct WorkspaceReviewFileGroups: Equatable {
    let primary: [WorkspaceChangedFile]
    let workRecords: [WorkspaceChangedFile]

    init(files: [WorkspaceChangedFile]) {
        primary = files.filter { !$0.isRoutineWorkRecord }
        workRecords = files.filter(\.isRoutineWorkRecord)
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
}
