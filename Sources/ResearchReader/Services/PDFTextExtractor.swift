import Foundation
import PDFKit

enum PDFTextExtractor {
    static func extractText(
        from url: URL,
        maxPages: Int = 5,
        startPage: Int? = nil,
        endPage: Int? = nil
    ) -> String {
        guard let document = PDFDocument(url: url), document.pageCount > 0 else {
            return ""
        }

        let lowerBound = max(1, startPage ?? 1)
        let upperInput = endPage ?? document.pageCount
        let upperBound = min(document.pageCount, max(lowerBound, upperInput))

        var textChunks: [String] = []
        textChunks.reserveCapacity(min(maxPages, upperBound - lowerBound + 1))

        var processed = 0
        for pageNumber in lowerBound...upperBound {
            if processed >= maxPages { break }
            guard let page = document.page(at: pageNumber - 1) else { continue }
            let pageText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !pageText.isEmpty {
                textChunks.append("[Page \(pageNumber)]\n\(pageText)")
                processed += 1
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
