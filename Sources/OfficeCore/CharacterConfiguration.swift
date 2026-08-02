// 이 파일은 설정 파일에서 캐릭터 이름과 CLI 실행 옵션을 읽는 모델을 제공한다.

import Foundation

public enum AgentBackend:
    String,
    CaseIterable,
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    case codex
    case claude

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .codex:
            "Codex"
        case .claude:
            "Claude Code"
        }
    }

    public var effortOptions: [String] {
        switch self {
        case .codex:
            ["high", "xhigh", "max", "ultra"]
        case .claude:
            ["high", "xhigh", "max"]
        }
    }

    public var modelOptions: [String] {
        switch self {
        case .codex:
            ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
        case .claude:
            [
                "claude-opus-5",
                "fable",
                "claude-sonnet-5",
            ]
        }
    }

    public var defaultModel: String {
        modelOptions[0]
    }

    public func supportsFastMode(model: String?) -> Bool {
        switch self {
        case .codex:
            true
        case .claude:
            model == "claude-opus-5"
        }
    }

    public func modelTitle(_ model: String) -> String {
        switch model {
        case "gpt-5.6-sol":
            "5.6 Sol"
        case "gpt-5.6-terra":
            "5.6 Terra"
        case "gpt-5.6-luna":
            "5.6 Luna"
        case "claude-opus-5":
            "Opus 5"
        case "fable":
            "Fable"
        case "claude-sonnet-5":
            "Sonnet 5"
        default:
            model
        }
    }
}

/// Codex와 Claude의 권한 값이 이름도 단계 수도 달라서 앱 공통 3단계로 다룬다.
public enum AgentPermission:
    String,
    CaseIterable,
    Codable,
    Identifiable,
    Hashable,
    Sendable
{
    case readOnly
    case workspaceWrite
    case fullAccess

    public var id: String {
        rawValue
    }

    public var title: String {
        switch self {
        case .readOnly:
            "읽기 전용"
        case .workspaceWrite:
            "작업 폴더 쓰기"
        case .fullAccess:
            "전체 허용"
        }
    }

    public func cliValue(for backend: AgentBackend) -> String {
        switch (self, backend) {
        case (.readOnly, .codex):
            "read-only"
        case (.readOnly, .claude):
            "plan"
        case (.workspaceWrite, .codex):
            "workspace-write"
        case (.workspaceWrite, .claude):
            "auto"
        case (.fullAccess, .codex):
            "danger-full-access"
        case (.fullAccess, .claude):
            "bypassPermissions"
        }
    }

    public init(cliValue: String) {
        switch cliValue {
        case "read-only", "plan":
            self = .readOnly
        case "danger-full-access", "bypassPermissions":
            self = .fullAccess
        case "workspace-write", "auto", "acceptEdits":
            self = .workspaceWrite
        default:
            self = .workspaceWrite
        }
    }
}

public struct CharacterAgentSettings: Equatable, Sendable {
    public var backend: AgentBackend
    public var model: String?
    public var effort: String
    public var fastMode: Bool
    public var permission: AgentPermission

    public init(
        backend: AgentBackend,
        model: String?,
        effort: String,
        fastMode: Bool,
        permission: AgentPermission
    ) {
        self.backend = backend
        self.model = model
        self.effort = effort
        self.fastMode = fastMode
        self.permission = permission
    }

    public mutating func selectModel(_ model: String) {
        self.model = model
        if !backend.supportsFastMode(model: model) {
            fastMode = false
        }
    }

    public mutating func setFastMode(_ isEnabled: Bool) {
        fastMode = isEnabled
        if isEnabled && !backend.supportsFastMode(model: model) {
            model = backend.defaultModel
        }
    }
}

public struct CharacterHitbox: Codable, Hashable, Sendable {
    public let x: CGFloat
    public let y: CGFloat
    public let width: CGFloat
    public let height: CGFloat

    public var rect: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

public struct CharacterBubbleAnchor: Codable, Hashable, Sendable {
    public let x: CGFloat
    public let y: CGFloat

    public var point: CGPoint {
        CGPoint(x: x, y: y)
    }
}

public struct CharacterConfiguration: Codable, Identifiable, Hashable, Sendable {
    public let id: OfficeCharacter
    public let name: String
    public let seat: String
    public let backend: AgentBackend
    public let identityPrompt: String
    public let model: String?
    public let effort: String
    public let fastMode: Bool
    public let permission: String
    public let executablePath: String?
    public let hitbox: CharacterHitbox
    public let monitorHitbox: CharacterHitbox
    public let bubble: CharacterBubbleAnchor

    public init(
        id: OfficeCharacter,
        name: String,
        seat: String,
        backend: AgentBackend,
        identityPrompt: String,
        model: String?,
        effort: String,
        fastMode: Bool,
        permission: String,
        executablePath: String?,
        hitbox: CharacterHitbox,
        monitorHitbox: CharacterHitbox,
        bubble: CharacterBubbleAnchor
    ) {
        self.id = id
        self.name = name
        self.seat = seat
        self.backend = backend
        self.identityPrompt = identityPrompt
        self.model = model
        self.effort = effort
        self.fastMode = fastMode
        self.permission = permission
        self.executablePath = executablePath
        self.hitbox = hitbox
        self.monitorHitbox = monitorHitbox
        self.bubble = bubble
    }

    public var agentSettings: CharacterAgentSettings {
        CharacterAgentSettings(
            backend: backend,
            model: model,
            effort: effort,
            fastMode: fastMode,
            permission: AgentPermission(cliValue: permission)
        )
    }

    public func applying(
        _ settings: CharacterAgentSettings
    ) -> CharacterConfiguration {
        CharacterConfiguration(
            id: id,
            name: name,
            seat: seat,
            backend: settings.backend,
            identityPrompt: identityPrompt,
            model: settings.model,
            effort: settings.effort,
            fastMode: settings.fastMode,
            permission: settings.permission.cliValue(for: settings.backend),
            executablePath: executablePath,
            hitbox: hitbox,
            monitorHitbox: monitorHitbox,
            bubble: bubble
        )
    }

    public func applying(
        identityPrompt: String
    ) -> CharacterConfiguration {
        CharacterConfiguration(
            id: id,
            name: name,
            seat: seat,
            backend: backend,
            identityPrompt: identityPrompt,
            model: model,
            effort: effort,
            fastMode: fastMode,
            permission: permission,
            executablePath: executablePath,
            hitbox: hitbox,
            monitorHitbox: monitorHitbox,
            bubble: bubble
        )
    }
}

public struct OfficeAgentConfiguration: Codable, Sendable {
    public let workdir: String
    public let databaseBaseURL: URL
    public let archiveCabinetHitbox: CharacterHitbox
    public let characters: [CharacterConfiguration]
}

public enum CharacterConfigurationAsset {
    public static func load() throws -> OfficeAgentConfiguration {
        guard let url = OfficeCoreResourceBundle.bundle.url(
            forResource: "characters",
            withExtension: "json"
        ) else {
            throw CharacterConfigurationError.resourceMissing
        }

        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(
            OfficeAgentConfiguration.self,
            from: data
        )
    }
}

public enum CharacterConfigurationError: LocalizedError {
    case resourceMissing

    public var errorDescription: String? {
        "characters.json 설정 파일을 찾을 수 없습니다."
    }
}
