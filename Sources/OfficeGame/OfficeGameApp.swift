// 이 파일은 2D·3D 오피스와 명령 입력창을 네이티브 macOS 창에 표시한다.

import AppKit
import OfficeCore
import SwiftUI

@main
struct OfficeGameApp: App {
    @StateObject private var director = AgentDirector()

    var body: some Scene {
        WindowGroup("OFFICESTRA") {
            OfficeGameView(director: director)
        }
        .defaultSize(width: 1_440, height: 900)
        .windowResizability(.contentMinSize)
    }
}

enum OfficeSplitLayout {
    static func columnWidths(
        availableWidth: CGFloat,
        fraction: Double,
        minimumColumnWidth: CGFloat
    ) -> (left: CGFloat, right: CGFloat) {
        guard availableWidth > 0 else {
            return (.zero, .zero)
        }
        let requestedLeftWidth = availableWidth
            * CGFloat(min(max(fraction, 0), 1))
        let left = clampedLeftWidth(
            requestedLeftWidth,
            availableWidth: availableWidth,
            minimumColumnWidth: minimumColumnWidth
        )
        return (left, availableWidth - left)
    }

    static func clampedLeftWidth(
        _ width: CGFloat,
        availableWidth: CGFloat,
        minimumColumnWidth: CGFloat
    ) -> CGFloat {
        guard availableWidth > 0 else {
            return .zero
        }
        let minimum = min(max(0, minimumColumnWidth), availableWidth / 2)
        return min(max(width, minimum), availableWidth - minimum)
    }

    static func rowHeights(
        availableHeight: CGFloat,
        fraction: Double
    ) -> (top: CGFloat, bottom: CGFloat) {
        guard availableHeight > 0 else {
            return (.zero, .zero)
        }
        let requestedTopHeight = availableHeight
            * CGFloat(min(max(fraction, 0), 1))
        let top = clampedTopHeight(
            requestedTopHeight,
            availableHeight: availableHeight
        )
        return (top, availableHeight - top)
    }

    static func clampedTopHeight(
        _ height: CGFloat,
        availableHeight: CGFloat
    ) -> CGFloat {
        guard availableHeight > 0 else {
            return .zero
        }
        let minimum = availableHeight / 3
        return min(max(height, minimum), availableHeight - minimum)
    }
}

