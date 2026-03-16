import Foundation

struct AgentChatMessage: Codable, Identifiable, Hashable {
    let id: UUID
    let isUser: Bool
    let text: String
    let createdAt: Date
}

struct AgentContextSnapshot {
    let projectName: String?
    let projectPaperCount: Int
    let paper: Paper?
    let pdfURL: URL?
    let currentPage: Int?
    let pageCount: Int?
    let annotations: [PDFAnnotationSummary]
}

struct PDFAnnotationSummary: Hashable {
    let id: String
    let kind: Kind
    let page: Int
    let text: String?
    let note: String?

    enum Kind: String, Hashable {
        case highlight
        case note
    }
}

enum AgentUICommand: Equatable {
    case goToPage(Int)
    case focusAnnotation(String)
    case previewAnnotation(String)
    case previewText(page: Int, text: String)
    case clearPreview
}
