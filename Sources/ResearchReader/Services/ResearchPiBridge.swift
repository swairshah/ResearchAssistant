import Foundation

@MainActor
final class ResearchPiBridge: ObservableObject {
    private let paths: AppPaths
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var pollTask: Task<Void, Never>?
    private var commandHandler: ((AgentUICommand) -> String)?

    init() {
        do {
            self.paths = try AppPaths.make()
        } catch {
            fatalError("Unable to initialize Pi bridge: \(error.localizedDescription)")
        }
    }

    deinit {
        pollTask?.cancel()
    }

    func start(commandHandler: @escaping (AgentUICommand) -> String) {
        self.commandHandler = commandHandler
        guard pollTask == nil else { return }

        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.processPendingCommands()
                try? await Task.sleep(nanoseconds: 300_000_000)
            }
        }
    }

    func updateContext(_ snapshot: AgentContextSnapshot) {
        let payload = BridgeContextPayload(snapshot: snapshot)
        do {
            let data = try encoder.encode(payload)
            try data.write(to: paths.piBridgeContextFile, options: [.atomic])
        } catch {
            assertionFailure("Unable to write Pi bridge context: \(error.localizedDescription)")
        }
    }

    private func processPendingCommands() async {
        let fm = FileManager.default
        guard let handler = commandHandler else { return }

        let urls = (try? fm.contentsOfDirectory(
            at: paths.piBridgeCommandsDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        )) ?? []

        let sortedURLs = urls.sorted { lhs, rhs in
            let lhsDate = (try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            let rhsDate = (try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
            return lhsDate < rhsDate
        }

        for url in sortedURLs where url.pathExtension == "json" {
            do {
                let data = try Data(contentsOf: url)
                let command = try decoder.decode(BridgeCommandPayload.self, from: data)
                let resultText = handler(command.toUICommand())
                let result = BridgeResultPayload(id: command.id, ok: true, message: resultText)
                let resultData = try encoder.encode(result)
                let resultURL = paths.piBridgeResultsDirectory.appendingPathComponent("\(command.id).json")
                try resultData.write(to: resultURL, options: [.atomic])
                try? fm.removeItem(at: url)
            } catch {
                let fallbackID = url.deletingPathExtension().lastPathComponent
                let result = BridgeResultPayload(id: fallbackID, ok: false, message: error.localizedDescription)
                if let resultData = try? encoder.encode(result) {
                    let resultURL = paths.piBridgeResultsDirectory.appendingPathComponent("\(fallbackID).json")
                    try? resultData.write(to: resultURL, options: [.atomic])
                }
                try? fm.removeItem(at: url)
            }
        }
    }
}

private struct BridgeContextPayload: Codable {
    let projectName: String?
    let projectPaperCount: Int
    let projectPapers: [BridgeProjectPaperPayload]
    let collections: [BridgeCollectionPayload]
    let paper: BridgePaperPayload?
    let currentPage: Int?
    let pageCount: Int?
    let currentSelection: BridgeSelectionPayload?
    let annotations: [BridgeAnnotationPayload]
    let notebook: BridgeNotebookPayload?
    let isFocusReaderVisible: Bool
    let isNotebookVisible: Bool

    init(snapshot: AgentContextSnapshot) {
        self.projectName = snapshot.projectName
        self.projectPaperCount = snapshot.projectPaperCount
        self.projectPapers = snapshot.projectPapers.map { BridgeProjectPaperPayload(summary: $0) }
        self.collections = snapshot.collections.map { BridgeCollectionPayload(summary: $0) }
        self.currentPage = snapshot.currentPage
        self.pageCount = snapshot.pageCount
        self.currentSelection = snapshot.currentSelection.map { BridgeSelectionPayload(summary: $0) }
        self.paper = snapshot.paper.map {
            BridgePaperPayload(
                id: $0.id.uuidString,
                title: $0.title,
                authors: $0.authors,
                venue: $0.venue,
                year: $0.year,
                doi: $0.doi,
                arxivID: $0.arxivID,
                abstractText: $0.abstractText,
                pdfPath: snapshot.pdfURL?.path
            )
        }
        self.annotations = snapshot.annotations.map {
            BridgeAnnotationPayload(
                id: $0.id,
                kind: $0.kind.rawValue,
                page: $0.page,
                text: $0.text,
                note: $0.note
            )
        }
        self.notebook = snapshot.notebook.map { BridgeNotebookPayload(snapshot: $0) }
        self.isFocusReaderVisible = snapshot.isFocusReaderVisible
        self.isNotebookVisible = snapshot.isNotebookVisible
    }
}

private struct BridgeProjectPaperPayload: Codable {
    let id: String
    let title: String
    let authors: [String]
    let year: Int?
    let doi: String?
    let arxivID: String?

    init(summary: ProjectPaperSummary) {
        self.id = summary.id.uuidString
        self.title = summary.title
        self.authors = summary.authors
        self.year = summary.year
        self.doi = summary.doi
        self.arxivID = summary.arxivID
    }
}

private struct BridgeCollectionPayload: Codable {
    let id: String
    let name: String
    let paperCount: Int

    init(summary: ProjectCollectionSummary) {
        self.id = summary.id.uuidString
        self.name = summary.name
        self.paperCount = summary.paperCount
    }
}

private struct BridgePaperPayload: Codable {
    let id: String
    let title: String
    let authors: [String]
    let venue: String?
    let year: Int?
    let doi: String?
    let arxivID: String?
    let abstractText: String?
    let pdfPath: String?
}

private struct BridgeAnnotationPayload: Codable {
    let id: String
    let kind: String
    let page: Int
    let text: String?
    let note: String?
}

private struct BridgeSelectionPayload: Codable {
    let page: Int
    let text: String

    init(summary: PDFSelectionSummary) {
        self.page = summary.page
        self.text = summary.text
    }
}

private struct BridgeNotebookPayload: Codable {
    let projectID: String
    let projectName: String
    let filePath: String
    let markdown: String
    let updatedAt: String?
    let papers: [BridgeProjectPaperPayload]

    init(snapshot: ProjectNotebookSnapshot) {
        self.projectID = snapshot.projectID.uuidString
        self.projectName = snapshot.projectName
        self.filePath = snapshot.filePath
        self.markdown = snapshot.markdown
        if let updatedAt = snapshot.updatedAt {
            self.updatedAt = ISO8601DateFormatter().string(from: updatedAt)
        } else {
            self.updatedAt = nil
        }
        self.papers = snapshot.papers.map { BridgeProjectPaperPayload(summary: $0) }
    }
}

private struct BridgeCommandPayload: Codable {
    let id: String
    let command: String
    let page: Int?
    let text: String?
    let annotationID: String?
    let markdown: String?
    let paperID: String?
    let action: String?
    let openReader: Bool?
    let maxPages: Int?
    let startPage: Int?
    let endPage: Int?

    let title: String?
    let authors: [String]?
    let venue: String?
    let year: Int?
    let doi: String?
    let arxivID: String?
    let abstractText: String?
    let sourceURL: String?
    let pdfURL: String?
    let collectionName: String?

    enum CodingKeys: String, CodingKey {
        case id
        case command
        case page
        case text
        case annotationID = "annotationId"
        case markdown
        case paperID = "paperId"
        case action
        case openReader
        case maxPages
        case startPage
        case endPage

        case title
        case authors
        case venue
        case year
        case doi
        case arxivID = "arxivId"
        case abstractText
        case sourceURL = "sourceUrl"
        case pdfURL = "pdfUrl"
        case collectionName
    }

    func toUICommand() -> AgentUICommand {
        switch command {
        case "go_to_page":
            return .goToPage(page ?? 1)
        case "focus_annotation":
            return .focusAnnotation(annotationID ?? "")
        case "preview_annotation":
            return .previewAnnotation(annotationID ?? "")
        case "preview_text":
            return .previewText(page: page ?? 1, text: text ?? "")
        case "clear_preview":
            return .clearPreview
        case "replace_notebook":
            return .replaceProjectNotebook(markdown ?? "")
        case "append_notebook":
            return .appendProjectNotebook(markdown ?? "")
        case "select_paper":
            return .selectPaper(paperID: paperID ?? "", openInFocusReader: openReader ?? true)
        case "set_notebook_visibility":
            let value = PanelVisibilityAction(rawValue: (action ?? "toggle").lowercased()) ?? .toggle
            return .setNotebookVisibility(value)
        case "set_focus_reader_visibility":
            let value = PanelVisibilityAction(rawValue: (action ?? "toggle").lowercased()) ?? .toggle
            return .setFocusReaderVisibility(value)
        case "add_note":
            return .addNote(text ?? "")
        case "highlight_selection":
            return .highlightSelection
        case "remove_highlights_in_selection":
            return .removeHighlightsInSelection
        case "add_paper_to_collection":
            return .addPaperToCollection(
                PaperCollectionDraft(
                    title: title ?? "",
                    authors: authors ?? [],
                    venue: venue,
                    year: year,
                    doi: doi,
                    arxivID: arxivID,
                    abstractText: abstractText,
                    sourceURL: sourceURL,
                    pdfURL: pdfURL,
                    collectionName: collectionName
                )
            )
        case "get_active_pdf_text":
            return .getActivePDFText(maxPages: maxPages, startPage: startPage, endPage: endPage)
        default:
            return .clearPreview
        }
    }
}

private struct BridgeResultPayload: Codable {
    let id: String
    let ok: Bool
    let message: String
}
