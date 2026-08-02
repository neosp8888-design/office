// 이 파일은 응답이 근거로 사용한 출처를 종류별로 한눈에 표시한다.

import SwiftUI

struct ResponseSourceWarningView: View {
    let message: String

    var body: some View {
        Label {
            Text(message)
                .textSelection(.enabled)
        } icon: {
            Image(systemName: "exclamationmark.triangle.fill")
        }
        .font(.system(size: 10.5, weight: .semibold))
        .foregroundStyle(Color.orange)
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            Color.orange.opacity(0.08),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .accessibilityIdentifier("responseSourceWarning")
    }
}

struct ResponseSourceList: View {
    let sources: [LiveFeedSource]
    let workspaceDirectory: String
    @State private var showsAllSources = false

    private static let collapsedLimit = 3

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label("응답 근거", systemImage: "link")
                .font(.system(size: 10.5, weight: .bold))
                .foregroundStyle(.secondary)

            ForEach(visibleSources) { source in
                ResponseSourceRow(
                    source: source,
                    workspaceDirectory: workspaceDirectory
                )
            }

            if sources.count > Self.collapsedLimit {
                Button {
                    showsAllSources.toggle()
                } label: {
                    Label(
                        showsAllSources
                            ? "출처 접기"
                            : "출처 \(sources.count - Self.collapsedLimit)개 더 보기",
                        systemImage:
                            showsAllSources ? "chevron.up" : "chevron.down"
                    )
                    .font(.system(size: 9.5, weight: .semibold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
            }
        }
        .padding(9)
        .background(
            Color.primary.opacity(0.025),
            in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .accessibilityIdentifier("responseSources")
    }

    private var visibleSources: ArraySlice<LiveFeedSource> {
        sources.prefix(
            showsAllSources ? sources.count : Self.collapsedLimit
        )
    }
}

private struct ResponseSourceRow: View {
    let source: LiveFeedSource
    let workspaceDirectory: String

    var body: some View {
        HStack(alignment: .top, spacing: 7) {
            Text(OfficeLocalization.string(source.sourceKind.title))
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(sourceColor)
                .padding(.horizontal, 6)
                .frame(height: 18)
                .background(sourceColor.opacity(0.10), in: Capsule())

            VStack(alignment: .leading, spacing: 3) {
                Text(source.title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .textSelection(.enabled)

                if source.sourceKind == .file {
                    WorkspaceFileRevealButton(
                        title: source.locator,
                        path: source.filePath,
                        workspaceDirectory: workspaceDirectory,
                        foregroundColor: .secondary,
                        accessibilityIdentifier: "responseSource-\(source.id)"
                    )
                } else if let webURL = source.webURL {
                    Link(destination: webURL) {
                        sourceLocatorText
                    }
                    .accessibilityIdentifier("responseSource-\(source.id)")
                } else {
                    sourceLocatorText
                }

                if let excerpt = source.excerpt, !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var sourceColor: Color {
        switch source.sourceKind {
        case .rag:
            .purple
        case .database:
            .blue
        case .file:
            .green
        case .web:
            .cyan
        case .tool:
            .orange
        case .skill:
            .pink
        }
    }

    private var sourceLocatorText: some View {
        Text(source.locator)
            .font(.system(size: 9.5, design: .monospaced))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
    }
}
