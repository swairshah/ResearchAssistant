import Foundation
import PDFKit

enum PDFTextExtractor {
    static func extractText(from url: URL, maxPages: Int = 5) -> String {
        guard let document = PDFDocument(url: url) else {
            return ""
        }

        let pageCount = min(document.pageCount, maxPages)
        var textChunks: [String] = []
        textChunks.reserveCapacity(pageCount)

        for index in 0..<pageCount {
            guard let page = document.page(at: index) else { continue }
            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !pageText.isEmpty {
                textChunks.append(pageText)
            }
        }

        return textChunks.joined(separator: "\n\n")
    }

    static func suggestedTitle(from url: URL) -> String {
        guard let document = PDFDocument(url: url) else {
            return url.deletingPathExtension().lastPathComponent
        }

        if let title = document.documentAttributes?[PDFDocumentAttribute.titleAttribute] as? String {
            let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return trimmed
            }
        }

        return url.deletingPathExtension().lastPathComponent
    }
}
