import Foundation
import SwiftUI

@MainActor
final class LibraryStore: ObservableObject {
    @Published private(set) var projects: [Project] = []
    @Published private(set) var papers: [Paper] = []
    @Published var isImporting = false

    private let paths: AppPaths
    private let metadataLookup = MetadataLookupService()
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init() {
        do {
            self.paths = try AppPaths.make()
        } catch {
            fatalError("Unable to initialize app storage: \(error.localizedDescription)")
        }

        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        load()
        bootstrapIfNeeded()
    }

    func project(for id: UUID?) -> Project? {
        guard let id else { return nil }
        return projects.first(where: { $0.id == id })
    }

    func paper(for id: UUID?) -> Paper? {
        guard let id else { return nil }
        return papers.first(where: { $0.id == id })
    }

    func papers(in projectID: UUID?) -> [Paper] {
        guard let project = project(for: projectID) else { return [] }
        let byID = Dictionary(uniqueKeysWithValues: papers.map { ($0.id, $0) })
        return project.paperIDs.compactMap { byID[$0] }
    }

    func createProject(named name: String) -> UUID {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let project = Project(
            id: UUID(),
            name: trimmed.isEmpty ? "Untitled Project" : trimmed,
            paperIDs: [],
            createdAt: Date()
        )
        projects.append(project)
        save()
        return project.id
    }

    func deleteProject(_ id: UUID) {
        guard let project = project(for: id) else { return }

        for paperID in project.paperIDs {
            deletePaperFile(id: paperID)
        }

        papers.removeAll { $0.projectID == id }
        projects.removeAll { $0.id == id }
        save()
    }

    func renameProject(_ id: UUID, to newName: String) {
        guard let index = projects.firstIndex(where: { $0.id == id }) else { return }
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        projects[index].name = trimmed
        save()
    }

    func importPDFs(urls: [URL], into projectID: UUID) async {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        isImporting = true
        defer { isImporting = false }

        for url in urls where url.pathExtension.lowercased() == "pdf" {
            let paperID = UUID()
            let destinationURL = paths.pdfsDirectory.appendingPathComponent("\(paperID).pdf", isDirectory: false)

            do {
                try FileManager.default.copyItem(at: url, to: destinationURL)

                let initialTitle = PDFTextExtractor.suggestedTitle(from: destinationURL)
                let paper = Paper(
                    id: paperID,
                    projectID: projectID,
                    title: initialTitle,
                    authors: [],
                    venue: nil,
                    year: nil,
                    doi: nil,
                    arxivID: nil,
                    abstractText: nil,
                    pdfRelativePath: destinationURL.lastPathComponent,
                    sourceFilename: url.lastPathComponent,
                    addedAt: Date(),
                    metadataStatus: .pending,
                    metadataSource: nil,
                    metadataError: nil
                )

                papers.append(paper)
                projects[projectIndex].paperIDs.append(paperID)
                save()

                await refreshMetadata(for: paperID)
            } catch {
                let failedPaper = Paper(
                    id: paperID,
                    projectID: projectID,
                    title: url.deletingPathExtension().lastPathComponent,
                    authors: [],
                    venue: nil,
                    year: nil,
                    doi: nil,
                    arxivID: nil,
                    abstractText: nil,
                    pdfRelativePath: "",
                    sourceFilename: url.lastPathComponent,
                    addedAt: Date(),
                    metadataStatus: .failed,
                    metadataSource: nil,
                    metadataError: error.localizedDescription
                )

                papers.append(failedPaper)
                projects[projectIndex].paperIDs.append(paperID)
                save()
            }
        }
    }

    /// Import a paper from a web URL (arXiv page, direct PDF link, or DOI URL).
    func importFromURL(_ url: URL, into projectID: UUID) async {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return }
        isImporting = true
        defer { isImporting = false }

        // 1) arXiv abstract or PDF page  →  fetch metadata + download PDF
        if let arxivID = Self.extractArxivID(from: url) {
            await importArxivPaper(arxivID: arxivID, sourceURL: url, projectIndex: projectIndex, projectID: projectID)
            return
        }