private struct OfficeGameView: View {
    @ObservedObject var director: AgentDirector
    @State private var command = ""
    @State private var attachments: [URL] = []
    @State private var showsCharacterSettings = false
    @State private var historyTarget: ConversationHistoryTarget?
    @State private var bubbleDetail: BubbleDetail?
    @State private var detailSelection = OfficeDetailSelection.archive
    @State private var outgoingArtStyle: OfficeArtStyle?
    @State private var artStyleRevealProgress: CGFloat = 1
    @State private var splitDragStartLeftWidth: CGFloat?
    @State private var splitDragStartTopHeight: CGFloat?
    @Namespace private var characterSelectionAnimation
    @AppStorage("officeTheme") private var selectedThemeRawValue =
        OfficeTheme.modernDay.rawValue
    @AppStorage("officeArtStyle") private var selectedArtStyleRawValue =
        OfficeArtStyle.twoD.rawValue
    @AppStorage("officeLeftColumnFraction") private var leftColumnFraction =
        0.5
    @AppStorage("officeTopRowFraction") private var topRowFraction = 0.5
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        GeometryReader { geometry in
            let outerPadding: CGFloat = 14
            let columnDividerWidth: CGFloat = 14
            let rowDividerHeight: CGFloat = 14
            let availableColumnWidth = max(
                0,
                geometry.size.width - outerPadding * 2 - columnDividerWidth
            )
            let columns = OfficeSplitLayout.columnWidths(
                availableWidth: availableColumnWidth,
                fraction: leftColumnFraction,
                minimumColumnWidth: 210
            )
            let availableRowHeight = max(
                0,
                geometry.size.height - outerPadding * 2 - rowDividerHeight
            )
            let rows = OfficeSplitLayout.rowHeights(
                availableHeight: availableRowHeight,
                fraction: topRowFraction
            )

            HStack(spacing: 0) {
                VStack(spacing: 0) {
                    officePanel
                        .frame(height: rows.top)

                    OfficeRowResizeHandle(
                        onDragChanged: { translation in
                            updateTopRowFraction(
                                translation: translation,
                                topRowHeight: rows.top,
                                availableRowHeight: availableRowHeight
                            )
                        },
                        onDragEnded: {
                            splitDragStartTopHeight = nil
                        }
                    )
                    .frame(height: rowDividerHeight)

                    OfficeDetailPanel(
                        director: director,
                        selection: detailSelection
                    )
                    .frame(height: rows.bottom)
                }
                .frame(width: columns.left)

                OfficeColumnResizeHandle(
                    onDragChanged: { translation in
                        updateLeftColumnFraction(
                            translation: translation,
                            leftColumnWidth: columns.left,
                            availableColumnWidth: availableColumnWidth
                        )
                    },
                    onDragEnded: {
                        splitDragStartLeftWidth = nil
                    }
                )
                .frame(width: columnDividerWidth)

                liveWorkspacePanel
                    .frame(width: columns.right)
                    .frame(height: availableRowHeight + rowDividerHeight)
            }
            .padding(outerPadding)
        }
        .background(
            DashboardPalette.canvas(isNight: theme.isNight)
                .ignoresSafeArea()
        )
        .preferredColorScheme(theme.isNight ? .dark : .light)
        .frame(minWidth: 1_180, minHeight: 760)
        .sheet(item: $historyTarget) { target in
            switch target {
            case .character(let character):
                CharacterConversationHistoryView(
                    director: director,
                    character: character
                )
            case .archive:
                ConversationArchiveView(director: director)
            }
        }
        .sheet(item: $bubbleDetail) { detail in
            BubbleDetailView(
                director: director,
                character: detail.character,
                name: detail.name,
                message: detail.message,
                isQuestion: detail.isQuestion,
                isFailure: detail.isFailure,
                isOffDuty: detail.isOffDuty
            )
        }
        .onAppear {
            director.selectDefaultCharacterIfNeeded()
        }
        .onChange(of: director.latestQuestion) { _, question in
            guard let question else {
                if
                    let detail = bubbleDetail,
                    detail.isQuestion,
                    director.pendingQuestion(for: detail.character) == nil
                {
                    bubbleDetail = nil
                }
                return
            }
            guard bubbleDetail == nil, historyTarget == nil else {
                return
            }
            bubbleDetail = BubbleDetail(
                character: question.character,
                name: director.displayName(for: question.character),
                message: question.text,
                isQuestion: true,
                isFailure: false,
                isOffDuty: false
            )
        }
    }

    private func updateLeftColumnFraction(
        translation: CGFloat,
        leftColumnWidth: CGFloat,
        availableColumnWidth: CGFloat
    ) {
        guard availableColumnWidth > 0 else {
            return
        }
        let start = splitDragStartLeftWidth ?? leftColumnWidth
        if splitDragStartLeftWidth == nil {
            splitDragStartLeftWidth = start
        }
        let updatedWidth = OfficeSplitLayout.clampedLeftWidth(
            start + translation,
            availableWidth: availableColumnWidth,
            minimumColumnWidth: 210
        )
        leftColumnFraction = Double(updatedWidth / availableColumnWidth)
    }

    private func updateTopRowFraction(
        translation: CGFloat,
        topRowHeight: CGFloat,
        availableRowHeight: CGFloat
    ) {
        guard availableRowHeight > 0 else {
            return
        }
        let start = splitDragStartTopHeight ?? topRowHeight
        if splitDragStartTopHeight == nil {
            splitDragStartTopHeight = start
        }
        let updatedHeight = OfficeSplitLayout.clampedTopHeight(
            start + translation,
            availableHeight: availableRowHeight
        )
        topRowFraction = Double(updatedHeight / availableRowHeight)
    }

    private var officePanel: some View {
        ZStack {
            if let outgoingArtStyle {
                officeArtwork(artStyle: outgoingArtStyle)
                    .id("style-\(outgoingArtStyle.rawValue)")

                officeArtwork(artStyle: artStyle)
                    .id("style-\(artStyle.rawValue)")
                    .mask {
                        OfficeArtStyleRevealMask(
                            progress: artStyleRevealProgress
                        )
                    }
            } else {
                officeArtwork(artStyle: artStyle)
                    .id("style-\(artStyle.rawValue)")
            }

            CharacterInteractionLayer(
                director: director,
                artStyle: artStyle,
                onMonitorTapped: {
                    historyTarget = .character($0)
                },
                onArchiveCabinetTapped: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        detailSelection = .archive
                    }
                },
                onWhiteboardTapped: {
                    withAnimation(.easeInOut(duration: 0.18)) {
                        detailSelection = .usage
                    }
                },
                onBubbleTapped: { character, message in
                    let offDutyReason = director.offDutyReason(
                        for: character
                    )
                    let failureMessage = director.failureMessage(
                        for: character
                    )
                    bubbleDetail = BubbleDetail(
                        character: character,
                        name: director.displayName(for: character),
                        message: offDutyReason ?? message,
                        isQuestion:
                            director.pendingQuestion(for: character) != nil,
                        isFailure: failureMessage != nil,
                        isOffDuty: offDutyReason != nil
                    )
                    if offDutyReason != nil || failureMessage != nil {
                        director.acknowledgeWarningBubble(for: character)
                    }
                }
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipShape(
            RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 7) {
                themeToggle
                artStyleToggle
                characterSettingsButton
            }
            .padding(12)
        }
        .officePanelStyle()
    }

    private var liveWorkspacePanel: some View {
        VStack(spacing: 0) {
            liveWorkspaceHeader

            Divider()
                .opacity(0.55)

            LiveWorkspaceFeed(director: director)
                .equatable()
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
                .opacity(0.55)

            commandBar
        }
        .officePanelStyle()
    }

    private var liveWorkspaceHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "bubble.left.and.text.bubble.right.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(DashboardPalette.accent)
                .frame(width: 36, height: 36)
                .background(
                    DashboardPalette.accent.opacity(0.10),
                    in: RoundedRectangle(
                        cornerRadius: 11,
                        style: .continuous
                    )
                )

            VStack(alignment: .leading, spacing: 2) {
                Text("실시간 대화")
                    .font(.system(size: 17, weight: .bold))
                Text(
                    String(
                        format: OfficeLocalization.string("%@의 대화와 진행 기록"),
                        director.selectedName
                            ?? OfficeLocalization.string("백부장")
                    )
                )
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer()

            HStack(spacing: 5) {
                Circle()
                    .fill(
                        director.isRealtimeConnected
                            ? Color.green
                            : Color.orange
                    )
                    .frame(width: 7, height: 7)
                Text(
                    director.isRealtimeConnected
                        ? "LIVE"
                        : "연결 중"
                )
            }
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(.secondary)
            .help(
                director.realtimeConnectionError
                    ?? "백엔드 WebSocket 실시간 연결"
            )
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
    }

    private var theme: OfficeTheme {
        let storedTheme =
            OfficeTheme(rawValue: selectedThemeRawValue)
            ?? .modernDay
        return storedTheme.isNight ? .modernNight : .modernDay
    }

    private var artStyle: OfficeArtStyle {
        OfficeArtStyle(rawValue: selectedArtStyleRawValue)
            ?? .twoD
    }

    @ViewBuilder
    private func officeArtwork(
        artStyle: OfficeArtStyle
    ) -> some View {
        ZStack {
            letterboxBackground(for: artStyle)
                .animation(.easeInOut(duration: 0.18), value: theme)

            OfficeRealtimeView(
                theme: theme,
                style: artStyle,
                isActive: scenePhase == .active,
                reduceMotion: reduceMotion,
                bossActivity: director.runningCharacters.contains(.boss)
                    ? .speaking
                    : .working
            )
            .accessibilityHidden(true)

            WhiteboardUsageLayer(
                isActive: scenePhase == .active,
                artStyle: artStyle
            )
        }
    }

    private func letterboxBackground(
        for artStyle: OfficeArtStyle
    ) -> LinearGradient {
        let colors: [Color]
        if artStyle == .twoD {
            colors = theme.isNight
                ? [
                    Color(
                        red: 87 / 255,
                        green: 106 / 255,
                        blue: 154 / 255
                    ),
                    Color(
                        red: 87 / 255,
                        green: 106 / 255,
                        blue: 153 / 255
                    ),
                    Color(
                        red: 86 / 255,
                        green: 105 / 255,
                        blue: 151 / 255
                    ),
                ]
                : [
                    Color(
                        red: 239 / 255,
                        green: 219 / 255,
                        blue: 205 / 255
                    ),
                    Color(
                        red: 240 / 255,
                        green: 220 / 255,
                        blue: 204 / 255
                    ),
                    Color(
                        red: 238 / 255,
                        green: 218 / 255,
                        blue: 202 / 255
                    ),
                ]
        } else {
            colors = theme.edgeBackdropColors.map {
                Color(nsColor: $0)
            }
        }

        return LinearGradient(
            colors: colors,
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private var themeToggle: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.18)) {
                selectedThemeRawValue = theme.isNight
                    ? OfficeTheme.modernDay.rawValue
                    : OfficeTheme.modernNight.rawValue
            }
        } label: {
            Image(
                systemName: theme.isNight
                    ? "moon.stars.fill"
                    : "sun.max.fill"
            )
            .font(.system(size: 15, weight: .semibold))
            .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, theme.isNight ? .dark : .light)
        .foregroundStyle(theme.isNight ? Color.white : Color.black.opacity(0.72))
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            theme.isNight
                ? Color.black.opacity(0.72)
                : Color.white.opacity(0.92),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    theme.isNight
                        ? Color.white.opacity(0.25)
                        : Color.black.opacity(0.08)
                )
        }
        .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
        .fixedSize()
        .accessibilityLabel("오피스 테마")
        .accessibilityValue(theme.title)
        .accessibilityIdentifier("officeThemeMenu")
        .help(theme.isNight ? "낮 테마로 전환" : "밤 테마로 전환")
    }

    private var artStyleToggle: some View {
        Button {
            toggleArtStyle()
        } label: {
            HStack(spacing: 2) {
                artStyleSegment(
                    title: "2D",
                    isSelected: artStyle == .twoD
                )
                artStyleSegment(
                    title: "3D",
                    isSelected: artStyle == .threeD
                )
            }
            .padding(2)
        }
        .buttonStyle(.plain)
        .disabled(outgoingArtStyle != nil)
        .environment(\.colorScheme, theme.isNight ? .dark : .light)
        .frame(height: 32)
        .background(
            theme.isNight
                ? Color.black.opacity(0.72)
                : Color.white.opacity(0.92),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    theme.isNight
                        ? Color.white.opacity(0.25)
                        : Color.black.opacity(0.08)
                )
        }
        .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
        .fixedSize()
        .accessibilityLabel("오피스 표현 방식")
        .accessibilityValue(artStyle.title)
        .accessibilityIdentifier("officeArtStyleToggle")
        .help(
            artStyle == .twoD
                ? "3D 오피스로 전환"
                : "2D 오피스로 전환"
        )
    }

    private func toggleArtStyle() {
        guard outgoingArtStyle == nil else {
            return
        }

        let previousStyle = artStyle
        let nextStyle: OfficeArtStyle =
            previousStyle == .twoD ? .threeD : .twoD

        guard !reduceMotion else {
            selectedArtStyleRawValue = nextStyle.rawValue
            return
        }

        outgoingArtStyle = previousStyle
        artStyleRevealProgress = 0
        selectedArtStyleRawValue = nextStyle.rawValue

        Task { @MainActor in
            await Task.yield()
            withAnimation(.easeInOut(duration: 1.55)) {
                artStyleRevealProgress = 1
            }
            try? await Task.sleep(for: .seconds(1.6))
            guard artStyle == nextStyle else {
                return
            }
            outgoingArtStyle = nil
            artStyleRevealProgress = 1
        }
    }

    private func artStyleSegment(
        title: String,
        isSelected: Bool
    ) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .bold, design: .rounded))
            .foregroundStyle(
                isSelected
                    ? DashboardPalette.accent
                    : theme.isNight
                    ? Color.white.opacity(0.52)
                    : Color.black.opacity(0.42)
            )
            .frame(width: 25, height: 26)
            .background(
                isSelected
                    ? DashboardPalette.accent.opacity(
                        theme.isNight ? 0.25 : 0.13
                    )
                    : Color.clear,
                in: Capsule()
            )
    }

    private var commandBar: some View {
        VStack(alignment: .leading, spacing: 9) {
            characterSelector

            if let character = director.selectedCharacter {
                HStack {
                    AgentQuickSettingsView(
                        director: director,
                        character: character
                    )

                    Spacer(minLength: 0)
                }
            }

            if !attachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 7) {
                        ForEach(attachments, id: \.path) { attachment in
                            HStack(spacing: 5) {
                                Image(systemName: "doc.fill")
                                    .font(.system(size: 10))
                                    .foregroundStyle(
                                        DashboardPalette.accent
                                    )
                                Text(attachment.lastPathComponent)
                                    .font(.system(size: 11, weight: .medium))
                                    .lineLimit(1)
                                Button {
                                    removeAttachment(attachment)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                        .font(.system(size: 11))
                                        .foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel(
                                    "\(attachment.lastPathComponent) 첨부 제거"
                                )
                            }
                            .padding(.horizontal, 9)
                            .frame(height: 27)
                            .background(
                                Color.primary.opacity(0.055),
                                in: Capsule()
                            )
                        }
                    }
                }
            }

            HStack(spacing: 9) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(DashboardPalette.accent)

                CommandComposerView(
                    text: $command,
                    placeholder: commandPlaceholder,
                    isEnabled:
                        director.isReadyForSubmissions
                            && !director.isUpdatingConfiguration
                            && !director.selectedCharacterNeedsWorkspaceReview,
                    onSubmit: submitCommand
                )
                .frame(height: 40)

                Button {
                    chooseAttachments()
                } label: {
                    Image(systemName: "paperclip")
                        .font(.system(size: 15, weight: .semibold))
                        .frame(width: 32, height: 32)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("파일 첨부")
                .help("파일 첨부 · 한 번에 최대 20개")
                .disabled(attachmentSelectionIsDisabled)
                .opacity(attachmentSelectionIsDisabled ? 0.42 : 1)

                if director.isSelectedCharacterRunning {
                    Button(action: director.cancelSelectedJob) {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                Color.red.opacity(0.88),
                                in: RoundedRectangle(
                                    cornerRadius: 11,
                                    style: .continuous
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("대화 중단")
                    .help("현재 직원의 업무 중단")
                    .disabled(director.isCancellingSelectedCharacter)
                    .opacity(
                        director.isCancellingSelectedCharacter ? 0.42 : 1
                    )
                } else {
                    Button(action: submitCommand) {
                        Image(systemName: "paperplane.fill")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 36, height: 36)
                            .background(
                                DashboardPalette.accent,
                                in: RoundedRectangle(
                                    cornerRadius: 11,
                                    style: .continuous
                                )
                            )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("보내기")
                    .disabled(commandIsDisabled)
                    .opacity(commandIsDisabled ? 0.42 : 1)
                }
            }
            .padding(.leading, 13)
            .padding(.trailing, 7)
            .padding(.vertical, 6)
            .background(
                Color.primary.opacity(0.045),
                in: RoundedRectangle(cornerRadius: 14, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(Color.primary.opacity(0.07))
            }
        }
        .padding(14)
    }

    private var characterSelector: some View {
        HStack(spacing: 3) {
            ForEach(director.characters) { character in
                let isSelected =
                    director.selectedCharacterID == character.id
                let isRunning =
                    director.runningCharacters.contains(character.id)
                let name = director.displayName(for: character.id)
                let badgeColor = DashboardPalette.characterAccent(
                    for: character.id.rawValue
                )
                let isCompleted =
                    director.unreviewedCompletedCharacters.contains(
                        character.id
                    )

                Button {
                    withAnimation(
                        .spring(
                            response: 0.28,
                            dampingFraction: 0.84
                        )
                    ) {
                        director.select(character)
                    }
                } label: {
                    HStack(spacing: 7) {
                        CharacterAvatar(
                            name: name,
                            characterID: character.id.rawValue,
                            size: 24
                        )
                        .overlay {
                            Circle()
                                .stroke(
                                    isSelected
                                        ? badgeColor
                                        : .clear,
                                    lineWidth: 2
                                )
                        }

                        Text(name)
                            .font(
                                .system(
                                    size: 13,
                                    weight: isSelected
                                        ? .bold
                                        : .semibold
                                )
                            )
                            .foregroundStyle(
                                Color.primary.opacity(
                                    isSelected ? 0.88 : 0.56
                                )
                            )
                            .lineLimit(1)
                            .truncationMode(.tail)

                        if isRunning || isCompleted {
                            CharacterTaskStatusIndicator(
                                isRunning: isRunning,
                                isCompleted: isCompleted,
                                reduceMotion: reduceMotion
                            )
                        }
                    }
                    .padding(.horizontal, 7)
                    .frame(maxWidth: .infinity)
                    .frame(height: 38)
                    .contentShape(
                        RoundedRectangle(
                            cornerRadius: 10,
                            style: .continuous
                        )
                    )
                    .background {
                        if isSelected {
                            RoundedRectangle(
                                cornerRadius: 10,
                                style: .continuous
                            )
                            .fill(
                                Color(nsColor: .controlBackgroundColor)
                                    .opacity(0.94)
                            )
                            .overlay {
                                RoundedRectangle(
                                    cornerRadius: 10,
                                    style: .continuous
                                )
                                .stroke(
                                    DashboardPalette.accent.opacity(0.18)
                                )
                            }
                            .matchedGeometryEffect(
                                id: "selectedCharacter",
                                in: characterSelectionAnimation
                            )
                            .shadow(
                                color: .black.opacity(0.10),
                                radius: 6,
                                y: 2
                            )
                        }
                    }
                }
                .buttonStyle(.plain)
                .help("\(name) 선택")
                .accessibilityLabel("\(name) 선택")
                .accessibilityValue(
                    isSelected ? "선택됨" : "선택되지 않음"
                )
                .accessibilityIdentifier(
                    "commandCharacter-\(character.id.rawValue)"
                )
            }
        }
        .padding(4)
        .background {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [
                            Color.primary.opacity(0.055),
                            Color.primary.opacity(0.025),
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
                .overlay {
                    RoundedRectangle(
                        cornerRadius: 14,
                        style: .continuous
                    )
                    .stroke(Color.primary.opacity(0.055))
                }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("직원 선택")
    }

    private var commandPlaceholder: String {
        if let restoreError = director.sessionRestoreError {
            return "세션 복구 실패 · \(restoreError)"
        }
        if !director.isReadyForSubmissions {
            return "저장된 세션을 복구하는 중입니다"
        }
        if director.selectedCharacterNeedsWorkspaceReview {
            return "변경사항을 승인하거나 거절한 뒤 새 업무를 보내세요"
        }
        if
            let selectedCharacterID = director.selectedCharacterID,
            let persistenceError =
                director.turnPersistenceErrors[selectedCharacterID]
        {
            return "대화 기록 저장 실패 · \(persistenceError)"
        }
        if let selectedName = director.selectedName {
            if
                let selectedCharacterID = director.selectedCharacterID,
                director.pendingQuestion(for: selectedCharacterID) != nil
            {
                return "\(selectedName)의 질문에 답변하세요"
            }
            if
                let selectedCharacterID = director.selectedCharacterID,
                director.offDutyReason(for: selectedCharacterID) != nil
            {
                return "\(selectedName)은 모델 한도 소진으로 퇴근했습니다"
            }
            if
                let selectedCharacterID = director.selectedCharacterID,
                director.failureMessage(for: selectedCharacterID) != nil
            {
                return "\(selectedName)에게 새 업무를 보내 다시 시작하세요"
            }
            return "\(selectedName)에게 업무를 입력하세요"
        }
        return "캐릭터를 선택하세요"
    }

    private var commandIsDisabled: Bool {
        !director.isReadyForSubmissions
            || director.isUpdatingConfiguration
            || director.selectedCharacter == nil
            || director.isSelectedCharacterRunning
            || director.selectedCharacterNeedsWorkspaceReview
            || (
                command.trimmingCharacters(
                    in: .whitespacesAndNewlines
                ).isEmpty
                    && attachments.isEmpty
            )
    }

    private var attachmentSelectionIsDisabled: Bool {
        !director.isReadyForSubmissions
            || director.isUpdatingConfiguration
            || director.selectedCharacter == nil
            || director.isSelectedCharacterRunning
            || director.selectedCharacterNeedsWorkspaceReview
            || attachments.count >= 20
    }

    private var characterSettingsButton: some View {
        Button {
            showsCharacterSettings.toggle()
        } label: {
            Image(systemName: "gearshape.fill")
                .font(.system(size: 15, weight: .semibold))
                .frame(width: 20, height: 20)
        }
        .buttonStyle(.plain)
        .environment(\.colorScheme, theme.isNight ? .dark : .light)
        .foregroundStyle(theme.isNight ? Color.white : Color.black.opacity(0.72))
        .padding(.horizontal, 8)
        .frame(height: 32)
        .background(
            theme.isNight
                ? Color.black.opacity(0.72)
                : Color.white.opacity(0.92),
            in: Capsule()
        )
        .overlay {
            Capsule()
                .stroke(
                    theme.isNight
                        ? Color.white.opacity(0.25)
                        : Color.black.opacity(0.08)
                )
        }
        .shadow(color: .black.opacity(0.14), radius: 7, y: 3)
        .popover(isPresented: $showsCharacterSettings) {
            CharacterSettingsView(director: director)
        }
        .disabled(
            !director.isReadyForSubmissions
                || director.isUpdatingConfiguration
        )
        .opacity(
            director.isReadyForSubmissions
                && !director.isUpdatingConfiguration
                ? 1
                : 0.45
        )
        .accessibilityLabel("캐릭터 설정")
        .help("캐릭터 이름 설정")
    }

    private func submitCommand() {
        let enteredPrompt = command.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard
            !commandIsDisabled,
            director.selectedCharacter != nil
        else {
            return
        }

        let prompt = enteredPrompt.isEmpty
            ? "첨부 파일을 확인해줘."
            : enteredPrompt
        let attachmentPaths = attachments.map(\.path)
        command = ""
        attachments = []
        director.submit(
            prompt,
            attachmentPaths: attachmentPaths
        )
    }

    private func chooseAttachments() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.allowsOtherFileTypes = true
        panel.prompt = "첨부"
        panel.message =
            "Codex 또는 Claude Code가 확인할 파일을 선택하세요."

        guard panel.runModal() == .OK else {
            return
        }
        let existingPaths = Set(attachments.map(\.standardizedFileURL.path))
        let newAttachments = panel.urls.filter {
            !existingPaths.contains($0.standardizedFileURL.path)
        }
        attachments.append(
            contentsOf: newAttachments.prefix(20 - attachments.count)
        )
    }

    private func removeAttachment(_ attachment: URL) {
        attachments.removeAll {
            $0.standardizedFileURL == attachment.standardizedFileURL
        }
    }
    }

private struct CharacterTaskStatusIndicator: View {
    let isRunning: Bool
    let isCompleted: Bool
    let reduceMotion: Bool

    private let completedColor = Color(
        red: 0.94,
        green: 0.52,
        blue: 0.16
    )

    var body: some View {
        Group {
            if isRunning {
                CoreAnimationRunningIndicator(
                    isAnimated: !reduceMotion
                )
                .frame(width: 24, height: 24)
                .accessibilityLabel("업무 중")
            } else if isCompleted {
                Image(systemName: "exclamationmark")
                    .font(.system(size: 11, weight: .black))
                    .foregroundStyle(.white)
                    .frame(width: 19, height: 19)
                    .background(completedColor, in: Circle())
                    .shadow(
                        color: completedColor.opacity(0.28),
                        radius: 4,
                        y: 2
                    )
                    .accessibilityLabel("업무 완료")
            }
        }
        .frame(width: 24, height: 24)
    }
}

private struct OfficeColumnResizeHandle: View {
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.primary.opacity(0.16))
                .frame(width: 2, height: 46)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .officeColumnResizeCursor()
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onDragChanged(value.translation.width)
                }
                .onEnded { _ in
                    onDragEnded()
                }
        )
        .accessibilityLabel("좌우 화면 폭 조절")
        .accessibilityHint("드래그해서 사무실과 실시간 대화 영역의 폭을 조절합니다")
    }
}

