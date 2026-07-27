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

    private func historyDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let value = try container.decode(String.self)

            let fractional = ISO8601DateFormatter()
            fractional.formatOptions = [
                .withInternetDateTime,
                .withFractionalSeconds,
            ]
            if let date = fractional.date(from: value) {
                return date
            }

            let standard = ISO8601DateFormatter()
            standard.formatOptions = [.withInternetDateTime]
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
    let executionBackend: AgentBackend?
    let executionModel: String?
    let executionEffort: String?
    let startedAt: Date
    let endedAt: Date?
}

struct GlobalHistoryTurn: Decodable, Identifiable, Sendable {
    let id: String
    let characterId: String
    let characterName: String
    let backend: AgentBackend
    let executionBackend: AgentBackend?
    let executionModel: String?
    let executionEffort: String?
    let externalSessionId: String?
    let prompt: String
    let response: String
    let startedAt: Date
    let endedAt: Date?
}

private struct GlobalHistoryResponse: Decodable {
    let turns: [GlobalHistoryTurn]
}

private struct NameRequest: Encodable {
    let name: String
}

private struct AgentSettingsRequest: Encodable {
    let backend: AgentBackend
    let model: String?
    let effort: String
    let permission: String
}

private struct IdentityPromptRequest: Encodable {
    let identityPrompt: String
}

enum OfficeDatabaseError: LocalizedError {
    case requestFailed

    var errorDescription: String? {
        "PostgreSQL 백엔드에 연결할 수 없습니다."
    }
}
