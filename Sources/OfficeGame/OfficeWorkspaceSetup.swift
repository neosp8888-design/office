// 이 파일은 첫 실행에서 직원들이 작업할 프로젝트 폴더를 선택하고 기억한다.

import AppKit
import Darwin
import Foundation
import OfficeCore
import SwiftUI

enum OfficeWorkspaceResolution: Equatable {
    case ready(String)
    case needsSelection
}

enum OfficeWorkspacePreference {
    static let defaultsKey = "officeWorkspaceDirectory"

    static func resolve(
        persistedPath: String?,
        configuredPath: String,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) -> OfficeWorkspaceResolution {
        let storedPath = String(persistedPath ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !storedPath.isEmpty {
            guard let path = validWorkspacePath(
                storedPath,
                fileManager: fileManager,
                homeDirectory: homeDirectory
            ) else {
                return .needsSelection
            }
            return .ready(path)
        }
        if let path = validWorkspacePath(
            configuredPath,
            fileManager: fileManager,
            homeDirectory: homeDirectory
        ) {
            return .ready(path)
        }
        return .needsSelection
    }

    static func validWorkspacePath(
        _ path: String?,
        fileManager: FileManager = .default,
        homeDirectory: URL? = nil
    ) -> String? {
        let trimmed = String(path ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return nil
        }

        let url = URL(fileURLWithPath: trimmed)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let resolvedHome = (homeDirectory
            ?? fileManager.homeDirectoryForCurrentUser)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        var isDirectory: ObjCBool = false
        guard
            url.path != "/",
            url.path != resolvedHome.path,
            fileManager.fileExists(
                atPath: url.path,
                isDirectory: &isDirectory
            ),
            isDirectory.boolValue,
            fileManager.isReadableFile(atPath: url.path),
            fileManager.isWritableFile(atPath: url.path)
        else {
            return nil
        }
        return url.path
    }
}

enum OfficeLaunchState: Equatable {
    case needsWorkspace
    case preparing(String)
    case needsSetup(OfficeSetupSnapshot)
    case ready(String)
    case failed(String)
}

struct OfficeBackendCompatibilityNotice: Equatable {
    let message: String
    let replacement: OfficeBackendReplacement
    var isReplacing = false
    var errorMessage: String?
}

@MainActor
final class OfficeLaunchCoordinator: ObservableObject {
    @Published private(set) var state: OfficeLaunchState
    @Published private(set) var validationError: String?
    @Published private(set) var backendCompatibilityNotice:
        OfficeBackendCompatibilityNotice?
    private(set) var director: AgentDirector?

    private let userDefaults: UserDefaults
    private let fileManager: FileManager
    private var preparationTask: Task<Void, Never>?
    private var selectedWorkspace: String?

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        validationError = nil
        backendCompatibilityNotice = nil
        director = nil
        preparationTask = nil
        selectedWorkspace = nil

        do {
            let configuration = try CharacterConfigurationAsset.load()
            let resolution = OfficeWorkspacePreference.resolve(
                persistedPath: userDefaults.string(
                    forKey: OfficeWorkspacePreference.defaultsKey
                ),
                configuredPath: configuration.workdir,
                fileManager: fileManager
            )
            switch resolution {
            case .needsSelection:
                state = .needsWorkspace
            case .ready(let path):
                state = .preparing("로컬 실행 환경을 확인하는 중")
                selectedWorkspace = path
                beginPreparation(for: path)
            }
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func chooseWorkspace() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = false
        panel.allowsMultipleSelection = false
        panel.prompt = OfficeLocalization.string("선택")
        panel.message = OfficeLocalization.string(
            "직원들이 작업할 프로젝트 폴더를 선택하세요."
        )

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }
        selectWorkspace(url)
    }

    func selectWorkspace(_ url: URL) {
        guard let path = OfficeWorkspacePreference.validWorkspacePath(
            url.path,
            fileManager: fileManager
        ) else {
            validationError = OfficeLocalization.string(
                "읽고 쓸 수 있는 프로젝트 폴더를 선택하세요."
            )
            return
        }

        userDefaults.set(
            path,
            forKey: OfficeWorkspacePreference.defaultsKey
        )
        validationError = nil
        selectedWorkspace = path
        beginPreparation(for: path)
    }

