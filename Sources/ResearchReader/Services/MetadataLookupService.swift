import Foundation

enum MetadataLookupError: LocalizedError {
    case noSupportedIdentifier
    case unableToResolve

    var errorDescription: String? {
        switch self {
        case .noSupportedIdentifier:
            return "No DOI or arXiv identifier was found."
        case .unableToResolve:
            return "Metadata lookup returned no usable result."
        }
    }
}

struct MetadataLookupService {
    private let session: URLSession

    init(session: URLSession = .shared) {
        self.session = session
    }

    func recognizeMetadata(for pdfURL: URL) async throws -> ResolvedMetadata {
        let text = PDFTextExtractor.extractText(from: pdfURL)

        if let arxivID = IdentifierDetector.firstArxivID(in: text) {
            return try await lookup(identifier: arxivID)
        }

        if let doi = IdentifierDetector.firstDOI(in: text) {
            return try await lookup(identifier: doi)
        }

        throw MetadataLookupError.noSupportedIdentifier
    }

    func lookup(identifier: String) async throws -> ResolvedMetadata {
        let trimmed = identifier.trimmingCharacters(in: .whitespacesAndNewlines)

        if let arxivID = IdentifierDetector.normalizeArxivID(trimmed) {
            return try await fetchArxiv(id: arxivID)
        }

        if let doi = IdentifierDetector.normalizeDOI(trimmed) {
            return try await fetchCrossref(doi: doi)
        }

        throw MetadataLookupError.noSupportedIdentifier
    }

    private func fetchCrossref(doi: String) async throws -> ResolvedMetadata {
        let encoded = doi.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? doi
        guard let url = URL(string: "https://api.crossref.org/works/\(encoded)") else {
            throw MetadataLookupError.unableToResolve
        }

        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ResearchReader/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try HTTPResponseValidator.validate(response: response)

        let decoded = try JSONDecoder().decode(CrossrefEnvelope.self, from: data)
        let work = decoded.message
        let title = work.title.first?.cleanedInlineWhitespace ?? doi
        let authors = work.author.map(\.displayName).filter { !$0.isEmpty }
        let venue = work.containerTitle.first?.cleanedInlineWhitespace
        let year = work.publishedPrint?.year
            ?? work.publishedOnline?.year
            ?? work.created.year
        let abstractText = work.abstract?.strippingSimpleHTML.cleanedInlineWhitespace

        return ResolvedMetadata(
            title: title,
            authors: authors,
            venue: venue,
            year: year,
            doi: doi,
            arxivID: nil,
            abstractText: abstractText,
            source: "Crossref"
        )
    }

    private func fetchArxiv(id: String) async throws -> ResolvedMetadata {
        guard let encoded = id.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: "https://export.arxiv.org/api/query?id_list=\(encoded)") else {
            throw MetadataLookupError.unableToResolve
        }

        var request = URLRequest(url: url)
        request.setValue("ResearchReader/0.1", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        try HTTPResponseValidator.validate(response: response)

        let parser = ArxivFeedParser()
        let entry = try parser.parse(data: data)

        return ResolvedMetadata(
            title: entry.title.cleanedInlineWhitespace,
            authors: entry.authors,
            venue: "arXiv",
            year: entry.year,
            doi: nil,
            arxivID: id,
            abstractText: entry.summary.cleanedInlineWhitespace,
            source: "arXiv"
        )
    }
}

private enum IdentifierDetector {
    private static let doiPattern = #"\b10\.[0-9]{4,}\/[^\s&"']*[^\s&"'.,;:]"#
    private static let arxivPattern = #"(?:arxiv\s*:?\s*)([A-Za-z\-\.]+\/\d{7}|\d{4}\.\d{4,5})(v\d+)?"#

    static func firstDOI(in text: String) -> String? {
        firstMatch(in: text, pattern: doiPattern).flatMap(normalizeDOI)
    }

    static func firstArxivID(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: arxivPattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let idRange = Range(match.range(at: 1), in: text) else {
            return nil
        }
        let version: String
        if match.numberOfRanges > 2, let versionRange = Range(match.range(at: 2), in: text) {
            version = String(text[versionRange])
        } else {
            version = ""
        }
        return normalizeArxivID(String(text[idRange]) + version)
    }

