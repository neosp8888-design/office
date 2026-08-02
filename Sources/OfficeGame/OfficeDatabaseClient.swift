// 이 파일은 캐릭터 이름·역할 지침과 CLI 대화 기록을 로컬 PostgreSQL 백엔드에 전달한다.

import Foundation
import OfficeCore

struct OfficeDatabaseClient: Sendable {
    let baseURL: URL

    func fetchCharacters() async throws -> [StoredCharacterProfile] {
        let url = baseURL.appending(path: "api/characters")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        let payload = try JSONDecoder().decode(
            CharacterListResponse.self,
            from: data
        )
        return payload.characters
    }

    func fetchActiveSessions() async throws -> [StoredActiveSession] {
        let url = baseURL.appending(path: "api/active-sessions")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        let payload = try JSONDecoder().decode(
            ActiveSessionListResponse.self,
            from: data
        )
        return payload.sessions
    }

    func fetchAutomationSettings() async throws -> AutomationSettings {
        let url = baseURL.appending(path: "api/automation-settings")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response, data: data)
        return try JSONDecoder().decode(AutomationSettings.self, from: data)
    }

    func updateAutomationSettings(
        autoApproveAndMerge: Bool
    ) async throws -> AutomationSettings {
        let url = baseURL.appending(path: "api/automation-settings")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "content-type"
        )
        request.httpBody = try JSONEncoder().encode(
            AutomationSettings(
                autoApproveAndMerge: autoApproveAndMerge
            )
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(AutomationSettings.self, from: data)
    }

    func updateName(
        _ name: String,
        for character: OfficeCharacter
    ) async throws {
        let url = baseURL
            .appending(path: "api/characters")
            .appending(path: character.rawValue)
            .appending(path: "name")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "content-type"
        )
        request.httpBody = try JSONEncoder().encode(NameRequest(name: name))
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    func updateSettings(
        _ settings: CharacterAgentSettings,
        for character: OfficeCharacter
    ) async throws {
        let url = baseURL
            .appending(path: "api/characters")
            .appending(path: character.rawValue)
            .appending(path: "settings")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "content-type"
        )
        request.httpBody = try JSONEncoder().encode(
            AgentSettingsRequest(
                backend: settings.backend,
                model: settings.model,
                effort: settings.effort,
                fastMode: settings.fastMode,
                permission: settings.permission.cliValue(
                    for: settings.backend
                )
            )
        )
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    func updateIdentityPrompt(
        _ identityPrompt: String,
        for character: OfficeCharacter
    ) async throws {
        let url = baseURL
            .appending(path: "api/characters")
            .appending(path: character.rawValue)
            .appending(path: "identity-prompt")
        var request = URLRequest(url: url)
        request.httpMethod = "PUT"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "content-type"
        )
        request.httpBody = try JSONEncoder().encode(
            IdentityPromptRequest(identityPrompt: identityPrompt)
        )
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    func fetchCharacterHistory(
        for character: OfficeCharacter
    ) async throws -> CharacterHistory {
        let url = baseURL
            .appending(path: "api/characters")
            .appending(path: character.rawValue)
            .appending(path: "history")
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        return try historyDecoder().decode(
            CharacterHistory.self,
            from: data
        )
    }

    func fetchGlobalHistory(
        character: OfficeCharacter?,
        from: Date?,
        to: Date?
    ) async throws -> [GlobalHistoryTurn] {
        let endpoint = baseURL.appending(path: "api/history")
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw OfficeDatabaseError.requestFailed
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        var queryItems: [URLQueryItem] = []
        if let character {
            queryItems.append(
                URLQueryItem(
                    name: "characterId",
                    value: character.rawValue
                )
            )
        }
        if let from {
            queryItems.append(
                URLQueryItem(name: "from", value: formatter.string(from: from))
            )
        }
        if let to {
            queryItems.append(
                URLQueryItem(name: "to", value: formatter.string(from: to))
            )
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw OfficeDatabaseError.requestFailed
        }

        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        return try historyDecoder().decode(
            GlobalHistoryResponse.self,
            from: data
        )
        .turns
    }

    func fetchLiveFeed(limit: Int) async throws -> [LiveFeedTurn] {
        let endpoint = baseURL
            .appending(path: "api")
            .appending(path: "live-feed")
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw OfficeDatabaseError.requestFailed
        }
        components.queryItems = [
            URLQueryItem(name: "limit", value: String(limit))
        ]
        guard let url = components.url else {
            throw OfficeDatabaseError.requestFailed
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        return try historyDecoder().decode(
            LiveFeedResponse.self,
            from: data
        )
        .turns
    }

    func fetchLiveFeedTurn(id: String) async throws -> LiveFeedTurn {
        let url = baseURL
            .appending(path: "api")
            .appending(path: "live-feed")
            .appending(path: id)
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        return try historyDecoder().decode(
            LiveFeedTurnResponse.self,
            from: data
        )
        .turn
    }

    func fetchArchiveFeed(
        query: String?,
        limit: Int,
        offset: Int
    ) async throws -> ArchiveFeedPage {
        let endpoint = baseURL
            .appending(path: "api")
            .appending(path: "archive-feed")
        guard var components = URLComponents(
            url: endpoint,
            resolvingAgainstBaseURL: false
        ) else {
            throw OfficeDatabaseError.requestFailed
        }
        var queryItems = [
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "offset", value: String(offset)),
        ]
        if let query, !query.isEmpty {
            queryItems.append(URLQueryItem(name: "query", value: query))
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw OfficeDatabaseError.requestFailed
        }
        let (data, response) = try await URLSession.shared.data(from: url)
        try validate(response)
        return try historyDecoder().decode(ArchiveFeedPage.self, from: data)
    }

    func fetchWorkspaceReview(
        turnID: String
    ) async throws -> TurnWorkspaceReview {
        try await workspaceReviewRequest(
            turnID: turnID,
            action: nil
        )
    }

    func approveWorkspaceReview(
        turnID: String,
        reviewTree: String
    ) async throws -> TurnWorkspaceReview {
        try await workspaceReviewRequest(
            turnID: turnID,
            action: "approve",
            reviewTree: reviewTree
        )
    }

    func rejectWorkspaceReview(
        turnID: String
    ) async throws -> TurnWorkspaceReview {
        try await workspaceReviewRequest(
            turnID: turnID,
            action: "reject"
        )
    }

    func startAgentJob(
        character: OfficeCharacter,
        prompt: String,
        conversationID: UUID,
        attachmentPaths: [String]
    ) async throws -> StartedAgentJob {
        let url = baseURL
            .appending(path: "api")
            .appending(path: "agent-jobs")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "content-type"
        )
        request.httpBody = try JSONEncoder().encode(
            StartAgentJobRequest(
                characterId: character.rawValue,
                prompt: prompt,
                conversationId: conversationID,
                attachmentPaths: attachmentPaths
            )
        )
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(StartedAgentJob.self, from: data)
    }

    func cancelAgentJob(
        character: OfficeCharacter
    ) async throws -> CancelledAgentJob {
        let url = baseURL
            .appending(path: "api")
            .appending(path: "agent-jobs")
            .appending(path: character.rawValue)
        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(CancelledAgentJob.self, from: data)
    }

    var realtimeWebSocketURL: URL {
        var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        )
        components?.scheme = baseURL.scheme == "https" ? "wss" : "ws"
        components?.path = "/ws"
        components?.query = nil
        return components?.url ?? baseURL
    }

    func recordTurn(_ turn: DatabaseTurn) async throws {
        let url = baseURL.appending(path: "api/turns")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue(
            "application/json",
            forHTTPHeaderField: "content-type"
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        request.httpBody = try encoder.encode(turn)
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response)
    }

    private func validate(_ response: URLResponse) throws {
        guard
            let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode)
        else {
            throw OfficeDatabaseError.requestFailed
        }
    }

    private func validate(_ response: URLResponse, data: Data) throws {
        guard
            let response = response as? HTTPURLResponse,
            (200..<300).contains(response.statusCode)
        else {
            let payload = try? JSONDecoder().decode(
                BackendErrorResponse.self,
                from: data
            )
            throw OfficeDatabaseError.backend(
                payload?.error ?? "백엔드 요청에 실패했습니다."
            )
        }
    }

    private func workspaceReviewRequest(
        turnID: String,
        action: String?,
        reviewTree: String? = nil
    ) async throws -> TurnWorkspaceReview {
        var url = baseURL
            .appending(path: "api")
            .appending(path: "workspace-reviews")
            .appending(path: turnID)
        if let action {
            url = url.appending(path: action)
        }
        var request = URLRequest(url: url)
        if action != nil {
            request.httpMethod = "POST"
            request.setValue(
                "application/json",
                forHTTPHeaderField: "content-type"
            )
            if let reviewTree {
                request.httpBody = try JSONEncoder().encode(
                    WorkspaceReviewApprovalRequest(reviewTree: reviewTree)
                )
            } else {
                request.httpBody = Data("{}".utf8)
            }
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response, data: data)
        return try JSONDecoder().decode(
            WorkspaceReviewResponse.self,
            from: data
        ).workspace
    }

    private func historyDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [
            .withInternetDateTime,
            .withFractionalSeconds,
        ]
        let standard = ISO8601DateFormatter()
        standard.formatOptions = [.withInternetDateTime]
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            if let date = fractional.date(from: value) {
                return date
            }

            if let date = standard.date(from: value) {
                return date
            }
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "날짜 형식이 올바르지 않습니다."
            )
        }
        return decoder
    }
}

