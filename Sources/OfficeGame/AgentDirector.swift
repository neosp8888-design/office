// 이 파일은 캐릭터 선택과 CLI 세션 및 말풍선 상태를 한곳에서 관리한다.

import Combine
import Foundation
import OfficeCore

@MainActor
final class AgentDirector: ObservableObject {
    @Published private(set) var characters: [CharacterConfiguration]
    @Published private(set) var names: [OfficeCharacter: String]
    @Published private(set) var bubbles: [OfficeCharacter: String] = [:]
    @Published private(set) var runningCharacters: Set<OfficeCharacter> = []
    @Published var selectedCharacterID: OfficeCharacter?
    @Published private(set) var settingsStatus: String?

    private let configuration: OfficeAgentConfiguration
    private let runner = AgentCLIRunner()
    private let database: OfficeDatabaseClient
    private let conversationID = UUID()
    private var sessionIDs: [OfficeCharacter: String] = [:]
    private var bubbleDismissTasks: [OfficeCharacter: Task<Void, Never>] = [:]
    private var idleChatterTask: Task<Void, Never>?
    private static let bubbleLifetime = Duration.seconds(10)
    private static let idleChatterInterval = Duration.seconds(14)
    private static let idleChatterMessages = [
        "☕ 커피가 저를 부르네요.",
        "🧠 뇌 업데이트 대기 중!",
        "🐣 오늘도 무사히 부화 중.",
        "🕺 키보드와 밀당 중이에요.",
        "🍪 간식 레이더 가동!",
        "😎 일은 없어도 폼은 유지 중.",
        "🫠 의자와 한 몸이 됐어요.",
        "🌱 아이디어 새싹 대기 중.",
        "🐙 손은 여덟 개면 좋겠어요.",
        "🚀 다음 업무 발사 대기!"
    ]

    init() {
        do {
            configuration = try CharacterConfigurationAsset.load()
        } catch {
            fatalError(error.localizedDescription)
        }
        characters = configuration.characters
        names = Dictionary(
            uniqueKeysWithValues: configuration.characters.map {
                ($0.id, $0.name)
            }
        )
        database = OfficeDatabaseClient(
            baseURL: configuration.databaseBaseURL
        )

        Task {
            await refreshCharacters()
        }
        startIdleChatter()
    }

    var selectedCharacter: CharacterConfiguration? {
        guard let selectedCharacterID else {
            return nil
        }
        return characters.first { $0.id == selectedCharacterID }
    }

    var archiveCabinetHitbox: CharacterHitbox {
        configuration.archiveCabinetHitbox
    }

    var selectedName: String? {
        guard let selectedCharacterID else {
            return nil
        }
        return displayName(for: selectedCharacterID)
    }

    var isSelectedCharacterRunning: Bool {
        guard let selectedCharacterID else {
            return false
        }
        return runningCharacters.contains(selectedCharacterID)
    }

    func displayName(for character: OfficeCharacter) -> String {
        names[character] ?? character.rawValue
    }

    func identityPrompt(for character: OfficeCharacter) -> String {
        characters.first { $0.id == character }?.identityPrompt ?? ""
    }

    func select(_ character: CharacterConfiguration) {
        selectedCharacterID = character.id
        clearBubbles()
        showBubble("네!", for: character.id)
    }

    func submit(_ prompt: String) {
        guard
            let character = selectedCharacter,
            !runningCharacters.contains(character.id)
        else {
            return
        }

        let startedAt = Date()
        runningCharacters.insert(character.id)
        showBubble("생각 중...", for: character.id, autoDismiss: false)

        Task {
            do {
                let response = try await runner.run(
                    prompt: prompt,
                    character: characterWithCurrentName(character),
                    workdir: configuration.workdir,
                    previousSessionID: sessionIDs[character.id]
                )
                if let sessionID = response.sessionID {
                    sessionIDs[character.id] = sessionID
                }
                showBubble(response.text, for: character.id)
                runningCharacters.remove(character.id)

                try? await database.recordTurn(
                    DatabaseTurn(
                        turnId: UUID(),
                        conversationId: conversationID,
                        characterId: character.id.rawValue,
                        externalSessionId: response.sessionID,
                        prompt: prompt,
                        response: response.text,
                        title: String(prompt.prefix(60)),
                        workdir: configuration.workdir,
                        startedAt: startedAt,
                        finishedAt: Date()
                    )
                )
            } catch {
                showBubble(
                    "오류\n\(error.localizedDescription)",
                    for: character.id
                )
                runningCharacters.remove(character.id)
            }
        }
    }

    func agentSettings(
        for character: OfficeCharacter
    ) -> CharacterAgentSettings {
        characters.first { $0.id == character }?.agentSettings
            ?? CharacterAgentSettings(
                backend: .codex,
                model: AgentBackend.codex.defaultModel,
                effort: "high",
                permission: .workspaceWrite
            )
    }

