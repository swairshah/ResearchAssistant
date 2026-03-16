import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @EnvironmentObject private var store: LibraryStore

    @StateObject private var piBridge = ResearchPiBridge()
    @StateObject private var piChatManager = ResearchPiChatManager()
    @StateObject private var readerController = PDFReaderController()
    @State private var selectedProjectID: UUID?
    @State private var selectedPaperID: UUID?
    @State private var newProjectName = ""
    @State private var showingProjectSheet = false
    @State private var showingAgentChat = false
    @State private var showingNoteSheet = false
    @State private var isPaperListDropTargeted = false
    @State private var searchText = ""
    @State private var isReaderExpanded = false
    @State private var noteDraft = ""

    var body: some View {
        Group {
            if isReaderExpanded, let paper = selectedPaper, let pdfURL = selectedPaperPDFURL {
                FocusedReaderView(paper: paper, pdfURL: pdfURL, readerController: readerController)
            } else {
                NavigationSplitView {
                    projectSidebar
                } content: {
                    paperList
                } detail: {
                    detailPane
                }
                .navigationSplitViewStyle(.balanced)
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search title, author, DOI, arXiv")
            }
        }
        .overlay(alignment: .bottomTrailing) {
            VStack(alignment: .trailing, spacing: 12) {
                if showingAgentChat {
                    AgentChatPanel(
                        chatManager: piChatManager,
                        context: agentContext,
                        onClose: { showingAgentChat = false }
                    )
                    .transition(.move(edge: .trailing).combined(with: .opacity))
                }

                Button {
                    withAnimation(.spring(duration: 0.24)) {
                        showingAgentChat.toggle()
                    }
                } label: {
                    Image(systemName: showingAgentChat ? "xmark" : "message.badge.waveform.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(.white)
                        .background(Color.accentColor, in: Circle())
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
                .help("Open Pi agent")
            }
            .padding(20)
        }
        .sheet(isPresented: $showingProjectSheet) {
            NewProjectSheet(
                name: $newProjectName,
                onCancel: {
                    newProjectName = ""
                    showingProjectSheet = false
                },
                onCreate: {
                    let newID = store.createProject(named: newProjectName)
                    selectedProjectID = newID
                    selectedPaperID = nil
                    newProjectName = ""
                    showingProjectSheet = false
                }
            )
        }
        .sheet(isPresented: $showingNoteSheet) {
            NoteComposerSheet(
                text: $noteDraft,
                onCancel: {
                    noteDraft = ""
                    showingNoteSheet = false
                },
                onAdd: {
                    readerController.addNote(noteDraft)
                    noteDraft = ""
                    showingNoteSheet = false
                }
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isReaderExpanded {
                    Button {
                        isReaderExpanded = false
                    } label: {
                        Label("Back to Library", systemImage: "sidebar.left")
                    }

                    Button {
                        if let paper = selectedPaper {
                            Task { await store.refreshMetadata(for: paper.id) }
                        }
                    } label: {
                        Label("Refresh Metadata", systemImage: "arrow.clockwise")
                    }
                    .disabled(selectedPaper == nil)

                    Button {
                        readerController.highlightSelection()
                    } label: {
                        Label("Highlight", systemImage: "highlighter")
                    }
                    .disabled(!readerController.hasSelection)

                    Button {
                        noteDraft = ""
                        showingNoteSheet = true
                    } label: {
                        Label("Add Note", systemImage: "note.text.badge.plus")
                    }
                    .disabled(!readerController.isDocumentLoaded)
                } else {
                    Button {
                        showingProjectSheet = true
                    } label: {
                        Label("New Project", systemImage: "folder.badge.plus")
                    }

                    Button {
                        importPDFs()
                    } label: {
                        Label("Import PDFs", systemImage: "doc.badge.plus")
                    }
                    .disabled(selectedProjectID == nil || store.isImporting)

                    Button {
                        expandSelectedPaper()
                    } label: {
                        Label("Focus Reader", systemImage: "book.pages")
                    }
                    .disabled(selectedPaper == nil || selectedPaperPDFURL == nil)
                }
            }

            ToolbarItem {
                if store.isImporting && !isReaderExpanded {
                    ProgressView()
                        .controlSize(.small)
                }
            }
        }
        .onAppear {
            piBridge.start(commandHandler: executeBridgeCommand)
            if selectedProjectID == nil {
                selectedProjectID = store.projects.first?.id
            }
            syncPaperSelection()
            syncPiBridgeContext()
        }
        .onChange(of: store.projects) { _, _ in
            if selectedProjectID == nil {
                selectedProjectID = store.projects.first?.id
            }
            syncPaperSelection()
            syncPiBridgeContext()
        }
        .onChange(of: selectedProjectID) { _, _ in
            syncPaperSelection()
            syncPiBridgeContext()
        }
        .onChange(of: searchText) { _, _ in
            syncPaperSelection()
        }
        .onChange(of: selectedPaperID) { _, _ in
            if isReaderExpanded, selectedPaper == nil {
                isReaderExpanded = false
            }
            syncPiBridgeContext()
        }
        .onChange(of: piChatManager.pendingCommands.count) { _, count in
            guard count > 0 else { return }
            executeAgentCommands()
        }
        .onChange(of: readerController.currentPageNumber) { _, _ in
            syncPiBridgeContext()
        }
        .onChange(of: readerController.pageCount) { _, _ in
            syncPiBridgeContext()
        }
        .onChange(of: readerController.annotationSummaries) { _, _ in
            syncPiBridgeContext()
        }
    }

    private var projectSidebar: some View {
        List(selection: $selectedProjectID) {
            Section {
                ForEach(store.projects) { project in
                    ProjectSidebarRow(
                        project: project,
                        canDelete: store.projects.count > 1,
                        onDropProviders: { providers in
                            handleDrop(providers, into: project.id)
                        },
                        onDelete: {
                            let shouldReselect = selectedProjectID == project.id
                            store.deleteProject(project.id)
                            if shouldReselect {
                                selectedProjectID = store.projects.first?.id
                            }
                        }
                    )
                    .tag(project.id)
                }
            } header: {
                Text("Projects")
            }
        }
        .navigationTitle("Research Reader")
    }

    private var paperList: some View {
        Group {
            if selectedProjectID == nil {
                ContentUnavailableView(
                    "No Project Selected",
                    systemImage: "sidebar.left",
                    description: Text("Create or select a project.")
                )
            } else if filteredPapers.isEmpty {
                if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    ContentUnavailableView(
                        "No Papers",
                        systemImage: "doc.text",
                        description: Text("Import PDFs into this project to start building a reading list.")
                    )
                } else {
                    ContentUnavailableView.search(text: searchText)
                }
            } else {
                Table(filteredPapers, selection: $selectedPaperID) {
                    TableColumn("Title") { paper in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(spacing: 8) {
                                Image(systemName: "doc.richtext")
                                    .foregroundStyle(.secondary)
                                Text(paper.title)
                                    .lineLimit(1)
                            }

                            if let statusText = statusText(for: paper) {
                                Text(statusText)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                        .padding(.vertical, 2)
                        .contextMenu {
                            paperContextMenu(for: paper)
                        }
                    }
                    .width(min: 380, ideal: 520)

                    TableColumn("Author") { paper in
                        Text(authorCellText(for: paper))
                            .lineLimit(1)
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 160, ideal: 220)

                    TableColumn("Year") { paper in
                        Text(paper.year.map(String.init) ?? "—")
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .width(70)

                    TableColumn("Added") { paper in
                        Text(paper.addedAt, format: .dateTime.month().day().year())
                            .foregroundStyle(.secondary)
                    }
                    .width(min: 120, ideal: 150)

                    TableColumn("Status") { paper in
                        StatusBadge(status: paper.metadataStatus)
                    }
                    .width(108)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: true))
                .contextMenu(forSelectionType: UUID.self) { selection in
                    if let id = selection.first, let paper = store.paper(for: id) {
                        paperContextMenu(for: paper)
                    }
                } primaryAction: { selection in
                    if let id = selection.first {
                        selectedPaperID = id
                        expandSelectedPaper()
                    }
                }
            }
        }
        .overlay {
            if isPaperListDropTargeted, selectedProjectID != nil {
                DropHintView(label: "Drop PDFs to import into this project")
                    .padding(24)
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isPaperListDropTargeted,
            perform: { providers in
                guard let projectID = selectedProjectID else { return false }
                return handleDrop(providers, into: projectID)
            }
        )
        .navigationTitle(store.project(for: selectedProjectID)?.name ?? "Papers")
    }

    @ViewBuilder
    private var detailPane: some View {
        if let paper = store.paper(for: selectedPaperID) {
            PaperDetailView(
                paper: paper,
                pdfURL: store.pdfURL(for: paper),
                onRefreshMetadata: {
                    Task { await store.refreshMetadata(for: paper.id) }
                },
                onLookupIdentifier: { identifier in
                    Task { await store.lookupMetadata(for: paper.id, identifier: identifier) }
                }
            )
        } else {
            ContentUnavailableView(
                "Select a Paper",
                systemImage: "doc.richtext",
                description: Text("Choose a paper to view its metadata and PDF.")
            )
        }
    }

    private var selectedPaper: Paper? {
        store.paper(for: selectedPaperID)
    }

    private var selectedPaperPDFURL: URL? {
        guard let selectedPaper else { return nil }
        return store.pdfURL(for: selectedPaper)
    }

    private var agentContext: AgentContextSnapshot {
        AgentContextSnapshot(
            projectName: store.project(for: selectedProjectID)?.name,
            projectPaperCount: store.papers(in: selectedProjectID).count,
            paper: selectedPaper,
            pdfURL: selectedPaperPDFURL,
            currentPage: selectedPaper != nil ? readerController.currentPageNumber : nil,
            pageCount: selectedPaper != nil ? readerController.pageCount : nil,
            annotations: selectedPaper != nil ? readerController.annotationSummaries : []
        )
    }

    private var filteredPapers: [Paper] {
        let papers = store.papers(in: selectedProjectID)
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !query.isEmpty else { return papers }

        return papers.filter { paper in
            let haystack = [
                paper.title,
                paper.authors.joined(separator: " "),
                paper.venue ?? "",
                paper.doi ?? "",
                paper.arxivID ?? "",
                paper.abstractText ?? "",
                paper.sourceFilename,
            ]
            .joined(separator: "\n")

            return haystack.localizedCaseInsensitiveContains(query)
        }
    }

    private func importPDFs() {
        guard let projectID = selectedProjectID else { return }

        let panel = NSOpenPanel()
        panel.title = "Import PDFs"
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.pdf]

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls

        Task {
            await store.importPDFs(urls: urls, into: projectID)
            if selectedPaperID == nil {
                selectedPaperID = store.papers(in: projectID).last?.id
            }
        }
    }

    private func handleDrop(_ providers: [NSItemProvider], into projectID: UUID) -> Bool {
        guard providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }) else {
            return false
        }

        Task {
            let urls = await loadDroppedPDFURLs(from: providers)
            guard !urls.isEmpty else { return }

            selectedProjectID = projectID
            await store.importPDFs(urls: urls, into: projectID)
            selectedPaperID = store.papers(in: projectID).last?.id
        }

        return true
    }

    private func loadDroppedPDFURLs(from providers: [NSItemProvider]) async -> [URL] {
        await withTaskGroup(of: URL?.self) { group in
            for provider in providers where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                group.addTask {
                    await loadFileURL(from: provider)
                }
            }

            var urls: [URL] = []
            for await url in group {
                guard let url, url.pathExtension.lowercased() == "pdf" else { continue }
                urls.append(url)
            }
            return urls
        }
    }

    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                if let data = item as? Data,
                   let url = URL(dataRepresentation: data, relativeTo: nil) {
                    continuation.resume(returning: url)
                    return
                }

                if let url = item as? URL {
                    continuation.resume(returning: url)
                    return
                }

                if let string = item as? String,
                   let url = URL(string: string) {
                    continuation.resume(returning: url)
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }

    private func syncPaperSelection() {
        let paperIDs = Set(filteredPapers.map(\.id))
        if let selectedPaperID, paperIDs.contains(selectedPaperID) {
            return
        }
        selectedPaperID = filteredPapers.first?.id
    }

    private func expandSelectedPaper() {
        guard selectedPaper != nil, selectedPaperPDFURL != nil else { return }
        isReaderExpanded = true
    }

    private func executeAgentCommands() {
        let commands = piChatManager.consumePendingCommands()
        guard !commands.isEmpty else { return }

        if !isReaderExpanded, selectedPaper != nil {
            isReaderExpanded = true
        }

        for command in commands {
            switch command {
            case .goToPage(let page):
                readerController.goToPage(page)
            case .focusAnnotation(let annotationID):
                readerController.focusAnnotation(id: annotationID)
            case .previewAnnotation(let annotationID):
                readerController.previewAnnotation(id: annotationID)
            case .previewText(let page, let text):
                readerController.previewText(page: page, text: text)
            case .clearPreview:
                readerController.clearPreview()
            }
        }
    }

    private func executeBridgeCommand(_ command: AgentUICommand) -> String {
        switch command {
        case .goToPage(let page):
            if !isReaderExpanded, selectedPaper != nil {
                isReaderExpanded = true
            }
            readerController.goToPage(page)
            return "Moved to page \(page)."
        case .focusAnnotation(let annotationID):
            if !isReaderExpanded, selectedPaper != nil {
                isReaderExpanded = true
            }
            readerController.focusAnnotation(id: annotationID)
            return "Focused annotation \(annotationID)."
        case .previewAnnotation(let annotationID):
            if !isReaderExpanded, selectedPaper != nil {
                isReaderExpanded = true
            }
            readerController.previewAnnotation(id: annotationID)
            return "Previewed annotation \(annotationID)."
        case .previewText(let page, let text):
            if !isReaderExpanded, selectedPaper != nil {
                isReaderExpanded = true
            }
            readerController.previewText(page: page, text: text)
            return "Previewed text on page \(page): \(text)"
        case .clearPreview:
            readerController.clearPreview()
            return "Cleared PDF preview."
        }
    }

    private func syncPiBridgeContext() {
        piBridge.updateContext(agentContext)
    }

    @ViewBuilder
    private func paperContextMenu(for paper: Paper) -> some View {
        Button {
            Task { await store.refreshMetadata(for: paper.id) }
        } label: {
            Text("Refresh Metadata")
        }

        Button {
            selectedPaperID = paper.id
            expandSelectedPaper()
        } label: {
            Text("Focus Reader")
        }

        Button(role: .destructive) {
            let deletedID = paper.id
            store.deletePaper(deletedID)
            if selectedPaperID == deletedID {
                selectedPaperID = filteredPapers.first?.id
            }
        } label: {
            Text("Delete Paper")
        }
    }

    private func authorCellText(for paper: Paper) -> String {
        if !paper.authors.isEmpty {
            return paper.authors.joined(separator: ", ")
        }
        return "—"
    }

    private func statusText(for paper: Paper) -> String? {
        let line = [paper.venue, paper.year.map(String.init)]
            .compactMap { $0 }
            .joined(separator: " · ")

        if !line.isEmpty {
            return line
        }

        return paper.metadataSource ?? paper.sourceFilename
    }
}