struct DatabaseTurn: Encodable, Sendable {
    let turnId: UUID
    let conversationId: UUID
    let characterId: String
    let externalSessionId: String?
    let backend: AgentBackend
    let model: String?
    let effort: String
    let fastMode: Bool
    let prompt: String
    let response: String
    let title: String
    let workdir: String
    let startedAt: Date
    let finishedAt: Date
}

private struct CharacterListResponse: Decodable {
    let characters: [StoredCharacterProfile]
}

private struct ActiveSessionListResponse: Decodable {
    let sessions: [StoredActiveSession]
}

struct StoredCharacterProfile: Decodable, Sendable {
    let id: String
    let name: String
    let backend: AgentBackend
    let model: String?
    let effort: String
    let fastMode: Bool
    let permission: String
    let identityPrompt: String
}

struct StoredActiveSession: Decodable, Sendable {
    let characterId: String
    let externalSessionId: String?
    let conversationId: UUID
}

struct CharacterHistory: Decodable, Sendable {
    let character: HistoryCharacter
    let sessions: [HistorySession]
}

struct HistoryCharacter: Decodable, Sendable {
    let id: String
    let name: String
    let seat: String
    let backend: AgentBackend
}

struct HistorySession: Decodable, Identifiable, Sendable {
    let id: String
    let externalId: String?
    let startedAt: Date
    let endedAt: Date?
    let turns: [HistoryTurn]
}

