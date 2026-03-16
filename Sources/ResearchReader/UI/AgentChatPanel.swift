import SwiftUI

struct AgentChatPanel: View {
    @ObservedObject var chatManager: ResearchPiChatManager
    let context: AgentContextSnapshot
    let onClose: () -> Void

    @State private var inputText = ""
    @FocusState private var isInputFocused: Bool
    @State private var panelSize = CGSize(width: 380, height: 520)

    private static let minPanelSize = CGSize(width: 320, height: 360)
    private static let maxPanelSize = CGSize(width: 540, height: 760)

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            messages
            Divider()
            composer
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .stroke(Color.black.opacity(0.08))
        )
        .overlay(resizeOverlay, alignment: .bottomTrailing)
        .shadow(color: .black.opacity(0.14), radius: 20, y: 8)
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
                Label("Pi Agent", systemImage: "sparkles.rectangle.stack")
                    .font(.headline)
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
                if let paper = context.paper {
                    contextRow(title: "Paper", value: paper.title)
                } else {
                    contextRow(title: "Paper", value: "None")
                }
            }

            if !chatManager.isPiAvailable || !chatManager.isExtensionAvailable {
                Text("Pi chat needs both a local `pi` binary and the app-local ResearchReader extension.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .padding(16)
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if chatManager.messages.isEmpty {
                        Text("Ask about the active paper, request a summary, compare papers, or turn ideas into implementation steps.")
                            .font(.callout)
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
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Pi is thinking…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .padding(.horizontal, 16)
                    }
                }
                .padding(.vertical, 16)
            }
            .onChange(of: chatManager.messages.count) { _, _ in
                if let last = chatManager.messages.last {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var composer: some View {
        HStack(spacing: 10) {
            TextField("Ask Pi about this paper or project…", text: $inputText, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .focused($isInputFocused)
                .lineLimit(1...4)
                .onSubmit(sendMessage)

            Button(action: sendMessage) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.title2)
            }
            .buttonStyle(.plain)
            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chatManager.isProcessing)
        }
        .padding(16)
    }

    private func sendMessage() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        chatManager.send(text, context: context)
        inputText = ""
    }

    private func contextRow(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout)
                .lineLimit(2)
        }
    }
}

private struct AgentMessageBubble: View {
    let message: AgentChatMessage

    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 6) {
            Text(message.isUser ? "You" : "Pi")
                .font(.caption)
                .foregroundStyle(.secondary)

            Text(renderedText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(message.isUser ? Color.accentColor.opacity(0.16) : Color.black.opacity(0.05))
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
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
