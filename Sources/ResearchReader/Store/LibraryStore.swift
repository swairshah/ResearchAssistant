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

    func pdfURL(for paper: Paper) -> URL? {
        guard !paper.pdfRelativePath.isEmpty else { return nil }
        return paths.pdfsDirectory.appendingPathComponent(paper.pdfRelativePath, isDirectory: false)
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
