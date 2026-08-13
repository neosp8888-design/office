// 이 파일은 오피스 화면에서 로컬 백엔드의 실행 상태를 확인하고 직접 제어한다.

import Darwin
import Foundation
import OfficeCore

enum OfficeBackendStatus: Equatable {
    case running
    case stopped
    case changing

    var isRunning: Bool {
        self == .running
    }

    var showsStoppedWarning: Bool {
        self == .stopped
    }

    var systemImage: String {
        switch self {
        case .running:
            "power"
        case .stopped:
            "power"
        case .changing:
            "arrow.triangle.2.circlepath"
        }
    }
}

struct OfficeBackendLaunchConfiguration: Equatable {
    static let jobLabel = "com.neo.office-backend-4317"

    let workdir: URL
    let backendDirectoryURL: URL
    let healthURL: URL
    let runtimeConfigurationURL: URL
    let releaseID: String
    let userID: uid_t

    var jobTarget: String {
        "gui/\(userID)/\(Self.jobLabel)"
    }
}

enum OfficeBackendRuntimeLocation {
    static func resolve(
        resourceURL: URL,
        workdir: URL,
        developmentRoot: URL? = nil,
        fileManager: FileManager = .default
    ) -> URL {
        let bundledBackend = resourceURL
            .appending(path: "OFFICESTRARuntime")
            .appending(path: "backend")
        let bundledServer = bundledBackend
            .appending(path: "src")
            .appending(path: "server.mjs")
        if fileManager.fileExists(atPath: bundledServer.path) {
            return bundledBackend
        }
        if let developmentRoot {
            let developmentBackend = developmentRoot.appending(path: "backend")
            let developmentServer = developmentBackend
                .appending(path: "src")
                .appending(path: "server.mjs")
            if fileManager.fileExists(atPath: developmentServer.path) {
                return developmentBackend
            }
        }
        return workdir.appending(path: "backend")
    }
}

struct OfficeBackendLaunchCommand: Equatable {
    let executableURL: URL
    let arguments: [String]
}

enum OfficeBackendLaunchCommands {
    static func stop(
        configuration: OfficeBackendLaunchConfiguration
    ) -> OfficeBackendLaunchCommand {
        OfficeBackendLaunchCommand(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["bootout", configuration.jobTarget]
        )
    }

    static func restart(
        configuration: OfficeBackendLaunchConfiguration
    ) -> OfficeBackendLaunchCommand {
        OfficeBackendLaunchCommand(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: ["kickstart", "-k", configuration.jobTarget]
        )
    }

    static func start(
        configuration: OfficeBackendLaunchConfiguration,
        nodeExecutableURL: URL,
        standardOutputURL: URL? = nil,
        standardErrorURL: URL? = nil,
        executableSearchPaths: [String] = []
    ) -> OfficeBackendLaunchCommand {
        let path = ([nodeExecutableURL.deletingLastPathComponent().path]
            + executableSearchPaths
            + [
                "/opt/homebrew/bin",
                "/usr/local/bin",
                "/usr/bin",
                "/bin",
                "/usr/sbin",
                "/sbin",
            ])
            .reduce(into: [String]()) { result, element in
                if !result.contains(element) {
                    result.append(element)
                }
            }
            .joined(separator: ":")
        let outputRedirect = standardOutputURL.map {
            " >> \(shellQuoted($0.path))"
        } ?? ""
        let errorRedirect = standardErrorURL.map {
            " 2>> \(shellQuoted($0.path))"
        } ?? ""
        let logDirectories = [standardOutputURL, standardErrorURL]
            .compactMap { $0?.deletingLastPathComponent().path }
            .reduce(into: [String]()) { result, element in
                if !result.contains(element) {
                    result.append(element)
                }
            }
        let quotedLogDirectories = logDirectories
            .map(shellQuoted)
            .joined(separator: " ")
        let prepareLogs = logDirectories.isEmpty
            ? ""
            : "mkdir -p \(quotedLogDirectories); "
        let command = "umask 077; \(prepareLogs)"
            + "export PATH=\(shellQuoted(path)); "
            + "export OFFICE_WORKDIR=\(shellQuoted(configuration.workdir.path)); "
            + "export OFFICESTRA_RELEASE_ID="
            + "\(shellQuoted(configuration.releaseID)); "
            + "export CHARACTER_CONFIG_PATH="
            + "\(shellQuoted(configuration.runtimeConfigurationURL.path)); "
            + "cd \(shellQuoted(configuration.backendDirectoryURL.path)); "
            + "exec \(shellQuoted(nodeExecutableURL.path)) src/server.mjs"
            + outputRedirect
            + errorRedirect
        return OfficeBackendLaunchCommand(
            executableURL: URL(fileURLWithPath: "/bin/launchctl"),
            arguments: [
                "submit",
                "-l",
                OfficeBackendLaunchConfiguration.jobLabel,
                "--",
                "/bin/zsh",
                "-lc",
                command,
            ]
        )
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\\''"))'"
    }
}