private struct PaperRow: View {
    let paper: Paper

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top) {
                Text(paper.title)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                Spacer()
                StatusBadge(status: paper.metadataStatus)
            }

            if !paper.authors.isEmpty {
                Text(paper.authors.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            } else {
                Text(paper.sourceFilename)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if let venueLine = [paper.venue, paper.year.map(String.init)].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
                Text(venueLine)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PaperDetailView: View {
    let paper: Paper
    let pdfURL: URL?
    let onRefreshMetadata: () -> Void
    let onLookupIdentifier: (String) -> Void

    var body: some View {
        Group {
            if let pdfURL {
                PDFDocumentView(url: pdfURL, readerController: nil)
            } else {
                ContentUnavailableView(
                    "PDF Missing",
                    systemImage: "exclamationmark.triangle",
                    description: Text("The imported PDF file is no longer available in app storage.")
                )
            }
        }
        .navigationTitle(paper.title)
    }
}

private struct FocusedReaderView: View {
    let paper: Paper
    let pdfURL: URL
    @ObservedObject var readerController: PDFReaderController

    var body: some View {
        PDFDocumentView(url: pdfURL, readerController: readerController)
            .navigationTitle(paper.title)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct NoteComposerSheet: View {
    @Binding var text: String
    let onCancel: () -> Void
    let onAdd: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Note")
                .font(.title3.weight(.semibold))

            Text("If text is selected, the note is attached next to that selection. Otherwise it is placed on the current page.")
                .font(.callout)
                .foregroundStyle(.secondary)

            TextEditor(text: $text)
                .font(.body)
                .frame(height: 160)
                .overlay(
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(Color.secondary.opacity(0.2))
                )

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Add Note", action: onAdd)
                    .keyboardShortcut(.defaultAction)
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 420)
    }
}

struct StatusBadge: View {
    let status: MetadataStatus

    var body: some View {
        Text(label)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(color.opacity(0.14), in: Capsule())
            .foregroundStyle(color)
    }

    private var label: String {
        switch status {
        case .pending:
            return "Pending"
        case .resolved:
            return "Resolved"
        case .failed:
            return "Needs Help"
        }
    }

    private var color: Color {
        switch status {
        case .pending:
            return .blue
        case .resolved:
            return .green
        case .failed:
            return .orange
        }
    }
}

private struct ProjectSidebarRow: View {
    let project: Project
    let canDelete: Bool
    let onDropProviders: ([NSItemProvider]) -> Bool
    let onDelete: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "folder")
                .foregroundStyle(Color.accentColor)
            VStack(alignment: .leading, spacing: 3) {
                Text(project.name)
                    .font(.body.weight(.medium))
                Text("\(project.paperIDs.count) papers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isDropTargeted ? Color.accentColor.opacity(0.16) : Color.clear)
        )
        .onDrop(
            of: [UTType.fileURL.identifier],
            isTargeted: $isDropTargeted,
            perform: onDropProviders
        )
        .contextMenu {
            if canDelete {
                Button(role: .destructive, action: onDelete) {
                    Text("Delete Project")
                }
            }
        }
    }
}

private struct NewProjectSheet: View {
    @Binding var name: String
    let onCancel: () -> Void
    let onCreate: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("New Project")
                .font(.title3.weight(.semibold))

            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onCreate)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Create", action: onCreate)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 360)
    }
}

private struct DropHintView: View {
    let label: String

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(.ultraThinMaterial)
            .stroke(Color.accentColor.opacity(0.45), style: StrokeStyle(lineWidth: 1.5, dash: [8, 6]))
            .overlay {
                VStack(spacing: 10) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 28, weight: .semibold))
                        .foregroundStyle(Color.accentColor)
                    Text(label)
                        .font(.headline)
                }
                .padding(28)
            }
            .frame(maxWidth: 320, maxHeight: 180)
            .allowsHitTesting(false)
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
