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
final class CharacterSelectionStore: ObservableObject {
    @Published private(set) var selectedCharacterID: OfficeCharacter?

    init(selectedCharacterID: OfficeCharacter? = .boss) {
        self.selectedCharacterID = selectedCharacterID
    }

    func select(_ characterID: OfficeCharacter?) {
        guard selectedCharacterID != characterID else {
            return
        }
        selectedCharacterID = characterID
    }
}

enum WorkspaceReviewDecision {
    case approve(reviewTree: String)
    case reject
}

@MainActor
final class CharacterLiveFeedStore: ObservableObject {
    @Published private(set) var turns: [LiveFeedTurn]
    @Published private(set) var isLoadingInitialFeed: Bool
    @Published private(set) var presentationRevision = 0

    private var latestTurns: [LiveFeedTurn]
    private var latestIsLoadingInitialFeed: Bool
    private var isPresented = false

    init(
        turns: [LiveFeedTurn] = [],
        isLoadingInitialFeed: Bool = true
    ) {
        self.turns = turns
        self.isLoadingInitialFeed = isLoadingInitialFeed
        latestTurns = turns
        latestIsLoadingInitialFeed = isLoadingInitialFeed
    }

    func stage(
        turns: [LiveFeedTurn],
        isLoadingInitialFeed: Bool
    ) {
        latestTurns = turns
        latestIsLoadingInitialFeed = isLoadingInitialFeed
        guard isPresented else {
            return
        }
        publishLatestIfNeeded()
    }

    func setPresented(_ isPresented: Bool) {
        guard self.isPresented != isPresented else {
            return
        }
        self.isPresented = isPresented
        guard isPresented else {
            return
        }
        publishLatestIfNeeded()
    }

    func refreshPresentation() {
        guard isPresented else {
            return
        }
        presentationRevision &+= 1
    }

    private func publishLatestIfNeeded() {
        if turns != latestTurns {
            turns = latestTurns
        }
        if isLoadingInitialFeed != latestIsLoadingInitialFeed {
            isLoadingInitialFeed = latestIsLoadingInitialFeed
        }
    }
}

private struct RealtimeFeedEvent: Decodable {
    let type: String
    let turnId: String?
}

@MainActor
final class LiveFeedStore: ObservableObject {
    private struct ResponseAnimationState {
        let characterID: String
        let animatesInitialSource: Bool
    }

    @Published private(set) var turns: [LiveFeedTurn] = []
    @Published private(set) var isLoadingInitialFeed = true
    private(set) var persistedTurns: [LiveFeedTurn] = []
    private var optimisticTurns: [String: LiveFeedTurn] = [:]
    private var turnsByCharacterID: [String: [LiveFeedTurn]] = [:]
    private var characterStores: [String: CharacterLiveFeedStore] = [:]
    private var responseAnimations: [String: ResponseAnimationState] = [:]
    private(set) var selectedCharacterFeedID: String?

    static let minimumTurnsPerCharacter = 10

    static func snapshotTurns(
        from sortedTurns: [LiveFeedTurn],
        recentLimit: Int
    ) -> [LiveFeedTurn] {
        let recentTurns = Array(sortedTurns.prefix(recentLimit))
        var selectedTurnIDs = Set(recentTurns.map(\.id))
        var selectedCounts = Dictionary(
            grouping: recentTurns,
            by: \.characterId
        ).mapValues(\.count)

        for turn in sortedTurns.dropFirst(recentLimit) {
            let selectedCount = selectedCounts[turn.characterId, default: 0]
            if selectedCount < minimumTurnsPerCharacter {
                selectedTurnIDs.insert(turn.id)
                selectedCounts[turn.characterId] = selectedCount + 1
            }
            if turn.workspace?.status.blocksNewTasks == true {
                selectedTurnIDs.insert(turn.id)
            }
        }

        return sortedTurns.filter { selectedTurnIDs.contains($0.id) }
    }

    func replace(with turns: [LiveFeedTurn]) {
        persistedTurns = turns
        let persistedIDs = Set(turns.map(\.id))
        optimisticTurns = optimisticTurns.filter {
            !persistedIDs.contains($0.key)
                && !hasMatchingPersistedTurn(
                    for: $0.value,
                    in: turns
                )
        }
        publishMergedTurns()
    }

    func insertOptimisticTurn(_ turn: LiveFeedTurn) {
        optimisticTurns[turn.id] = turn
        publishMergedTurns()
    }

    func reconcileOptimisticTurn(
        id: String,
        with persistedTurnID: String
    ) {
        guard let turn = optimisticTurns.removeValue(forKey: id) else {
            return
        }
        if !persistedTurns.contains(where: { $0.id == persistedTurnID }) {
            optimisticTurns[persistedTurnID] = turn.replacingID(
                with: persistedTurnID
            )
        }
        publishMergedTurns()
    }

    func removeOptimisticTurn(id: String) {
        guard optimisticTurns.removeValue(forKey: id) != nil else {
            return
        }
        publishMergedTurns()
    }

    func updateFeedback(
        for turnID: String,
        to feedback: TurnResponseFeedback?
    ) {
        guard let index = persistedTurns.firstIndex(where: {
            $0.id == turnID
        }) else {
            return
        }
        persistedTurns[index] = persistedTurns[index].replacingFeedback(
            with: feedback
        )
        publishMergedTurns()
    }

    var optimisticCharacterIDs: Set<String> {
        Set(optimisticTurns.values.map(\.characterId))
    }

    func turns(for characterID: String) -> [LiveFeedTurn] {
        turnsByCharacterID[characterID] ?? []
    }

    func characterStore(
        for characterID: String
    ) -> CharacterLiveFeedStore {
        if let store = characterStores[characterID] {
            return store
        }
        let store = CharacterLiveFeedStore(
            turns: turnsByCharacterID[characterID] ?? [],
            isLoadingInitialFeed: isLoadingInitialFeed
        )
        characterStores[characterID] = store
        return store
    }

    func selectCharacterFeed(_ characterID: String?) {
        guard selectedCharacterFeedID != characterID else {
            return
        }
        if let selectedCharacterFeedID {
            discardTerminalResponseAnimations(
                forCharacterID: selectedCharacterFeedID
            )
            characterStore(for: selectedCharacterFeedID)
                .setPresented(false)
        }
        selectedCharacterFeedID = characterID
        if let characterID {
            characterStore(for: characterID).setPresented(true)
        }
    }

    func refreshSelectedCharacterFeedAfterMount(
        _ characterID: String
    ) {
        guard selectedCharacterFeedID == characterID else {
            return
        }
        characterStores[characterID]?.refreshPresentation()
    }

