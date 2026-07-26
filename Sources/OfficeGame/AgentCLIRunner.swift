// 이 파일은 Codex와 Claude Code CLI를 실행하고 JSONL 응답을 공통 형식으로 변환한다.

import Foundation
import OfficeCore

struct AgentCLIResponse: Sendable {
    let text: String
    let sessionID: String?
}

actor AgentCLIRunner {
    func run(
        prompt: String,
        character: CharacterConfiguration,
        workdir: String,
        previousSessionID: String?
    ) async throws -> AgentCLIResponse {
        let executable = try ExecutableLocator.locate(
            backend: character.backend,
            configuredPath: character.executablePath
        )
        let arguments = arguments(
            prompt: prompt,
            character: character,
            previousSessionID: previousSessionID
        )
        let result = try await launch(
            executable: executable,
            arguments: arguments,
            workdir: workdir
        )

        guard result.status == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw AgentCLIError.failed(
                stderr.isEmpty
                    ? "CLI가 종료 코드 \(result.status)로 끝났습니다."
                    : stderr
            )
        }

        let output = String(decoding: result.stdout, as: UTF8.self)
        switch character.backend {
        case .codex:
            return try parseCodex(output)
        case .claude:
            return try parseClaude(output)
        }
    }

    private func arguments(
        prompt: String,
        character: CharacterConfiguration,
        previousSessionID: String?
    ) -> [String] {
        switch character.backend {
        case .codex:
            return codexArguments(
                prompt: prompt,
                character: character,
                previousSessionID: previousSessionID
            )
        case .claude:
            return claudeArguments(
                prompt: prompt,
                character: character,
                previousSessionID: previousSessionID
            )
        }
    }

    private func codexArguments(
        prompt: String,
        character: CharacterConfiguration,
        previousSessionID: String?
    ) -> [String] {
        var arguments = ["exec"]
        var effectivePrompt = prompt

        if let previousSessionID {
            arguments += ["resume", previousSessionID, "--json"]
        } else {
            arguments += ["--json", "--skip-git-repo-check"]
            effectivePrompt = """
            너는 이 사무실의 \(character.name)이다. \(character.seat)에 앉아 있다.
            \(character.identityPrompt)

            사용자 업무
            \(prompt)
            """
        }

        if let model = character.model, !model.isEmpty {
            arguments += ["-c", "model=\"\(model)\""]
        }
        arguments += [
            "-c",
            "model_reasoning_effort=\"\(character.effort)\"",
        ]
        if previousSessionID == nil {
            arguments += ["-s", character.permission]
        }
        arguments.append(effectivePrompt)
        return arguments
    }

    private func claudeArguments(
        prompt: String,
        character: CharacterConfiguration,
        previousSessionID: String?
    ) -> [String] {
        var arguments = [
            "-p",
            prompt,
            "--output-format",
            "stream-json",
            "--verbose",
            "--effort",
            character.effort,
            "--permission-mode",
            character.permission,
        ]
        if let model = character.model, !model.isEmpty {
            arguments += ["--model", model]
        }
        if let previousSessionID {
            arguments += ["--resume", previousSessionID]
        } else {
            let identity = """
            너는 이 사무실의 \(character.name)이다. \(character.seat)에 앉아 있다.
            \(character.identityPrompt)
            """
            arguments += ["--append-system-prompt", identity]
        }
        return arguments
    }

    private func launch(
        executable: URL,
        arguments: [String],
        workdir: String
    ) async throws -> ProcessResult {
        let workingDirectory = URL(fileURLWithPath: workdir)
        guard FileManager.default.fileExists(atPath: workingDirectory.path)
        else {
            throw AgentCLIError.invalidWorkdir(workdir)
        }

        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.currentDirectoryURL = workingDirectory
        process.standardOutput = stdout
        process.standardError = stderr
        process.standardInput = FileHandle.nullDevice

        let outputTask = Task.detached {
            stdout.fileHandleForReading.readDataToEndOfFile()
        }
        let errorTask = Task.detached {
            stderr.fileHandleForReading.readDataToEndOfFile()
        }

        let status = try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Int32, Error>) in
            process.terminationHandler = {
                continuation.resume(returning: $0.terminationStatus)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }

        return await ProcessResult(
            stdout: outputTask.value,
            stderr: errorTask.value,
            status: status
        )
    }

    private func parseCodex(_ output: String) throws -> AgentCLIResponse {
        var sessionID: String?
        var messages: [String] = []

        for object in jsonObjects(from: output) {
            let type = object["type"] as? String
            if type == "thread.started" {
                sessionID = object["thread_id"] as? String
            } else if
                type == "item.completed",
                let item = object["item"] as? [String: Any],
                item["type"] as? String == "agent_message",
                let text = item["text"] as? String,
                !text.isEmpty
            {
                messages.append(text)
            } else if type == "turn.failed" {
                throw AgentCLIError.failed(
                    object["error"] as? String ?? "Codex 작업이 실패했습니다."
                )
            }
        }

        guard let text = messages.last else {
            throw AgentCLIError.invalidOutput("Codex 최종 메시지가 없습니다.")
        }
        return AgentCLIResponse(text: text, sessionID: sessionID)
    }

    private func parseClaude(_ output: String) throws -> AgentCLIResponse {
        var sessionID: String?
        var messages: [String] = []
        var resultText: String?

        for object in jsonObjects(from: output) {
            let type = object["type"] as? String
            if type == "system", object["subtype"] as? String == "init" {
                sessionID = object["session_id"] as? String
            } else if
                type == "assistant",
                let message = object["message"] as? [String: Any],
                let content = message["content"] as? [[String: Any]]
            {
                let text = content.compactMap { item -> String? in
                    guard item["type"] as? String == "text" else {
                        return nil
                    }
                    return item["text"] as? String
                }
                .joined()
                if !text.isEmpty {
                    messages.append(text)
                }
            } else if type == "result" {
                if object["is_error"] as? Bool == true {
                    throw AgentCLIError.failed(
                        object["result"] as? String
                            ?? "Claude Code 작업이 실패했습니다."
                    )
                }
                resultText = object["result"] as? String
                sessionID = sessionID ?? object["session_id"] as? String
            }
        }

        guard let text = messages.last ?? resultText, !text.isEmpty else {
            throw AgentCLIError.invalidOutput(
                "Claude Code 최종 메시지가 없습니다."
            )
        }
        return AgentCLIResponse(text: text, sessionID: sessionID)
    }

    private func jsonObjects(from output: String) -> [[String: Any]] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            guard
                let data = String(line).data(using: .utf8),
                let object = try? JSONSerialization.jsonObject(with: data)
                    as? [String: Any]
            else {
                return nil
            }
            return object
        }
    }
}

