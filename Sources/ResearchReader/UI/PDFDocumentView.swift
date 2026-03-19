import Foundation
import PDFKit
import SwiftUI

struct PDFDocumentView: NSViewRepresentable {
    let url: URL
    let paperID: UUID?
    var readerController: PDFReaderController?

    func makeNSView(context: Context) -> ReaderPDFView {
        let view = ReaderPDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        view.displaysAsBook = false
        view.onAnnotationHit = { [weak readerController] annotation in
            Task { @MainActor in
                readerController?.registerAnnotationHit(annotation)
            }
        }
        view.onRemoveHighlightRequest = { [weak readerController] in
            Task { @MainActor in
                readerController?.removeHighlightsInSelection()
            }
        }
        readerController?.attach(to: view, paperID: paperID)
        return view
    }

    func updateNSView(_ nsView: ReaderPDFView, context: Context) {
        nsView.onAnnotationHit = { [weak readerController] annotation in
            Task { @MainActor in
                readerController?.registerAnnotationHit(annotation)
            }
        }
        nsView.onRemoveHighlightRequest = { [weak readerController] in
            Task { @MainActor in
                readerController?.removeHighlightsInSelection()
            }
        }
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
        readerController?.attach(to: nsView, paperID: paperID)
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: ()) {
        // no-op
    }
}

final class ReaderPDFView: PDFView {
    var onAnnotationHit: ((PDFAnnotation?) -> Void)?
    var onRemoveHighlightRequest: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        super.mouseDown(with: event)
        reportAnnotationHit(from: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        reportAnnotationHit(from: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        super.otherMouseDown(with: event)
        reportAnnotationHit(from: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let hit = annotationAt(event: event)
        onAnnotationHit?(hit)

        guard let menu = super.menu(for: event) else { return nil }

        let isHighlight = ((hit?.type ?? "").lowercased().contains("highlight"))
        guard isHighlight else { return menu }

        var patched = false
        for item in menu.items {
            let t = item.title.lowercased()
            if t.contains("remove") && t.contains("highlight") {
                item.target = self
                item.action = #selector(handleRemoveHighlightMenuAction(_:))
                item.isEnabled = true
                patched = true
            }
        }

        if !patched {
            let removeItem = NSMenuItem(title: "Remove Highlight", action: #selector(handleRemoveHighlightMenuAction(_:)), keyEquivalent: "")
            removeItem.target = self
            menu.insertItem(removeItem, at: 0)
        }

        return menu
    }

    @objc private func handleRemoveHighlightMenuAction(_ sender: Any?) {
        onRemoveHighlightRequest?()
    }

    private func reportAnnotationHit(from event: NSEvent) {
        onAnnotationHit?(annotationAt(event: event))
    }

    private func annotationAt(event: NSEvent) -> PDFAnnotation? {
        let pointInView = convert(event.locationInWindow, from: nil)
        guard let page = page(for: pointInView, nearest: true) else {
            return nil
        }
        let pointOnPage = convert(pointInView, to: page)
        return page.annotation(at: pointOnPage)
    }
}
