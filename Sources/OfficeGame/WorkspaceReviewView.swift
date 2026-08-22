// 이 파일은 격리 작업공간의 변경과 명시적 통합 결과를 표시한다.

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

    @State private var isWorkRecordListExpanded = false

    private static let visibleFileLimit = 12

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !currentReview.changedFiles.isEmpty {
                changedFileSummary
            }

            if let message = currentReview.errorMessage {
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
    }

    private var currentReview: TurnWorkspaceReview {
        workspace
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

                    if currentReview.status == .merging {
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
                    title: "통합할 변경",
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
            Label(
                "통합·재빌드·재시작을 요청하면 반영됩니다.",
                systemImage: "tray.full.fill"
            )
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.secondary)
        case .conflict:
            Label(
                "통합 충돌 해결을 요청하세요.",
                systemImage: "exclamationmark.triangle.fill"
            )
            .font(.system(size: 10.5, weight: .semibold))
            .foregroundStyle(.red)
        case .active, .merging, .merged, .rejected, .closed, .failed:
            EmptyView()
        }
    }

    private var statusTitle: String {
        switch currentReview.status {
        case .active:
            "격리 작업공간 사용 중"
        case .awaitingApproval:
            "변경사항 통합 대기"
        case .merging:
            "변경사항 통합 중"
        case .merged:
            "\(currentReview.baseBranch) 통합 완료"
        case .rejected:
            "변경사항 거절됨"
        case .closed:
            "변경 없는 작업공간 종료됨"
        case .conflict:
            "통합 충돌"
        case .failed:
            "작업공간 처리 실패"
        }
    }

    private var statusIcon: String {
        switch currentReview.status {
        case .active:
            "hammer.fill"
        case .awaitingApproval:
            "tray.full.fill"
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
            .orange
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