@MainActor
final class OfficeBackendController: ObservableObject {
    @Published private(set) var status: OfficeBackendStatus = .changing
    @Published private(set) var errorMessage: String?

    private var configuration: OfficeBackendLaunchConfiguration?
    private var monitorTask: Task<Void, Never>?

    deinit {
        monitorTask?.cancel()
    }

    func activate(workdir: String, healthURL: URL) {
        guard configuration == nil else {
            return
        }
        guard let resourceURL = Bundle.main.resourceURL else {
            errorMessage = "앱 리소스 경로를 찾을 수 없습니다."
            status = .stopped
            return
        }
        let workdirURL = URL(fileURLWithPath: workdir)
        let developmentRoot = Bundle.main.bundleURL.pathExtension == "app"
            ? nil
            : OfficeDevelopmentRuntimeLocator.locate()
        let layout = OfficeRuntimeLayout.resolve(
            resourceURL: resourceURL,
            developmentRoot: developmentRoot
        )
        configuration = OfficeBackendLaunchConfiguration(
            workdir: workdirURL,
            backendDirectoryURL: OfficeBackendRuntimeLocation.resolve(
                resourceURL: resourceURL,
                workdir: workdirURL,
                developmentRoot: developmentRoot
            ),
            healthURL: healthURL,
            runtimeConfigurationURL: layout.runtimeConfiguration,
            releaseID: OfficeAppReleaseIdentity.current(),
            userID: getuid()
        )
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func toggle() {
        guard let configuration, status != .changing else {
            return
        }
        let wasRunning = status.isRunning
        status = .changing
        errorMessage = nil

        Task {
            let failure = await Task.detached {
                Self.changeServerState(
                    wasRunning: wasRunning,
                    configuration: configuration
                )
            }.value
            if let failure {
                errorMessage = failure
            }
            try? await Task.sleep(for: .milliseconds(250))
            await refresh()
        }
    }

    func refresh() async {
        guard let configuration else {
            return
        }
        let isRunning = await Self.isHealthy(at: configuration.healthURL)
        guard status != .changing else {
            status = isRunning ? .running : .stopped
            return
        }
        status = isRunning ? .running : .stopped
    }

    private nonisolated static func changeServerState(
        wasRunning: Bool,
        configuration: OfficeBackendLaunchConfiguration
    ) -> String? {
        do {
            if wasRunning {
                try run(OfficeBackendLaunchCommands.stop(configuration: configuration))
            } else {
                do {
                    try run(
                        OfficeBackendLaunchCommands.restart(
                            configuration: configuration
                        )
                    )
                } catch {
                    try run(
                        OfficeBackendLaunchCommands.start(
                            configuration: configuration,
                            nodeExecutableURL: nodeExecutableURL(
                                configuration: configuration
                            ),
                            standardOutputURL: logURL(
                                named: "backend.out.log",
                                configuration: configuration
                            ),
                            standardErrorURL: logURL(
                                named: "backend.err.log",
                                configuration: configuration
                            ),
                            executableSearchPaths: cliSearchPaths()
                        )
                    )
                }
            }
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    private nonisolated static func isHealthy(at url: URL) async -> Bool {
        do {
            let (_, response) = try await URLSession.shared.data(from: url)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private nonisolated static func nodeExecutableURL(
        configuration: OfficeBackendLaunchConfiguration
    ) throws -> URL {
        let bundledNode = configuration.backendDirectoryURL
            .deletingLastPathComponent()
            .appending(path: "node/bin/node")
        let candidates = [
            bundledNode,
            URL(fileURLWithPath: "/opt/homebrew/bin/node"),
            URL(fileURLWithPath: "/usr/local/bin/node"),
        ]
        guard let executable = candidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            throw OfficeBackendControlError.nodeExecutableMissing
        }
        return executable
    }

    private nonisolated static func logURL(
        named name: String,
        configuration: OfficeBackendLaunchConfiguration
    ) -> URL {
        configuration.runtimeConfigurationURL
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appending(path: "logs")
            .appending(path: name)
    }

    private nonisolated static func cliSearchPaths() -> [String] {
        [AgentBackend.codex, .claude].compactMap {
            OfficeToolLocator.locate($0.rawValue)?
                .deletingLastPathComponent()
                .path
        }
    }

    private nonisolated static func run(
        _ command: OfficeBackendLaunchCommand
    ) throws {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = command.executableURL
        process.arguments = command.arguments
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let output = stderr.fileHandleForReading.readDataToEndOfFile()
            let message = String(decoding: output, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw OfficeBackendControlError.launchctlFailed(
                message.isEmpty ? "launchctl 실행에 실패했습니다." : message
            )
        }
    }
}

private enum OfficeBackendControlError: LocalizedError {
    case nodeExecutableMissing
    case launchctlFailed(String)

    var errorDescription: String? {
        switch self {
        case .nodeExecutableMissing:
            "Node 실행 파일을 찾을 수 없습니다."
        case let .launchctlFailed(message):
            message
        }
    }
}
