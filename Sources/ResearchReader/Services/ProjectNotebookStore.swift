import Foundation

@MainActor
final class ProjectNotebookStore: ObservableObject {
    @Published private(set) var currentProjectID: UUID?
    @Published private(set) var markdown = ""
    @Published private(set) var lastSavedAt: Date?

    private let paths: AppPaths
    private var pendingSaveTask: Task<Void, Never>?

    init() {
        do {
            self.paths = try AppPaths.make()
        } catch {
            fatalError("Unable to initialize notebook paths: \(error.localizedDescription)")
        }
    }

    deinit {
        pendingSaveTask?.cancel()
    }

    func load(project: Project?) {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil

        guard let project else {
            currentProjectID = nil
            markdown = ""
            lastSavedAt = nil
            return
        }

        currentProjectID = project.id

        let url = notebookURL(for: project.id)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            markdown = text
        } else {
            markdown = defaultNotebook(for: project)
        }

        lastSavedAt = modificationDate(for: url)
    }

    func updateMarkdown(_ text: String, for project: Project?) {
        guard let project else { return }
        if currentProjectID != project.id {
            load(project: project)
        }
        markdown = text
        scheduleSave(for: project.id, text: text)
    }

    func replaceNotebook(with text: String, for project: Project) {
        pendingSaveTask?.cancel()
        pendingSaveTask = nil
        currentProjectID = project.id
        markdown = text
        write(text: text, for: project.id)
    }

    func appendToNotebook(_ snippet: String, for project: Project) {
        let trimmed = snippet.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        let existing = currentText(for: project)
        let combined: String
        if existing.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            combined = trimmed + "\n"
        } else if existing.hasSuffix("\n\n") {
            combined = existing + trimmed + "\n"
        } else if existing.hasSuffix("\n") {
            combined = existing + "\n" + trimmed + "\n"
        } else {
            combined = existing + "\n\n" + trimmed + "\n"
        }

        replaceNotebook(with: combined, for: project)
    }

    func insertReference(for paper: Paper, in project: Project) {
        appendToNotebook(referenceMarkdown(for: paper), for: project)
    }

    func snapshot(project: Project?, papers: [Paper]) -> ProjectNotebookSnapshot? {
        guard let project else { return nil }
        let text = currentText(for: project)
        let url = notebookURL(for: project.id)
        return ProjectNotebookSnapshot(
            projectID: project.id,
            projectName: project.name,
            filePath: url.path,
            markdown: text,
            updatedAt: modificationDate(for: url),
            papers: papers.map { ProjectPaperSummary(paper: $0) }
        )
    }

    private func scheduleSave(for projectID: UUID, text: String) {
        pendingSaveTask?.cancel()
        pendingSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            self?.write(text: text, for: projectID)
        }
    }

    private func write(text: String, for projectID: UUID) {
        let url = notebookURL(for: projectID)
        do {
            try text.data(using: .utf8)?.write(to: url, options: [.atomic])
            lastSavedAt = modificationDate(for: url) ?? Date()
        } catch {
            assertionFailure("Unable to save notebook: \(error.localizedDescription)")
        }
    }

    private func currentText(for project: Project) -> String {
        if currentProjectID == project.id {
            return markdown
        }

        let url = notebookURL(for: project.id)
        if let data = try? Data(contentsOf: url),
           let text = String(data: data, encoding: .utf8) {
            return text
        }

        return defaultNotebook(for: project)
    }

    private func notebookURL(for projectID: UUID) -> URL {
        paths.projectNotebooksDirectory.appendingPathComponent("\(projectID.uuidString).md", isDirectory: false)
    }

    private func modificationDate(for url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }

    private func defaultNotebook(for project: Project) -> String {
        """
        # \(project.name)

        ## Consolidated Notes

        ## Paper References

        """
    }

    private func referenceMarkdown(for paper: Paper) -> String {
        let authors = paper.authors.isEmpty ? nil : paper.authors.joined(separator: ", ")
        let year = paper.year.map(String.init)
        let ids = [paper.doi, paper.arxivID].compactMap { $0 }.joined(separator: " · ")

        let detailLine = [authors, year, ids.nonEmpty]
            .compactMap { $0 }
            .joined(separator: " · ")

        if detailLine.isEmpty {
            return "- [[paper:\(paper.id.uuidString)]] \(paper.title)"
        }

        return "- [[paper:\(paper.id.uuidString)]] \(paper.title)\n  \(detailLine)"
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