    private func hasMatchingPersistedTurn(
        for optimisticTurn: LiveFeedTurn,
        in turns: [LiveFeedTurn]
    ) -> Bool {
        let optimisticPrompt = TaskPromptPresentation(
            prompt: optimisticTurn.prompt
        ).text
        return turns.contains { turn in
            turn.characterId == optimisticTurn.characterId
                && TaskPromptPresentation(prompt: turn.prompt).text
                    == optimisticPrompt
                && turn.startedAt
                    >= optimisticTurn.startedAt.addingTimeInterval(-5)
                && turn.startedAt
                    <= optimisticTurn.startedAt.addingTimeInterval(120)
        }
    }

    private func publishMergedTurns() {
        var mergedTurns = persistedTurns
        mergedTurns.append(contentsOf: optimisticTurns.values)
        mergedTurns.sort {
            if $0.startedAt == $1.startedAt {
                return $0.id > $1.id
            }
            return $0.startedAt > $1.startedAt
        }
        pruneResponseAnimations(for: mergedTurns)
        suppressHiddenInitialResponseAnimations(in: mergedTurns)
        guard turns != mergedTurns else {
            return
        }
        let updatedTurnsByCharacterID = Dictionary(
            grouping: mergedTurns,
            by: \.characterId
        )
        turnsByCharacterID = updatedTurnsByCharacterID
        for (characterID, store) in characterStores {
            store.stage(
                turns: updatedTurnsByCharacterID[characterID] ?? [],
                isLoadingInitialFeed: isLoadingInitialFeed
            )
        }
        turns = mergedTurns
    }

    func finishInitialLoading() {
        guard isLoadingInitialFeed else {
            return
        }
        isLoadingInitialFeed = false
        for (characterID, store) in characterStores {
            store.stage(
                turns: turnsByCharacterID[characterID] ?? [],
                isLoadingInitialFeed: false
            )
        }
    }

    func restoreResponseAnimations(for turns: [LiveFeedTurn]) {
        for turn in turns where turn.status.isRunning {
            guard responseAnimations[turn.id] == nil else {
                continue
            }
            responseAnimations[turn.id] = ResponseAnimationState(
                characterID: turn.characterId,
                animatesInitialSource: restoredTurnAnimatesInitialSource(turn)
            )
        }
    }

    private func restoredTurnAnimatesInitialSource(
        _ turn: LiveFeedTurn
    ) -> Bool {
        guard (turn.backend ?? turn.characterBackend) == .claude else {
            return turn.response.isEmpty
        }
        return ClaudeTranscriptPresentation.make(
            turnID: turn.id,
            activities: turn.activities,
            response: turn.response,
            responseUpdatedAt: turn.updatedAt,
            isRunning: true
        ).streamingMessageID == nil
    }

    func beginResponseAnimation(
        for turnID: String,
        characterID: String? = nil,
        notifiesCharacterStore: Bool = true
    ) {
        guard responseAnimations[turnID] == nil else {
            return
        }
        guard
            let resolvedCharacterID = characterID
                ?? turn(withID: turnID)?.characterId
        else {
            return
        }
        responseAnimations[turnID] = ResponseAnimationState(
            characterID: resolvedCharacterID,
            animatesInitialSource: true
        )
        if notifiesCharacterStore {
            characterStores[resolvedCharacterID]?
                .refreshPresentation()
        }
    }

    func shouldAnimateResponse(for turn: LiveFeedTurn) -> Bool {
        responseAnimations[turn.id] != nil
    }

    func shouldAnimateInitialResponse(for turn: LiveFeedTurn) -> Bool {
        responseAnimations[turn.id]?.animatesInitialSource == true
    }

    func finishResponseAnimation(for turnID: String) {
        guard let animation = responseAnimations[turnID] else {
            return
        }
        let turn = turn(withID: turnID)
        guard turn?.status.isRunning != true else {
            return
        }
        responseAnimations[turnID] = nil
        characterStores[animation.characterID]?
            .refreshPresentation()
    }

    private func turn(withID turnID: String) -> LiveFeedTurn? {
        optimisticTurns[turnID]
            ?? persistedTurns.first(where: { $0.id == turnID })
    }

    private func discardTerminalResponseAnimations(
        forCharacterID characterID: String
    ) {
        let turnIDs = responseAnimations.compactMap { element -> String? in
            let (turnID, animation) = element
            guard
                animation.characterID == characterID,
                turn(withID: turnID)?.status.isRunning != true
            else {
                return nil
            }
            return turnID
        }
        for turnID in turnIDs {
            responseAnimations[turnID] = nil
        }
    }

    private func pruneResponseAnimations(for turns: [LiveFeedTurn]) {
        let turnsByID = Dictionary(
            uniqueKeysWithValues: turns.map { ($0.id, $0) }
        )
        let turnIDs = responseAnimations.compactMap { element -> String? in
            let (turnID, animation) = element
            guard let turn = turnsByID[turnID] else {
                return turnID
            }
            guard !turn.status.isRunning else {
                return nil
            }
            if turn.status != .completed
                || turn.response.isEmpty
                || animation.characterID != selectedCharacterFeedID
            {
                return turnID
            }
            return nil
        }
        for turnID in turnIDs {
            responseAnimations[turnID] = nil
        }
    }

    private func suppressHiddenInitialResponseAnimations(
        in turns: [LiveFeedTurn]
    ) {
        let turnsByID = Dictionary(
            uniqueKeysWithValues: turns.map { ($0.id, $0) }
        )
        let turnIDs = responseAnimations.compactMap { element -> String? in
            let (turnID, animation) = element
            guard
                animation.animatesInitialSource,
                animation.characterID != selectedCharacterFeedID,
                let turn = turnsByID[turnID],
                turn.status.isRunning,
                !restoredTurnAnimatesInitialSource(turn)
            else {
                return nil
            }
            return turnID
        }
        for turnID in turnIDs {
            guard let animation = responseAnimations[turnID] else {
                continue
            }
            responseAnimations[turnID] = ResponseAnimationState(
                characterID: animation.characterID,
                animatesInitialSource: false
            )
        }
    }
}

@MainActor
final class ArchiveFeedStore: ObservableObject {
    @Published private(set) var turns: [LiveFeedTurn] = []
    private var revision: [String] = []

    func replaceIfNeeded(with turns: [LiveFeedTurn]) {
        let updatedRevision = turns.map {
            "\($0.id)|\($0.status.rawValue)|"
                + "\($0.workspace?.status.rawValue ?? "")|"
                + "\($0.workspace?.mergedCommit ?? "")|"
                + "\($0.responseSourceWarning ?? "")|"
                + "\($0.feedback?.rawValue ?? "")|"
                + $0.responseSources.map {
                    "\($0.id),\($0.sourceKind.rawValue),\($0.title),"
                        + "\($0.locator),\($0.excerpt ?? "")"
                }
                .joined(separator: ",")
        }
        guard revision != updatedRevision else {
            return
        }
        revision = updatedRevision
        self.turns = turns
    }
}