    func retrySetup() {
        guard let selectedWorkspace else {
            state = .needsWorkspace
            return
        }
        beginPreparation(for: selectedWorkspace)
    }

    func useCurrentDatabase() {
        selectDockerProject(.current)
    }

    func useConfirmedLegacyDatabase() {
        selectDockerProject(.legacy)
    }

    func remapExistingCharacters() {
        guard case .needsSetup(var snapshot) = state,
              let backend = snapshot.providerRemapTarget
        else {
            return
        }
        snapshot.backend = .checking(
            OfficeLocalization.format(
                "기존 직원 설정을 %@로 전환하는 중",
                backend.title
            )
        )
        state = .needsSetup(snapshot)

        Task { [weak self] in
            do {
                let healthURL = try CharacterConfigurationAsset.load()
                    .databaseBaseURL
                    .appending(path: "health")
                try await OfficeSetupAssistant.remapExistingCharacters(
                    healthURL: healthURL,
                    to: backend
                )
                guard let self else {
                    return
                }
                self.retrySetup()
            } catch {
                guard let self else {
                    return
                }
                snapshot.backend = .failed(
                    OfficeLocalization.format(
                        "직원 설정 전환에 실패했습니다: %@",
                        error.localizedDescription
                    )
                )
                self.state = .needsSetup(snapshot)
            }
        }
    }

    func replaceIdleBackend() {
        if case .ready = state,
           var notice = backendCompatibilityNotice,
           !notice.isReplacing
        {
            notice.isReplacing = true
            notice.errorMessage = nil
            backendCompatibilityNotice = notice

            Task { [weak self] in
                do {
                    let healthURL = try CharacterConfigurationAsset.load()
                        .databaseBaseURL
                        .appending(path: "health")
                    try await OfficeBackendReplacementSafety
                        .replaceIdleBackend(healthURL: healthURL)
                    guard let self else {
                        return
                    }
                    self.retrySetup()
                } catch {
                    guard let self,
                          var currentNotice = self.backendCompatibilityNotice
                    else {
                        return
                    }
                    currentNotice.isReplacing = false
                    currentNotice.errorMessage = error.localizedDescription
                    self.backendCompatibilityNotice = currentNotice
                }
            }
            return
        }

        guard case .needsSetup(var snapshot) = state,
              snapshot.backendReplacement != nil
        else {
            return
        }
        snapshot.backend = .checking(
            OfficeLocalization.string(
                "실행 중 업무와 백엔드 소유권을 확인하는 중"
            )
        )
        state = .needsSetup(snapshot)

        Task { [weak self] in
            do {
                let healthURL = try CharacterConfigurationAsset.load()
                    .databaseBaseURL
                    .appending(path: "health")
                try await OfficeBackendReplacementSafety.replaceIdleBackend(
                    healthURL: healthURL
                )
                guard let self else {
                    return
                }
                self.retrySetup()
            } catch {
                guard let self else {
                    return
                }
                snapshot.backend = .failed(error.localizedDescription)
                self.state = .needsSetup(snapshot)
            }
        }
    }

    func openDocker() {
        let dockerApp = URL(fileURLWithPath: "/Applications/Docker.app")
        if fileManager.fileExists(atPath: dockerApp.path) {
            NSWorkspace.shared.openApplication(
                at: dockerApp,
                configuration: NSWorkspace.OpenConfiguration(),
                completionHandler: { _, _ in }
            )
            return
        }
        openWebPage("https://www.docker.com/products/docker-desktop/")
    }

