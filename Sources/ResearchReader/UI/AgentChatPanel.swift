import AppKit
import SwiftUI

private enum ChatTheme {
    static let panelBackground = NSColor(name: "chatPanelBackground") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            : NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1)
    }

    static let panelBorder = NSColor(name: "chatPanelBorder") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.24, green: 0.24, blue: 0.24, alpha: 1)
            : NSColor(red: 0.86, green: 0.86, blue: 0.86, alpha: 1)
    }

    static let surfaceBackground = NSColor(name: "chatSurfaceBackground") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.135, green: 0.135, blue: 0.135, alpha: 1)
            : NSColor(red: 1, green: 1, blue: 1, alpha: 0.8)
    }

    static let assistantBubble = NSColor(name: "chatAssistantBubble") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.17, green: 0.17, blue: 0.17, alpha: 1)
            : NSColor(red: 1, green: 1, blue: 1, alpha: 0.9)
    }

    static let userBubble = NSColor(name: "chatUserBubble") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.23, green: 0.33, blue: 0.53, alpha: 0.35)
            : NSColor(red: 0.12, green: 0.33, blue: 0.78, alpha: 0.14)
    }

    static var panelBackgroundSwiftUI: Color { Color(nsColor: panelBackground) }
    static var panelBorderSwiftUI: Color { Color(nsColor: panelBorder) }
    static var surfaceBackgroundSwiftUI: Color { Color(nsColor: surfaceBackground) }
    static var assistantBubbleSwiftUI: Color { Color(nsColor: assistantBubble) }
    static var userBubbleSwiftUI: Color { Color(nsColor: userBubble) }
}

private extension NSAppearance {
    var isDarkMode: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

struct AgentChatPanel: View {
    @ObservedObject var chatManager: ResearchPiChatManager
    let context: AgentContextSnapshot
    let onClose: () -> Void

    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var panelSize = CGSize(width: 420, height: 560)

    private static let minPanelSize = CGSize(width: 340, height: 400)
    private static let maxPanelSize = CGSize(width: 640, height: 820)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            composer
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background(ChatTheme.panelBackgroundSwiftUI, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(ChatTheme.panelBorderSwiftUI, lineWidth: 1)
        )
        .overlay(resizeOverlay, alignment: .bottomTrailing)
        .shadow(color: .black.opacity(0.12), radius: 18, y: 8)
        .onAppear {
            isInputFocused = true
        }
    }

    private var resizeOverlay: some View {
        ResizableDragHandle { delta, _ in
            adjustPanelSize(by: delta)
        }
        .padding(12)
    }

    private func adjustPanelSize(by delta: CGSize) {
        guard delta != .zero else { return }
        var nextSize = panelSize
        nextSize.width += delta.width
        nextSize.height += delta.height
        panelSize = clamped(nextSize)
    }