@MainActor
final class SpeechBubbleStore: ObservableObject {
    @Published private(set) var bubbles: [OfficeCharacter: String] = [:]

    func set(_ text: String, for character: OfficeCharacter) {
        guard bubbles[character] != text else {
            return
        }
        bubbles[character] = text
    }

    func remove(for character: OfficeCharacter) {
        guard bubbles[character] != nil else {
            return
        }
        bubbles[character] = nil
    }

    func replace(with bubbles: [OfficeCharacter: String]) {
        guard self.bubbles != bubbles else {
            return
        }
        self.bubbles = bubbles
    }
}

@MainActor
final class AgentDirector: ObservableObject {
    @Published private(set) var characters: [CharacterConfiguration]
    @Published private(set) var names: [OfficeCharacter: String]
    @Published private(set) var pendingQuestions:
        [OfficeCharacter: String] = [:]
    /// 대화 안에서 답변받을 턴을 가리킨다. 답변이 끝나면 비운다.
    @Published private(set) var pendingQuestionTurnIDs:
        [OfficeCharacter: String] = [:]
    @Published private(set) var questionSubmissionErrors:
        [OfficeCharacter: String] = [:]
    @Published private(set) var latestQuestion: PendingAgentQuestion?
    @Published private(set) var runningCharacters: Set<OfficeCharacter> = []
    @Published private(set) var unreviewedCompletedCharacters:
        Set<OfficeCharacter> = []
    @Published private(set) var cancellingCharacters:
        Set<OfficeCharacter> = []
    @Published private(set) var pendingWorkspaceReviewCharacters:
        Set<OfficeCharacter> = []
    @Published private(set) var failedCharacters:
        [OfficeCharacter: String] = [:]
    @Published private(set) var offDutyCharacters:
        [OfficeCharacter: String] = [:]
    @Published private(set) var isReadyForSubmissions = false
    @Published private(set) var sessionRestoreError: String?
    @Published private(set) var isUpdatingConfiguration = false
    @Published private(set) var autoApproveAndMerge = true
    @Published private(set) var turnPersistenceErrors:
        [OfficeCharacter: String] = [:]
    @Published private(set) var settingsStatus: String?
    @Published private(set) var latestSubmittedCommandID: UUID?
    @Published private(set) var latestSubmittedTurnID: String?
    @Published private(set) var latestStartedCommandID: UUID?
    @Published private(set) var latestCompletedTurnID: String?
    @Published private(set) var latestTerminalTurnID: String?
    @Published private(set) var isRealtimeConnected = false
    @Published private(set) var realtimeConnectionError: String?

    let liveFeedStore = LiveFeedStore()
    let archiveFeedStore = ArchiveFeedStore()
    let speechBubbleStore = SpeechBubbleStore()
    let characterSelectionStore = CharacterSelectionStore()

    var selectedCharacterID: OfficeCharacter? {
        get {
            characterSelectionStore.selectedCharacterID
        }
        set {
            guard characterSelectionStore.selectedCharacterID != newValue
            else {
                return
            }
            liveFeedStore.selectCharacterFeed(newValue?.rawValue)
            characterSelectionStore.select(newValue)
        }
    }

    var workspaceDirectory: String {
        configuration.workdir
    }

    var databaseBaseURL: URL {
        configuration.databaseBaseURL
    }

