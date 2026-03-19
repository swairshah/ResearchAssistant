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
        view.onRemoveHighlightRequest = { [weak readerController] annotation, page, pointOnPage in
            Task { @MainActor in
                readerController?.removeHighlightsInSelection(
                    from: nil,
                    annotation: annotation,
                    hitPage: page,
                    hitPointOnPage: pointOnPage
                )
            }
        }
        view.onQuickHighlightRequest = { [weak readerController] selection in
            Task { @MainActor in
                readerController?.highlightSelection(from: selection)
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
        nsView.onRemoveHighlightRequest = { [weak readerController] annotation, page, pointOnPage in
            Task { @MainActor in
                readerController?.removeHighlightsInSelection(
                    from: nil,
                    annotation: annotation,
                    hitPage: page,
                    hitPointOnPage: pointOnPage
                )
            }
        }
        nsView.onQuickHighlightRequest = { [weak readerController] selection in
            Task { @MainActor in
                readerController?.highlightSelection(from: selection)
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
    var onRemoveHighlightRequest: ((PDFAnnotation?, PDFPage?, CGPoint?) -> Void)?
    var onQuickHighlightRequest: ((PDFSelection?) -> Void)?

    private var hideQuickHighlightWorkItem: DispatchWorkItem?
    private var pendingQuickHighlightSelection: PDFSelection?
    private var pendingRemoveHighlightAnnotation: PDFAnnotation?
    private var pendingRemoveHighlightPage: PDFPage?
    private var pendingRemoveHighlightPointOnPage: CGPoint?

    private lazy var quickHighlightPopover: NSPopover = {
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = true
        popover.contentViewController = QuickHighlightPopoverController { [weak self] in
            guard let self else { return }
            self.onQuickHighlightRequest?(self.pendingQuickHighlightSelection)
            self.hideQuickHighlightPopover()
        }
        return popover
    }()

    override func mouseDown(with event: NSEvent) {
        hideQuickHighlightPopover()
        super.mouseDown(with: event)
        reportAnnotationHit(from: event)
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        reportAnnotationHit(from: event)
        maybeShowQuickHighlightPopover(from: event)
    }

    override func rightMouseDown(with event: NSEvent) {
        super.rightMouseDown(with: event)
        reportAnnotationHit(from: event)
    }

    override func rightMouseUp(with event: NSEvent) {
        super.rightMouseUp(with: event)
        reportAnnotationHit(from: event)
        maybeShowQuickHighlightPopover(from: event)
    }

    override func otherMouseDown(with event: NSEvent) {
        hideQuickHighlightPopover()
        super.otherMouseDown(with: event)
        reportAnnotationHit(from: event)
    }

    override func scrollWheel(with event: NSEvent) {
        hideQuickHighlightPopover()
        super.scrollWheel(with: event)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let pointInView = convert(event.locationInWindow, from: nil)
        let page = page(for: pointInView, nearest: true)
        let pointOnPage = page.map { convert(pointInView, to: $0) }

        let hit: PDFAnnotation?
        if let page, let pointOnPage {
            hit = page.annotation(at: pointOnPage) ?? highlightAnnotation(on: page, at: pointOnPage)
        } else {
            hit = nil
        }

        onAnnotationHit?(hit)
        pendingRemoveHighlightAnnotation = hit
        pendingRemoveHighlightPage = page
        pendingRemoveHighlightPointOnPage = pointOnPage

        let systemMenu = super.menu(for: event)
        let menu = systemMenu ?? NSMenu(title: "Context")

        let isHighlight = ((hit?.type ?? "").lowercased().contains("highlight"))
        guard isHighlight else { return systemMenu }
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
        onRemoveHighlightRequest?(
            pendingRemoveHighlightAnnotation,
            pendingRemoveHighlightPage,
            pendingRemoveHighlightPointOnPage
        )
    }

    private var hasTextSelection: Bool {
        guard let text = currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines) else {
            return false
        }
        return !text.isEmpty
    }

    private func maybeShowQuickHighlightPopover(from event: NSEvent) {
        guard hasTextSelection else {
            hideQuickHighlightPopover()
            return
        }

        let capturedSelection: PDFSelection?
        if let selection = currentSelection {
            capturedSelection = (selection.copy() as? PDFSelection) ?? selection
        } else {
            capturedSelection = nil
        }

        let point = convert(event.locationInWindow, from: nil)
        let anchorRect = NSRect(x: point.x, y: point.y, width: 1, height: 1)

        // Close any existing popover without clearing the just-captured selection.
        if quickHighlightPopover.isShown {
            quickHighlightPopover.performClose(nil)
        }

        pendingQuickHighlightSelection = capturedSelection
        quickHighlightPopover.show(relativeTo: anchorRect, of: self, preferredEdge: .maxY)

        hideQuickHighlightWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.hideQuickHighlightPopover()
        }
        hideQuickHighlightWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }

    private func hideQuickHighlightPopover() {
        hideQuickHighlightWorkItem?.cancel()
        hideQuickHighlightWorkItem = nil
        pendingQuickHighlightSelection = nil
        if quickHighlightPopover.isShown {
            quickHighlightPopover.performClose(nil)
        }
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
        return page.annotation(at: pointOnPage) ?? highlightAnnotation(on: page, at: pointOnPage)
    }

    private func highlightAnnotation(on page: PDFPage, at pointOnPage: CGPoint) -> PDFAnnotation? {
        for annotation in page.annotations.reversed() {
            let isHighlight = ((annotation.type ?? "").lowercased().contains("highlight"))
            guard isHighlight else { continue }

            if annotation.bounds.insetBy(dx: -2, dy: -2).contains(pointOnPage) {
                return annotation
            }
        }
        return nil
    }
}

private final class QuickHighlightPopoverController: NSViewController {
    private let onTap: () -> Void

    init(onTap: @escaping () -> Void) {
        self.onTap = onTap
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 110, height: 38))
        let button = NSButton(title: "Highlight", target: self, action: #selector(handleTap(_:)))
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.frame = NSRect(x: 9, y: 7, width: 92, height: 24)
        root.addSubview(button)
        view = root
    }

    @objc private func handleTap(_ sender: Any?) {
        onTap()
    }
}