private struct OfficeRowResizeHandle: View {
    let onDragChanged: (CGFloat) -> Void
    let onDragEnded: () -> Void

    var body: some View {
        ZStack {
            Capsule()
                .fill(Color.primary.opacity(0.16))
                .frame(width: 46, height: 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .contentShape(Rectangle())
        .officeRowResizeCursor()
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    onDragChanged(value.translation.height)
                }
                .onEnded { _ in
                    onDragEnded()
                }
        )
        .accessibilityLabel("상하 화면 높이 조절")
        .accessibilityHint("드래그해서 사무실과 상세 영역의 높이를 조절합니다")
    }
}

private struct OfficeArtStyleRevealMask: View, Animatable {
    var progress: CGFloat

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let feather = min(72, width * 0.13)
            let clampedProgress = min(max(progress, 0), 1)
            let sweep = clampedProgress * (width + feather)
            let solidWidth = min(width, max(0, sweep - feather))
            let softWidth = min(feather, max(0, sweep - solidWidth))

            HStack(spacing: 0) {
                Color.white
                    .frame(width: solidWidth)

                if softWidth > 0 {
                    LinearGradient(
                        colors: [.white, .clear],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .frame(width: softWidth)
                }

                Spacer(minLength: 0)
            }
            .frame(
                maxWidth: .infinity,
                maxHeight: .infinity,
                alignment: .leading
            )
        }
    }
}