    func openProviderSetup(_ backend: AgentBackend) {
        guard let executable = OfficeToolLocator.locate(backend.executableName) else {
            switch backend {
            case .codex:
                openWebPage(
                    "https://help.openai.com/en/articles/11096431-openai-codex-cli-getting-started"
                )
            case .claude:
                openWebPage(
                    "https://docs.anthropic.com/en/docs/claude-code/getting-started"
                )
            case .antigravity:
                openWebPage("https://antigravity.google/")
            }
            return
        }
        do {
            let support = fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
                .appending(path: "OFFICESTRA/login")
            try fileManager.createDirectory(
                at: support,
                withIntermediateDirectories: true
            )
            try fileManager.setAttributes(
                [.posixPermissions: 0o700],
                ofItemAtPath: support.path
            )
            let script = support.appending(
                path: "login-\(backend.rawValue).command"
            )
            let arguments: String
            switch backend {
            case .codex:
                arguments = "login"
            case .claude:
                arguments = "auth login"
            case .antigravity:
                arguments = ""
            }
            let source = """
            #!/bin/zsh
            clear
            echo '\(backend.title) 로그인을 시작합니다.'
            \(shellQuoted(executable.path)) \(arguments)
            echo
            echo '로그인이 끝났습니다. 이 창을 닫고 OFFICESTRA에서 다시 확인을 누르세요.'
            """
            try Data(source.utf8).write(to: script, options: .atomic)
            guard chmod(script.path, 0o700) == 0 else {
                throw CocoaError(.fileWriteNoPermission)
            }
            NSWorkspace.shared.open(script)
        } catch {
            validationError = error.localizedDescription
        }
    }

