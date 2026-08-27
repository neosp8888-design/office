// 이 파일은 직원 AI CLI를 실행하고 JSONL 응답을 공통 형식으로 변환한다.

import Foundation
import OfficeCore

struct AgentCLIResponse: Sendable {
    let text: String
    let sessionID: String?
    let needsInput: Bool
}

actor AgentCLIRunner {
    func run(
        prompt: String,
        character: CharacterConfiguration,
        workdir: String,
        previousSessionID: String?,
        onProgress: (@MainActor @Sendable (String) -> Void)? = nil
    ) async throws -> AgentCLIResponse {
        let executable = try ExecutableLocator.locate(
            backend: character.backend,
            configuredPath: character.executablePath
        )
        let arguments = arguments(
            prompt: prompt,
            character: character,
            previousSessionID: previousSessionID,
            workdir: workdir
        )
        let result = try await launch(
            executable: executable,
            arguments: arguments,
            workdir: workdir,
            backend: character.backend,
            onProgress: onProgress
        )
        let output = String(decoding: result.stdout, as: UTF8.self)

        guard result.status == 0 else {
            let stderr = String(decoding: result.stderr, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let structuredError = structuredFailureMessage(
                in: output,
                backend: character.backend
            )
            throw AgentCLIError.failed(
                structuredError
                    ?? (stderr.isEmpty
                        ? "CLI가 종료 코드 \(result.status)로 끝났습니다."
                        : stderr)
            )
        }

        switch character.backend {
        case .codex:
            return try parseCodex(output)
        case .claude:
            return try parseClaude(output)
        case .antigravity:
            return try parseAntigravity(output)
        }
    }

    private func arguments(
        prompt: String,
        character: CharacterConfiguration,
        previousSessionID: String?,
        workdir: String
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
        case .antigravity:
            return antigravityArguments(
                prompt: prompt,
                character: character,
                previousSessionID: previousSessionID,
                workdir: workdir
            )
        }
    }

    private func codexArguments(
        prompt: String,
        character: CharacterConfiguration,
        previousSessionID: String?
    ) -> [String] {
        var arguments = ["exec"]

        if let previousSessionID {
            arguments += ["resume", previousSessionID, "--json"]
        } else {
            arguments += ["--json", "--skip-git-repo-check"]
        }

        if let model = character.model, !model.isEmpty {
            arguments += ["-c", "model=\"\(model)\""]
        }
        arguments += [
            "-c",
            "model_reasoning_effort=\"\(character.effort)\"",
            "-c",
            "service_tier=\"\(character.fastMode ? "fast" : "default")\"",
            "-c",
            "model_reasoning_summary=\"detailed\"",
            "-c",
            "show_raw_agent_reasoning=true",
            "-c",
            "developer_instructions=\(jsonString(character.identityPrompt))",
        ]
        if previousSessionID == nil {
            arguments += ["-s", character.permission]
        }
        arguments.append(prompt)
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
            "--settings",
            "{\"fastMode\":\(character.fastMode)}",
            "--effort",
            character.effort,
            "--permission-mode",
            character.permission,
        ]
        if let model = character.model, !model.isEmpty {
            arguments += ["--model", model]
        }
        arguments += ["--append-system-prompt", character.identityPrompt]
        if let previousSessionID {
            arguments += ["--resume", previousSessionID]
        }
        return arguments
    }

    private func antigravityArguments(
        prompt: String,
        character: CharacterConfiguration,
        previousSessionID: String?,
        workdir: String
    ) -> [String] {
        let executionPrompt = """
        <officestra_identity>
        \(character.identityPrompt)
        </officestra_identity>
        <officestra_execution>
        업무 폴더는 \(jsonString(workdir))입니다.
        명령을 실행할 때는 반드시 \(jsonString(workdir))로 이동한 뒤 실행합니다.
        사용자 요청 범위를 벗어난 파일이나 서비스를 변경하지 않습니다.
        </officestra_execution>
        <user_request>
        \(prompt)
        </user_request>
        """
        var arguments = [
            "-p",
            executionPrompt,
            "--output-format",
            "stream-json",
            "--model",
            character.model ?? character.backend.defaultModel,
            "--effort",
            character.effort,
        ]
        if let previousSessionID {
            arguments += ["--conversation", previousSessionID]
        }
        // Headless plan에서도 작업 폴더의 첨부와 소스를 읽을 수 있게
        // 명시적인 workspace root를 전달한다.
        arguments += ["--add-dir", workdir]
        switch character.permission {
        case "plan":
            arguments += ["--mode", "plan"]
        case "accept-edits":
            arguments += [
                "--mode", "accept-edits", "--sandbox",
                "--dangerously-skip-permissions",
            ]
        case "dangerously-skip-permissions":
            arguments += [
                "--mode", "accept-edits",
                "--dangerously-skip-permissions",
            ]
        default:
            break
        }
        return arguments
    }

    private func jsonString(_ value: String) -> String {
        guard
            let data = try? JSONEncoder().encode(value),
            let encoded = String(data: data, encoding: .utf8)
        else {
            return "\"\""
        }
        return encoded
    }

    private func launch(
        executable: URL,
        arguments: [String],
        workdir: String,
        backend: AgentBackend,
        onProgress: (@MainActor @Sendable (String) -> Void)?
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
        if backend == .antigravity {
            process.environment = antigravityEnvironment()
        }

        let outputTask = Task.detached {
            await StreamingOutputReader.read(
                from: stdout.fileHandleForReading
            ) { line in
                guard
                    let onProgress,
                    let message = AgentProgressEventParser.message(
                        fromJSONLine: line,
                        backend: backend
                    )
                else {
                    return
                }
                await onProgress(message)
            }
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

    private func antigravityEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let bundledRuntime = Bundle.main.resourceURL?
            .appending(path: "OFFICESTRARuntime")
        let developmentRuntime = OfficeDevelopmentRuntimeLocator.locate()
        let driverCandidates = [
            bundledRuntime?
                .appending(path: "backend/src/playwright-driver-1.57.0"),
            developmentRuntime?
                .appending(path: "backend/src/playwright-driver-1.57.0"),
        ].compactMap { $0 }
        guard let driver = driverCandidates.first(where: {
            FileManager.default.fileExists(
                atPath: $0.appending(path: "package/cli.js").path
            )
        }) else {
            return environment
        }
        environment["PLAYWRIGHT_DRIVER_PATH"] =
            environment["PLAYWRIGHT_DRIVER_PATH"] ?? driver.path
        let bundledNode = bundledRuntime?
            .appending(path: "node/bin/node")
        let node = [bundledNode, OfficeToolLocator.locate("node")]
            .compactMap { $0 }
            .first(where: {
                FileManager.default.isExecutableFile(atPath: $0.path)
            })
        if let node {
            environment["PLAYWRIGHT_NODEJS_PATH"] =
                environment["PLAYWRIGHT_NODEJS_PATH"] ?? node.path
        }
        return environment
    }

    private func parseCodex(_ output: String) throws -> AgentCLIResponse {
        var sessionID: String?
        var messages: [String] = []
        var lastError: String?

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
            } else if type == "error" {
                lastError =
                    failureMessage(from: object["message"])
                    ?? failureMessage(from: object["error"])
            } else if type == "turn.failed" {
                throw AgentCLIError.failed(
                    failureMessage(from: object["error"])
                        ?? lastError
                        ?? "Codex 작업이 실패했습니다."
                )
            }
        }

        guard let text = messages.last else {
            if let lastError {
                throw AgentCLIError.failed(lastError)
            }
            throw AgentCLIError.invalidOutput("Codex 최종 메시지가 없습니다.")
        }
        return response(text: text, sessionID: sessionID)
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
        return response(text: text, sessionID: sessionID)
    }

    private func parseAntigravity(_ output: String) throws -> AgentCLIResponse {
        var sessionID: String?
        var responseText: String?
        for object in jsonObjects(from: output) {
            let event = object["event"] as? String
            if event == "init" {
                sessionID = object["conversation_id"] as? String
            } else if event == "result",
                      let result = object["result"] as? [String: Any]
            {
                sessionID = sessionID ?? result["conversation_id"] as? String
                if
                    let status = result["status"] as? String,
                    status != "SUCCESS"
                {
                    throw AgentCLIError.failed(
                        failureMessage(from: result["error"])
                            ?? failureMessage(from: result["response"])
                            ?? "Antigravity 작업이 실패했습니다."
                    )
                }
                responseText = result["response"] as? String
            }
        }
        guard let responseText, !responseText.isEmpty else {
            throw AgentCLIError.invalidOutput(
                "Antigravity 최종 메시지가 없습니다."
            )
        }
        return response(text: responseText, sessionID: sessionID)
    }

    private func structuredFailureMessage(
        in output: String,
        backend: AgentBackend
    ) -> String? {
        var lastError: String?
        for object in jsonObjects(from: output) {
            switch backend {
            case .codex:
                if object["type"] as? String == "turn.failed" {
                    return failureMessage(from: object["error"]) ?? lastError
                }
                if object["type"] as? String == "error" {
                    lastError =
                        failureMessage(from: object["message"])
                        ?? failureMessage(from: object["error"])
                }
            case .claude:
                if
                    object["type"] as? String == "result",
                    object["is_error"] as? Bool == true
                {
                    return failureMessage(from: object["result"])
                }
            case .antigravity:
                if
                    object["event"] as? String == "result",
                    let result = object["result"] as? [String: Any],
                    let status = result["status"] as? String,
                    status != "SUCCESS"
                {
                    return failureMessage(from: result["error"])
                        ?? failureMessage(from: result["response"])
                }
                if object["event"] as? String == "error" {
                    lastError = failureMessage(from: object["error"])
                        ?? failureMessage(from: object["message"])
                }
            }
        }
        return lastError
    }

    private func failureMessage(from value: Any?) -> String? {
        if let value = value as? String {
            let trimmed = value.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
            return trimmed.isEmpty ? nil : trimmed
        }
        guard let object = value as? [String: Any] else {
            return nil
        }
        let fields = ["message", "detail", "code", "type", "error"]
        let messages = fields.compactMap {
            failureMessage(from: object[$0])
        }
        .reduce(into: [String]()) { result, message in
            if !result.contains(message) {
                result.append(message)
            }
        }
        return messages.isEmpty ? nil : messages.joined(separator: "\n")
    }

    private func response(
        text: String,
        sessionID: String?
    ) -> AgentCLIResponse {
        let decoded = AgentResponseProtocol.decode(text)
        return AgentCLIResponse(
            text: decoded.text,
            sessionID: sessionID,
            needsInput: decoded.needsInput
        )
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

private enum StreamingOutputReader {
    static func read(
        from handle: FileHandle,
        onLine: @escaping @Sendable (String) async -> Void
    ) async -> Data {
        var output = Data()
        var pending = Data()

        while true {
            let chunk = handle.readData(ofLength: 4_096)
            guard !chunk.isEmpty else {
                break
            }
            output.append(chunk)
            pending.append(chunk)

            while let newlineIndex = pending.firstIndex(of: 0x0A) {
                let lineData = Data(pending[..<newlineIndex])
                pending.removeSubrange(
                    pending.startIndex ... newlineIndex
                )
                await emit(lineData, to: onLine)
            }
        }

        if !pending.isEmpty {
            await emit(pending, to: onLine)
        }
        return output
    }

    private static func emit(
        _ data: Data,
        to onLine: @escaping @Sendable (String) async -> Void
    ) async {
        var line = String(decoding: data, as: UTF8.self)
        if line.last == "\r" {
            line.removeLast()
        }
        guard !line.isEmpty else {
            return
        }
        await onLine(line)
    }
}

private enum ExecutableLocator {
    static func locate(
        backend: AgentBackend,
        configuredPath: String?
    ) throws -> URL {
        let name = backend.executableName
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