private struct BubbleDetail: Identifiable {
    let id = UUID()
    let character: OfficeCharacter
    let name: String
    let message: String
    let isQuestion: Bool
    let isFailure: Bool
    let isOffDuty: Bool
}

private struct BubbleDetailView: View {
    @ObservedObject var director: AgentDirector
    let character: OfficeCharacter
    let name: String
    let message: String
    let isQuestion: Bool
    let isFailure: Bool
    let isOffDuty: Bool
    @State private var answer = ""
    @FocusState private var answerIsFocused: Bool
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let presentation = AgentQuestionPresentation(text: message)

        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text(detailTitle)
                        .font(.system(size: 19, weight: .bold))
                    Text(
                        isQuestion
                            ? "질문 원문을 확인하고 아래에 답변하세요"
                            : isOffDuty
                            ? "모델 한도 소진 원문과 재설정 안내"
                            : isFailure
                            ? "CLI 작업이 중단된 원인 전문"
                            : "말풍선에 표시된 응답 전문"
                    )
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("닫기") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(18)

            Divider()

            ScrollView {
                ConversationMarkdownView(
                    source: isQuestion ? presentation.question : message,
                    fontSize: 13
                )
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }

            if isQuestion {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text(
                        presentation.choices.isEmpty
                            ? "답변"
                            : "선택지"
                    )
                        .font(.system(size: 13, weight: .bold))

                    if
                        let error = director.questionSubmissionError(
                            for: character
                        )
                    {
                        Label(
                            "전송하지 못했습니다. \(error)",
                            systemImage: "exclamationmark.triangle.fill"
                        )
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Color.red)
                    }