    func saveConfiguration(
        names nameDrafts: [OfficeCharacter: String],
        settings settingsDrafts: [OfficeCharacter: CharacterAgentSettings],
        identityPrompts identityPromptDrafts: [OfficeCharacter: String]
    ) async {
        settingsStatus = nil
        do {
            for character in characters {
                let name =
                    nameDrafts[character.id]?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !name.isEmpty else {
                    throw AgentConfigurationError.emptyName
                }
                if name != displayName(for: character.id) {
                    try await database.updateName(name, for: character.id)
                    names[character.id] = name
                }

                if
                    let settings = settingsDrafts[character.id],
                    settings != character.agentSettings
                {
                    try await database.updateSettings(
                        settings,
                        for: character.id
                    )
                    apply(settings, to: character.id)
                }

                let identityPrompt =
                    identityPromptDrafts[character.id]?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !identityPrompt.isEmpty else {
                    throw AgentConfigurationError.emptyIdentityPrompt
                }
                if identityPrompt != character.identityPrompt {
                    try await database.updateIdentityPrompt(
                        identityPrompt,
                        for: character.id
                    )
                    apply(identityPrompt: identityPrompt, to: character.id)
                }
            }
            settingsStatus = "설정을 저장했습니다."
        } catch {
            settingsStatus = error.localizedDescription
        }
    }

    func updateAgentSettings(
        _ settings: CharacterAgentSettings,
        for character: OfficeCharacter
    ) async {
        settingsStatus = nil
        do {
            try await database.updateSettings(settings, for: character)
            apply(settings, to: character)
            settingsStatus = "설정을 저장했습니다."
        } catch {
            settingsStatus = error.localizedDescription
        }
    }

    func characterHistory(
        for character: OfficeCharacter
    ) async throws -> CharacterHistory {
        try await database.fetchCharacterHistory(for: character)
    }

    func globalHistory(
        character: OfficeCharacter?,
        from: Date?,
        to: Date?
    ) async throws -> [GlobalHistoryTurn] {
        try await database.fetchGlobalHistory(
            character: character,
            from: from,
            to: to
        )
    }

    private func showBubble(
        _ text: String,
        for character: OfficeCharacter,
        autoDismiss: Bool = true
    ) {
        bubbleDismissTasks.removeValue(forKey: character)?.cancel()
        bubbles[character] = text

        guard autoDismiss else {
            return
        }

        bubbleDismissTasks[character] = Task { [weak self] in
            try? await Task.sleep(for: Self.bubbleLifetime)
            guard !Task.isCancelled else {
                return
            }
            self?.bubbles[character] = nil
            self?.bubbleDismissTasks[character] = nil
        }
    }

    private func clearBubbles() {
        for task in bubbleDismissTasks.values {
            task.cancel()
        }
        bubbleDismissTasks = [:]
        bubbles = [:]
    }

    private func startIdleChatter() {
        idleChatterTask = Task { [weak self] in
            do {
                try await Task.sleep(for: .seconds(2))

                while !Task.isCancelled {
                    self?.showIdleChatter()
                    try await Task.sleep(for: Self.idleChatterInterval)
                }
            } catch {
                return
            }
        }
    }

    private func showIdleChatter() {
        let idleCharacters = characters.filter {
            !runningCharacters.contains($0.id) && bubbles[$0.id] == nil
        }
        let messages = Self.idleChatterMessages.shuffled()

        for (character, message) in zip(idleCharacters, messages) {
            showBubble(message, for: character.id)
        }
    }

    private func refreshCharacters() async {
        guard let storedCharacters = try? await database.fetchCharacters()
        else {
            return
        }
        for stored in storedCharacters {
            guard let character = OfficeCharacter(rawValue: stored.id) else {
                continue
            }
            names[character] = stored.name
            apply(
                CharacterAgentSettings(
                    backend: stored.backend,
                    model: stored.model,
                    effort: stored.effort,
                    permission: AgentPermission(cliValue: stored.permission)
                ),
                to: character
            )
            apply(identityPrompt: stored.identityPrompt, to: character)
        }
    }

    private func apply(
        _ settings: CharacterAgentSettings,
        to character: OfficeCharacter
    ) {
        guard let index = characters.firstIndex(
            where: { $0.id == character }
        ) else {
            return
        }
        let previous = characters[index]
        if previous.agentSettings != settings {
            sessionIDs[character] = nil
        }
        characters[index] = previous.applying(settings)
    }

    private func apply(
        identityPrompt: String,
        to character: OfficeCharacter
    ) {
        guard let index = characters.firstIndex(
            where: { $0.id == character }
        ) else {
            return
        }
        let previous = characters[index]
        guard previous.identityPrompt != identityPrompt else {
            return
        }
        sessionIDs[character] = nil
        characters[index] = previous.applying(identityPrompt: identityPrompt)
    }

    private func characterWithCurrentName(
        _ character: CharacterConfiguration
    ) -> CharacterConfiguration {
        CharacterConfiguration(
            id: character.id,
            name: displayName(for: character.id),
            seat: character.seat,
            backend: character.backend,
            identityPrompt: character.identityPrompt,
            model: character.model,
            effort: character.effort,
            permission: character.permission,
            executablePath: character.executablePath,
            hitbox: character.hitbox,
            monitorHitbox: character.monitorHitbox,
            bubble: character.bubble
        )
    }
}

private enum AgentConfigurationError: LocalizedError {
    case emptyName
    case emptyIdentityPrompt

    var errorDescription: String? {
        switch self {
        case .emptyName:
            "직원 이름을 입력하세요."
        case .emptyIdentityPrompt:
            "직원별 역할·업무 지침을 입력하세요."
        }
    }
}
