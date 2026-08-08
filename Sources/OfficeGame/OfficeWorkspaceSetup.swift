// 이 파일은 첫 실행에서 직원들이 작업할 프로젝트 폴더를 선택하고 기억한다.

import AppKit
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
    case ready(String)
    case failed(String)
}

@MainActor
final class OfficeLaunchCoordinator: ObservableObject {
    @Published private(set) var state: OfficeLaunchState
    @Published private(set) var validationError: String?
    private(set) var director: AgentDirector?

    private let userDefaults: UserDefaults
    private let fileManager: FileManager

    init(
        userDefaults: UserDefaults = .standard,
        fileManager: FileManager = .default
    ) {
        self.userDefaults = userDefaults
        self.fileManager = fileManager
        validationError = nil
        director = nil

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
                state = .ready(path)
                director = AgentDirector(workspaceDirectory: path)
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
        director = AgentDirector(workspaceDirectory: path)
        state = .ready(path)
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
                Text("OFFICESTRA 시작하기")
                    .font(.system(size: 28, weight: .bold))
                Text("업무 폴더 선택")
                    .font(.system(size: 18, weight: .semibold))
                Text(
                    "직원들이 작업할 프로젝트 폴더를 선택하세요. Git 프로젝트는 별도 worktree에서 검토하고 일반 폴더는 공유 방식으로 사용합니다."
                )
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 520)
            }

            if let validationError {
                Label(validationError, systemImage: "exclamationmark.triangle")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("officeWorkspaceValidationError")
            }

            Button(action: chooseWorkspace) {
                Label("프로젝트 폴더 선택", systemImage: "folder.badge.plus")
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .accessibilityIdentifier("officeWorkspaceChooseButton")

            Text("폴더 경로는 이 Mac에만 저장됩니다. Mac 전체나 홈 폴더는 선택할 수 없습니다.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

struct OfficeLaunchFailureView: View {
    let message: String

    var body: some View {
        ContentUnavailableView(
            "앱 설정을 읽지 못했습니다",
            systemImage: "exclamationmark.triangle",
            description: Text(message)
        )
    }
}
