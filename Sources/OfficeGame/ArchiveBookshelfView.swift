// 이 파일은 대화 기록을 간결한 타일과 좌우 페이지형 상세 화면으로 표시한다.

import AppKit
import SwiftUI

struct ArchiveRecordGrid: View {
    let turns: [LiveFeedTurn]
    let onSelect: (LiveFeedTurn) -> Void

    var body: some View {
        LazyVGrid(
            columns: [
                GridItem(
                    .adaptive(minimum: 220, maximum: 360),
                    spacing: 8
                ),
            ],
            alignment: .leading,
            spacing: 8
        ) {
            ForEach(turns) { turn in
                ArchiveRecordTile(turn: turn) {
                    onSelect(turn)
                }
            }
        }
    }
}

private struct ArchiveRecordTile: View {
    let turn: LiveFeedTurn
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 10) {
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(bookColor)
                    .frame(width: 4)

                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 6) {
                        Text(String(turn.characterName.prefix(1)))
                            .font(
                                .system(
                                    size: 10,
                                    weight: .black,
                                    design: .rounded
                                )
                            )
                            .foregroundStyle(bookColor)
                            .frame(width: 22, height: 22)
                            .background(
                                bookColor.opacity(0.11),
                                in: Circle()
                            )

                        Text(turn.characterName)
                            .font(.system(size: 10, weight: .bold))

                        if turn.status.isRunning {
                            Text("업무 중")
                                .foregroundStyle(Color.green)
                        } else if turn.needsInput {
                            Text("답변 필요")
                                .foregroundStyle(Color.orange)
                        }

                        Spacer()

                        Text(
                            turn.startedAt.formatted(
                                date: .omitted,
                                time: .shortened
                            )
                        )
                        .foregroundStyle(.tertiary)
                    }
                    .font(.system(size: 8.5, weight: .bold))

                    Text(recordTitle)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.primary.opacity(0.82))
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                        .frame(
                            maxWidth: .infinity,
                            alignment: .leading
                        )

                    Text(executionSummary)
                        .font(.system(size: 8.5, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, minHeight: 82)
            .background(
                Color(nsColor: .controlBackgroundColor).opacity(0.60),
                in: RoundedRectangle(
                    cornerRadius: 10,
                    style: .continuous
                )
            )
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.primary.opacity(0.06))
            }
        }
        .buttonStyle(.plain)
        .help("\(turn.characterName) · \(turn.prompt)")
        .accessibilityLabel(
            "\(turn.characterName) 기록 · \(turn.prompt)"
        )
    }

    private var bookColor: Color {
        DashboardPalette.characterAccent(for: turn.characterId)
    }

    private var recordTitle: String {
        let title = turn.prompt.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        return title.isEmpty ? "제목 없는 업무" : title
    }

    private var executionSummary: String {
        guard let backend = turn.backend else {
            return "이전 기록"
        }

        var parts = [backend.title]
        if let model = turn.model {
            parts.append(backend.modelTitle(model))
        }
        if let effort = turn.effort {
            parts.append("추론 \(effort)")
        }
        return parts.joined(separator: " · ")
    }
}

struct ArchiveOpenBook: View {
    let turn: LiveFeedTurn
    let onClose: () -> Void
    @State private var copiedKey: String?

    var body: some View {
        VStack(spacing: 0) {
            bookToolbar

            GeometryReader { geometry in
                let pageWidth = max(
                    0,
                    (geometry.size.width - 30) / 2
                )

                HStack(spacing: 0) {
                    leftPage
                        .frame(width: pageWidth)

                    bookBinding
                        .frame(width: 14)

                    rightPage
                        .frame(width: pageWidth)
                }
                .padding(.horizontal, 8)
                .padding(.bottom, 10)
            }
        }
        .background(
            LinearGradient(
                colors: [
                    bookColor.opacity(0.055),
                    Color.primary.opacity(0.012),
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        )
    }

    private var bookToolbar: some View {
        HStack(spacing: 9) {
            Button(action: onClose) {
                Label("목록", systemImage: "chevron.left")
                    .font(.system(size: 10, weight: .bold))
                    .padding(.horizontal, 9)
                    .frame(height: 26)
                    .background(
                        Color.primary.opacity(0.055),
                        in: Capsule()
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("기록 목록으로 돌아가기")

            CharacterBadge(
                name: turn.characterName,
                characterID: turn.characterId,
                size: 25
            )

            VStack(alignment: .leading, spacing: 1) {
                Text(turn.characterName)
                    .font(.system(size: 11, weight: .bold))
                Text(
                    turn.startedAt.formatted(
                        date: .abbreviated,
                        time: .shortened
                    )
                )
                .font(.system(size: 8.5, weight: .medium))
                .foregroundStyle(.secondary)
            }

            Spacer()

            Label(statusTitle, systemImage: "bookmark.fill")
                .font(.system(size: 9, weight: .bold))
                .foregroundStyle(bookColor)
        }
        .padding(.horizontal, 12)
        .frame(height: 43)
    }

    private var leftPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                pageHeading("장서 정보", systemImage: "info.circle.fill")

                VStack(spacing: 7) {
                    metadataRow(
                        label: "세션 ID",
                        value: turn.externalSessionId ?? "기록 없음",
                        monospaced: true,
                        copyKey: "session",
                        copyText: turn.externalSessionId
                    )
                    metadataRow(
                        label: "모델",
                        value: modelTitle
                    )
                    metadataRow(
                        label: "추론",
                        value: turn.effort ?? "기록 없음"
                    )
                }
                .padding(9)
                .background(
                    Color.primary.opacity(0.035),
                    in: RoundedRectangle(cornerRadius: 9)
                )

                pageHeading("업무", systemImage: "text.quote")

                Text(turn.prompt)
                    .font(.system(size: 11, weight: .semibold))
                    .lineSpacing(2)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
        }
        .background(
            pageBackground,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07))
        }
        .shadow(color: .black.opacity(0.08), radius: 6, x: -2, y: 3)
    }