struct HistoryTurn: Decodable, Identifiable, Sendable {
    let id: String
    let sessionId: String
    let prompt: String
    let response: String
    let sources: [LiveFeedSource]?
    let executionBackend: AgentBackend?
    let executionModel: String?
    let executionEffort: String?
    let executionFastMode: Bool?
    let conversationWorkdir: String?
    let responseSourceWarning: String?
    let startedAt: Date
    let endedAt: Date?

    var responseSources: [LiveFeedSource] {
        sources ?? []
    }
}

struct GlobalHistoryTurn: Decodable, Identifiable, Sendable {
    let id: String
    let characterId: String
    let characterName: String
    let backend: AgentBackend
    let executionBackend: AgentBackend?
    let executionModel: String?
    let executionEffort: String?
    let executionFastMode: Bool?
    let externalSessionId: String?
    let conversationWorkdir: String?
    let prompt: String
    let response: String
    let sources: [LiveFeedSource]?
    let responseSourceWarning: String?
    let startedAt: Date
    let endedAt: Date?

    var responseSources: [LiveFeedSource] {
        sources ?? []
    }
}

enum LiveTurnStatus: String, Decodable, Sendable {
    case pending
    case running
    case completed
    case failed
    case interrupted

    var isRunning: Bool {
        self == .pending || self == .running
    }
}

