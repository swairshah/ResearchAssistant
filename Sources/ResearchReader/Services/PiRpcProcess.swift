import Foundation
import os.log

private let logger = Logger(subsystem: "com.researchreader", category: "PiRpc")

/// Manages a persistent `pi --mode rpc` subprocess. Messages are exchanged as JSON
/// lines over stdin/stdout. The process stays alive across prompts so pi retains its
/// full session context natively instead of being cold-started on every message.
actor PiRpcProcess {

    // MARK: - Types

    struct RpcCommand: Encodable {
        let id: String?
        let type: String
        let message: String?
        let streamingBehavior: String?

        init(type: String, id: String? = nil, message: String? = nil, streamingBehavior: String? = nil) {
            self.id = id
            self.type = type
            self.message = message
            self.streamingBehavior = streamingBehavior
        }
    }

    struct RpcEvent: Decodable {
        let type: String
        let id: String?
        let command: String?
        let success: Bool?
        let error: String?
        let messages: [RpcAgentMessage]?
        let assistantMessageEvent: AssistantMessageEvent?
        let data: AnyCodable?

        // Tool execution fields
        let toolCallId: String?
        let toolName: String?
        let args: AnyCodable?
        let result: AnyCodable?
        let isError: Bool?
        let reason: String?

        struct AssistantMessageEvent: Decodable {
            let type: String          // text_delta, text_start, text_end, thinking_delta, toolcall_start, done, error …
            let delta: String?
            let contentIndex: Int?
        }
    }

    struct RpcAgentMessage: Decodable {
        let role: String
        let content: AnyCodable?
    }

    enum Status: Sendable {
        case idle
        case busy
        case dead(String)
    }

    enum StreamDelta: Sendable {
        case textDelta(String)
        case toolStart(name: String, toolCallId: String)
        case toolEnd(name: String, toolCallId: String, isError: Bool)
        case agentEnd
        case error(String)
    }

    typealias DeltaHandler = @Sendable (StreamDelta) -> Void

    // MARK: - State

    private var process: Process?
    private var stdin: FileHandle?
    private var readTask: Task<Void, Never>?
    private var stderrTask: Task<Void, Never>?
    private var deltaHandler: DeltaHandler?
    private var pendingPromptContinuation: CheckedContinuation<Void, Error>?

    private let piPath: String
    private let extensionPath: String
    private let sessionDir: String
    private let bridgeDir: String
    private let configDir: String
    private let workingDir: String

    private(set) var status: Status = .idle

    // MARK: - Init

    init(piPath: String, extensionPath: String, sessionDir: String, bridgeDir: String, configDir: String, workingDir: String) {
        self.piPath = piPath
        self.extensionPath = extensionPath
        self.sessionDir = sessionDir
        self.bridgeDir = bridgeDir
        self.configDir = configDir
        self.workingDir = workingDir
        logger.info("PiRpcProcess created — pi: \(piPath), ext: \(extensionPath)")
    }

    deinit {
        readTask?.cancel()
        stderrTask?.cancel()
        process?.terminate()
    }

    // MARK: - Lifecycle

    /// Ensures the RPC subprocess is alive. Spawns it if needed.
    func ensureRunning() throws {
        if let process, process.isRunning {
            logger.debug("ensureRunning: process already alive (pid \(process.processIdentifier))")
            return
        }
        logger.info("ensureRunning: spawning new pi process…")
        try spawnProcess()
    }

    /// Kills the subprocess if running.
    func stop() {
        logger.info("stop: terminating pi process")
        readTask?.cancel()
        readTask = nil
        stderrTask?.cancel()
        stderrTask = nil
        process?.terminate()
        process = nil
        stdin = nil
        status = .idle
    }

    /// Send a new-session command to reset context without killing the process.
    func resetSession() async throws {
        try ensureRunning()
        let cmd = RpcCommand(type: "new_session", id: "reset-\(UUID().uuidString)")
        logger.info("resetSession: sending new_session command")
        try sendCommand(cmd)
    }

    // MARK: - Prompting

    /// Send a prompt and stream deltas back via `onDelta`. The returned task
    /// completes when the agent finishes (agent_end received).
    func prompt(_ message: String, onDelta: @escaping DeltaHandler) async throws {
        try ensureRunning()

        deltaHandler = onDelta
        let promptId = "p-\(UUID().uuidString)"
        let cmd = RpcCommand(type: "prompt", id: promptId, message: message)
        logger.info("prompt: sending [\(promptId)] — \(message.prefix(120))…")
        try sendCommand(cmd)

        // Wait until agent_end or error
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            pendingPromptContinuation = cont
        }
        logger.info("prompt: [\(promptId)] completed")
    }

    /// Abort the running prompt.
    func abort() throws {
        logger.info("abort: sending abort command")
        try sendCommand(RpcCommand(type: "abort"))
    }

    // MARK: - Private

    private func spawnProcess() throws {
        let proc = Process()
        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()

        let isBundled = piPath.contains(".app/Contents/")

        var args: [String] = []

        let rpcArgs = buildRpcArgs()

        if isBundled {
            proc.executableURL = URL(fileURLWithPath: piPath)
            args = rpcArgs
            logger.info("spawn: bundled mode — \(self.piPath) \(rpcArgs.joined(separator: " "))")
        } else {
            proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let escapedArgs = rpcArgs.map { arg in
                "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
            }.joined(separator: " ")
            let shellCommand = """
            export PATH="$HOME/.nvm/versions/node/v22.16.0/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            "\(piPath)" \(escapedArgs)
            """
            args = ["-c", shellCommand]
            logger.info("spawn: shell mode — zsh -c '\(self.piPath) \(rpcArgs.joined(separator: " "))'")
        }

        proc.arguments = args
        proc.environment = buildEnvironment()
        proc.currentDirectoryURL = URL(fileURLWithPath: workingDir)
        proc.standardInput = stdinPipe
        proc.standardOutput = stdoutPipe
        proc.standardError = stderrPipe

        try proc.run()
        logger.info("spawn: pi started with pid \(proc.processIdentifier)")

        self.process = proc
        self.stdin = stdinPipe.fileHandleForWriting

        // Start reading stdout for JSONL events.
        // IMPORTANT: This must be Task.detached so the blocking availableData
        // call doesn't hold the actor's executor, which would prevent the
        // prompt() continuation from ever resuming (actor deadlock).
        let stdout = stdoutPipe.fileHandleForReading
        readTask = Task.detached { [weak self] in
            var buffer = Data()
            while !Task.isCancelled {
                let chunk = stdout.availableData
                if chunk.isEmpty {
                    logger.info("readLoop: EOF — pi stdout closed")
                    break
                }
                buffer.append(chunk)

                while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                    var lineData = buffer[buffer.startIndex..<newlineIndex]
                    buffer = Data(buffer[buffer.index(after: newlineIndex)...])
                    if let last = lineData.last, last == 0x0D {
                        lineData = lineData.dropLast()
                    }
                    if lineData.isEmpty { continue }
                    // Dispatch back to the actor for processing
                    await self?.processLine(Data(lineData))
                }
            }
        }

        // Drain and log stderr (also detached to avoid blocking the actor)
        let stderrHandle = stderrPipe.fileHandleForReading
        stderrTask = Task.detached {
            var stderrBuffer = Data()
            while true {
                let data = stderrHandle.availableData
                if data.isEmpty { break }
                stderrBuffer.append(data)
                while let newlineIdx = stderrBuffer.firstIndex(of: 0x0A) {
                    let lineData = stderrBuffer[stderrBuffer.startIndex..<newlineIdx]
                    stderrBuffer = Data(stderrBuffer[stderrBuffer.index(after: newlineIdx)...])
                    if let line = String(data: lineData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !line.isEmpty {
                        logger.warning("pi stderr: \(line)")
                    }
                }
            }
            if let remaining = String(data: stderrBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines), !remaining.isEmpty {
                logger.warning("pi stderr (final): \(remaining)")
            }
        }

        proc.terminationHandler = { [weak self] terminatedProc in
            let code = terminatedProc.terminationStatus
            logger.error("pi process terminated with code \(code)")
            Task { [weak self] in
                await self?.handleTermination()
            }
        }

        status = .idle
    }

    private func buildRpcArgs() -> [String] {
        var args: [String] = []
        args += ["--mode", "rpc"]
        args += ["--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes"]
        args += ["--extension", extensionPath]
        args += ["--session-dir", sessionDir]
        args += ["--provider", "anthropic"]
        args += ["--model", "claude-haiku-4-5"]
        args += ["--system", systemPrompt]
        return args
    }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PI_CODING_AGENT_DIR"] = configDir
        env["RESEARCHREADER_BRIDGE_DIR"] = bridgeDir
        return env
    }

    private func sendCommand(_ command: RpcCommand) throws {
        guard let stdin else {
            logger.error("sendCommand: stdin is nil — process not running")
            throw PiRpcError.notRunning
        }
        let encoder = JSONEncoder()
        let data = try encoder.encode(command)
        if let jsonStr = String(data: data, encoding: .utf8) {
            logger.debug("→ stdin: \(jsonStr)")
        }
        var line = data
        line.append(contentsOf: [0x0A]) // newline
        stdin.write(line)
    }

    // MARK: - Event Processing

    private func processLine(_ data: Data) async {
        // Log every raw line from pi
        if let rawLine = String(data: data, encoding: .utf8) {
            // Truncate very long lines for logging (e.g. full message objects)
            let logLine = rawLine.count > 300 ? String(rawLine.prefix(300)) + "…[\(rawLine.count) chars]" : rawLine
            logger.debug("← stdout: \(logLine)")
        }

        guard let event = try? JSONDecoder().decode(RpcEvent.self, from: data) else {
            if let rawLine = String(data: data, encoding: .utf8) {
                logger.error("Failed to decode JSONL event: \(rawLine.prefix(200))")
            }
            return
        }

        switch event.type {
        case "message_update":
            if let ame = event.assistantMessageEvent {
                switch ame.type {
                case "text_delta":
                    if let delta = ame.delta {
                        deltaHandler?(.textDelta(delta))
                    }
                case "thinking_delta":
                    logger.debug("  [thinking delta]")
                case "toolcall_start":
                    logger.info("  [toolcall_start]")
                case "toolcall_end":
                    logger.info("  [toolcall_end]")
                case "done":
                    logger.info("  [message done]")
                case "error":
                    logger.error("  [message error]")
                    deltaHandler?(.error("Agent streaming error"))
                default:
                    break
                }
            }

        case "tool_execution_start":
            let toolName = event.toolName ?? "unknown"
            let callId = event.toolCallId ?? "?"
            logger.info("🔧 tool_execution_start: \(toolName) [\(callId)]")
            deltaHandler?(.toolStart(name: toolName, toolCallId: callId))

        case "tool_execution_update":
            let toolName = event.toolName ?? "unknown"
            logger.debug("🔧 tool_execution_update: \(toolName)")

        case "tool_execution_end":
            let toolName = event.toolName ?? "unknown"
            let callId = event.toolCallId ?? "?"
            let isErr = event.isError ?? false
            logger.info("🔧 tool_execution_end: \(toolName) [\(callId)] isError=\(isErr)")
            deltaHandler?(.toolEnd(name: toolName, toolCallId: callId, isError: isErr))

        case "agent_start":
            logger.info("▶ agent_start")

        case "agent_end":
            logger.info("■ agent_end")
            deltaHandler?(.agentEnd)
            let cont = pendingPromptContinuation
            pendingPromptContinuation = nil
            status = .idle
            cont?.resume()

        case "turn_start":
            logger.info("↻ turn_start")

        case "turn_end":
            logger.info("↻ turn_end")

        case "message_start":
            logger.debug("message_start")

        case "message_end":
            logger.debug("message_end")

        case "auto_compaction_start":
            let reason = event.reason ?? "unknown"
            logger.info("🗜 auto_compaction_start: \(reason)")

        case "auto_compaction_end":
            logger.info("🗜 auto_compaction_end")

        case "auto_retry_start":
            logger.warning("🔄 auto_retry_start")

        case "auto_retry_end":
            logger.info("🔄 auto_retry_end")

        case "response":
            // Command acknowledgements — check for errors
            let cmdName = event.command ?? "?"
            if event.success == true {
                logger.info("✓ response: \(cmdName) succeeded")
            } else {
                let errMsg = event.error ?? "unknown error"
                logger.error("✗ response: \(cmdName) failed — \(errMsg)")
                deltaHandler?(.error(errMsg))
                let cont = pendingPromptContinuation
                pendingPromptContinuation = nil
                status = .idle
                cont?.resume(throwing: PiRpcError.commandFailed(errMsg))
            }

        case "extension_error":
            let errMsg = event.error ?? "unknown"
            logger.error("extension_error: \(errMsg)")

        default:
            logger.debug("Unhandled event type: \(event.type)")
        }
    }

    private func handleTermination() {
        let exitCode = process?.terminationStatus ?? -1
        logger.error("handleTermination: exit code \(exitCode)")
        status = .dead("Pi process exited with code \(exitCode)")
        let cont = pendingPromptContinuation
        pendingPromptContinuation = nil
        cont?.resume(throwing: PiRpcError.processExited(exitCode))
    }

    // MARK: - System Prompt

    private let systemPrompt = """
You are the integrated Pi coding agent inside ResearchReader, a native macOS paper-reading app.

Your role:
- Help the user think through papers, summarize, compare, critique, and extract implementation ideas.
- Use the ResearchReader extension tools to inspect the active project, project notebook, paper, page, and annotations.
- If the user asks coding questions inspired by the active paper, reason like a practical software engineer.
- If the current paper is relevant, anchor your answer to it directly rather than speaking abstractly.

Behavior:
- Be concise and concrete.
- Prefer actionable answers over generic background.
- When context is missing, say what is missing instead of pretending.
- Treat the active project as the user's working set and the active paper as the primary reference.
- When the user refers to the project notebook, notes, "this paper", the current page, highlights, or PDF navigation, call `get_reader_context` first unless the answer is already obvious from the conversation.
- Use the PDF tools directly when navigation or temporary preview would help the user.
- Read or update the project notebook using the notebook tools instead of asking the user to copy text manually.
- If the user asks you to add to, update, summarize into, or save something in the notebook, you must use `get_project_notebook` plus `append_project_notebook` or `replace_project_notebook` before you answer.
- Do not merely say that you can update the notebook. Perform the notebook tool call when asked, then report what you changed.
- Do not reintroduce yourself, restate your instructions, or ask a generic "what would you like to do?" when the user has already made a concrete request.
- If the user gives a direct action request, execute it immediately with tools when possible, then answer with the result.
"""
}

