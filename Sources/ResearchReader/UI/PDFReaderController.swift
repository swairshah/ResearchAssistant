import AppKit
import PDFKit
import SwiftUI

@MainActor
final class PDFReaderController: ObservableObject {
    @Published private(set) var hasSelection = false
    @Published private(set) var isDocumentLoaded = false
    @Published private(set) var currentPageNumber = 1
    @Published private(set) var pageCount = 0
    @Published private(set) var annotationSummaries: [PDFAnnotationSummary] = []

    private weak var pdfView: PDFView?
    private var selectionObserver: NSObjectProtocol?
    private var pageChangeObserver: NSObjectProtocol?
    private var annotationRefMap: [String: (pageIndex: Int, bounds: CGRect)] = [:]
    private var previewAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []
    private var previewClearTask: Task<Void, Never>?

    private let previewUserName = "ResearchReaderPreview"

    func attach(to view: PDFView) {
        if pdfView === view {
            updateState()
            return
        }

        if let observer = selectionObserver {
            NotificationCenter.default.removeObserver(observer)
            selectionObserver = nil
        }
        if let observer = pageChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            pageChangeObserver = nil
        }

        pdfView = view
        selectionObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewSelectionChanged,
            object: view,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateState()
            }
        }
        pageChangeObserver = NotificationCenter.default.addObserver(
            forName: .PDFViewPageChanged,
            object: view,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.updateState()
            }
        }
        updateState()
    }

    func highlightSelection() {
        guard let pdfView,
              let selection = pdfView.currentSelection,
              let selectedText = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedText.isEmpty else {
            return
        }

        clearPreview()

        for lineSelection in selection.selectionsByLine() {
            for page in lineSelection.pages {
                let bounds = lineSelection.bounds(for: page).insetBy(dx: -0.5, dy: 0.8)
                let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
                annotation.color = NSColor.systemYellow.withAlphaComponent(0.45)
                page.addAnnotation(annotation)
            }
        }

        persistChanges()
        updateState()
    }

    func addNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let pdfView else {
            return
        }

        clearPreview()

        let notePage: PDFPage
        let noteBounds: CGRect

        if let selection = pdfView.currentSelection,
           let page = selection.pages.first {
            let selectionBounds = selection.bounds(for: page)
            notePage = page
            noteBounds = CGRect(x: selectionBounds.maxX + 6, y: selectionBounds.maxY - 18, width: 22, height: 22)
        } else if let page = pdfView.currentPage {
            let visibleBounds = pdfView.convert(pdfView.bounds, to: page)
            notePage = page
            noteBounds = CGRect(x: visibleBounds.midX, y: visibleBounds.midY, width: 22, height: 22)
        } else {
            return
        }

        let annotation = PDFAnnotation(bounds: noteBounds, forType: .text, withProperties: nil)
        annotation.contents = trimmed
        annotation.color = NSColor.systemYellow
        annotation.userName = NSFullUserName()
        notePage.addAnnotation(annotation)

        persistChanges()
        updateState()
    }

    func goToPage(_ pageNumber: Int) {
        guard let pdfView,
              let document = pdfView.document,
              document.pageCount > 0 else {
            return
        }

        let clamped = min(max(1, pageNumber), document.pageCount)
        guard let page = document.page(at: clamped - 1) else { return }
        pdfView.go(to: page)
        updateState()
    }

    func focusAnnotation(id: String) {
        guard let ref = annotationRefMap[id],
              let pdfView,
              let page = pdfView.document?.page(at: ref.pageIndex) else {
            return
        }

        let expanded = ref.bounds.insetBy(dx: -28, dy: -28)
        pdfView.go(to: expanded, on: page)
        updateState()
    }

    func previewAnnotation(id: String) {
        guard let ref = annotationRefMap[id],
              let page = pdfView?.document?.page(at: ref.pageIndex) else {
            return
        }

        clearPreview()
        addPreviewHighlight(on: page, bounds: ref.bounds)
        pdfView?.go(to: ref.bounds.insetBy(dx: -28, dy: -28), on: page)
        schedulePreviewClear()
        updateState()
    }

    func previewText(page pageNumber: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let pdfView,
              let document = pdfView.document,
              let page = document.page(at: max(0, pageNumber - 1)) else {
            return
        }

        clearPreview()

        if let selection = selection(on: page, matching: trimmed) {
            for lineSelection in selection.selectionsByLine() {
                for selectionPage in lineSelection.pages {
                    let bounds = lineSelection.bounds(for: selectionPage).insetBy(dx: -0.5, dy: 0.8)
                    addPreviewHighlight(on: selectionPage, bounds: bounds)
                }
            }
            let firstBounds = selection.bounds(for: page)
            pdfView.go(to: firstBounds.insetBy(dx: -28, dy: -28), on: page)
            schedulePreviewClear()
            updateState()
        }
    }

    func clearPreview() {
        previewClearTask?.cancel()
        previewClearTask = nil

        guard !previewAnnotations.isEmpty else { return }
        for entry in previewAnnotations {
            entry.page.removeAnnotation(entry.annotation)
        }
        previewAnnotations.removeAll()
        updateState()
    }

    private func updateState() {
        isDocumentLoaded = pdfView?.document != nil
        hasSelection = !(pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        pageCount = pdfView?.document?.pageCount ?? 0
        if let document = pdfView?.document,
           let page = pdfView?.currentPage {
            currentPageNumber = document.index(for: page) + 1
        } else {
            currentPageNumber = 1
        }
        refreshAnnotations()
    }

    private func persistChanges() {
        guard let document = pdfView?.document,
              let url = document.documentURL else {
            return
        }

        _ = document.write(to: url)
    }

    private func refreshAnnotations() {
        guard let document = pdfView?.document else {
            annotationSummaries = []
            annotationRefMap = [:]
            return
        }

        var summaries: [PDFAnnotationSummary] = []
        var refs: [String: (pageIndex: Int, bounds: CGRect)] = [:]

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            var visibleAnnotationCount = 0
            for annotation in page.annotations {
                guard annotation.userName != previewUserName else { continue }
                guard let summary = makeAnnotationSummary(
                    annotation: annotation,
                    page: page,
                    pageIndex: pageIndex,
                    ordinal: visibleAnnotationCount + 1
                ) else {
                    continue
                }

                visibleAnnotationCount += 1
                summaries.append(summary)
                refs[summary.id] = (pageIndex: pageIndex, bounds: annotation.bounds)
            }
        }

        annotationSummaries = summaries
        annotationRefMap = refs
    }

    private func makeAnnotationSummary(annotation: PDFAnnotation, page: PDFPage, pageIndex: Int, ordinal: Int) -> PDFAnnotationSummary? {
        let subtype = annotation.type
        let id = "p\(pageIndex + 1)-a\(ordinal)"

        if subtype == PDFAnnotationSubtype.highlight.rawValue {
            let extractedText = page.selection(for: annotation.bounds)?
                .string?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return PDFAnnotationSummary(
                id: id,
                kind: .highlight,
                page: pageIndex + 1,
                text: extractedText?.isEmpty == true ? nil : extractedText,
                note: annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            )
        }

        if subtype == PDFAnnotationSubtype.text.rawValue {
            return PDFAnnotationSummary(
                id: id,
                kind: .note,
                page: pageIndex + 1,
                text: nil,
                note: annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            )
        }

        return nil
    }

    private func addPreviewHighlight(on page: PDFPage, bounds: CGRect) {
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = NSColor.systemCyan.withAlphaComponent(0.55)
        annotation.userName = previewUserName
        page.addAnnotation(annotation)
        previewAnnotations.append((page: page, annotation: annotation))
    }

    private func schedulePreviewClear() {
        previewClearTask?.cancel()
        previewClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.clearPreview()
        }
    }

    private func selection(on page: PDFPage, matching text: String) -> PDFSelection? {
        guard let pageText = page.string else { return nil }
        let nsText = pageText as NSString
        let searchRange = NSRange(location: 0, length: nsText.length)
        let foundRange = nsText.range(
            of: text,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchRange
        )

        guard foundRange.location != NSNotFound else { return nil }
        return page.selection(for: foundRange)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
