import AppKit
import SwiftUI

private enum NotebookTheme {
    static var editorFontSize: CGFloat {
        let size = UserDefaults.standard.double(forKey: "editorFontSize")
        return size > 0 ? CGFloat(size) : 16
    }

    static var editorFont: NSFont {
        NSFont.monospacedSystemFont(ofSize: editorFontSize, weight: .regular)
    }

    static let editorInsetX: CGFloat = 60
    static let editorInsetTop: CGFloat = 10
    static let lineSpacing: CGFloat = 8

    static let backgroundColor = NSColor(name: "notebookBackground") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
            : NSColor(red: 0.98, green: 0.98, blue: 0.98, alpha: 1)
    }

    static let textColor = NSColor(name: "notebookText") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.878, green: 0.878, blue: 0.878, alpha: 1)
            : NSColor(red: 0.133, green: 0.133, blue: 0.133, alpha: 1)
    }

    static let syntaxColor = NSColor(name: "notebookSyntax") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.45, green: 0.45, blue: 0.45, alpha: 1)
            : NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
    }

    static let headingColor = NSColor(name: "notebookHeading") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.95, green: 0.95, blue: 0.95, alpha: 1)
            : NSColor(red: 0.1, green: 0.1, blue: 0.1, alpha: 1)
    }

    static let boldColor = NSColor(name: "notebookBold") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1)
            : NSColor(red: 0.15, green: 0.15, blue: 0.15, alpha: 1)
    }

    static let italicColor = NSColor(name: "notebookItalic") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.8, green: 0.8, blue: 0.8, alpha: 1)
            : NSColor(red: 0.25, green: 0.25, blue: 0.25, alpha: 1)
    }

    static let codeColor = NSColor(name: "notebookCode") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.9, green: 0.45, blue: 0.45, alpha: 1)
            : NSColor(red: 0.75, green: 0.2, blue: 0.2, alpha: 1)
    }

    static let linkColor = NSColor(name: "notebookLink") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.4, green: 0.6, blue: 0.9, alpha: 1)
            : NSColor(red: 0.2, green: 0.4, blue: 0.7, alpha: 1)
    }

    static let blockquoteColor = NSColor(name: "notebookBlockquote") { appearance in
        appearance.isDarkMode
            ? NSColor(red: 0.6, green: 0.6, blue: 0.6, alpha: 1)
            : NSColor(red: 0.4, green: 0.4, blue: 0.4, alpha: 1)
    }

    static var backgroundColorSwiftUI: Color { Color(nsColor: backgroundColor) }
}

private extension NSAppearance {
    var isDarkMode: Bool {
        bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }
}

