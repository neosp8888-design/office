// 이 파일은 캐릭터 선택과 CLI 세션 및 말풍선 상태를 한곳에서 관리한다.

import Combine
import Foundation
import OfficeCore

struct PendingAgentQuestion: Identifiable, Equatable {
    let id = UUID()
    let character: OfficeCharacter
    let text: String
}

@MainActor
final class AgentDirector: ObservableObject {
    @Published private(set) var characters: [CharacterConfiguration]
    @Published private(set) var names: [OfficeCharacter: String]
    @Published private(set) var bubbles: [OfficeCharacter: String] = [:]
    @Published private(set) var pendingQuestions:
        [OfficeCharacter: String] = [:]
    @Published private(set) var questionSubmissionErrors:
        [OfficeCharacter: String] = [:]
    @Published private(set) var latestQuestion: PendingAgentQuestion?
    @Published private(set) var runningCharacters: Set<OfficeCharacter> = []
    @Published private(set) var failedCharacters:
        [OfficeCharacter: String] = [:]
    @Published private(set) var offDutyCharacters:
        [OfficeCharacter: String] = [:]
    @Published private(set) var isReadyForSubmissions = false
    @Published private(set) var sessionRestoreError: String?
    @Published private(set) var isUpdatingConfiguration = false
    @Published private(set) var turnPersistenceErrors:
        [OfficeCharacter: String] = [:]
    @Published var selectedCharacterID: OfficeCharacter?
    @Published private(set) var settingsStatus: String?

    private let configuration: OfficeAgentConfiguration
    private let runner = AgentCLIRunner()
    private let database: OfficeDatabaseClient
    private var conversationIDs: [OfficeCharacter: UUID] = [:]
    private var sessionIDs: [OfficeCharacter: String] = [:]
    private var bubbleDismissTasks: [OfficeCharacter: Task<Void, Never>] = [:]
    private var idleChatterTask: Task<Void, Never>?
    private var lastIdleChatterCharacter: OfficeCharacter?
    private static let bubbleLifetime = Duration.seconds(10)
    private static let sessionRestoreRetryDelay = Duration.seconds(2)
    private static let idleChatterQuietDelaySeconds = 5 ... 12
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
        "🚀 다음 업무 발사 대기!",
        "📋 우선순위를 조용히 정리 중.",
        "🔍 놓친 조건이 없는지 살펴보는 중.",
        "🧭 다음 병목이 어디일지 생각 중.",
        "🧩 작은 개선점 하나를 찾았어요.",
        "🛠️ 반복 업무를 줄일 방법 고민 중.",
        "📈 오늘의 진척을 숫자로 보는 중.",
        "🤝 동료 의견도 한번 들어보고 싶어요.",
        "💬 좋은 질문 하나 준비 중.",
        "🧪 작은 실험부터 해보면 어떨까요?",
        "📚 새 기술을 짧게 훑어보는 중.",
        "📝 다음 사람도 알기 쉽게 메모 중.",
        "🎯 지금 가장 중요한 한 가지는 뭘까요?",
        "🌤️ 잠깐 먼 곳을 보며 눈 쉬는 중.",
        "🪴 화분처럼 차분히 성장 중.",
        "🎧 집중할 리듬을 찾는 중.",
        "🕰️ 서두르지 않고 정확하게 보는 중.",
        "🛰️ 다른 관점에서 문제를 내려다보는 중.",
        "🧹 머릿속 탭을 정리하는 중.",
        "🔄 반대로 생각하면 답이 보일지도요.",
        "💡 불편한 점 하나가 개선의 시작이죠."
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
            await restorePersistentState()
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

    func pendingQuestion(for character: OfficeCharacter) -> String? {
        pendingQuestions[character]
    }

    func questionSubmissionError(for character: OfficeCharacter) -> String? {
        questionSubmissionErrors[character]
    }

    func failureMessage(for character: OfficeCharacter) -> String? {
        failedCharacters[character]
    }

    func offDutyReason(for character: OfficeCharacter) -> String? {
        offDutyCharacters[character]
    }

    func select(_ character: CharacterConfiguration) {
        selectedCharacterID = character.id
        clearTransientBubbles()
        if
            pendingQuestions[character.id] == nil,
            !runningCharacters.contains(character.id),
            failedCharacters[character.id] == nil,
            offDutyCharacters[character.id] == nil
        {
            showBubble("네!", for: character.id)
        }
    }

