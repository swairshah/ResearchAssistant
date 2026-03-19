import Foundation
import os.log

private let logger = Logger(subsystem: "com.researchreader", category: "PiChat")

/// Thread-safe accumulator for streaming text. Sendable so it can be
/// captured safely by the @Sendable delta handler closure.
private final class StreamTextAccumulator: @unchecked Sendable {
    private let lock = NSLock()
    private var _text = ""

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return _text
    }

    /// Appends a fragment and returns the new accumulated text.
    @discardableResult
    func append(_ fragment: String) -> String {
        lock.lock()
        defer { lock.unlock() }
        _text += fragment
        return _text
    }
}

@MainActor
final class ResearchPiChatManager: ObservableObject {
    @Published private(set) var messages: [AgentChatMessage] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var streamingText: String = ""
    @Published private(set) var activityStatus: String = ""
    @Published private(set) var pendingCommands: [AgentUICommand] = []

    private let paths: AppPaths
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let piPath: String
    private let extensionPath: String

    /// The persistent RPC subprocess — stays alive across messages.
    private var rpcProcess: PiRpcProcess?

    var isPiAvailable: Bool {
        FileManager.default.fileExists(atPath: piPath)
    }

    var isExtensionAvailable: Bool {
        FileManager.default.fileExists(atPath: extensionPath)
    }

    init() {
        do {
            self.paths = try AppPaths.make()
        } catch {
            fatalError("Unable to initialize Pi chat paths: \(error.localizedDescription)")
        }

        self.piPath = Self.resolvePiPath()
        self.extensionPath = Self.installLocalExtension(to: paths.piExtensionFile)
        logger.info("init: piPath=\(self.piPath) extPath=\(self.extensionPath)")
        logger.info("init: piAvailable=\(self.isPiAvailable) extAvailable=\(self.isExtensionAvailable)")
        load()
    }

    // MARK: - Public API

    func send(_ text: String, context: AgentContextSnapshot) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProcessing else { return }

        logger.info("send: user message — \(trimmed.prefix(100))")
        append(AgentChatMessage(id: UUID(), isUser: true, text: trimmed, createdAt: Date()))
        isProcessing = true
        streamingText = ""
        activityStatus = "Starting…"

        // Context file is already kept up-to-date by MainWindowView's
        // syncPiBridgeContext(), so no need to write it here.

        let prompt = buildPrompt(userMessage: trimmed, context: context)
        logger.debug("send: built prompt (\(prompt.count) chars)")