struct LiveFeedActivity: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let kind: String
    let text: String
    let status: LiveFeedActivityStatus
    let occurredAt: Date

    private enum CodingKeys: String, CodingKey {
        case id
        case kind
        case text
        case status
        case occurredAt
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        kind = try container.decode(String.self, forKey: .kind)
        text = try container.decode(String.self, forKey: .text)
        status = try container.decodeIfPresent(
            LiveFeedActivityStatus.self,
            forKey: .status
        ) ?? .completed
        occurredAt = try container.decode(Date.self, forKey: .occurredAt)
    }
}

enum LiveFeedActivityStatus: String, Decodable, Sendable {
    case running
    case completed
    case failed
}

enum WorkspaceReviewStatus: String, Decodable, Equatable, Sendable {
    case active
    case awaitingApproval = "awaiting_approval"
    case merging
    case merged
    case rejected
    case closed
    case conflict
    case failed

    var blocksNewTasks: Bool {
        switch self {
        case .awaitingApproval, .merging, .conflict:
            true
        case .active, .merged, .rejected, .closed, .failed:
            false
        }
    }

    var showsReviewPanel: Bool {
        self != .active && self != .closed
    }
}

struct WorkspaceChangedFile: Decodable, Equatable, Identifiable, Sendable {
    let status: String
    let path: String
    let previousPath: String?

    init(
        status: String,
        path: String,
        previousPath: String? = nil
    ) {
        self.status = status
        self.path = path
        self.previousPath = previousPath
    }

    var id: String {
        "\(status)|\(previousPath ?? "")|\(path)"
    }
}

struct TurnWorkspaceReview: Decodable, Equatable, Sendable {
    let status: WorkspaceReviewStatus
    let repositoryRoot: String
    let worktreePath: String
    let executionWorkdir: String?
    let branchName: String
    let baseBranch: String
    let baseCommit: String
    let reviewTree: String?
    let headCommit: String?
    let changedFiles: [WorkspaceChangedFile]
    let mergedCommit: String?
    let errorMessage: String?
    let diff: String?
    let diffTruncated: Bool?

    func fileBaseDirectory(fallback: String) -> String {
        if let executionWorkdir, !executionWorkdir.isEmpty {
            return executionWorkdir
        }
        if status == .merged, !repositoryRoot.isEmpty {
            return repositoryRoot
        }
        if !worktreePath.isEmpty {
            return worktreePath
        }
        if !repositoryRoot.isEmpty {
            return repositoryRoot
        }
        return fallback
    }

    func reviewFileBaseDirectory(fallback: String) -> String {
        if status == .merged, !repositoryRoot.isEmpty {
            return repositoryRoot
        }
        if !worktreePath.isEmpty {
            return worktreePath
        }
        if !repositoryRoot.isEmpty {
            return repositoryRoot
        }
        return fallback
    }

    var canApprove: Bool {
        status == .awaitingApproval
            && !(reviewTree?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true)
    }

    var canRetryMerge: Bool {
        status == .conflict
            && !(reviewTree?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty ?? true)
    }
}

struct SessionContextUsage: Decodable, Equatable, Sendable {
    let usedTokens: Int
    let limitTokens: Int

    var remainingTokens: Int {
        max(0, limitTokens - usedTokens)
    }

    var remainingRatio: Double {
        guard limitTokens > 0 else {
            return 0
        }
        return Double(remainingTokens) / Double(limitTokens)
    }
}

enum LiveFeedSourceKind: String, Decodable, Sendable {
    case rag
    case database
    case file
    case web
    case tool
    case skill

    var title: String {
        switch self {
        case .rag:
            "RAG"
        case .database:
            "DB"
        case .file:
            "파일"
        case .web:
            "웹"
        case .tool:
            "도구"
        case .skill:
            "스킬"
        }
    }
}