    func submit(
        _ prompt: String,
        to requestedCharacter: OfficeCharacter? = nil
    ) {
        let character: CharacterConfiguration?
        if let requestedCharacter {
            character = characters.first { $0.id == requestedCharacter }
        } else {
            character = selectedCharacter
        }

        guard
            let character,
            isReadyForSubmissions,
            !isUpdatingConfiguration,
            !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !runningCharacters.contains(character.id)
        else {
            return
        }

        let questionBeingAnswered = pendingQuestions[character.id]
        let conversationID = conversationIDs[character.id] ?? UUID()
        conversationIDs[character.id] = conversationID
        selectedCharacterID = character.id
        pendingQuestions[character.id] = nil
        questionSubmissionErrors[character.id] = nil
        turnPersistenceErrors[character.id] = nil
        failedCharacters[character.id] = nil
        offDutyCharacters[character.id] = nil
        if latestQuestion?.character == character.id {
            latestQuestion = nil
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
                ) { [weak self] progress in
                    guard
                        let self,
                        self.runningCharacters.contains(character.id),
                        self.bubbles[character.id] != progress
                    else {
                        return
                    }
                    self.showBubble(
                        progress,
                        for: character.id,
                        autoDismiss: false
                    )
                }
                if let sessionID = response.sessionID {
                    sessionIDs[character.id] = sessionID
                }
                let activeSessionID =
                    response.sessionID ?? sessionIDs[character.id]
                if response.needsInput {
                    pendingQuestions[character.id] = response.text
                    latestQuestion = PendingAgentQuestion(
                        character: character.id,
                        text: response.text
                    )
                    showBubble(
                        response.text,
                        for: character.id,
                        autoDismiss: false
                    )
                } else {
                    pendingQuestions[character.id] = nil
                    showBubble(response.text, for: character.id)
                }

                await persistTurn(
                    DatabaseTurn(
                        turnId: UUID(),
                        conversationId: conversationID,
                        characterId: character.id.rawValue,
                        externalSessionId: activeSessionID,
                        backend: character.backend,
                        model: character.model,
                        effort: character.effort,
                        prompt: prompt,
                        response: response.text,
                        title: String(prompt.prefix(60)),
                        workdir: configuration.workdir,
                        startedAt: startedAt,
                        finishedAt: Date()
                    ),
                    for: character.id
                )
                runningCharacters.remove(character.id)
            } catch {
                runningCharacters.remove(character.id)
                let message = error.localizedDescription
                if AgentUsageLimitClassifier.isLimitReached(message) {
                    pendingQuestions[character.id] = nil
                    questionSubmissionErrors[character.id] = nil
                    failedCharacters[character.id] = nil
                    offDutyCharacters[character.id] = message
                    if latestQuestion?.character == character.id {
                        latestQuestion = nil
                    }
                    showBubble(
                        "퇴근",
                        for: character.id,
                        autoDismiss: false
                    )
                } else if let questionBeingAnswered {
                    pendingQuestions[character.id] = questionBeingAnswered
                    questionSubmissionErrors[character.id] =
                        message
                    latestQuestion = PendingAgentQuestion(
                        character: character.id,
                        text: questionBeingAnswered
                    )
                    showBubble(
                        questionBeingAnswered,
                        for: character.id,
                        autoDismiss: false
                    )
                } else {
                    failedCharacters[character.id] = message
                    showBubble(
                        "업무 중단\n\(message)",
                        for: character.id,
                        autoDismiss: false
                    )
                }
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
        guard isReadyForSubmissions else {
            settingsStatus =
                sessionRestoreError ?? "세션 복구가 끝난 뒤 설정할 수 있습니다."
            return
        }
        guard runningCharacters.isEmpty else {
            settingsStatus = "진행 중인 업무가 끝난 뒤 설정할 수 있습니다."
            return
        }
        guard !isUpdatingConfiguration else {
            settingsStatus = "다른 설정을 저장하는 중입니다."
            return
        }
        isUpdatingConfiguration = true
        defer {
            isUpdatingConfiguration = false
        }
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
            let message = error.localizedDescription
            await restorePersistentState()
            settingsStatus = message
        }
    }

    func updateAgentSettings(
        _ settings: CharacterAgentSettings,
        for character: OfficeCharacter
    ) async {
        settingsStatus = nil
        guard isReadyForSubmissions else {
            settingsStatus =
                sessionRestoreError ?? "세션 복구가 끝난 뒤 설정할 수 있습니다."
            return
        }
        guard !runningCharacters.contains(character) else {
            settingsStatus = "진행 중인 업무가 끝난 뒤 설정할 수 있습니다."
            return
        }
        guard !isUpdatingConfiguration else {
            settingsStatus = "다른 설정을 저장하는 중입니다."
            return
        }
        isUpdatingConfiguration = true
        defer {
            isUpdatingConfiguration = false
        }
        do {
            try await database.updateSettings(settings, for: character)
            apply(settings, to: character)
            settingsStatus = "설정을 저장했습니다."
        } catch {
            let message = error.localizedDescription
            await restorePersistentState()
            settingsStatus = message
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

    private func clearTransientBubbles() {
        for task in bubbleDismissTasks.values {
            task.cancel()
        }
        bubbleDismissTasks = [:]
        bubbles = bubbles.filter {
            pendingQuestions[$0.key] != nil
                || runningCharacters.contains($0.key)
                || failedCharacters[$0.key] != nil
                || offDutyCharacters[$0.key] != nil
        }
    }

    private func startIdleChatter() {
        idleChatterTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    let quietDelay = Int.random(
                        in: Self.idleChatterQuietDelaySeconds
                    )
                    try await Task.sleep(for: .seconds(quietDelay))

                    if self?.showIdleChatter() == true {
                        try await Task.sleep(for: Self.bubbleLifetime)
                    }
                }
            } catch {
                return
            }
        }
    }

    private func showIdleChatter() -> Bool {
        guard bubbles.isEmpty, runningCharacters.isEmpty else {
            return false
        }

        var idleCharacters = characters
        if idleCharacters.count > 1, let lastIdleChatterCharacter {
            idleCharacters.removeAll { $0.id == lastIdleChatterCharacter }
        }

        guard
            let character = idleCharacters.randomElement(),
            let message = Self.idleChatterMessages.randomElement()
        else {
            return false
        }

        lastIdleChatterCharacter = character.id
        showBubble(message, for: character.id)
        return true
    }

    private func restorePersistentState() async {
        isReadyForSubmissions = false
        sessionRestoreError = nil
        conversationIDs = [:]
        sessionIDs = [:]

        while !Task.isCancelled {
            do {
                let storedCharacters = try await database.fetchCharacters()
                for stored in storedCharacters {
                    guard let character = OfficeCharacter(rawValue: stored.id)
                    else {
                        continue
                    }
                    names[character] = stored.name
                    apply(
                        CharacterAgentSettings(
                            backend: stored.backend,
                            model: stored.model,
                            effort: stored.effort,
                            permission: AgentPermission(
                                cliValue: stored.permission
                            )
                        ),
                        to: character
                    )
                    apply(
                        identityPrompt: stored.identityPrompt,
                        to: character
                    )
                }

                let activeSessions = try await database.fetchActiveSessions()
                var restoredConversationIDs:
                    [OfficeCharacter: UUID] = [:]
                var restoredSessionIDs: [OfficeCharacter: String] = [:]
                for storedSession in activeSessions {
                    guard
                        let character = OfficeCharacter(
                            rawValue: storedSession.characterId
                        ),
                        let externalSessionID =
                            storedSession.externalSessionId?
                            .trimmingCharacters(
                                in: .whitespacesAndNewlines
                            ),
                        !externalSessionID.isEmpty
                    else {
                        continue
                    }
                    restoredConversationIDs[character] =
                        storedSession.conversationId
                    restoredSessionIDs[character] = externalSessionID
                }
                conversationIDs = restoredConversationIDs
                sessionIDs = restoredSessionIDs
                sessionRestoreError = nil
                isReadyForSubmissions = true
                return
            } catch {
                conversationIDs = [:]
                sessionIDs = [:]
                sessionRestoreError = error.localizedDescription
                do {
                    try await Task.sleep(
                        for: Self.sessionRestoreRetryDelay
                    )
                } catch {
                    return
                }
            }
        }
    }

    private func persistTurn(
        _ turn: DatabaseTurn,
        for character: OfficeCharacter
    ) async {
        var attempt = 0
        while !Task.isCancelled {
            do {
                try await database.recordTurn(turn)
                turnPersistenceErrors[character] = nil
                return
            } catch {
                attempt += 1
                turnPersistenceErrors[character] =
                    error.localizedDescription
                try? await Task.sleep(
                    for: .seconds(min(attempt, 10))
                )
            }
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
            invalidateSession(for: character)
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
        invalidateSession(for: character)
        characters[index] = previous.applying(identityPrompt: identityPrompt)
    }

    private func invalidateSession(for character: OfficeCharacter) {
        conversationIDs[character] = nil
        sessionIDs[character] = nil
        pendingQuestions[character] = nil
        questionSubmissionErrors[character] = nil
        failedCharacters[character] = nil
        offDutyCharacters[character] = nil
        bubbleDismissTasks.removeValue(forKey: character)?.cancel()
        bubbles[character] = nil
        if latestQuestion?.character == character {
            latestQuestion = nil
        }
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
