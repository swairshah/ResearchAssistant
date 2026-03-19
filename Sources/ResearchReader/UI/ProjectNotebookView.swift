import AppKit
import SwiftUI

struct ProjectNotebookView: View {
    let project: Project
    @Binding var markdown: String
    let lastSavedAt: Date?

    private var wordCount: Int {
        markdown.split { $0.isWhitespace || $0.isNewline }.count
    }

    private var characterCount: Int {
        markdown.count
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            NotebookEditorView(text: $markdown)
                .frame(minWidth: 320, idealWidth: 420, maxWidth: .infinity, maxHeight: .infinity)
            footer
        }
        .background(NotebookEditorView.backgroundColor)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Notebook")
                        .font(.headline)
                    Text(project.name)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    NSApp.sendAction(#selector(NotebookTextView.showFindPanel(_:)), to: nil, from: nil)
                } label: {
                    Image(systemName: "magnifyingglass")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Find (⌘F)")
            }

            HStack {
                if let lastSavedAt {
                    Text("Saved \(lastSavedAt, format: .relative(presentation: .named))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not saved yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text("\(wordCount) words")
            Text("\(characterCount) characters")
            Spacer()
        }
        .font(.caption)
        .foregroundStyle(.tertiary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
        .background(NotebookEditorView.backgroundColor)
    }
}