// MARK: - Errors

enum PiRpcError: LocalizedError {
    case notRunning
    case processExited(Int32)
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .notRunning:
            return "Pi RPC process is not running."
        case .processExited(let code):
            return "Pi process exited unexpectedly (code \(code))."
        case .commandFailed(let msg):
            return "Pi command failed: \(msg)"
        }
    }
}

// MARK: - AnyCodable helper for decoding arbitrary JSON

struct AnyCodable: Decodable, Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = NSNull()
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else if let int = try? container.decode(Int.self) {
            value = int
        } else if let double = try? container.decode(Double.self) {
            value = double
        } else if let string = try? container.decode(String.self) {
            value = string
        } else if let array = try? container.decode([AnyCodable].self) {
            value = array.map(\.value)
        } else if let dict = try? container.decode([String: AnyCodable].self) {
            value = dict.mapValues(\.value)
        } else {
            value = NSNull()
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let bool as Bool:
            try container.encode(bool)
        case let int as Int:
            try container.encode(int)
        case let double as Double:
            try container.encode(double)
        case let string as String:
            try container.encode(string)
        case let array as [Any]:
            try container.encode(array.map { AnyCodable($0) })
        case let dict as [String: Any]:
            try container.encode(dict.mapValues { AnyCodable($0) })
        default:
            try container.encodeNil()
        }
    }
}