                    if !presentation.choices.isEmpty {
                        VStack(spacing: 8) {
                            ForEach(
                                Array(presentation.choices.enumerated()),
                                id: \.offset
                            ) { index, choice in
                                Button {
                                    submitAnswer(choice.response)
                                } label: {
                                    HStack(spacing: 10) {
                                        Text("\(index + 1)")
                                            .font(
                                                .system(
                                                    size: 11,
                                                    weight: .bold,
                                                    design: .rounded
                                                )
                                            )
                                            .foregroundStyle(Color.accentColor)
                                            .frame(width: 24, height: 24)
                                            .background(
                                                Circle()
                                                    .fill(
                                                        Color.accentColor
                                                            .opacity(0.12)
                                                    )
                                            )
                                        Text(choice.title)
                                            .font(.system(size: 13))
                                            .multilineTextAlignment(.leading)
                                        Spacer(minLength: 8)
                                        Image(systemName: "arrow.right")
                                            .font(
                                                .system(
                                                    size: 11,
                                                    weight: .semibold
                                                )
                                            )
                                            .foregroundStyle(.secondary)
                                    }
                                    .padding(.horizontal, 12)
                                    .padding(.vertical, 9)
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)
                                .background(
                                    RoundedRectangle(
                                        cornerRadius: 9,
                                        style: .continuous
                                    )
                                    .fill(Color.accentColor.opacity(0.055))
                                )
                                .overlay {
                                    RoundedRectangle(
                                        cornerRadius: 9,
                                        style: .continuous
                                    )
                                    .stroke(Color.accentColor.opacity(0.22))
                                }
                                .disabled(
                                    director.runningCharacters.contains(
                                        character
                                    )
                                )
                                .accessibilityIdentifier(
                                    "needsInputChoice.\(index + 1)"
                                )
                                .accessibilityLabel(
                                    "\(index + 1)번 \(choice.title)"
                                )
                            }
                        }

                        Divider()

                        Text("직접 입력")
                            .font(.system(size: 13, weight: .bold))
                    }