final class NotebookTextView: NSTextView {
    @objc func showFindPanel(_ sender: Any?) {
        let item = NSMenuItem()
        item.tag = Int(NSFindPanelAction.showFindPanel.rawValue)
        performFindPanelAction(item)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.contains(.command) else {
            return super.performKeyEquivalent(with: event)
        }
        if event.charactersIgnoringModifiers == "f" {
            showFindPanel(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

final class NotebookMarkdownSyntaxHighlighter: NSObject, NSTextStorageDelegate {
    private enum HighlightStyle {
        case heading
        case bold
        case italic
        case strikethrough
        case inlineCode
        case codeBlock
        case link
        case blockquote
        case listMarker
        case syntax
    }

    private static let patterns: [(NSRegularExpression, HighlightStyle)] = {
        var result: [(NSRegularExpression, HighlightStyle)] = []

        func add(_ pattern: String, _ style: HighlightStyle, options: NSRegularExpression.Options = []) {
            if let regex = try? NSRegularExpression(pattern: pattern, options: options) {
                result.append((regex, style))
            }
        }

        add("^(`{3,})(.*?)\\n([\\s\\S]*?)^\\1\\s*$", .codeBlock, options: .anchorsMatchLines)
        add("^(#{1,6}\\s+)(.+)$", .heading, options: .anchorsMatchLines)
        add("(\\*\\*|__)(.+?)(\\1)", .bold)
        add("(?<![\\w*])(\\*|_)(?!\\s)(.+?)(?<!\\s)\\1(?![\\w*])", .italic)
        add("(~~)(.+?)(~~)", .strikethrough)
        add("(`+)(.+?)(\\1)", .inlineCode)
        add("(\\[)(.+?)(\\]\\(.+?\\))", .link)
        add("^(>+\\s?)(.*)$", .blockquote, options: .anchorsMatchLines)
        add("^(\\s*[-*+]\\s)", .listMarker, options: .anchorsMatchLines)
        add("^(\\s*\\d+\\.\\s)", .listMarker, options: .anchorsMatchLines)
        add("^(\\s*[-*+]\\s\\[[ xX]\\]\\s)", .listMarker, options: .anchorsMatchLines)
        add("^([-*_]{3,})\\s*$", .syntax, options: .anchorsMatchLines)

        return result
    }()

    func textStorage(
        _ textStorage: NSTextStorage,
        didProcessEditing editedMask: NSTextStorageEditActions,
        range editedRange: NSRange,
        changeInLength delta: Int
    ) {
        guard editedMask.contains(.editedCharacters) else { return }
        highlightAll(textStorage)
    }

    func highlightAll(_ textStorage: NSTextStorage) {
        let fullRange = NSRange(location: 0, length: textStorage.length)
        let text = textStorage.string

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = NotebookTheme.lineSpacing

        textStorage.addAttributes([
            .font: NotebookTheme.editorFont,
            .foregroundColor: NotebookTheme.textColor,
            .paragraphStyle: paragraph,
        ], range: fullRange)

        var codeBlockRanges: [NSRange] = []

        for (regex, style) in Self.patterns {
            regex.enumerateMatches(in: text, range: fullRange) { match, _, _ in
                guard let match else { return }

                if style != .codeBlock {
                    let matchRange = match.range
                    if codeBlockRanges.contains(where: { NSIntersectionRange($0, matchRange).length > 0 }) {
                        return
                    }
                }

                switch style {
                case .heading:
                    if match.numberOfRanges >= 3 {
                        let syntaxRange = match.range(at: 1)
                        let contentRange = match.range(at: 2)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: syntaxRange)
                        textStorage.addAttributes([
                            .foregroundColor: NotebookTheme.headingColor,
                            .font: NSFont.monospacedSystemFont(ofSize: NotebookTheme.editorFontSize + 4, weight: .bold),
                        ], range: contentRange)
                    }

                case .bold:
                    if match.numberOfRanges >= 4 {
                        let openRange = match.range(at: 1)
                        let contentRange = match.range(at: 2)
                        let closeRange = match.range(at: 3)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: openRange)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: closeRange)
                        textStorage.addAttributes([
                            .foregroundColor: NotebookTheme.boldColor,
                            .font: NSFont.monospacedSystemFont(ofSize: NotebookTheme.editorFontSize, weight: .bold),
                        ], range: contentRange)
                    }

                case .italic:
                    if match.numberOfRanges >= 3 {
                        let syntaxRange = match.range(at: 1)
                        let contentRange = match.range(at: 2)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: syntaxRange)
                        let closingStart = match.range(at: 2).upperBound
                        let closingRange = NSRange(location: closingStart, length: match.range(at: 1).length)
                        if closingRange.upperBound <= textStorage.length {
                            textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: closingRange)
                        }
                        let italicFont = NSFontManager.shared.convert(NotebookTheme.editorFont, toHaveTrait: .italicFontMask)
                        textStorage.addAttributes([
                            .foregroundColor: NotebookTheme.italicColor,
                            .font: italicFont,
                        ], range: contentRange)
                    }

                case .strikethrough:
                    if match.numberOfRanges >= 4 {
                        let openRange = match.range(at: 1)
                        let contentRange = match.range(at: 2)
                        let closeRange = match.range(at: 3)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: openRange)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: closeRange)
                        textStorage.addAttributes([
                            .strikethroughStyle: NSUnderlineStyle.single.rawValue,
                            .foregroundColor: NotebookTheme.syntaxColor,
                        ], range: contentRange)
                    }

                case .inlineCode:
                    if match.numberOfRanges >= 4 {
                        let openRange = match.range(at: 1)
                        let contentRange = match.range(at: 2)
                        let closeRange = match.range(at: 3)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: openRange)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: closeRange)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.codeColor, range: contentRange)
                    }

                case .codeBlock:
                    codeBlockRanges.append(match.range)
                    textStorage.addAttribute(.foregroundColor, value: NotebookTheme.codeColor, range: match.range)
                    if match.numberOfRanges >= 2 {
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: match.range(at: 1))
                    }

                case .link:
                    if match.numberOfRanges >= 4 {
                        let bracketRange = match.range(at: 1)
                        let textRange = match.range(at: 2)
                        let urlPartRange = match.range(at: 3)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: bracketRange)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.linkColor, range: textRange)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: urlPartRange)
                    }

                case .blockquote:
                    if match.numberOfRanges >= 3 {
                        let markerRange = match.range(at: 1)
                        let contentRange = match.range(at: 2)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: markerRange)
                        textStorage.addAttribute(.foregroundColor, value: NotebookTheme.blockquoteColor, range: contentRange)
                    }

                case .listMarker:
                    textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: match.range)

                case .syntax:
                    textStorage.addAttribute(.foregroundColor, value: NotebookTheme.syntaxColor, range: match.range)
                }
            }
        }
    }
}

