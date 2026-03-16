import PDFKit
import SwiftUI

struct PDFDocumentView: NSViewRepresentable {
    let url: URL
    var readerController: PDFReaderController?

    func makeNSView(context: Context) -> PDFView {
        let view = PDFView()
        view.autoScales = true
        view.displayMode = .singlePageContinuous
        view.displaysPageBreaks = true
        view.backgroundColor = .windowBackgroundColor
        view.displaysAsBook = false
        readerController?.attach(to: view)
        return view
    }

    func updateNSView(_ nsView: PDFView, context: Context) {
        if nsView.document?.documentURL != url {
            nsView.document = PDFDocument(url: url)
        }
        readerController?.attach(to: nsView)
    }

    static func dismantleNSView(_ nsView: PDFView, coordinator: ()) {
        // no-op
    }
}