                    TextEditor(text: $answer)
                        .font(.system(size: 13))
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .frame(minHeight: 92, maxHeight: 150)
                        .background(
                            RoundedRectangle(
                                cornerRadius: 9,
                                style: .continuous
                            )
                            .fill(Color(nsColor: .textBackgroundColor))
                        )
                        .overlay {
                            RoundedRectangle(
                                cornerRadius: 9,
                                style: .continuous
                            )
                            .stroke(Color.primary.opacity(0.14))
                        }
                        .focused($answerIsFocused)

                    HStack {
                        Text("답변은 같은 CLI 세션으로 이어집니다.")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("답변 보내기", action: submitTypedAnswer)
                            .buttonStyle(.borderedProminent)
                            .keyboardShortcut(.defaultAction)
                            .disabled(
                                answer.trimmingCharacters(
                                    in: .whitespacesAndNewlines
                                ).isEmpty
                                    || director.runningCharacters.contains(
                                        character
                                    )
                            )
                    }
                }
                .padding(18)
            }
        }
        .frame(
            minWidth: 820,
            idealWidth: 1_000,
            minHeight: isQuestion ? 540 : 420
        )
        .onAppear {
            answerIsFocused = isQuestion
                && presentation.choices.isEmpty
        }
    }

    private func submitTypedAnswer() {
        submitAnswer(answer)
    }

    private func submitAnswer(_ response: String) {
        let value = response.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !value.isEmpty else {
            return
        }
        director.submit(value, to: character)
        dismiss()
    }

    private var detailTitle: String {
        if isQuestion {
            return "\(name) 확인 질문"
        }
        if isOffDuty {
            return "\(name) 퇴근"
        }
        if isFailure {
            return "\(name) 업무 중단"
        }
        return "\(name) 응답"
    }
}