        // 2) DOI URL (e.g. https://doi.org/10.xxxx/...)
        if let doi = Self.extractDOI(from: url) {
            await importDOIPaper(doi: doi, sourceURL: url, projectIndex: projectIndex, projectID: projectID)
            return
        }

        // 3) Direct PDF link  →  download and extract metadata from the PDF
        if url.pathExtension.lowercased() == "pdf" || url.absoluteString.lowercased().contains(".pdf") {
            await importDirectPDF(from: url, projectIndex: projectIndex, projectID: projectID)
            return
        }

        // 4) Generic web URL  →  store as a paper with the URL as source, no PDF
        let paperID = UUID()
        let title = url.host ?? url.absoluteString
        let paper = Paper(
            id: paperID,
            projectID: projectID,
            title: title,
            authors: [],
            venue: nil,
            year: nil,
            doi: nil,
            arxivID: nil,
            abstractText: nil,
            pdfRelativePath: "",
            sourceFilename: url.absoluteString,
            addedAt: Date(),
            metadataStatus: .pending,
            metadataSource: nil,
            metadataError: nil
        )
        papers.append(paper)
        projects[projectIndex].paperIDs.append(paperID)
        save()
    }

    // MARK: – URL Import Helpers

    private func importArxivPaper(arxivID: String, sourceURL: URL, projectIndex: Int, projectID: UUID) async {
        // De-duplicate: check if this arXiv ID already exists in the project
        let normalizedArxiv = arxivID.lowercased()
        if let existing = papers.first(where: {
            $0.projectID == projectID &&
            $0.arxivID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedArxiv
        }) {
            // Already have it — if it's missing a PDF, try downloading one
            if existing.pdfRelativePath.isEmpty,
               let pdfURL = URL(string: "https://arxiv.org/pdf/\(arxivID).pdf"),
               let index = papers.firstIndex(where: { $0.id == existing.id }),
               let downloaded = downloadPDF(from: pdfURL, id: existing.id) {
                papers[index].pdfRelativePath = downloaded.relativePath
                papers[index].sourceFilename = downloaded.sourceFilename
                save()
            }
            return
        }

        let paperID = UUID()

        // Try to fetch metadata from arXiv API
        do {
            let metadata = try await metadataLookup.lookup(identifier: arxivID)
            let pdfURL = URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")
            let downloaded = pdfURL.flatMap { downloadPDF(from: $0, id: paperID) }

            let paper = Paper(
                id: paperID,
                projectID: projectID,
                title: metadata.title,
                authors: metadata.authors,
                venue: metadata.venue,
                year: metadata.year,
                doi: metadata.doi,
                arxivID: arxivID,
                abstractText: metadata.abstractText,
                pdfRelativePath: downloaded?.relativePath ?? "",
                sourceFilename: downloaded?.sourceFilename ?? sourceURL.absoluteString,
                addedAt: Date(),
                metadataStatus: .resolved,
                metadataSource: metadata.source,
                metadataError: nil
            )
            papers.append(paper)
            projects[projectIndex].paperIDs.append(paperID)
            save()
        } catch {
            // Metadata fetch failed — still create the paper entry
            let pdfURL = URL(string: "https://arxiv.org/pdf/\(arxivID).pdf")
            let downloaded = pdfURL.flatMap { downloadPDF(from: $0, id: paperID) }

            let paper = Paper(
                id: paperID,
                projectID: projectID,
                title: "arXiv:\(arxivID)",
                authors: [],
                venue: "arXiv",
                year: nil,
                doi: nil,
                arxivID: arxivID,
                abstractText: nil,
                pdfRelativePath: downloaded?.relativePath ?? "",
                sourceFilename: sourceURL.absoluteString,
                addedAt: Date(),
                metadataStatus: .failed,
                metadataSource: nil,
                metadataError: error.localizedDescription
            )
            papers.append(paper)
            projects[projectIndex].paperIDs.append(paperID)
            save()
        }
    }

    private func importDOIPaper(doi: String, sourceURL: URL, projectIndex: Int, projectID: UUID) async {
        // De-duplicate
        let normalizedDOI = doi.lowercased()
        if papers.contains(where: {
            $0.projectID == projectID &&
            $0.doi?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == normalizedDOI
        }) {
            return
        }

        let paperID = UUID()

        do {
            let metadata = try await metadataLookup.lookup(identifier: doi)

            let paper = Paper(
                id: paperID,
                projectID: projectID,
                title: metadata.title,
                authors: metadata.authors,
                venue: metadata.venue,
                year: metadata.year,
                doi: doi,
                arxivID: metadata.arxivID,
                abstractText: metadata.abstractText,
                pdfRelativePath: "",
                sourceFilename: sourceURL.absoluteString,
                addedAt: Date(),
                metadataStatus: .resolved,
                metadataSource: metadata.source,
                metadataError: nil
            )
            papers.append(paper)
            projects[projectIndex].paperIDs.append(paperID)
            save()
        } catch {
            let paper = Paper(
                id: paperID,
                projectID: projectID,
                title: doi,
                authors: [],
                venue: nil,
                year: nil,
                doi: doi,
                arxivID: nil,
                abstractText: nil,
                pdfRelativePath: "",
                sourceFilename: sourceURL.absoluteString,
                addedAt: Date(),
                metadataStatus: .failed,
                metadataSource: nil,
                metadataError: error.localizedDescription
            )
            papers.append(paper)
            projects[projectIndex].paperIDs.append(paperID)
            save()
        }
    }

    private func importDirectPDF(from remoteURL: URL, projectIndex: Int, projectID: UUID) async {
        let paperID = UUID()
        let downloaded = downloadPDF(from: remoteURL, id: paperID)

        guard let downloaded else {
            let paper = Paper(
                id: paperID,
                projectID: projectID,
                title: remoteURL.deletingPathExtension().lastPathComponent,
                authors: [],
                venue: nil,
                year: nil,
                doi: nil,
                arxivID: nil,
                abstractText: nil,
                pdfRelativePath: "",
                sourceFilename: remoteURL.absoluteString,
                addedAt: Date(),
                metadataStatus: .failed,
                metadataSource: nil,
                metadataError: "Failed to download PDF from URL."
            )
            papers.append(paper)
            projects[projectIndex].paperIDs.append(paperID)
            save()
            return
        }

        let localURL = paths.pdfsDirectory.appendingPathComponent(downloaded.relativePath, isDirectory: false)
        let initialTitle = PDFTextExtractor.suggestedTitle(from: localURL)

        let paper = Paper(
            id: paperID,
            projectID: projectID,
            title: initialTitle,
            authors: [],
            venue: nil,
            year: nil,
            doi: nil,
            arxivID: nil,
            abstractText: nil,
            pdfRelativePath: downloaded.relativePath,
            sourceFilename: downloaded.sourceFilename,
            addedAt: Date(),
            metadataStatus: .pending,
            metadataSource: nil,
            metadataError: nil
        )
        papers.append(paper)
        projects[projectIndex].paperIDs.append(paperID)
        save()

        await refreshMetadata(for: paperID)
    }

    // MARK: – URL Pattern Extraction

    /// Extract an arXiv ID from a URL like https://arxiv.org/abs/2301.12345 or https://arxiv.org/pdf/2301.12345.pdf
    static func extractArxivID(from url: URL) -> String? {
        guard let host = url.host?.lowercased(),
              host.contains("arxiv.org") else { return nil }

        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }

        if path.hasPrefix("abs/") {
            return String(path.dropFirst(4))
        }
        if path.hasPrefix("pdf/") {
            var id = String(path.dropFirst(4))
            if id.hasSuffix(".pdf") { id.removeLast(4) }
            return id
        }
        return nil
    }

    /// Extract a DOI from a URL like https://doi.org/10.xxxx/yyyy
    static func extractDOI(from url: URL) -> String? {
        let str = url.absoluteString

        // doi.org direct link
        if let host = url.host?.lowercased(), host.contains("doi.org") {
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path.range(of: #"^10\.[0-9]{4,}/\S+$"#, options: .regularExpression) != nil {
                return path
            }
        }

        // DOI embedded in a query param or URL path
        let doiPattern = #"10\.[0-9]{4,}\/[^\s&"']*[^\s&"'.,;:]"#
        if let regex = try? NSRegularExpression(pattern: doiPattern, options: []),
           let match = regex.firstMatch(in: str, options: [], range: NSRange(str.startIndex..<str.endIndex, in: str)),
           let range = Range(match.range(at: 0), in: str) {
            return String(str[range])
        }

        return nil
    }

    func refreshMetadata(for paperID: UUID) async {
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }
        let pdfURL = pdfURL(for: papers[index])
        guard let pdfURL else {
            papers[index].metadataStatus = .failed
            papers[index].metadataError = "Local PDF file is missing."
            save()
            return
        }

        papers[index].metadataStatus = .pending
        papers[index].metadataError = nil
        save()

        do {
            let metadata = try await metadataLookup.recognizeMetadata(for: pdfURL)
            apply(metadata: metadata, to: paperID)
        } catch {
            papers[index].metadataStatus = .failed
            papers[index].metadataError = error.localizedDescription
            save()
        }
    }

    func lookupMetadata(for paperID: UUID, identifier: String) async {
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }
        papers[index].metadataStatus = .pending
        papers[index].metadataError = nil
        save()

        do {
            let metadata = try await metadataLookup.lookup(identifier: identifier)
            apply(metadata: metadata, to: paperID)
        } catch {
            papers[index].metadataStatus = .failed
            papers[index].metadataError = error.localizedDescription
            save()
        }
    }

    func deletePaper(_ id: UUID) {
        deletePaperFile(id: id)
        papers.removeAll { $0.id == id }
        for index in projects.indices {
            projects[index].paperIDs.removeAll { $0 == id }
        }
        save()
    }

    @discardableResult
    func addPaperToProject(
        projectID: UUID,
        title: String,
        authors: [String],
        venue: String?,
        year: Int?,
        doi: String?,
        arxivID: String?,
        abstractText: String?,
        sourceLabel: String?,
        pdfURL: String?,
        sourceURL: String?
    ) -> Paper? {
        guard let projectIndex = projects.firstIndex(where: { $0.id == projectID }) else { return nil }

        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return nil }

        let normalizedDOI = doi?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let normalizedArxiv = arxivID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        // De-duplicate within project using DOI/arXiv/title heuristics.
        let existing = papers.first { paper in
            guard paper.projectID == projectID else { return false }
            if let normalizedDOI,
               let existingDOI = paper.doi?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !normalizedDOI.isEmpty,
               normalizedDOI == existingDOI {
                return true
            }
            if let normalizedArxiv,
               let existingArxiv = paper.arxivID?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
               !normalizedArxiv.isEmpty,
               normalizedArxiv == existingArxiv {
                return true
            }
            return paper.title.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare(normalizedTitle) == .orderedSame
        }

        if let existing,
           existing.pdfRelativePath.isEmpty,
           let index = papers.firstIndex(where: { $0.id == existing.id }),
           let remotePDF = resolveRemotePDFURL(pdfURL: pdfURL, sourceURL: sourceURL, arxivID: arxivID),
           let downloaded = downloadPDF(from: remotePDF, id: existing.id) {
            papers[index].pdfRelativePath = downloaded.relativePath
            papers[index].sourceFilename = downloaded.sourceFilename
            save()
            return papers[index]
        }

        if let existing {
            return existing
        }

        let id = UUID()
        let remotePDF = resolveRemotePDFURL(pdfURL: pdfURL, sourceURL: sourceURL, arxivID: arxivID)
        let downloaded = remotePDF.flatMap { downloadPDF(from: $0, id: id) }

        let trimmedSource = sourceLabel?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let sourceFilename = downloaded?.sourceFilename ?? (trimmedSource.isEmpty ? normalizedTitle : trimmedSource)

        let paper = Paper(
            id: id,
            projectID: projectID,
            title: normalizedTitle,
            authors: authors,
            venue: venue,
            year: year,
            doi: doi,
            arxivID: arxivID,
            abstractText: abstractText,
            pdfRelativePath: downloaded?.relativePath ?? "",
            sourceFilename: sourceFilename,
            addedAt: Date(),
            metadataStatus: .resolved,
            metadataSource: "pi-web",
            metadataError: nil
        )

        papers.append(paper)
        projects[projectIndex].paperIDs.append(id)
        save()
        return paper
    }

    func pdfURL(for paper: Paper) -> URL? {
        guard !paper.pdfRelativePath.isEmpty else { return nil }
        return paths.pdfsDirectory.appendingPathComponent(paper.pdfRelativePath, isDirectory: false)
    }

    private func resolveRemotePDFURL(pdfURL: String?, sourceURL: String?, arxivID: String?) -> URL? {
        if let pdfURL,
           let url = URL(string: pdfURL.trimmingCharacters(in: .whitespacesAndNewlines)),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            return url
        }

        if let sourceURL,
           let url = URL(string: sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)),
           ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
            if url.pathExtension.lowercased() == "pdf" {
                return url
            }

            if let arxivFromURL = extractArxivID(from: url) {
                return arxivPDFURL(from: arxivFromURL)
            }
        }

        if let arxivID {
            return arxivPDFURL(from: arxivID)
        }

        return nil
    }

    private func extractArxivID(from url: URL) -> String? {
        let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !path.isEmpty else { return nil }

        if path.hasPrefix("abs/") {
            return String(path.dropFirst(4))
        }
        if path.hasPrefix("pdf/") {
            var id = String(path.dropFirst(4))
            if id.hasSuffix(".pdf") {
                id.removeLast(4)
            }
            return id
        }
        return nil
    }

    private func arxivPDFURL(from rawID: String) -> URL? {
        var id = rawID.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.lowercased().hasPrefix("arxiv:") {
            id = String(id.dropFirst(6))
        }
        guard !id.isEmpty else { return nil }
        return URL(string: "https://arxiv.org/pdf/\(id).pdf")
    }

    private func downloadPDF(from remoteURL: URL, id: UUID) -> (relativePath: String, sourceFilename: String)? {
        let destination = paths.pdfsDirectory.appendingPathComponent("\(id).pdf", isDirectory: false)

        do {
            let data = try Data(contentsOf: remoteURL)
            guard data.starts(with: Data("%PDF".utf8)) || remoteURL.pathExtension.lowercased() == "pdf" else {
                return nil
            }
            try data.write(to: destination, options: [.atomic])

            let filename = remoteURL.lastPathComponent.isEmpty
                ? "\(id).pdf"
                : remoteURL.lastPathComponent

            return (destination.lastPathComponent, filename)
        } catch {
            return nil
        }
    }

    private func apply(metadata: ResolvedMetadata, to paperID: UUID) {
        guard let index = papers.firstIndex(where: { $0.id == paperID }) else { return }

        papers[index].title = metadata.title
        papers[index].authors = metadata.authors
        papers[index].venue = metadata.venue
        papers[index].year = metadata.year
        papers[index].doi = metadata.doi
        papers[index].arxivID = metadata.arxivID
        papers[index].abstractText = metadata.abstractText
        papers[index].metadataStatus = .resolved
        papers[index].metadataSource = metadata.source
        papers[index].metadataError = nil
        save()
    }

    private func load() {
        guard FileManager.default.fileExists(atPath: paths.libraryFile.path) else { return }

        do {
            let data = try Data(contentsOf: paths.libraryFile)
            let snapshot = try decoder.decode(LibrarySnapshot.self, from: data)
            projects = snapshot.projects.sorted(by: { $0.createdAt < $1.createdAt })
            papers = snapshot.papers.sorted(by: { $0.addedAt < $1.addedAt })
        } catch {
            projects = []
            papers = []
        }
    }

    private func bootstrapIfNeeded() {
        guard projects.isEmpty else { return }
        let project = Project(id: UUID(), name: "Inbox", paperIDs: [], createdAt: Date())
        projects = [project]
        save()
    }

    private func save() {
        do {
            let snapshot = LibrarySnapshot(projects: projects, papers: papers)
            let data = try encoder.encode(snapshot)
            try data.write(to: paths.libraryFile, options: [.atomic])
        } catch {
            assertionFailure("Unable to save library: \(error.localizedDescription)")
        }
    }

    private func deletePaperFile(id: UUID) {
        let url = paths.pdfsDirectory.appendingPathComponent("\(id).pdf", isDirectory: false)
        try? FileManager.default.removeItem(at: url)
    }
}
