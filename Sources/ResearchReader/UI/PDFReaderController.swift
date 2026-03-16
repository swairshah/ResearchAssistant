import AppKit
import PDFKit
import SwiftUI

@MainActor
final class PDFReaderController: ObservableObject {
    @Published private(set) var hasSelection = false
    @Published private(set) var isDocumentLoaded = false

    private weak var pdfView: PDFView?
    private var selectionObserver: NSObjectProtocol?

    func attach(to view: PDFView) {
        if pdfView === view {
            updateState()
            return
        }

        if let observer = selectionObserver {
            NotificationCenter.default.removeObserver(observer)
            selectionObserver = nil
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
        updateState()
    }

    func highlightSelection() {
        guard let pdfView,
              let selection = pdfView.currentSelection,
              let selectedText = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedText.isEmpty else {
            return
        }

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

    private func updateState() {
        isDocumentLoaded = pdfView?.document != nil
        hasSelection = !(pdfView?.currentSelection?.string?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
    }

    private func persistChanges() {
        guard let document = pdfView?.document,
              let url = document.documentURL else {
            return
        }

        _ = document.write(to: url)
    }
}
