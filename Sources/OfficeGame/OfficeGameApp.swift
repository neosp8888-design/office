// 이 파일은 네 가지 V4 도트 오피스 테마와 명령 입력창을 네이티브 macOS 창에 표시한다.

import OfficeCore
import SwiftUI

@main
struct OfficeGameApp: App {
    var body: some Scene {
        WindowGroup("사무실") {
            OfficeGameView()
        }
        .defaultSize(width: 1_200, height: 800)
        .windowResizability(.contentMinSize)
    }
}

private struct OfficeGameView: View {
    @StateObject private var director = AgentDirector()
    @State private var command = ""
    @State private var showsCharacterSettings = false
    @State private var historyTarget: ConversationHistoryTarget?
    @State private var bubbleDetail: BubbleDetail?
    @AppStorage("officeTheme") private var selectedThemeRawValue =
        OfficeTheme.modernDay.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            letterboxColor
                .ignoresSafeArea()
                .animation(.easeInOut(duration: 0.18), value: theme)

            OfficeRealtimeView(
                theme: theme,
                isActive: scenePhase == .active,
                reduceMotion: reduceMotion,
                bossActivity: director.runningCharacters.contains(.boss)
                    ? .speaking
                    : .working
            )
            .ignoresSafeArea()
            .accessibilityHidden(true)

            WhiteboardUsageLayer(
                isActive: scenePhase == .active
            )
            .ignoresSafeArea()

            CharacterInteractionLayer(
                director: director,
                onMonitorTapped: {
                    historyTarget = .character($0)
                },
                onArchiveCabinetTapped: {
                    historyTarget = .archive
                },
                onBubbleTapped: { character, message in
                    let offDutyReason = director.offDutyReason(
                        for: character
                    )
                    bubbleDetail = BubbleDetail(
                        character: character,
                        name: director.displayName(for: character),
                        message: offDutyReason ?? message,
                        isQuestion:
                            director.pendingQuestion(for: character) != nil,
                        isFailure:
                            director.failureMessage(for: character) != nil,
                        isOffDuty: offDutyReason != nil
                    )
                }
            )
                .ignoresSafeArea()

            VStack {
                Spacer()
                commandBar
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .overlay(alignment: .topTrailing) {
            HStack(spacing: 8) {
                themeToggle
                characterSettingsButton
            }
                .padding(.top, 12)
                .padding(.trailing, 14)
                .zIndex(100)
        }
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

    private var theme: OfficeTheme {
        OfficeTheme(rawValue: selectedThemeRawValue) ?? .modernDay
    }

    private var letterboxColor: Color {
        switch theme {
        case .modernDay, .woodDay:
            Color(red: 0.965, green: 0.925, blue: 0.895)
        case .modernNight:
            Color(red: 0.095, green: 0.135, blue: 0.205)
        case .woodNight:
            Color(red: 0.11, green: 0.12, blue: 0.17)
        }
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

    private var commandBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "chevron.right")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(Color(red: 0.46, green: 0.40, blue: 0.34))

            if let selectedName = director.selectedName {
                Text(selectedName)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.white)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        Color(red: 0.18, green: 0.58, blue: 0.53),
                        in: Capsule()
                    )
            }

            if let character = director.selectedCharacter {
                AgentQuickSettingsView(
                    director: director,
                    character: character
                )
            }

            TextField(commandPlaceholder, text: $command)
                .textFieldStyle(.plain)
                .font(.system(size: 15, weight: .medium))
                .onSubmit(submitCommand)

            Button {
            } label: {
                Image(systemName: "paperclip")
                    .font(.system(size: 17, weight: .semibold))
                    .frame(width: 34, height: 34)
                    .foregroundStyle(Color(red: 0.44, green: 0.39, blue: 0.34))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("파일 첨부")

            Button(action: submitCommand) {
                Image(systemName: "paperplane.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 38, height: 38)
                    .background(
                        Color(red: 0.18, green: 0.58, blue: 0.53),
                        in: RoundedRectangle(cornerRadius: 11, style: .continuous)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("보내기")
            .disabled(
                director.selectedCharacter == nil
                    || director.isSelectedCharacterRunning
            )
            .opacity(
                director.selectedCharacter == nil
                    || director.isSelectedCharacterRunning
                    ? 0.45
                    : 1
            )
        }
        .padding(.leading, 16)
        .padding(.trailing, 10)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(.white.opacity(0.94))
                .shadow(color: .black.opacity(0.15), radius: 18, y: 7)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(.white.opacity(0.90), lineWidth: 1)
        }
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
    }

    private var commandPlaceholder: String {
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
        .accessibilityLabel("캐릭터 설정")
        .help("캐릭터 이름 설정")
    }

    private func submitCommand() {
        let prompt = command.trimmingCharacters(
            in: .whitespacesAndNewlines
        )
        guard !prompt.isEmpty, director.selectedCharacter != nil else {
            return
        }

        command = ""
        director.submit(prompt)
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
                Text(message)
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(18)
            }

            if isQuestion {
                Divider()

                VStack(alignment: .leading, spacing: 10) {
                    Text("답변")
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
                        Button("답변 보내기", action: submitAnswer)
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
            minWidth: 560,
            minHeight: isQuestion ? 540 : 420
        )
        .onAppear {
            answerIsFocused = isQuestion
        }
    }

    private func submitAnswer() {
        let value = answer.trimmingCharacters(
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
                        updated.model = model
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
        .disabled(director.runningCharacters.contains(character.id))
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
            .foregroundStyle(Color.black.opacity(0.68))
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .background(Color.black.opacity(0.055), in: Capsule())
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
                    permission: settings.permission
                )
            }
        )
    }

    private var modelBinding: Binding<String> {
        Binding(
            get: { settings.model ?? settings.backend.defaultModel },
            set: { settings.model = $0 }
        )
    }

    private func settingPickerLabel(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(.secondary)
    }
}