    func openSetupLogs() {
        guard let resourceURL = Bundle.main.resourceURL else {
            return
        }
        let layout = OfficeRuntimeLayout.resolve(resourceURL: resourceURL)
        let logDirectory = layout.standardOutputLog
            .deletingLastPathComponent()
        try? fileManager.createDirectory(
            at: logDirectory,
            withIntermediateDirectories: true
        )
        try? fileManager.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: logDirectory.path
        )
        NSWorkspace.shared.activateFileViewerSelecting([
            logDirectory,
        ])
    }

    private func beginPreparation(for path: String) {
        preparationTask?.cancel()
        backendCompatibilityNotice = nil
        director = nil
        state = .preparing("로컬 실행 환경을 확인하는 중")
        guard let resourceURL = Bundle.main.resourceURL else {
            state = .failed("앱 리소스 경로를 찾을 수 없습니다.")
            return
        }
        let healthURL: URL
        do {
            healthURL = try CharacterConfigurationAsset.load()
                .databaseBaseURL
                .appending(path: "health")
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        let setupFileManager = fileManager
        let dockerProjectPreference = OfficeDockerProjectPreference.load(
            from: userDefaults
        )

        preparationTask = Task { [weak self] in
            let developmentRoot = Bundle.main.bundleURL.pathExtension == "app"
                ? nil
                : OfficeDevelopmentRuntimeLocator.locate(
                    fileManager: setupFileManager
                )
            let result = await OfficeSetupAssistant.prepare(
                workdir: path,
                healthURL: healthURL,
                resourceURL: resourceURL,
                developmentRoot: developmentRoot,
                dockerProjectPreference: dockerProjectPreference,
                progress: { stage in
                    await MainActor.run {
                        guard let self,
                              self.selectedWorkspace == path
                        else {
                            return
                        }
                        self.state = .preparing(stage)
                    }
                }
            )
            guard !Task.isCancelled,
                  let self,
                  self.selectedWorkspace == path
            else {
                return
            }
            switch result {
            case let .ready(
                snapshot,
                availableBackends,
                executablePaths
            ):
                self.backendCompatibilityNotice = Self.compatibilityNotice(
                    from: snapshot
                )
                self.director = AgentDirector(
                    workspaceDirectory: path,
                    availableBackends: availableBackends,
                    executablePaths: executablePaths
                )
                self.state = .ready(path)
            case .needsAction(let snapshot):
                self.state = .needsSetup(snapshot)
            case .failed(_, let message):
                self.state = .failed(message)
            }
        }
    }

    static func compatibilityNotice(
        from snapshot: OfficeSetupSnapshot
    ) -> OfficeBackendCompatibilityNotice? {
        guard let replacement = snapshot.backendReplacement,
              case .differentRelease = replacement,
              case .ready(let message) = snapshot.backend
        else {
            return nil
        }
        return OfficeBackendCompatibilityNotice(
            message: message,
            replacement: replacement
        )
    }

    private func openWebPage(_ value: String) {
        guard let url = URL(string: value) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func selectDockerProject(
        _ preference: OfficeDockerProjectPreference
    ) {
        preference.save(to: userDefaults)
        retrySetup()
    }

    private func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

struct OfficeWorkspaceSetupView: View {
    let validationError: String?
    let chooseWorkspace: () -> Void

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "building.2.crop.circle")
                .font(.system(size: 58, weight: .medium))
                .foregroundStyle(.tint)
                .accessibilityHidden(true)

            VStack(spacing: 8) {
                Text(OfficeLocalization.string("OFFICESTRA 시작하기"))
                    .font(.system(size: 28, weight: .bold))
                Text(OfficeLocalization.string("업무 폴더 선택"))
                    .font(.system(size: 18, weight: .semibold))
                Text(
                    OfficeLocalization.string(
                        "직원들이 함께 작업할 프로젝트 폴더를 선택하세요. 모든 직원은 이 폴더의 현재 파일을 함께 사용합니다."
                    )
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            }

            if let validationError {
                Label(
                    OfficeLocalization.string(validationError),
                    systemImage: "exclamationmark.triangle"
                )
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("officeWorkspaceValidationError")
            }

            Button(action: chooseWorkspace) {
                Label(
                    OfficeLocalization.string("프로젝트 폴더 선택"),
                    systemImage: "folder.badge.plus"
                )
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("officeWorkspaceChooseButton")

            Text(
                OfficeLocalization.string(
                    "폴더 경로는 이 Mac에만 저장됩니다. Mac 전체나 홈 폴더는 선택할 수 없습니다."
                )
            )
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct OfficeSetupPreparingView: View {
    let stage: String

    var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text(OfficeLocalization.string("OFFICESTRA 준비 중"))
                .font(.system(size: 26, weight: .bold))
            Text(OfficeLocalization.string(stage))
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("officeSetupStage")
            Text(
                OfficeLocalization.string(
                    "기존 프로젝트와 대화 데이터는 삭제하지 않습니다."
                )
            )
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct OfficeEnvironmentSetupView: View {
    let snapshot: OfficeSetupSnapshot
    let retry: () -> Void
    let chooseWorkspace: () -> Void
    let useCurrentDatabase: () -> Void
    let useLegacyDatabase: () -> Void
    let remapExistingCharacters: () -> Void
    let replaceIdleBackend: () -> Void
    let openDocker: () -> Void
    let setupCodex: () -> Void
    let setupClaude: () -> Void
    let setupAntigravity: () -> Void
    let openLogs: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 7) {
                Image(systemName: "checklist")
                    .font(.system(size: 50, weight: .medium))
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text(OfficeLocalization.string("OFFICESTRA 시작 준비"))
                    .font(.system(size: 27, weight: .bold))
                Text(
                    OfficeLocalization.string(
                        "필요한 항목만 준비하면 다음 확인부터 자동으로 이어집니다."
                    )
                )
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                OfficeSetupStatusRow(
                    title: "프로젝트 폴더",
                    state: .ready(snapshot.workspace)
                )
                OfficeSetupStatusRow(
                    title: "앱 런타임",
                    state: snapshot.runtime
                )
                OfficeSetupStatusRow(
                    title: "Docker Desktop",
                    state: snapshot.docker
                )
                OfficeSetupStatusRow(
                    title: "로컬 데이터",
                    state: snapshot.database
                )
                OfficeSetupStatusRow(
                    title: "백엔드",
                    state: snapshot.backend
                )
                OfficeSetupStatusRow(title: "Codex", state: snapshot.codex)
                OfficeSetupStatusRow(
                    title: "Claude Code",
                    state: snapshot.claude
                )
                OfficeSetupStatusRow(
                    title: "Antigravity",
                    state: snapshot.antigravity
                )
            }
            .frame(maxWidth: 620)

            HStack(spacing: 10) {
                Button(
                    OfficeLocalization.string("프로젝트 폴더 변경"),
                    action: chooseWorkspace
                )
                    .accessibilityIdentifier(
                        "officeSetupChangeWorkspaceButton"
                    )
                if !snapshot.docker.isReady {
                    Button(
                        OfficeLocalization.string("Docker 준비"),
                        action: openDocker
                    )
                        .accessibilityIdentifier("officeSetupDockerButton")
                }
                if !snapshot.codex.isReady {
                    Button(
                        OfficeLocalization.string("Codex 준비"),
                        action: setupCodex
                    )
                        .accessibilityIdentifier("officeSetupCodexButton")
                }
                if !snapshot.claude.isReady {
                    Button(
                        OfficeLocalization.string("Claude Code 준비"),
                        action: setupClaude
                    )
                        .accessibilityIdentifier("officeSetupClaudeButton")
                }
                if !snapshot.antigravity.isReady {
                    Button(
                        OfficeLocalization.string("Antigravity 준비"),
                        action: setupAntigravity
                    )
                        .accessibilityIdentifier(
                            "officeSetupAntigravityButton"
                        )
                }
                Button(OfficeLocalization.string("로그 열기"), action: openLogs)
                if snapshot.dockerDataSelection == .currentAndLegacy {
                    Button(
                        OfficeLocalization.string("현재 OFFICESTRA 데이터 사용"),
                        action: useCurrentDatabase
                    )
                    .accessibilityIdentifier(
                        "officeSetupUseCurrentDatabaseButton"
                    )
                }
                if snapshot.dockerDataSelection != nil {
                    Button(
                        OfficeLocalization.string("기존 OFFICESTRA 데이터 사용"),
                        action: useLegacyDatabase
                    )
                    .accessibilityIdentifier(
                        "officeSetupUseLegacyDatabaseButton"
                    )
                }
                if let backend = snapshot.providerRemapTarget {
                    Button(
                        OfficeLocalization.format(
                            "모든 직원을 %@로 전환",
                            backend.title
                        ),
                        action: remapExistingCharacters
                    )
                    .accessibilityIdentifier(
                        "officeSetupRemapCharactersButton"
                    )
                }
                if let replacement = snapshot.backendReplacement {
                    Button(
                        replacement.actionTitle,
                        action: replaceIdleBackend
                    )
                    .accessibilityIdentifier(
                        "officeSetupReplaceBackendButton"
                    )
                }
                Button(OfficeLocalization.string("다시 확인"), action: retry)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .accessibilityIdentifier("officeSetupRetryButton")
            }

            Text(
                OfficeLocalization.string(
                    "Antigravity, Claude Code 또는 Codex 중 하나만 로그인돼도 시작할 수 있습니다."
                )
            )
                .font(.footnote)
                .foregroundStyle(.tertiary)
            if snapshot.dockerDataSelection == .currentAndLegacy {
                Text(
                    OfficeLocalization.string(
                        "두 볼륨 중 선택한 데이터만 연결하며 다른 볼륨은 그대로 보존됩니다."
                    )
                )
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if snapshot.providerRemapTarget != nil {
                Text(
                    OfficeLocalization.string(
                        "직원 전환은 진행 중 업무가 없을 때만 가능하며, 기존 대화 기록은 보존됩니다."
                    )
                )
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
            if snapshot.backendReplacement != nil {
                Text(
                    OfficeLocalization.string(
                        "백엔드 전환은 실행 중 업무가 0건이고 4317 리스너가 OFFICESTRA launchd 작업과 일치할 때만 수행됩니다."
                    )
                )
                    .font(.footnote)
                    .foregroundStyle(.orange)
            }
        }
        .padding(42)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct OfficeSetupStatusRow: View {
    let title: String
    let state: OfficeSetupCheck

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .foregroundStyle(color)
                .frame(width: 22)
            Text(OfficeLocalization.string(title))
                .fontWeight(.semibold)
                .frame(width: 130, alignment: .leading)
            Text(detail)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .combine)
    }

    private var detail: String {
        switch state {
        case .pending:
            OfficeLocalization.string("확인 대기")
        case .checking(let value),
             .ready(let value),
             .actionRequired(let value),
             .failed(let value):
            OfficeLocalization.string(value)
        }
    }

    private var symbol: String {
        switch state {
        case .pending:
            "circle"
        case .checking:
            "arrow.triangle.2.circlepath"
        case .ready:
            "checkmark.circle.fill"
        case .actionRequired:
            "exclamationmark.circle.fill"
        case .failed:
            "xmark.octagon.fill"
        }
    }

    private var color: Color {
        switch state {
        case .ready:
            .green
        case .actionRequired:
            .orange
        case .failed:
            .red
        case .pending, .checking:
            .secondary
        }
    }
}

struct OfficeLaunchFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView(
            OfficeLocalization.string("앱 설정을 읽지 못했습니다"),
            systemImage: "exclamationmark.triangle",
            description: Text(OfficeLocalization.string(message))
        )
    }
}