private struct AgentQuickSettingsView: View {
    @ObservedObject var director: AgentDirector
    let character: CharacterConfiguration

    private var settings: CharacterAgentSettings {
        director.agentSettings(for: character.id)
    }

    var body: some View {
        HStack(spacing: 4) {
            Menu {
                ForEach(AgentBackend.allCases) { backend in
                    Button {
                        apply(
                            CharacterAgentSettings(
                                backend: backend,
                                model: backend.defaultModel,
                                effort: "high",
                                fastMode: settings.fastMode,
                                permission: settings.permission
                            )
                        )
                    } label: {
                        if settings.backend == backend {
                            Label(backend.title, systemImage: "checkmark")
                        } else {
                            Text(backend.title)
                        }
                    }
                }
            } label: {
                QuickSettingLabel(
                    text: settings.backend.title,
                    systemImage: "terminal"
                )
            }

            Menu {
                ForEach(settings.backend.modelOptions, id: \.self) { model in
                    Button {
                        var updated = settings
                        updated.selectModel(model)
                        apply(updated)
                    } label: {
                        if settings.model == model {
                            Label(
                                settings.backend.modelTitle(model),
                                systemImage: "checkmark"
                            )
                        } else {
                            Text(settings.backend.modelTitle(model))
                        }
                    }
                }
            } label: {
                QuickSettingLabel(
                    text: settings.backend.modelTitle(
                        settings.model ?? settings.backend.defaultModel
                    ),
                    systemImage: "cpu"
                )
            }

            Button {
                var updated = settings
                updated.setFastMode(!settings.fastMode)
                apply(updated)
            } label: {
                QuickSettingLabel(
                    text: settings.fastMode ? "Fast" : "Standard",
                    systemImage: settings.fastMode ? "bolt.fill" : "bolt"
                )
            }
            .buttonStyle(.plain)
            .help(settings.fastMode ? "Fast 모드 끄기" : "Fast 모드 켜기")

            Menu {
                ForEach(settings.backend.effortOptions, id: \.self) { effort in
                    Button {
                        var updated = settings
                        updated.effort = effort
                        apply(updated)
                    } label: {
                        if settings.effort == effort {
                            Label(effort, systemImage: "checkmark")
                        } else {
                            Text(effort)
                        }
                    }
                }
            } label: {
                QuickSettingLabel(
                    text: settings.effort,
                    systemImage: "brain"
                )
            }

            Menu {
                ForEach(AgentPermission.allCases) { permission in
                    Button {
                        var updated = settings
                        updated.permission = permission
                        apply(updated)
                    } label: {
                        if settings.permission == permission {
                            Label(permission.title, systemImage: "checkmark")
                        } else {
                            Text(permission.title)
                        }
                    }
                }
            } label: {
                QuickSettingLabel(
                    text: settings.permission.title,
                    systemImage: "shield"
                )
            }
        }
        .menuStyle(.borderlessButton)
        .disabled(
            !director.isReadyForSubmissions
                || director.isUpdatingConfiguration
                || director.runningCharacters.contains(character.id)
                || director.pendingWorkspaceReviewCharacters.contains(
                    character.id
                )
        )
    }