    private let configuration: OfficeAgentConfiguration
    private let database: OfficeDatabaseClient
    private var conversationIDs: [OfficeCharacter: UUID] = [:]
    private var sessionIDs: [OfficeCharacter: String] = [:]
    private var realtimeTask: Task<Void, Never>?
    private var realtimeRefreshTask: Task<Void, Never>?
    private var realtimeSnapshotRefreshPending = false
    private var pendingRealtimeTurnIDs: Set<String> = []
    private var hasLoadedLiveFeedSnapshot = false
    private var hasReceivedRealtimeReady = false
    private var nextLiveFeedRequestSequence = 0
    private var lastAppliedLiveFeedRequestSequence = 0
    private var observedTurnStatuses: [String: LiveTurnStatus] = [:]
    private var acknowledgedWarningMessages: [OfficeCharacter: String] = [:]
    private var bubbleDismissTasks: [OfficeCharacter: Task<Void, Never>] = [:]
    private var idleChatterTask: Task<Void, Never>?
    private var workingBubbleTask: Task<Void, Never>?
    private var lastIdleChatterCharacter: OfficeCharacter?
    private var workingBubbleStep = 0
    private var hasAppliedDefaultSelection = false
    private var hasAppliedLatestConversationSelection = false
    private var hasUserChosenCharacter = false
    private static let liveFeedSnapshotLimit = 120
    private static let bubbleLifetime = Duration.seconds(10)
    private static let sessionRestoreRetryDelay = Duration.seconds(2)
    private static let realtimeTurnBatchDelay = Duration.milliseconds(250)
    private static let realtimeRefreshRetryDelay = Duration.seconds(1)
    private static let idleChatterQuietDelaySeconds = 5 ... 12
    private static let workingBubbleRotationDelay =
        Duration.milliseconds(1_400)
    private static let koreanWorkingBubbleMessages = [
        "🫡 오더 접수, 바로 갑니다",
        "🧠 뇌풀가동 ON",
        "⚡ 속도감 미쳤다",
        "🧩 퍼즐 맞추는 중",
        "👀 디테일 감시 중",
        "🛠️ 손 빠르게 움직이는 중",
        "🔎 이슈 냄새 맡는 중",
        "🚀 속도 붙었습니다",
        "🧪 검증까지 야무지게",
        "🎯 핵심만 콕콕",
        "⌨️ 키보드 열일 중",
        "📌 우선순위부터 픽",
        "🔥 집중력 만렙",
        "🧯 불씨 발견, 바로 끔",
        "🧭 길 잃지 않고 진행 중",
        "📦 결과물 포장 중",
        "💻 코드랑 합 맞추는 중",
        "⚙️ 착착 굴러갑니다",
        "🧠 뇌내 회의 중",
        "📈 진척도 쑥쑥",
        "🪄 막힘, 살짝 치워봄",
        "🧱 차근차근 쌓는 중",
        "🔬 디테일 체크 완료각",
        "🗺️ 다음 수 읽는 중",
        "🏃 할 일과 레이스 중",
        "📎 빠진 조건 없는지 확인",
        "🧰 도구함 오픈",
        "🧪 마지막까지 테스트",
        "🎮 이슈 보스전 중",
        "🌊 흐름 탔습니다",
        "🕵️ 원인 추적 모드",
        "📚 자료 폭풍 흡수 중",
        "⚡ 손가락 가속 중",
        "🧷 마감선에 딱 맞추는 중",
        "🧠 생각 정리 완료각",
        "🔄 한 번 더 크로스체크",
        "🫧 복잡한 건 가볍게 정리",
        "💎 퀄리티 반짝이게",
        "🐞 버그 잡으러 출동",
        "🧨 리스크는 미리 컷",
        "📐 각 잡고 마무리 중",
        "🧹 군더더기 정리 중",
        "🏁 끝선 보입니다",
        "🪜 한 단계씩 클리어",
        "💬 필요한 말만 딱 정리",
        "🛰️ 해답 좌표 찍는 중",
        "🥷 조용히 처리 중",
        "🍀 잘 풀리는 중",
        "🧋 당충전 상상 중",
        "✅ 결과물 곧 도착",
    ]
    private static let koreanIdleChatterMessages = [
        "☕ 카페인 1%로 버티는 중",
        "👀 새 업무 뜨면 바로 탑승",
        "🧠 뇌는 이미 출근 완료",
        "🫠 잠깐 멍도 업무의 일부",
        "🍪 간식 레이더 이상 무",
        "😎 할 일 없어도 프로답게",
        "🪑 의자와 동기화 완료",
        "🌱 아이디어 새싹 키우는 중",
        "🎧 집중 플리 고르는 중",
        "🚀 다음 오더 대기 중",
        "📌 오늘 할 일 살짝 정리 중",
        "🔍 누락된 조건 없는지 훑는 중",
        "🧭 다음 이슈 냄새 맡는 중",
        "🧩 개선 포인트 줍줍 중",
        "🛠️ 귀찮은 반복 일단 관찰 중",
        "📈 오늘의 성장 그래프 상상 중",
        "🤝 동료 찬스 기다리는 중",
        "💬 질문 하나 장전 완료",
        "🧪 작게 해보고 크게 웃자",
        "📚 새 기능 스캔 중",
        "📝 미래의 나에게 메모 중",
        "🎯 제일 중요한 거부터 픽",
        "🌤️ 눈에도 로딩 타임 필요",
        "🪴 조용히 레벨업 중",
        "🎵 집중 버튼 찾는 중",
        "🕰️ 급할수록 체크 한 번 더",
        "🛰️ 다른 각도에서 보는 중",
        "🧹 머릿속 탭 정리 중",
        "🔄 역발상 한 스푼 넣는 중",
        "💡 불편함은 개선각",
        "📩 안 읽은 메일과 눈치 게임 중",
        "🔔 알림에 집중력 털린 중",
        "🗓️ 회의가 회의를 낳는 중",
        "⏰ 퇴근 5분 전은 왜 늘 바쁠까",
        "🧾 최종본의 최종본 찾는 중",
        "📎 파일명에 진심인 편",
        "🫥 방금 뭐 했더라 모드",
        "☕ 커피 식기 전에 집중",
        "🖨️ 프린터와 기싸움 중",
        "💬 간단한 부탁, 진짜 맞죠?",
        "📊 숫자랑 눈 마주치는 중",
        "🧠 멀티태스킹은 탭 파티",
        "🚇 출근으로 체력 선지급",
        "🍱 점심 메뉴가 최대 난제",
        "🪫 충전기는 제게도 필요",
        "🧑‍💻 저장 버튼 한 번 더 꾹",
        "🕔 시계만 유난히 슬로모션",
        "📝 할 일 적다 할 일 추가",
        "🔁 같은 설명 리믹스 중",
        "📞 통화 종료와 기억 삭제 동시 실행",
        "🧯 급한 일 위에 긴급 추가",
        "🗂️ 파일 찾다 폴더 정리 중",
        "🪑 회의 끝, 숙제 시작",
        "🫠 네, 가능합니다를 너무 빨리 함",
        "😶 의견 냈더니 담당자 됨",
        "🧩 요구사항이 또 춤추는 중",
        "🌙 야근 오타, 자신감 만렙",
        "🧘 전송 전 심호흡 세 번",
        "🏃 일정이 저보다 빠름",
        "🛌 오늘의 목표, 무사 퇴근"
    ]
    private static let englishWorkingBubbleMessages = [
        "🫡 Got it, on it",
        "🧠 Thinking it through",
        "⚡ Moving quickly",
        "🧩 Putting the pieces together",
        "👀 Checking the details",
        "🛠️ Working on it",
        "🔎 Tracing the issue",
        "🧪 Verifying the result",
        "🎯 Focusing on the key point",
        "⌨️ Coding away",
        "📌 Setting priorities",
        "✅ Result coming soon",
    ]
    private static let englishIdleChatterMessages = [
        "☕ Ready for the next task",
        "👀 Standing by",
        "🧠 Thinking ahead",
        "🌱 Growing new ideas",
        "🎧 Finding focus",
        "🚀 Waiting for the next request",
        "📌 Organizing today's work",
        "🔍 Checking for missed details",
        "🧩 Looking for improvements",
        "🛠️ Watching the workflow",
        "📚 Exploring new ideas",
        "🎯 Ready when you are",
    ]
    private static var workingBubbleMessages: [String] {
        OfficeLocalization.usesKorean
            ? koreanWorkingBubbleMessages
            : englishWorkingBubbleMessages
    }
    private static var idleChatterMessages: [String] {
        OfficeLocalization.usesKorean
            ? koreanIdleChatterMessages
            : englishIdleChatterMessages
    }

