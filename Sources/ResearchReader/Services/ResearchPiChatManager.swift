import Foundation

@MainActor
final class ResearchPiChatManager: ObservableObject {
    @Published private(set) var messages: [AgentChatMessage] = []
    @Published private(set) var isProcessing = false
    @Published private(set) var pendingCommands: [AgentUICommand] = []

    private let paths: AppPaths
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private let piPath: String
    private let extensionPath: String

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
        load()
    }

    func send(_ text: String, context: AgentContextSnapshot) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isProcessing else { return }

        append(AgentChatMessage(id: UUID(), isUser: true, text: trimmed, createdAt: Date()))
        isProcessing = true

        Task {
            let reply: String
            if isPiAvailable && isExtensionAvailable {
                do {
                    reply = try await runPi(message: buildPrompt(userMessage: trimmed, context: context), continueSession: true)
                } catch {
                    reply = "Pi error: \(error.localizedDescription)"
                }
            } else {
                reply = "Pi or the ResearchReader extension is not available."
            }

            await MainActor.run {
                let parsed = self.parseAgentReply(reply)
                self.pendingCommands.append(contentsOf: parsed.commands)
                self.append(AgentChatMessage(id: UUID(), isUser: false, text: parsed.displayText, createdAt: Date()))
                self.isProcessing = false
            }
        }
    }

    func consumePendingCommands() -> [AgentUICommand] {
        let commands = pendingCommands
        pendingCommands.removeAll()
        return commands
    }

    func clearConversation() {
        messages.removeAll()
        save()

        let fm = FileManager.default
        try? fm.removeItem(at: paths.piSessionDirectory)
        try? fm.createDirectory(at: paths.piSessionDirectory, withIntermediateDirectories: true)
    }

    private func append(_ message: AgentChatMessage) {
        messages.append(message)
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: paths.chatHistoryFile.path) else { return }
        do {
            let data = try Data(contentsOf: paths.chatHistoryFile)
            messages = try decoder.decode([AgentChatMessage].self, from: data)
        } catch {
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

    private func runPi(message: String, continueSession: Bool) async throws -> String {
        let process = Process()
        let args = buildPiArgs(message: message, continueSession: continueSession)

        let bundledPiPath = Bundle.main.resourceURL?.appendingPathComponent("Support/pi").path
        let isBundled = bundledPiPath == piPath

        if isBundled {
            process.executableURL = URL(fileURLWithPath: piPath)
            process.arguments = args
        } else {
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            let escapedArgs = args.map { arg in
                "'\(arg.replacingOccurrences(of: "'", with: "'\\''"))'"
            }.joined(separator: " ")
            let shellCommand = """
            export PATH="$HOME/.nvm/versions/node/v22.16.0/bin:/opt/homebrew/bin:/usr/local/bin:$PATH"
            "\(piPath)" \(escapedArgs)
            """
            process.arguments = ["-c", shellCommand]
        }

        process.environment = buildEnvironment()
        process.currentDirectoryURL = paths.rootDirectory

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        try process.run()

        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                process.waitUntilExit()

                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let output = String(data: data, encoding: .utf8) ?? ""
                let cleanOutput = output.trimmingCharacters(in: .whitespacesAndNewlines)

                if !cleanOutput.isEmpty {
                    continuation.resume(returning: cleanOutput)
                } else {
                    continuation.resume(throwing: NSError(
                        domain: "ResearchPiChat",
                        code: Int(process.terminationStatus),
                        userInfo: [NSLocalizedDescriptionKey: output]
                    ))
                }
            }
        }
    }

    private func buildEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PI_CODING_AGENT_DIR"] = paths.piConfigDirectory.path
        env["RESEARCHREADER_BRIDGE_DIR"] = paths.piBridgeDirectory.path
        return env
    }

    private func buildPiArgs(message: String, continueSession: Bool) -> [String] {
        var args: [String] = []
        args += ["--no-extensions", "--no-skills", "--no-prompt-templates", "--no-themes"]
        args += ["--extension", extensionPath]
        args += ["--session-dir", paths.piSessionDirectory.path]
        if continueSession, !messages.isEmpty {
            args += ["--continue"]
        }
        args += ["--print"]
        args += ["--provider", "anthropic"]
        args += ["--model", "claude-haiku-4-5"]
        args += ["--system", systemPrompt]
        args += [message]
        return args
    }

    private func buildPrompt(userMessage: String, context: AgentContextSnapshot) -> String {
        var lines: [String] = []
        lines.append("- Active project: \(context.projectName ?? "None")")
        if let paper = context.paper {
            lines.append("- Active paper: \(paper.title)")
        } else {
            lines.append("- Active paper: None")
        }

        lines.append("")
        lines.append("User message:")
        lines.append(userMessage)
        return lines.joined(separator: "\n")
    }

    private let systemPrompt = """
You are the integrated Pi coding agent inside ResearchReader, a native macOS paper-reading app.

Your role:
- Help the user think through papers, summarize, compare, critique, and extract implementation ideas.
- Use the ResearchReader extension tools to inspect the active project, paper, page, and annotations.
- If the user asks coding questions inspired by the active paper, reason like a practical software engineer.
- If the current paper is relevant, anchor your answer to it directly rather than speaking abstractly.

Behavior:
- Be concise and concrete.
- Prefer actionable answers over generic background.
- When context is missing, say what is missing instead of pretending.
- Treat the active project as the user's working set and the active paper as the primary reference.
- When the user refers to "this paper", "the current page", highlights, notes, or PDF navigation, call `get_reader_context` first unless the answer is already obvious from the conversation.
- Use the PDF tools directly when navigation or temporary preview would help the user.
"""

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
}