private struct ProcessResult: Sendable {
    let stdout: Data
    let stderr: Data
    let status: Int32
}

private enum ExecutableLocator {
    static func locate(
        backend: AgentBackend,
        configuredPath: String?
    ) throws -> URL {
        let name = backend.rawValue
        let fileManager = FileManager.default

        if
            let configuredPath,
            fileManager.isExecutableFile(atPath: configuredPath)
        {
            return URL(fileURLWithPath: configuredPath)
        }

        let home = fileManager.homeDirectoryForCurrentUser.path
        var candidates = [
            "\(home)/.local/bin/\(name)",
            "/opt/homebrew/bin/\(name)",
            "/usr/local/bin/\(name)",
        ]
        if backend == .claude {
            let versions = "\(home)/.nvm/versions/node"
            let versionNames =
                (try? fileManager.contentsOfDirectory(atPath: versions)) ?? []
            candidates.insert(
                contentsOf: versionNames.sorted().reversed().map {
                    "\(versions)/\($0)/bin/claude"
                },
                at: 0
            )
        }

        if let path = candidates.first(
            where: fileManager.isExecutableFile(atPath:)
        ) {
            return URL(fileURLWithPath: path)
        }

        if let shellPath = locateWithLoginShell(name) {
            return URL(fileURLWithPath: shellPath)
        }
        throw AgentCLIError.executableMissing(name)
    }

    private static func locateWithLoginShell(_ name: String) -> String? {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = ["-lc", "command -v \(name)"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else {
            return nil
        }
        let path = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        )
        .trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}

enum AgentCLIError: LocalizedError {
    case executableMissing(String)
    case invalidWorkdir(String)
    case invalidOutput(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .executableMissing(let name):
            "\(name) 실행 파일을 찾을 수 없습니다."
        case .invalidWorkdir(let path):
            "작업 폴더가 없습니다. \(path)"
        case .invalidOutput(let message), .failed(let message):
            message
        }
    }
}