        Task {
            let reply: String
            if isPiAvailable && isExtensionAvailable {
                do {
                    reply = try await promptRpc(message: prompt)
                    logger.info("send: got reply (\(reply.count) chars)")
                } catch {
                    logger.error("send: promptRpc error — \(error.localizedDescription)")
                    reply = "Pi error: \(error.localizedDescription)"
                }
            } else {
                logger.warning("send: pi or extension not available")
                reply = "Pi or the ResearchReader extension is not available."
            }

            await MainActor.run {
                let parsed = self.parseAgentReply(reply)
                self.pendingCommands.append(contentsOf: parsed.commands)
                self.append(AgentChatMessage(id: UUID(), isUser: false, text: parsed.displayText, createdAt: Date()))
                self.streamingText = ""
                self.activityStatus = ""
                self.isProcessing = false
                logger.info("send: done, \(parsed.commands.count) UI command(s) extracted")
            }
        }
    }

    func consumePendingCommands() -> [AgentUICommand] {
        let commands = pendingCommands
        pendingCommands.removeAll()
        return commands
    }

    func clearConversation() {
        logger.info("clearConversation")
        messages.removeAll()
        save()

        // Tell the RPC process to start a new session instead of killing it
        Task {
            if let rpc = rpcProcess {
                try? await rpc.resetSession()
            }
        }
    }

    func stopAgent() {
        logger.info("stopAgent")
        Task {
            await rpcProcess?.stop()
            rpcProcess = nil
        }
    }

    // MARK: - RPC Subprocess

    private func ensureRpcProcess() -> PiRpcProcess {
        if let existing = rpcProcess {
            return existing
        }
        logger.info("ensureRpcProcess: creating new PiRpcProcess")
        let rpc = PiRpcProcess(
            piPath: piPath,
            extensionPath: extensionPath,
            sessionDir: paths.piSessionDirectory.path,
            bridgeDir: paths.piBridgeDirectory.path,
            configDir: paths.piConfigDirectory.path,
            workingDir: paths.rootDirectory.path
        )
        rpcProcess = rpc
        return rpc
    }

    private func promptRpc(message: String) async throws -> String {
        let rpc = ensureRpcProcess()

        // Thread-safe accumulator for streaming text
        let accumulator = StreamTextAccumulator()

        try await rpc.prompt(message) { [weak self] delta in
            switch delta {
            case .textDelta(let text):
                let current = accumulator.append(text)
                Task { @MainActor [weak self] in
                    self?.streamingText = current
                    self?.activityStatus = "Responding…"
                }

            case .toolStart(let name, let callId):
                logger.info("toolStart: \(name) [\(callId)]")
                let displayName = Self.friendlyToolName(name)
                Task { @MainActor [weak self] in
                    self?.activityStatus = "Running \(displayName)…"
                }

            case .toolEnd(let name, let callId, let isError):
                logger.info("toolEnd: \(name) [\(callId)] error=\(isError)")
                Task { @MainActor [weak self] in
                    if isError {
                        self?.activityStatus = "\(Self.friendlyToolName(name)) failed"
                    } else {
                        self?.activityStatus = "Thinking…"
                    }
                }

            case .agentEnd:
                logger.info("agentEnd received in delta handler")

            case .error(let msg):
                logger.error("error delta: \(msg)")
                _ = accumulator.append("\n[Error: \(msg)]")
                Task { @MainActor [weak self] in
                    self?.activityStatus = "Error: \(msg)"
                }
            }
        }

        return accumulator.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Map internal tool names to readable labels for the UI status.
    private nonisolated static func friendlyToolName(_ name: String) -> String {
        switch name {
        case "get_reader_context":      return "reading context"
        case "get_project_notebook":    return "reading notebook"
        case "replace_project_notebook": return "updating notebook"
        case "append_project_notebook": return "appending to notebook"
        case "go_to_pdf_page":          return "navigating PDF"
        case "focus_pdf_annotation":    return "focusing annotation"
        case "preview_pdf_annotation":  return "previewing annotation"
        case "preview_pdf_text":        return "previewing text"
        case "clear_pdf_preview":       return "clearing preview"
        default:                        return name
        }
    }

    // MARK: - Persistence

    private func append(_ message: AgentChatMessage) {
        messages.append(message)
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: paths.chatHistoryFile.path) else { return }
        do {
            let data = try Data(contentsOf: paths.chatHistoryFile)
            messages = try decoder.decode([AgentChatMessage].self, from: data)
            logger.info("load: restored \(self.messages.count) messages")
        } catch {
            logger.error("load: failed — \(error.localizedDescription)")
            messages = []
        }
    }

    private func save() {
        do {
            let data = try encoder.encode(messages)
            try data.write(to: paths.chatHistoryFile, options: [.atomic])
        } catch {
            assertionFailure("Unable to save chat history: \(error.localizedDescription)")
        }
    }

    // MARK: - Prompt Building

    private func buildPrompt(userMessage: String, context: AgentContextSnapshot) -> String {
        var lines: [String] = []
        lines.append("- Active project: \(context.projectName ?? "None")")
        if let notebook = context.notebook {
            lines.append("- Active notebook: \(notebook.projectName) (\(notebook.filePath))")
            let preview = notebook.markdown
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(1400)
            if !preview.isEmpty {
                lines.append("- Notebook preview:")
                lines.append(String(preview))
            } else {
                lines.append("- Notebook preview: empty")
            }
        } else {
            lines.append("- Active notebook: None")
        }
        if let paper = context.paper {
            lines.append("- Active paper: \(paper.title)")
        } else {
            lines.append("- Active paper: None")
        }
        if let selection = context.currentSelection {
            lines.append("- Current selection on page \(selection.page):")
            lines.append(selection.text)
        } else {
            lines.append("- Current selection: None")
        }

        lines.append("")
        lines.append("User message:")
        lines.append(userMessage)
        return lines.joined(separator: "\n")
    }

    // MARK: - Reply Parsing

    private func parseAgentReply(_ raw: String) -> (displayText: String, commands: [AgentUICommand]) {
        let pattern = #"\[\[(goto_page|focus_annotation|preview_annotation|preview_text)\s*:\s*([^\]]+)\]\]|\[\[(clear_preview)\]\]"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return (raw, [])
        }

        let nsRange = NSRange(raw.startIndex..<raw.endIndex, in: raw)
        let matches = regex.matches(in: raw, options: [], range: nsRange)

        var commands: [AgentUICommand] = []
        for match in matches {
            if let clearRange = Range(match.range(at: 3), in: raw) {
                let name = raw[clearRange].lowercased()
                if name == "clear_preview" {
                    commands.append(.clearPreview)
                }
                continue
            }

            guard let nameRange = Range(match.range(at: 1), in: raw),
                  let valueRange = Range(match.range(at: 2), in: raw) else {
                continue
            }
            let name = raw[nameRange].lowercased()
            let value = raw[valueRange].trimmingCharacters(in: .whitespacesAndNewlines)

            switch name {
            case "goto_page":
                if let page = Int(value) {
                    commands.append(.goToPage(page))
                }
            case "focus_annotation":
                commands.append(.focusAnnotation(value))
            case "preview_annotation":
                commands.append(.previewAnnotation(value))
            case "preview_text":
                if let command = parsePreviewTextDirective(value) {
                    commands.append(command)
                }
            default:
                break
            }
        }

        let cleaned = regex.stringByReplacingMatches(in: raw, range: nsRange, withTemplate: "")
            .replacingOccurrences(of: "\n\n\n", with: "\n\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return (cleaned.isEmpty ? "Done." : cleaned, commands)
    }

    private func parsePreviewTextDirective(_ value: String) -> AgentUICommand? {
        let parts = value.split(separator: "|", omittingEmptySubsequences: true)
        var page: Int?
        var text: String?

        for part in parts {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: true)
            guard pair.count == 2 else { continue }
            let key = pair[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let rawValue = pair[1].trimmingCharacters(in: .whitespacesAndNewlines)

            switch key {
            case "page":
                page = Int(rawValue)
            case "text":
                text = rawValue
            default:
                break
            }
        }

        guard let page, let text, !text.isEmpty else { return nil }
        return .previewText(page: page, text: text)
    }

    // MARK: - Path Resolution

    private static func resolvePiPath() -> String {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("Support/pi").path
        let candidates = [
            bundled,
            NSHomeDirectory() + "/.nvm/versions/node/v22.16.0/bin/pi",
            "/opt/homebrew/bin/pi",
            "/usr/local/bin/pi",
        ].compactMap { $0 }

        return candidates.first(where: { FileManager.default.fileExists(atPath: $0) }) ?? (bundled ?? "")
    }

    private static func installLocalExtension(to destination: URL) -> String {
        let candidatePaths = [
            Bundle.main.resourceURL.map { $0.appendingPathComponent("Support/research-reader-pi-extension/index.js").path() },
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("PiExtension/index.js").path(),
            "/Users/swair/work/projects/research-reader/PiExtension/index.js",
        ].compactMap { $0 }

        guard let sourcePath = candidatePaths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
            return destination.path()
        }

        do {
            let sourceURL = URL(fileURLWithPath: sourcePath)
            let data = try Data(contentsOf: sourceURL)
            try data.write(to: destination, options: Data.WritingOptions.atomic)
        } catch {
            return sourcePath
        }

        return destination.path
    }
}