struct NotebookEditorView: NSViewRepresentable {
    @Binding var text: String

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        let textView = NotebookTextView()
        textView.isRichText = false
        textView.allowsUndo = true
        textView.usesFindPanel = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false

        textView.font = NotebookTheme.editorFont
        textView.textColor = NotebookTheme.textColor
        textView.backgroundColor = NotebookTheme.backgroundColor

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = NotebookTheme.lineSpacing
        textView.defaultParagraphStyle = paragraph
        textView.typingAttributes = [
            .font: NotebookTheme.editorFont,
            .foregroundColor: NotebookTheme.textColor,
            .paragraphStyle: paragraph,
        ]

        textView.textContainerInset = NSSize(width: NotebookTheme.editorInsetX, height: NotebookTheme.editorInsetTop)
        textView.textContainer?.lineFragmentPadding = 0

        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true

        textView.insertionPointColor = NotebookTheme.textColor
        textView.delegate = context.coordinator

        let highlighter = NotebookMarkdownSyntaxHighlighter()
        textView.textStorage?.delegate = highlighter
        context.coordinator.highlighter = highlighter

        textView.string = text
        if let storage = textView.textStorage {
            highlighter.highlightAll(storage)
        }

        scrollView.documentView = textView
        context.coordinator.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView else { return }

        textView.backgroundColor = NotebookTheme.backgroundColor
        textView.insertionPointColor = NotebookTheme.textColor

        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = NotebookTheme.lineSpacing
        textView.typingAttributes = [
            .font: NotebookTheme.editorFont,
            .foregroundColor: NotebookTheme.textColor,
            .paragraphStyle: paragraph,
        ]

        if let storage = textView.textStorage {
            context.coordinator.highlighter?.highlightAll(storage)
        }

        if !context.coordinator.isUpdating && textView.string != text {
            let selectedRanges = textView.selectedRanges
            textView.string = text
            textView.selectedRanges = selectedRanges
            if let storage = textView.textStorage {
                context.coordinator.highlighter?.highlightAll(storage)
            }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        let parent: NotebookEditorView
        var isUpdating = false
        var highlighter: NotebookMarkdownSyntaxHighlighter?
        weak var textView: NSTextView?

        init(_ parent: NotebookEditorView) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            isUpdating = true
            parent.text = textView.string
            isUpdating = false
        }
    }
}

extension NotebookEditorView {
    static var backgroundColor: Color {
        NotebookTheme.backgroundColorSwiftUI
    }
}
