// 이 파일은 오피스 화면에서 로컬 백엔드의 실행 상태를 확인하고 직접 제어한다.

import Darwin
import Foundation

enum OfficeBackendStatus: Equatable {
    case running
    case stopped
    case changing

    var isRunning: Bool {
        self == .running
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
    let healthURL: URL
    let runtimeConfigurationURL: URL
    let userID: uid_t

    var jobTarget: String {
        "gui/\(userID)/\(Self.jobLabel)"
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
        nodeExecutableURL: URL
    ) -> OfficeBackendLaunchCommand {
        let command = """
        export CHARACTER_CONFIG_PATH=\(shellQuoted(configuration.runtimeConfigurationURL.path)); \
        cd \(shellQuoted(configuration.workdir.appending(path: "backend").path)); \
        exec \(shellQuoted(nodeExecutableURL.path)) src/server.mjs
        """
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
        "'\(value.replacingOccurrences(of: "'", with: "'\\\\''"))'"
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
        configuration = OfficeBackendLaunchConfiguration(
            workdir: URL(fileURLWithPath: workdir),
            healthURL: healthURL,
            runtimeConfigurationURL: resourceURL
                .appending(path: "OfficeLLM_OfficeCore.bundle")
                .appending(path: "characters.json"),
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
                            nodeExecutableURL: nodeExecutableURL()
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

    private nonisolated static func nodeExecutableURL() throws -> URL {
        let candidates = [
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