    init(
        startBackgroundTasks: Bool = true,
        workspaceDirectory: String? = nil
    ) {
        do {
            let loadedConfiguration = try CharacterConfigurationAsset.load()
            if let workspaceDirectory {
                configuration = loadedConfiguration.using(
                    workdir: workspaceDirectory
                )
            } else {
                configuration = loadedConfiguration
            }
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
        liveFeedStore.selectCharacterFeed(
            characterSelectionStore.selectedCharacterID?.rawValue
        )

        if startBackgroundTasks {
            Task {
                await restorePersistentState()
                await refreshLiveFeed(announcingTransitions: false)
                startRealtimeUpdates()
            }
            startIdleChatter()
            startWorkingBubbleRotation()
        }
    }

    var selectedCharacter: CharacterConfiguration? {
        guard let selectedCharacterID else {
            return nil
        }
        return characters.first { $0.id == selectedCharacterID }
    }

    var liveTurns: [LiveFeedTurn] {
        liveFeedStore.persistedTurns
    }

    var bubbles: [OfficeCharacter: String] {
        speechBubbleStore.bubbles
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

    var isCancellingSelectedCharacter: Bool {
        guard let selectedCharacterID else {
            return false
        }
        return cancellingCharacters.contains(selectedCharacterID)
    }

    var selectedCharacterNeedsWorkspaceReview: Bool {
        guard let selectedCharacterID else {
            return false
        }
        return pendingWorkspaceReviewCharacters.contains(selectedCharacterID)
    }

    func selectDefaultCharacterIfNeeded() {
        guard !hasAppliedDefaultSelection else {
            return
        }
        hasAppliedDefaultSelection = true
        selectedCharacterID = .boss
    }

    /// 앱을 다시 열었을 때 첫 피드 스냅샷에서 가장 최근 대화의 직원을 선택한다.
    private func selectLatestConversationCharacterIfNeeded(
        _ turns: [LiveFeedTurn]
    ) {
        guard
            !hasAppliedLatestConversationSelection,
            !hasUserChosenCharacter,
            let latestCharacter = Self.latestConversationCharacter(
                in: turns
            )
        else {
            return
        }
        hasAppliedLatestConversationSelection = true
        guard latestCharacter != selectedCharacterID else {
            return
        }
        if unreviewedCompletedCharacters.contains(latestCharacter) {
            unreviewedCompletedCharacters.remove(latestCharacter)
        }
        selectedCharacterID = latestCharacter
    }

    static func latestConversationCharacter(
        in turns: [LiveFeedTurn]
    ) -> OfficeCharacter? {
        turns.compactMap { turn -> (OfficeCharacter, Date)? in
            guard let character = OfficeCharacter(
                rawValue: turn.characterId
            ) else {
                return nil
            }
            return (character, turn.updatedAt)
        }
        .max(by: { $0.1 < $1.1 })?.0
    }

    func displayName(for character: OfficeCharacter) -> String {
        OfficeLocalization.string(names[character] ?? character.rawValue)
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

    func pendingQuestionTurnID(
        for character: OfficeCharacter
    ) -> String? {
        pendingQuestionTurnIDs[character]
    }

    func failureMessage(for character: OfficeCharacter) -> String? {
        failedCharacters[character]
    }

    func offDutyReason(for character: OfficeCharacter) -> String? {
        offDutyCharacters[character]
    }

    func acknowledgeWarningBubble(for character: OfficeCharacter) {
        guard let message = warningMessage(for: character) else {
            return
        }
        acknowledgedWarningMessages[character] = message
        bubbleDismissTasks.removeValue(forKey: character)?.cancel()
        speechBubbleStore.remove(for: character)
    }

    func select(_ character: CharacterConfiguration) {
        hasUserChosenCharacter = true
        var remainingCompletedCharacters =
            unreviewedCompletedCharacters
        if let selectedCharacterID {
            remainingCompletedCharacters.remove(selectedCharacterID)
        }
        remainingCompletedCharacters.remove(character.id)
        if remainingCompletedCharacters != unreviewedCompletedCharacters {
            unreviewedCompletedCharacters = remainingCompletedCharacters
        }
        selectedCharacterID = character.id
        let shouldShowReadyBubble =
            pendingQuestions[character.id] == nil
            && !runningCharacters.contains(character.id)
            && failedCharacters[character.id] == nil
            &&
            offDutyCharacters[character.id] == nil
        refreshBubblesAfterSelection(
            character.id,
            readyMessage: shouldShowReadyBubble
                ? "🫡 콜! 준비 완료"
                : nil
        )
    }

    func submit(
        _ prompt: String,
        attachmentPaths: [String] = [],
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
        let questionTurnIDBeingAnswered =
            pendingQuestionTurnIDs[character.id]
        let conversationID = conversationIDs[character.id] ?? UUID()
        conversationIDs[character.id] = conversationID
        hasUserChosenCharacter = true
        selectedCharacterID = character.id
        pendingQuestions[character.id] = nil
        pendingQuestionTurnIDs[character.id] = nil
        questionSubmissionErrors[character.id] = nil
        turnPersistenceErrors[character.id] = nil
        unreviewedCompletedCharacters.remove(character.id)
        acknowledgedWarningMessages[character.id] = nil
        failedCharacters[character.id] = nil
        offDutyCharacters[character.id] = nil
        if latestQuestion?.character == character.id {
            latestQuestion = nil
        }
        runningCharacters.insert(character.id)
        showWorkingBubble(for: character.id)
        let commandID = UUID()
        let optimisticTurnID = "local-\(commandID.uuidString.lowercased())"
        let submittedAt = Date()
        liveFeedStore.insertOptimisticTurn(
            LiveFeedTurn(
                id: optimisticTurnID,
                characterId: character.id.rawValue,
                characterName: displayName(for: character.id),
                characterBackend: character.backend,
                backend: character.backend,
                model: character.model,
                effort: character.effort,
                fastMode: character.fastMode,
                externalSessionId: nil,
                conversationWorkdir: nil,
                prompt: TaskPromptPresentation.canonicalPrompt(
                    text: prompt,
                    attachmentPaths: attachmentPaths
                ),
                response: "",
                feedback: nil,
                status: .running,
                needsInput: false,
                errorMessage: nil,
                responseSourceWarning: nil,
                startedAt: submittedAt,
                endedAt: nil,
                updatedAt: submittedAt,
                estimatedCostUsd: nil,
                sessionContext: nil,
                activities: [],
                sources: nil,
                workspace: nil
            )
        )
        latestSubmittedTurnID = optimisticTurnID
        latestSubmittedCommandID = commandID

        Task {
            do {
                let started = try await database.startAgentJob(
                    character: character.id,
                    prompt: prompt,
                    conversationID: conversationID,
                    attachmentPaths: attachmentPaths
                )
                conversationIDs[character.id] = started.conversationId
                liveFeedStore.beginResponseAnimation(
                    for: started.turnId,
                    characterID: character.id.rawValue,
                    notifiesCharacterStore: false
                )
                liveFeedStore.reconcileOptimisticTurn(
                    id: optimisticTurnID,
                    with: started.turnId
                )
                latestSubmittedTurnID = started.turnId
                scheduleRealtimeFeedRefresh(turnID: started.turnId)
                latestStartedCommandID = commandID
            } catch {
                liveFeedStore.removeOptimisticTurn(id: optimisticTurnID)
                runningCharacters.remove(character.id)
                let message = error.localizedDescription
                if AgentUsageLimitClassifier.isLimitReached(message) {
                    pendingQuestions[character.id] = nil
                    pendingQuestionTurnIDs[character.id] = nil
                    questionSubmissionErrors[character.id] = nil
                    failedCharacters[character.id] = nil
                    offDutyCharacters[character.id] = message
                    if latestQuestion?.character == character.id {
                        latestQuestion = nil
                    }
                    showBubble(
                        "오늘 할당량 끝, 퇴근 모드 🌙",
                        for: character.id,
                        autoDismiss: false
                    )
                } else if let questionBeingAnswered {
                    pendingQuestions[character.id] = questionBeingAnswered
                    pendingQuestionTurnIDs[character.id] =
                        questionTurnIDBeingAnswered
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
                        "앗, 작업 멈춤\n\(message)",
                        for: character.id,
                        autoDismiss: false
                    )
                }
            }
        }
    }

    func cancelSelectedJob() {
        guard
            let character = selectedCharacterID,
            runningCharacters.contains(character),
            !cancellingCharacters.contains(character)
        else {
            return
        }

        cancellingCharacters.insert(character)
        showBubble(
            "작업 정리 중... 🧹",
            for: character,
            autoDismiss: false
        )

        Task {
            defer {
                cancellingCharacters.remove(character)
            }
            do {
                let cancelled = try await database.cancelAgentJob(
                    character: character
                )
                scheduleRealtimeFeedRefresh(turnID: cancelled.turnId)
            } catch {
                turnPersistenceErrors[character] =
                    "중단 요청이 삐끗했어요 · \(error.localizedDescription)"
                scheduleRealtimeFeedRefresh(turnID: nil)
            }
        }
    }

    func fetchWorkspaceReview(
        turnID: String
    ) async throws -> TurnWorkspaceReview {
        try await database.fetchWorkspaceReview(turnID: turnID)
    }

    func updateResponseFeedback(
        turnID: String,
        feedback: TurnResponseFeedback?
    ) async {
        guard
            let turn = liveTurns.first(where: { $0.id == turnID }),
            turn.status == .completed
        else {
            return
        }

        let previousFeedback = turn.feedback
        liveFeedStore.updateFeedback(for: turnID, to: feedback)
        do {
            let storedFeedback = try await database.updateTurnFeedback(
                turnID: turnID,
                feedback: feedback
            )
            liveFeedStore.updateFeedback(for: turnID, to: storedFeedback)
        } catch {
            liveFeedStore.updateFeedback(
                for: turnID,
                to: previousFeedback
            )
            let message = error.localizedDescription
            if realtimeConnectionError != message {
                realtimeConnectionError = message
            }
        }
    }

    func resolveWorkspaceReview(
        turnID: String,
        decision: WorkspaceReviewDecision
    ) async throws -> TurnWorkspaceReview {
        let workspace: TurnWorkspaceReview
        switch decision {
        case .approve(let reviewTree):
            workspace = try await database.approveWorkspaceReview(
                turnID: turnID,
                reviewTree: reviewTree
            )
        case .reject:
            workspace = try await database.rejectWorkspaceReview(
                turnID: turnID
            )
        }

        let refreshed = await refreshLiveFeedTurn(
            turnID,
            announcingTransitions: false
        )
        if !refreshed {
            scheduleRealtimeFeedRefresh(turnID: turnID)
        }
        return workspace
    }

    func agentSettings(
        for character: OfficeCharacter
    ) -> CharacterAgentSettings {
        characters.first { $0.id == character }?.agentSettings
            ?? CharacterAgentSettings(
                backend: .codex,
                model: AgentBackend.codex.defaultModel,
                effort: "high",
                fastMode: true,
                permission: .workspaceWrite
            )
    }

    func saveConfiguration(
        names nameDrafts: [OfficeCharacter: String],
        settings settingsDrafts: [OfficeCharacter: CharacterAgentSettings],
        identityPrompts identityPromptDrafts: [OfficeCharacter: String],
        autoApproveAndMerge autoApproveAndMergeDraft: Bool
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
            let automationChanged =
                autoApproveAndMergeDraft != autoApproveAndMerge
            if automationChanged {
                let automationSettings =
                    try await database.updateAutomationSettings(
                        autoApproveAndMerge: autoApproveAndMergeDraft
                    )
                autoApproveAndMerge =
                    automationSettings.autoApproveAndMerge
            }
            guard pendingWorkspaceReviewCharacters.isEmpty else {
                if automationChanged {
                    settingsStatus = autoApproveAndMerge
                        ? "자동 승인 설정을 저장했고 대기 중 변경사항을 처리합니다."
                        : "자동 승인 설정을 꺼서 저장했습니다. 기존 변경사항은 검토 대기합니다."
                } else {
                    settingsStatus =
                        "변경사항 검토를 마친 뒤 직원 설정을 바꿀 수 있습니다."
                }
                return
            }
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
        guard !pendingWorkspaceReviewCharacters.contains(character) else {
            settingsStatus = "변경사항 검토를 마친 뒤 설정할 수 있습니다."
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

    func archiveFeed(
        query: String?,
        limit: Int,
        offset: Int
    ) async throws -> ArchiveFeedPage {
        try await database.fetchArchiveFeed(
            query: query,
            limit: limit,
            offset: offset
        )
    }

    private func showBubble(
        _ text: String,
        for character: OfficeCharacter,
        autoDismiss: Bool = true
    ) {
        bubbleDismissTasks.removeValue(forKey: character)?.cancel()
        speechBubbleStore.set(text, for: character)

        guard autoDismiss else {
            return
        }

        bubbleDismissTasks[character] = Task { [weak self] in
            try? await Task.sleep(for: Self.bubbleLifetime)
            guard !Task.isCancelled else {
                return
            }
            self?.speechBubbleStore.remove(for: character)
            self?.bubbleDismissTasks[character] = nil
        }
    }

    private func refreshBubblesAfterSelection(
        _ character: OfficeCharacter,
        readyMessage: String?
    ) {
        for task in bubbleDismissTasks.values {
            task.cancel()
        }
        bubbleDismissTasks = [:]
        var updatedBubbles = bubbles.filter {
            pendingQuestions[$0.key] != nil
                || runningCharacters.contains($0.key)
                || !isWarningAcknowledged(for: $0.key)
                    && warningMessage(for: $0.key) != nil
        }
        if let readyMessage {
            updatedBubbles[character] = readyMessage
        }
        speechBubbleStore.replace(with: updatedBubbles)

        guard readyMessage != nil else {
            return
        }
        bubbleDismissTasks[character] = Task { [weak self] in
            try? await Task.sleep(for: Self.bubbleLifetime)
            guard !Task.isCancelled else {
                return
            }
            self?.speechBubbleStore.remove(for: character)
            self?.bubbleDismissTasks[character] = nil
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

    private func startWorkingBubbleRotation() {
        workingBubbleTask?.cancel()
        workingBubbleTask = Task { [weak self] in
            do {
                while !Task.isCancelled {
                    try await Task.sleep(
                        for: Self.workingBubbleRotationDelay
                    )
                    self?.rotateWorkingBubbles()
                }
            } catch {
                return
            }
        }
    }

    private func rotateWorkingBubbles() {
        guard !runningCharacters.isEmpty else {
            return
        }
        workingBubbleStep =
            (workingBubbleStep + 1) % Self.workingBubbleMessages.count
        for character in runningCharacters {
            showWorkingBubble(for: character)
        }
    }

    private func showWorkingBubble(for character: OfficeCharacter) {
        guard
            runningCharacters.contains(character),
            !cancellingCharacters.contains(character)
        else {
            return
        }
        let characterOffset =
            (OfficeCharacter.allCases.firstIndex(of: character) ?? 0) * 3
        let messageIndex =
            (workingBubbleStep + characterOffset)
            % Self.workingBubbleMessages.count
        showBubble(
            Self.workingBubbleMessages[messageIndex],
            for: character,
            autoDismiss: false
        )
    }

    private func restorePersistentState() async {
        isReadyForSubmissions = false
        sessionRestoreError = nil
        conversationIDs = [:]
        sessionIDs = [:]

        while !Task.isCancelled {
            do {
                let storedCharacters = try await database.fetchCharacters()
                let automationSettings =
                    try await database.fetchAutomationSettings()
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
                            fastMode: stored.fastMode,
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
                autoApproveAndMerge =
                    automationSettings.autoApproveAndMerge

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

    private func startRealtimeUpdates() {
        realtimeTask?.cancel()
        realtimeRefreshTask?.cancel()
        realtimeRefreshTask = nil
        realtimeSnapshotRefreshPending = false
        pendingRealtimeTurnIDs.removeAll()
        realtimeTask = Task { [weak self] in
            guard let self else {
                return
            }
            while !Task.isCancelled {
                let socket = URLSession.shared.webSocketTask(
                    with: self.database.realtimeWebSocketURL
                )
                socket.resume()
                do {
                    while !Task.isCancelled {
                        let message = try await socket.receive()
                        if !self.isRealtimeConnected {
                            self.isRealtimeConnected = true
                        }
                        if self.realtimeConnectionError != nil {
                            self.realtimeConnectionError = nil
                        }
                        let event = self.realtimeEvent(from: message)
                        if event?.type == "ready" {
                            let shouldRefreshSnapshot =
                                self.hasReceivedRealtimeReady
                                    || !self.hasLoadedLiveFeedSnapshot
                            self.hasReceivedRealtimeReady = true
                            if shouldRefreshSnapshot {
                                self.scheduleRealtimeFeedRefresh(turnID: nil)
                            }
                        } else {
                            self.scheduleRealtimeFeedRefresh(
                                turnID: event?.turnId
                            )
                        }
                    }
                } catch {
                    if self.isRealtimeConnected {
                        self.isRealtimeConnected = false
                    }
                    if !Task.isCancelled {
                        let message = error.localizedDescription
                        if self.realtimeConnectionError != message {
                            self.realtimeConnectionError = message
                        }
                    }
                }
                socket.cancel(with: .goingAway, reason: nil)
                if Task.isCancelled {
                    return
                }
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    private func realtimeEvent(
        from message: URLSessionWebSocketTask.Message
    ) -> RealtimeFeedEvent? {
        let data: Data
        switch message {
        case .data(let messageData):
            data = messageData
        case .string(let text):
            data = Data(text.utf8)
        @unknown default:
            return nil
        }
        return try? JSONDecoder().decode(
            RealtimeFeedEvent.self,
            from: data
        )
    }

    private func scheduleRealtimeFeedRefresh(turnID: String?) {
        if let turnID = turnID?.trimmingCharacters(
            in: .whitespacesAndNewlines
        ), !turnID.isEmpty {
            pendingRealtimeTurnIDs.insert(turnID)
        } else {
            realtimeSnapshotRefreshPending = true
        }
        guard realtimeRefreshTask == nil else {
            return
        }

        realtimeRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                self.realtimeRefreshTask = nil
            }

            while
                self.realtimeSnapshotRefreshPending
                    || !self.pendingRealtimeTurnIDs.isEmpty
            {
                guard !Task.isCancelled else {
                    return
                }

                if self.realtimeSnapshotRefreshPending {
                    self.realtimeSnapshotRefreshPending = false
                    let refreshed = await self.refreshLiveFeed(
                        announcingTransitions: true
                    )
                    if !refreshed, !Task.isCancelled {
                        self.realtimeSnapshotRefreshPending = true
                        do {
                            try await Task.sleep(
                                for: Self.realtimeRefreshRetryDelay
                            )
                        } catch {
                            return
                        }
                    }
                    continue
                }

                do {
                    try await Task.sleep(
                        for: Self.realtimeTurnBatchDelay
                    )
                } catch {
                    return
                }
                let turnIDs = self.pendingRealtimeTurnIDs
                self.pendingRealtimeTurnIDs.removeAll()
                for turnID in turnIDs {
                    let refreshed = await self.refreshLiveFeedTurn(
                        turnID,
                        announcingTransitions: true
                    )
                    if !refreshed {
                        self.realtimeSnapshotRefreshPending = true
                        break
                    }
                }
                if self.realtimeSnapshotRefreshPending, !Task.isCancelled {
                    do {
                        try await Task.sleep(
                            for: Self.realtimeRefreshRetryDelay
                        )
                    } catch {
                        return
                    }
                }
            }
        }
    }

    @discardableResult
    private func refreshLiveFeed(
        announcingTransitions: Bool
    ) async -> Bool {
        nextLiveFeedRequestSequence += 1
        let requestSequence = nextLiveFeedRequestSequence

        do {
            let turns = try await database.fetchLiveFeed(
                limit: Self.liveFeedSnapshotLimit
            )
            guard requestSequence > lastAppliedLiveFeedRequestSequence else {
                return true
            }
            lastAppliedLiveFeedRequestSequence = requestSequence
            applyLiveFeed(
                turns,
                announcingTransitions: announcingTransitions
            )
            hasLoadedLiveFeedSnapshot = true
            liveFeedStore.finishInitialLoading()
            if realtimeConnectionError != nil {
                realtimeConnectionError = nil
            }
            return true
        } catch {
            let message = error.localizedDescription
            if realtimeConnectionError != message {
                realtimeConnectionError = message
            }
            return false
        }
    }

    @discardableResult
    private func refreshLiveFeedTurn(
        _ turnID: String,
        announcingTransitions: Bool
    ) async -> Bool {
        do {
            let turn = try await database.fetchLiveFeedTurn(id: turnID)
            var turns = liveTurns.filter { $0.id != turn.id }
            turns.append(turn)
            turns.sort {
                if $0.startedAt == $1.startedAt {
                    return $0.id > $1.id
                }
                return $0.startedAt > $1.startedAt
            }
            applyLiveFeed(
                LiveFeedStore.snapshotTurns(
                    from: turns,
                    recentLimit: Self.liveFeedSnapshotLimit
                ),
                announcingTransitions: announcingTransitions
            )
            if realtimeConnectionError != nil {
                realtimeConnectionError = nil
            }
            return true
        } catch {
            let message = error.localizedDescription
            if realtimeConnectionError != message {
                realtimeConnectionError = message
            }
            return false
        }
    }

    private func applyLiveFeed(
        _ turns: [LiveFeedTurn],
        announcingTransitions: Bool
    ) {
        guard hasFeedRevisionChanged(turns) else {
            return
        }

        let previousStatuses = observedTurnStatuses
        let previousRunningCharacters = runningCharacters
        if !hasLoadedLiveFeedSnapshot {
            liveFeedStore.restoreResponseAnimations(for: turns)
        } else if announcingTransitions {
            for turn in turns where
                turn.status.isRunning && previousStatuses[turn.id] == nil
            {
                liveFeedStore.beginResponseAnimation(
                    for: turn.id,
                    characterID: turn.characterId,
                    notifiesCharacterStore: false
                )
            }
        }
        liveFeedStore.replace(with: turns)
        archiveFeedStore.replaceIfNeeded(with: turns)
        selectLatestConversationCharacterIfNeeded(turns)
        observedTurnStatuses = Dictionary(
            uniqueKeysWithValues: turns.map { ($0.id, $0.status) }
        )

        let updatedReviewCharacters = Set(
            turns.compactMap { turn -> OfficeCharacter? in
                guard turn.workspace?.status.blocksNewTasks == true else {
                    return nil
                }
                return OfficeCharacter(rawValue: turn.characterId)
            }
        )
        if pendingWorkspaceReviewCharacters != updatedReviewCharacters {
            pendingWorkspaceReviewCharacters = updatedReviewCharacters
        }

        let runningTurns = turns.filter { $0.status.isRunning }
        let updatedRunningCharacters = Set(
            runningTurns.compactMap {
                OfficeCharacter(rawValue: $0.characterId)
            }
        ).union(
            liveFeedStore.optimisticCharacterIDs.compactMap(
                OfficeCharacter.init(rawValue:)
            )
        )
        if runningCharacters != updatedRunningCharacters {
            runningCharacters = updatedRunningCharacters
        }
        for character in runningCharacters
        where
            !previousRunningCharacters.contains(character)
                || bubbles[character] == nil
        {
            showWorkingBubble(for: character)
        }

        var latestTurns:
            [OfficeCharacter: LiveFeedTurn] = [:]
        for turn in turns {
            guard
                let character = OfficeCharacter(
                    rawValue: turn.characterId
                ),
                latestTurns[character] == nil
            else {
                continue
            }
            latestTurns[character] = turn
        }

        for (character, turn) in latestTurns {
            if turn.status == .completed, turn.needsInput {
                if pendingQuestions[character] != turn.response {
                    pendingQuestions[character] = turn.response
                    latestQuestion = PendingAgentQuestion(
                        character: character,
                        text: turn.response
                    )
                    showBubble(
                        turn.response,
                        for: character,
                        autoDismiss: false
                    )
                }
                pendingQuestionTurnIDs[character] = turn.id
            } else if
                !turn.status.isRunning,
                pendingQuestions[character] != nil
            {
                pendingQuestions[character] = nil
                pendingQuestionTurnIDs[character] = nil
            }

            if
                !announcingTransitions,
                turn.status == .failed || turn.status == .interrupted
            {
                applyTerminalTurn(turn, for: character)
            } else if turn.status == .completed, !turn.needsInput {
                acknowledgedWarningMessages[character] = nil
                if failedCharacters[character] != nil {
                    failedCharacters[character] = nil
                }
                if offDutyCharacters[character] != nil {
                    offDutyCharacters[character] = nil
                }
            }

            guard
                announcingTransitions,
                previousStatuses[turn.id]?.isRunning == true,
                !turn.status.isRunning
            else {
                continue
            }
            latestTerminalTurnID = turn.id
            if turn.status == .completed {
                unreviewedCompletedCharacters.insert(character)
                latestCompletedTurnID = turn.id
            }
            applyTerminalTurn(turn, for: character)
        }
    }

    private func hasFeedRevisionChanged(
        _ turns: [LiveFeedTurn]
    ) -> Bool {
        guard liveTurns.count == turns.count else {
            return true
        }

        return zip(liveTurns, turns).contains { $0 != $1 }
    }

    private func applyTerminalTurn(
        _ turn: LiveFeedTurn,
        for character: OfficeCharacter
    ) {
        switch turn.status {
        case .completed:
            acknowledgedWarningMessages[character] = nil
            if failedCharacters[character] != nil {
                failedCharacters[character] = nil
            }
            if offDutyCharacters[character] != nil {
                offDutyCharacters[character] = nil
            }
            if turn.needsInput {
                if pendingQuestions[character] != turn.response {
                    pendingQuestions[character] = turn.response
                    latestQuestion = PendingAgentQuestion(
                        character: character,
                        text: turn.response
                    )
                    showBubble(
                        turn.response,
                        for: character,
                        autoDismiss: false
                    )
                }
                pendingQuestionTurnIDs[character] = turn.id
            } else {
                if pendingQuestions[character] != nil {
                    pendingQuestions[character] = nil
                }
                pendingQuestionTurnIDs[character] = nil
                showBubble(turn.response, for: character)
            }
        case .failed, .interrupted:
            let message =
                turn.errorMessage ?? "작업이 멈췄어요."
            if AgentUsageLimitClassifier.isLimitReached(message) {
                if failedCharacters[character] != nil {
                    failedCharacters[character] = nil
                }
                if offDutyCharacters[character] != message {
                    offDutyCharacters[character] = message
                }
                if !isWarningAcknowledged(for: character) {
                    showBubble(
                        "오늘 할당량 끝, 퇴근 모드 🌙",
                        for: character,
                        autoDismiss: false
                    )
                }
            } else {
                if offDutyCharacters[character] != nil {
                    offDutyCharacters[character] = nil
                }
                if failedCharacters[character] != message {
                    failedCharacters[character] = message
                }
                if !isWarningAcknowledged(for: character) {
                    showBubble(
                        "앗, 작업 멈춤\n\(message)",
                        for: character,
                        autoDismiss: false
                    )
                }
            }
        case .pending, .running:
            break
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
        pendingQuestionTurnIDs[character] = nil
        questionSubmissionErrors[character] = nil
        acknowledgedWarningMessages[character] = nil
        failedCharacters[character] = nil
        offDutyCharacters[character] = nil
        bubbleDismissTasks.removeValue(forKey: character)?.cancel()
        speechBubbleStore.remove(for: character)
        if latestQuestion?.character == character {
            latestQuestion = nil
        }
    }

    private func warningMessage(for character: OfficeCharacter) -> String? {
        failedCharacters[character] ?? offDutyCharacters[character]
    }

    private func isWarningAcknowledged(
        for character: OfficeCharacter
    ) -> Bool {
        guard let message = warningMessage(for: character) else {
            return false
        }
        return acknowledgedWarningMessages[character] == message
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
            fastMode: character.fastMode,
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