struct LiveFeedSource: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let sourceKind: LiveFeedSourceKind
    let title: String
    let locator: String
    let excerpt: String?
    let ragDocumentId: String?
    let workRecordId: String?

    var filePath: String? {
        guard sourceKind == .file else {
            return nil
        }
        let components = locator.split(separator: ":", omittingEmptySubsequences: false)
        guard components.count > 1, let suffix = components.last else {
            return locator
        }
        let lineRange = suffix.split(separator: "-", omittingEmptySubsequences: false)
        guard
            !lineRange.isEmpty,
            lineRange.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) })
        else {
            return locator
        }
        return components.dropLast().joined(separator: ":")
    }

    var webURL: URL? {
        guard
            sourceKind == .web,
            let components = URLComponents(string: locator),
            let scheme = components.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            components.user == nil,
            components.password == nil,
            let host = components.host,
            !host.isEmpty
        else {
            return nil
        }
        return components.url
    }
}

struct LiveFeedTurn: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let characterId: String
    let characterName: String
    let characterBackend: AgentBackend
    let backend: AgentBackend?
    let model: String?
    let effort: String?
    let fastMode: Bool?
    let externalSessionId: String?
    let conversationWorkdir: String?
    let prompt: String
    let response: String
    let status: LiveTurnStatus
    let needsInput: Bool
    let errorMessage: String?
    let responseSourceWarning: String?
    let startedAt: Date
    let endedAt: Date?
    let updatedAt: Date
    let estimatedCostUsd: Double?
    let sessionContext: SessionContextUsage?
    let activities: [LiveFeedActivity]
    let sources: [LiveFeedSource]?
    let workspace: TurnWorkspaceReview?

    var responseSources: [LiveFeedSource] {
        sources ?? []
    }

    func replacingID(with id: String) -> LiveFeedTurn {
        LiveFeedTurn(
            id: id,
            characterId: characterId,
            characterName: characterName,
            characterBackend: characterBackend,
            backend: backend,
            model: model,
            effort: effort,
            fastMode: fastMode,
            externalSessionId: externalSessionId,
            conversationWorkdir: conversationWorkdir,
            prompt: prompt,
            response: response,
            status: status,
            needsInput: needsInput,
            errorMessage: errorMessage,
            responseSourceWarning: responseSourceWarning,
            startedAt: startedAt,
            endedAt: endedAt,
            updatedAt: updatedAt,
            estimatedCostUsd: estimatedCostUsd,
            sessionContext: sessionContext,
            activities: activities,
            sources: sources,
            workspace: workspace
        )
    }
}

struct ArchiveFeedPage: Decodable, Sendable {
    let turns: [LiveFeedTurn]
    let total: Int
}

struct AutomationSettings: Codable, Equatable, Sendable {
    let autoApproveAndMerge: Bool
}

func agentExecutionModeTitle(_ fastMode: Bool?) -> String {
    fastMode == true ? "Fast" : "Standard"
}

private struct GlobalHistoryResponse: Decodable {
    let turns: [GlobalHistoryTurn]
}

private struct LiveFeedResponse: Decodable {
    let turns: [LiveFeedTurn]
}

private struct LiveFeedTurnResponse: Decodable {
    let turn: LiveFeedTurn
}

private struct WorkspaceReviewResponse: Decodable {
    let workspace: TurnWorkspaceReview
}

private struct WorkspaceReviewApprovalRequest: Encodable {
    let reviewTree: String
}

private struct StartAgentJobRequest: Encodable {
    let characterId: String
    let prompt: String
    let conversationId: UUID
    let attachmentPaths: [String]
}

struct StartedAgentJob: Decodable, Sendable {
    let turnId: String
    let conversationId: UUID
    let status: String
}

struct CancelledAgentJob: Decodable, Sendable {
    let turnId: String
    let status: String
}

private struct NameRequest: Encodable {
    let name: String
}

private struct AgentSettingsRequest: Encodable {
    let backend: AgentBackend
    let model: String?
    let effort: String
    let fastMode: Bool
    let permission: String
}

private struct IdentityPromptRequest: Encodable {
    let identityPrompt: String
}

enum OfficeDatabaseError: LocalizedError {
    case requestFailed
    case backend(String)

    var errorDescription: String? {
        switch self {
        case .requestFailed:
            "PostgreSQL 백엔드에 연결할 수 없습니다."
        case .backend(let message):
            message
        }
    }
}

private struct BackendErrorResponse: Decodable {
    let error: String
}
