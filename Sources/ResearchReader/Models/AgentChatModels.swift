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
    let projectPapers: [ProjectPaperSummary]
    let paper: Paper?
    let pdfURL: URL?
    let currentPage: Int?
    let pageCount: Int?
    let currentSelection: PDFSelectionSummary?
    let annotations: [PDFAnnotationSummary]
    let notebook: ProjectNotebookSnapshot?
}

struct PDFSelectionSummary: Hashable {
    let page: Int
    let text: String
}

struct ProjectPaperSummary: Codable, Hashable, Identifiable {
    let id: UUID
    let title: String
    let authors: [String]
    let year: Int?
    let doi: String?
    let arxivID: String?

    init(paper: Paper) {
        self.id = paper.id
        self.title = paper.title
        self.authors = paper.authors
        self.year = paper.year
        self.doi = paper.doi
        self.arxivID = paper.arxivID
    }
}

struct ProjectNotebookSnapshot: Codable, Hashable {
    let projectID: UUID
    let projectName: String
    let filePath: String
    let markdown: String
    let updatedAt: Date?
    let papers: [ProjectPaperSummary]
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
    case replaceProjectNotebook(String)
    case appendProjectNotebook(String)
}