    private var rightPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    pageHeading(
                        turn.response.isEmpty ? "기록" : "응답",
                        systemImage:
                            turn.response.isEmpty
                            ? "ellipsis.bubble"
                            : "checkmark.bubble.fill"
                    )

                    Spacer()

                    if !turn.response.isEmpty {
                        copyButton(
                            key: "response",
                            text: turn.response,
                            label: "응답 복사"
                        )
                    }
                }

                if !turn.response.isEmpty {
                    ConversationMarkdownView(
                        source: turn.response,
                        fontSize: 14
                    )
                } else if let error = turn.errorMessage {
                    Text(error)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.red.opacity(0.86))
                        .textSelection(.enabled)
                } else {
                    Text("업무가 진행 중입니다.")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(12)
        }
        .background(
            pageBackground,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.primary.opacity(0.07))
        }
        .shadow(color: .black.opacity(0.08), radius: 6, x: 2, y: 3)
    }

    private var bookBinding: some View {
        LinearGradient(
            colors: [
                Color.black.opacity(0.04),
                bookColor.opacity(0.22),
                Color.black.opacity(0.07),
            ],
            startPoint: .leading,
            endPoint: .trailing
        )
        .overlay {
            Rectangle()
                .fill(Color.white.opacity(0.28))
                .frame(width: 1)
        }
        .padding(.vertical, 5)
    }

    private var pageBackground: some ShapeStyle {
        LinearGradient(
            colors: [
                Color(nsColor: .textBackgroundColor),
                Color(red: 0.98, green: 0.96, blue: 0.89)
                    .opacity(0.56),
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func pageHeading(
        _ title: String,
        systemImage: String
    ) -> some View {
        Label(title, systemImage: systemImage)
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(bookColor)
    }

    private var modelTitle: String {
        guard let backend = turn.backend, let model = turn.model else {
            return "기록 없음"
        }
        return "\(backend.title) · \(backend.modelTitle(model))"
    }

    private func metadataRow(
        label: String,
        value: String,
        monospaced: Bool = false,
        copyKey: String? = nil,
        copyText: String? = nil
    ) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(label)
                .font(.system(size: 8.5, weight: .bold))
                .foregroundStyle(.secondary)
                .frame(width: 42, alignment: .leading)

            Text(value)
                .font(
                    monospaced
                        ? .system(size: 8.5, design: .monospaced)
                        : .system(size: 9.5, weight: .medium)
                )
                .textSelection(.enabled)
                .lineLimit(monospaced ? 1 : 2)
                .truncationMode(.middle)

            Spacer(minLength: 3)

            if let copyKey, let copyText {
                copyButton(
                    key: copyKey,
                    text: copyText,
                    label: "\(label) 복사",
                    compact: true
                )
            }
        }
    }

    private func copyButton(
        key: String,
        text: String,
        label: String,
        compact: Bool = false
    ) -> some View {
        Button {
            copyToPasteboard(text, key: key)
        } label: {
            Group {
                if compact {
                    Image(
                        systemName:
                            copiedKey == key
                            ? "checkmark"
                            : "doc.on.doc"
                    )
                } else {
                    Label(
                        copiedKey == key ? "복사됨" : "복사",
                        systemImage:
                            copiedKey == key
                            ? "checkmark"
                            : "doc.on.doc"
                    )
                }
            }
            .font(.system(size: 8.5, weight: .bold))
            .padding(.horizontal, compact ? 4 : 7)
            .frame(height: 22)
            .background(
                Color.primary.opacity(0.05),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func copyToPasteboard(_ text: String, key: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedKey = key

        Task {
            try? await Task.sleep(for: .seconds(1.3))
            if !Task.isCancelled, copiedKey == key {
                copiedKey = nil
            }
        }
    }

    private var statusTitle: String {
        switch turn.status {
        case .pending:
            "대기 중"
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

    private var bookColor: Color {
        DashboardPalette.characterAccent(for: turn.characterId)
    }
}