    private func clamped(_ size: CGSize) -> CGSize {
        CGSize(
            width: min(Self.maxPanelSize.width, max(Self.minPanelSize.width, size.width)),
            height: min(Self.maxPanelSize.height, max(Self.minPanelSize.height, size.height))
        )
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("PI NOTEBOOK ASSISTANT")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                Spacer()
                if !chatManager.messages.isEmpty {
                    Button("Clear") {
                        chatManager.clearConversation()
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                }
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                contextRow(title: "Project", value: context.projectName ?? "None")
                contextRow(title: "Notebook", value: notebookStatusText)
                contextRow(title: "Paper", value: context.paper?.title ?? "None")
            }

            if !chatManager.isPiAvailable || !chatManager.isExtensionAvailable {
                Text("Pi chat needs both a local `pi` binary and the app-local ResearchReader extension.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chatManager.messages.isEmpty {
                        Text("Ask about the active paper, compare papers, draft implementation plans, or update your notebook.")
                            .font(.system(size: 14, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(16)
                    } else {
                        ForEach(chatManager.messages) { message in
                            AgentMessageBubble(message: message)
                                .id(message.id)
                        }
                    }

                    if chatManager.isProcessing {
                        if !chatManager.streamingText.isEmpty {
                            AgentStreamingBubble(
                                text: chatManager.streamingText,
                                activityStatus: chatManager.activityStatus
                            )
                        } else {
                            HStack(spacing: 8) {
                                ProgressView()
                                    .controlSize(.small)
                                Text(chatManager.activityStatus.isEmpty ? "Pi is thinking…" : chatManager.activityStatus)
                                    .font(.system(size: 12, design: .monospaced))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal, 16)
                        }
                        Color.clear.frame(height: 1).id("streaming-bottom")
                    }
                }
                .padding(.vertical, 14)
            }
            .background(ChatTheme.surfaceBackgroundSwiftUI)
            .onChange(of: chatManager.messages.count) { _, _ in
                if let last = chatManager.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
            .onChange(of: chatManager.streamingText) { _, _ in
                if chatManager.isProcessing {
                    proxy.scrollTo("streaming-bottom", anchor: .bottom)
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask Pi about this paper or project…", text: $inputText, axis: .vertical)
                .textFieldStyle(.plain)
                .focused($isInputFocused)
                .lineLimit(1...4)
                .font(.system(size: 14, design: .monospaced))
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .fill(ChatTheme.surfaceBackgroundSwiftUI)
                        .overlay(
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .stroke(ChatTheme.panelBorderSwiftUI.opacity(0.85), lineWidth: 1)
                        )
                )
                .onSubmit(sendMessage)

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatManager.isProcessing)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatManager.send(text, context: context)
        inputText = ""
    }

    private var notebookStatusText: String {
        guard let notebook = context.notebook else {
            return "None"
        }

        let count = notebook.markdown.trimmingCharacters(in: .whitespacesAndNewlines).count
        if count == 0 {
            return "\(notebook.projectName) notebook"
        }
        return "\(notebook.projectName) notebook, \(count) chars"
    }

    private func contextRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 13, design: .monospaced))
                .lineLimit(2)
        }
    }
}

private struct AgentStreamingBubble: View {
    let text: String
    var activityStatus: String = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("PI")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.secondary)
                ProgressView()
                    .controlSize(.mini)
                if !activityStatus.isEmpty {
                    Text(activityStatus)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.tertiary)
                }
            }

            Text(text)
                .font(.system(size: 14, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(ChatTheme.assistantBubbleSwiftUI)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
    }
}

private struct AgentMessageBubble: View {
    let message: AgentChatMessage

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
            Text(message.isUser ? "YOU" : "PI")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(.secondary)

            Text(renderedText)
                .font(.system(size: 14, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(message.isUser ? ChatTheme.userBubbleSwiftUI : ChatTheme.assistantBubbleSwiftUI)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .frame(maxWidth: .infinity, alignment: message.isUser ? .trailing : .leading)
        .padding(.horizontal, 16)
    }

    private var renderedText: AttributedString {
        guard !message.isUser else {
            return AttributedString(message.text)
        }

        do {
            var options = AttributedString.MarkdownParsingOptions()
            options.interpretedSyntax = .inlineOnlyPreservingWhitespace
            var attributed = try AttributedString(markdown: message.text, options: options)

            let urlPattern = #"https?://[^\s\)\]\>]+"#
            if let regex = try? NSRegularExpression(pattern: urlPattern) {
                let nsString = message.text as NSString
                let matches = regex.matches(in: message.text, range: NSRange(location: 0, length: nsString.length))

                for match in matches {
                    guard let textRange = Range(match.range, in: message.text),
                          let url = URL(string: String(message.text[textRange])),
                          let attrRange = attributed.range(of: String(message.text[textRange])) else {
                        continue
                    }
                    attributed[attrRange].link = url
                    attributed[attrRange].foregroundColor = .accentColor
                }
            }

            return attributed
        } catch {
            return AttributedString(message.text)
        }
    }
}