    private func apply(_ settings: CharacterAgentSettings) {
        Task {
            await director.updateAgentSettings(
                settings,
                for: character.id
            )
        }
    }
}

private struct QuickSettingLabel: View {
    let text: String
    let systemImage: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Color.primary.opacity(0.68))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.primary.opacity(0.055), in: Capsule())
            .fixedSize()
    }
}

private struct CharacterSettingsView: View {
    @ObservedObject var director: AgentDirector
    @Environment(\.dismiss) private var dismiss
    @State private var nameDrafts: [OfficeCharacter: String] = [:]
    @State private var settingsDrafts:
        [OfficeCharacter: CharacterAgentSettings] = [:]
    @State private var identityPromptDrafts: [OfficeCharacter: String] = [:]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("직원별 설정")
                .font(.system(size: 17, weight: .bold))

            Text("이름, 역할·업무 지침, CLI 실행 방식을 직원마다 설정합니다.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)

            ScrollView {
                VStack(spacing: 10) {
                    ForEach(director.characters) { character in
                        CharacterSettingsEditor(
                            seat: character.seat,
                            name: nameBinding(for: character.id),
                            identityPrompt: identityPromptBinding(
                                for: character.id
                            ),
                            settings: settingsBinding(for: character.id)
                        )
                    }
                }
            }
            .frame(maxHeight: 560)

            if let status = director.settingsStatus {
                Text(status)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(
                        status.contains("저장") ? Color.green : Color.red
                    )
            }

            HStack {
                Spacer()
                Button("닫기") {
                    dismiss()
                }
                Button("저장") {
                    Task {
                        await director.saveConfiguration(
                            names: nameDrafts,
                            settings: settingsDrafts,
                            identityPrompts: identityPromptDrafts
                        )
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 620)
        .onAppear {
            nameDrafts = Dictionary(
                uniqueKeysWithValues: director.characters.map {
                    ($0.id, director.displayName(for: $0.id))
                }
            )
            settingsDrafts = Dictionary(
                uniqueKeysWithValues: director.characters.map {
                    ($0.id, director.agentSettings(for: $0.id))
                }
            )
            identityPromptDrafts = Dictionary(
                uniqueKeysWithValues: director.characters.map {
                    ($0.id, director.identityPrompt(for: $0.id))
                }
            )
        }
    }

    private func nameBinding(
        for character: OfficeCharacter
    ) -> Binding<String> {
        Binding(
            get: { nameDrafts[character] ?? "" },
            set: { nameDrafts[character] = $0 }
        )
    }

    private func settingsBinding(
        for character: OfficeCharacter
    ) -> Binding<CharacterAgentSettings> {
        Binding(
            get: {
                settingsDrafts[character]
                    ?? director.agentSettings(for: character)
            },
            set: { settingsDrafts[character] = $0 }
        )
    }

    private func identityPromptBinding(
        for character: OfficeCharacter
    ) -> Binding<String> {
        Binding(
            get: { identityPromptDrafts[character] ?? "" },
            set: { identityPromptDrafts[character] = $0 }
        )
    }
}

private struct CharacterSettingsEditor: View {
    let seat: String
    @Binding var name: String
    @Binding var identityPrompt: String
    @Binding var settings: CharacterAgentSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Text(seat)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 70, alignment: .leading)

                TextField("이름", text: $name)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("역할·업무 지침")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                TextEditor(text: $identityPrompt)
                    .font(.system(size: 12))
                    .frame(height: 62)
                    .padding(4)
                    .overlay {
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(
                                Color.primary.opacity(0.14),
                                lineWidth: 1
                            )
                    }
            }

            HStack(spacing: 12) {
                settingPickerLabel("CLI")
                Picker("CLI", selection: backendBinding) {
                    ForEach(AgentBackend.allCases) { backend in
                        Text(backend.title).tag(backend)
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                settingPickerLabel("모델")
                Picker("모델", selection: modelBinding) {
                    ForEach(settings.backend.modelOptions, id: \.self) { model in
                        Text(settings.backend.modelTitle(model)).tag(model)
                    }
                }
                .labelsHidden()
                .frame(width: 130)

                settingPickerLabel("추론")
                Picker("추론", selection: $settings.effort) {
                    ForEach(settings.backend.effortOptions, id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .labelsHidden()
                .frame(width: 90)
            }
            .controlSize(.small)

            HStack(spacing: 12) {
                settingPickerLabel("권한")
                Picker("권한", selection: $settings.permission) {
                    ForEach(AgentPermission.allCases) { permission in
                        Text(permission.title).tag(permission)
                    }
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 300)

                Text(settings.permission.cliValue(for: settings.backend))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)

                Spacer()

                Toggle(isOn: fastModeBinding) {
                    Label(
                        settings.fastMode ? "Fast" : "Standard",
                        systemImage: settings.fastMode ? "bolt.fill" : "bolt"
                    )
                    .font(.system(size: 11, weight: .semibold))
                }
                .toggleStyle(.switch)
                .fixedSize()
            }
            .controlSize(.small)
        }
        .padding(11)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.045))
        )
    }

    private var backendBinding: Binding<AgentBackend> {
        Binding(
            get: { settings.backend },
            set: { backend in
                settings = CharacterAgentSettings(
                    backend: backend,
                    model: backend.defaultModel,
                    effort: "high",
                    fastMode: settings.fastMode,
                    permission: settings.permission
                )
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { settings.model ?? settings.backend.defaultModel },
            set: { settings.selectModel($0) }
        )
    }

    private var fastModeBinding: Binding<Bool> {
        Binding(
            get: { settings.fastMode },
            set: { settings.setFastMode($0) }
        )
    }

    private func settingPickerLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }
}
