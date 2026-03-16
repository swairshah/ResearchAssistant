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
    let paper: BridgePaperPayload?
    let currentPage: Int?
    let pageCount: Int?
    let annotations: [BridgeAnnotationPayload]

    init(snapshot: AgentContextSnapshot) {
        self.projectName = snapshot.projectName
        self.projectPaperCount = snapshot.projectPaperCount
        self.currentPage = snapshot.currentPage
        self.pageCount = snapshot.pageCount
        self.paper = snapshot.paper.map {
            BridgePaperPayload(
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
    }
}

private struct BridgePaperPayload: Codable {
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

private struct BridgeCommandPayload: Codable {
    let id: String
    let command: String
    let page: Int?
    let text: String?
    let annotationID: String?

    enum CodingKeys: String, CodingKey {
        case id
        case command
        case page
        case text
        case annotationID = "annotationId"
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