    static func normalizeDOI(_ raw: String) -> String? {
        let trimmed = raw
            .replacingOccurrences(of: "https://doi.org/", with: "", options: [.caseInsensitive])
            .replacingOccurrences(of: "doi:", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.range(of: #"^10\.[0-9]{4,}/\S+$"#, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    static func normalizeArxivID(_ raw: String) -> String? {
        let trimmed = raw
            .replacingOccurrences(of: "arXiv:", with: "", options: [.caseInsensitive])
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.range(of: #"^([A-Za-z\-\.]+/\d{7}|\d{4}\.\d{4,5})(v\d+)?$"#, options: .regularExpression) != nil else {
            return nil
        }
        return trimmed
    }

    private static func firstMatch(in text: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsRange = NSRange(text.startIndex..<text.endIndex, in: text)
        guard let match = regex.firstMatch(in: text, options: [], range: nsRange),
              let range = Range(match.range(at: 0), in: text) else {
            return nil
        }
        return String(text[range])
    }
}

private enum HTTPResponseValidator {
    static func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw MetadataLookupError.unableToResolve
        }
    }
}

private struct CrossrefEnvelope: Decodable {
    let message: CrossrefWork
}

private struct CrossrefWork: Decodable {
    let title: [String]
    let author: [CrossrefAuthor]
    let containerTitle: [String]
    let abstract: String?
    let publishedPrint: CrossrefDateParts?
    let publishedOnline: CrossrefDateParts?
    let created: CrossrefDateParts

    enum CodingKeys: String, CodingKey {
        case title
        case author
        case abstract
        case created
        case containerTitle = "container-title"
        case publishedPrint = "published-print"
        case publishedOnline = "published-online"
    }
}

private struct CrossrefAuthor: Decodable {
    let given: String?
    let family: String?

    var displayName: String {
        [given, family]
            .compactMap { $0?.cleanedInlineWhitespace }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }
}

private struct CrossrefDateParts: Decodable {
    let dateParts: [[Int]]

    enum CodingKeys: String, CodingKey {
        case dateParts = "date-parts"
    }

    var year: Int? {
        dateParts.first?.first
    }
}

private final class ArxivFeedParser: NSObject, XMLParserDelegate {
    private struct Entry {
        var title = ""
        var summary = ""
        var authors: [String] = []
        var published = ""
    }

    private var currentElement = ""
    private var currentText = ""
    private var isInsideEntry = false
    private var isInsideAuthor = false
    private var currentEntry = Entry()
    private var parsedEntry: Entry?

    func parse(data: Data) throws -> (title: String, summary: String, authors: [String], year: Int?) {
        let parser = XMLParser(data: data)
        parser.delegate = self

        guard parser.parse() else {
            throw parser.parserError ?? MetadataLookupError.unableToResolve
        }

        guard let entry = parsedEntry else {
            throw MetadataLookupError.unableToResolve
        }

        let year = Int(entry.published.prefix(4))
        return (entry.title, entry.summary, entry.authors, year)
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String : String] = [:]) {
        currentElement = elementName
        currentText = ""

        if elementName == "entry" {
            isInsideEntry = true
            currentEntry = Entry()
        } else if elementName == "author" {
            isInsideAuthor = true
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        currentText += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let value = currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        defer {
            currentElement = ""
            currentText = ""
        }

        guard isInsideEntry else { return }

        switch elementName {
        case "title":
            if currentEntry.title.isEmpty, !value.isEmpty {
                currentEntry.title = value
            }
        case "summary":
            if !value.isEmpty {
                currentEntry.summary = value
            }
        case "published":
            if !value.isEmpty {
                currentEntry.published = value
            }
        case "name":
            if isInsideAuthor, !value.isEmpty {
                currentEntry.authors.append(value)
            }
        case "author":
            isInsideAuthor = false
        case "entry":
            parsedEntry = currentEntry
            isInsideEntry = false
        default:
            break
        }
    }
}

private extension String {
    var cleanedInlineWhitespace: String {
        replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var strippingSimpleHTML: String {
        replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
    }
}
