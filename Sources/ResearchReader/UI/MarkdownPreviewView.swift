import AppKit
import SwiftUI

struct MarkdownPreviewView: NSViewRepresentable {
    let markdown: String

    func makeNSView(context: Context) -> NSScrollView {
        let textView = NSTextView()
        textView.isEditable = false
        textView.isRichText = true
        textView.importsGraphics = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 18, height: 18)
        textView.textContainer?.widthTracksTextView = true
        textView.linkTextAttributes = [
            .foregroundColor: NSColor.linkColor,
            .underlineStyle: NSUnderlineStyle.single.rawValue,
        ]

        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = textView

        update(textView: textView)
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }
        update(textView: textView)
    }

    private func update(textView: NSTextView) {
        let attributed = renderedMarkdown(from: markdown)
        textView.textStorage?.setAttributedString(attributed)
    }

    private func renderedMarkdown(from markdown: String) -> NSAttributedString {
        let source = markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "_Notebook preview will appear here._" : markdown

        if let attributed = try? AttributedString(
            markdown: source,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .full)
        ) {
            let mutable = NSMutableAttributedString(attributedString: NSAttributedString(attributed))
            let fullRange = NSRange(location: 0, length: mutable.length)
            mutable.addAttributes([
                NSAttributedString.Key.font: NSFont.systemFont(ofSize: 15),
                NSAttributedString.Key.foregroundColor: NSColor.labelColor,
            ], range: fullRange)
            return mutable
        }

        return NSAttributedString(string: source, attributes: [
            NSAttributedString.Key.font: NSFont.systemFont(ofSize: 15),
            NSAttributedString.Key.foregroundColor: NSColor.labelColor,
        ])
    }
}
