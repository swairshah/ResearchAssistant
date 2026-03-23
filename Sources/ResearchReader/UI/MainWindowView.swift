import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MainWindowView: View {
    @EnvironmentObject private var store: LibraryStore
    @EnvironmentObject private var shortcuts: ShortcutSettingsStore

    @StateObject private var piBridge = ResearchPiBridge()
    @StateObject private var piChatManager = ResearchPiChatManager()
    @StateObject private var readerController = PDFReaderController()
    @StateObject private var notebookStore = ProjectNotebookStore()
    @StateObject private var shortcutMonitor = ShortcutEventMonitor()
    @StateObject private var voiceInput = PiVoiceInputController()
    @State private var selectedProjectID: UUID?
    @State private var selectedPaperID: UUID?
    @State private var newProjectName = ""
    @State private var showingProjectSheet = false
    @State private var showingRenameProjectSheet = false
    @State private var projectRenameDraft = ""
    @State private var projectRenameTargetID: UUID?
    @State private var showingAgentChat = false
    @State private var showingNoteSheet = false
    @State private var isPaperListDropTargeted = false
    @State private var searchText = ""
    @State private var isReaderExpanded = false
    @State private var isNotebookVisible = false
    @State private var noteDraft = ""
    @State private var queuedVoicePrompts: [String] = []
    @State private var hasUnreadChatActivity = false
    @State private var expandedProjectIDs: Set<UUID> = []
    @State private var hoveredProjectID: UUID?
    @State private var hoveredPaperID: UUID?

    var body: some View {
        AnyView(rootContent)
            .overlay(alignment: .bottomTrailing) {
                floatingOverlay
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
        .sheet(isPresented: $showingRenameProjectSheet) {
            RenameProjectSheet(
                name: $projectRenameDraft,
                onCancel: {
                    projectRenameDraft = ""
                    projectRenameTargetID = nil
                    showingRenameProjectSheet = false
                },
                onSave: {
                    guard let id = projectRenameTargetID else { return }
                    store.renameProject(id, to: projectRenameDraft)
                    projectRenameDraft = ""
                    projectRenameTargetID = nil
                    showingRenameProjectSheet = false
                    syncPiBridgeContext()
                }
            )
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                if isReaderExpanded {
                    Button {
                        isReaderExpanded = false
                    } label: {
                        Label("Library", systemImage: "chevron.left")
                    }
                    .help("Back to library (Esc)")

                    Spacer()

                    if store.isImporting {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Button {
                        if let paper = selectedPaper {
                            Task { await store.refreshMetadata(for: paper.id) }
                        }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .help("Re-fetch paper metadata")
                    .disabled(selectedPaper == nil)

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isNotebookVisible.toggle()
                        }
                    } label: {
                        Label("Notebook", systemImage: isNotebookVisible ? "note.text.badge.plus" : "note.text")
                    }
                    .help(isNotebookVisible ? "Hide notebook" : "Show notebook")
                    .disabled(selectedProject == nil)
                } else {
                    Button {
                        showingProjectSheet = true
                    } label: {
                        Label("New Project", systemImage: "folder.badge.plus")
                    }
                    .help("Create a new project")

                    Button {
                        importPDFs()
                    } label: {
                        Label("Import", systemImage: "plus")
                    }
                    .help("Import PDF files or URLs")
                    .disabled(selectedProjectID == nil || store.isImporting)

                    if store.isImporting {
                        ProgressView()
                            .controlSize(.small)
                    }

                    Spacer()

                    Button {
                        expandSelectedPaper()
                    } label: {
                        Label("Read", systemImage: "book.pages")
                    }
                    .help("Open paper in focus reader")
                    .disabled(selectedPaper == nil || selectedPaperPDFURL == nil)

                    Button {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            isNotebookVisible.toggle()
                        }
                    } label: {
                        Label("Notebook", systemImage: isNotebookVisible ? "note.text.badge.plus" : "note.text")
                    }
                    .help(isNotebookVisible ? "Hide notebook" : "Show notebook")
                    .disabled(selectedProject == nil)

                    if let paper = selectedPaper {
                        Button(role: .destructive) {
                            deleteSelectedPaper()
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                        .help("Delete '\(paper.title)'")
                    }
                }
            }
        }
        .onAppear {
            configureVoiceInputCallbacks()
            piBridge.start(commandHandler: executeBridgeCommand)
            shortcutMonitor.start(handler: handleShortcutEvent)
            if selectedProjectID == nil {
                selectedProjectID = store.projects.first?.id
            }
            syncExpandedProjects()
            notebookStore.load(project: selectedProject)
            syncPaperSelection()
            syncPiBridgeContext()
        }
        .onChange(of: store.projects) { _, _ in
            if selectedProjectID == nil {
                selectedProjectID = store.projects.first?.id
            }
            syncExpandedProjects()
            notebookStore.load(project: selectedProject)
            syncPaperSelection()
            syncPiBridgeContext()
        }
        .onChange(of: store.papers) { _, _ in
            syncPaperSelection()
            syncPiBridgeContext()
        }
        .onChange(of: selectedProjectID) { _, _ in
            syncExpandedProjects()
            notebookStore.load(project: selectedProject)
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
        .onChange(of: piChatManager.isProcessing) { _, isProcessing in
            guard !isProcessing else { return }
            flushQueuedVoicePromptIfNeeded()
        }
        .onChange(of: readerController.currentPageNumber) { _, _ in
            syncPiBridgeContext()
        }
        .onChange(of: readerController.pageCount) { _, _ in
            syncPiBridgeContext()
        }
        .onChange(of: readerController.currentSelection) { _, _ in
            syncPiBridgeContext()
        }
        .onChange(of: readerController.annotationSummaries) { _, _ in
            syncPiBridgeContext()
        }
        .onChange(of: notebookStore.markdown) { _, _ in
            syncPiBridgeContext()
        }
        .onChange(of: isNotebookVisible) { _, isVisible in
            guard isVisible,
                  !isReaderExpanded,
                  selectedPaper != nil,
                  selectedPaperPDFURL != nil else { return }
            withAnimation(.easeInOut(duration: 0.18)) {
                isReaderExpanded = true
            }
        }
        .onMoveCommand(perform: handleMoveCommand)
        .onDeleteCommand {
            if !isReaderExpanded {
                deleteSelectedPaper()
            }
        }
        .onDisappear {
            shortcutMonitor.stop()
            voiceInput.stop()
        }
    }

    private var rootContent: some View {
        Group {
            if isReaderExpanded, let paper = selectedPaper, let pdfURL = selectedPaperPDFURL {
                FocusedReaderView(
                    paper: paper,
                    pdfURL: pdfURL,
                    project: selectedProject,
                    isNotebookVisible: isNotebookVisible,
                    notebookText: notebookBinding,
                    notebookLastSavedAt: notebookStore.lastSavedAt,
                    readerController: readerController
                )
            } else {
                NavigationSplitView {
                    librarySidebar
                } detail: {
                    detailPane
                }
                .navigationSplitViewStyle(.balanced)
                .searchable(text: $searchText, placement: .toolbar, prompt: "Search title, author, DOI, arXiv")
            }
        }
    }

    private var micButtonColor: Color {
        switch voiceInput.state {
        case .error:
            return .red
        case .off:
            return Color.gray.opacity(0.6)
        case .listening, .transcribing:
            return .green
        }
    }

    private var chatButtonColor: Color {
        if hasUnreadChatActivity, !showingAgentChat {
            return Color(red: 0.64, green: 0.86, blue: 0.64)
        }
        return Color.accentColor
    }

    private var floatingOverlay: some View {
        VStack(alignment: .trailing, spacing: 12) {
            if showingAgentChat {
                AgentChatPanel(
                    chatManager: piChatManager,
                    context: agentContext,
                    onClose: { showingAgentChat = false }
                )
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }

            HStack(spacing: 10) {
                Button {
                    voiceInput.toggle()
                } label: {
                    Image(systemName: voiceInput.isActive ? "mic.fill" : "mic")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 46, height: 46)
                        .foregroundStyle(.white)
                        .background(micButtonColor, in: Circle())
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.16), radius: 10, y: 5)
                .help("Voice input: \(voiceInput.state.label) (⌘/)")

                Button {
                    withAnimation(.spring(duration: 0.24)) {
                        if showingAgentChat {
                            showingAgentChat = false
                        } else {
                            showingAgentChat = true
                            hasUnreadChatActivity = false
                        }
                    }
                } label: {
                    Image(systemName: showingAgentChat ? "xmark" : "message.badge.waveform.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .foregroundStyle(.white)
                        .background(chatButtonColor, in: Circle())
                }
                .buttonStyle(.plain)
                .shadow(color: .black.opacity(0.16), radius: 12, y: 6)
                .help("Open Pi agent")
            }
        }
        .padding(20)
    }

    private var librarySidebar: some View {
        List {
            ForEach(store.projects) { project in
                sidebarProjectHeader(for: project)

                if expandedProjectIDs.contains(project.id) {
                    let papers = filteredPapers(in: project.id)
                    if papers.isEmpty {
                        Text(searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "No papers yet" : "No matching papers")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .padding(.leading, 36)
                            .padding(.vertical, 2)
                            .listRowSeparator(.hidden)
                    } else {
                        ForEach(papers) { paper in
                            sidebarPaperRow(paper: paper, projectID: project.id)
                        }
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .overlay {
            if isPaperListDropTargeted, selectedProjectID != nil {
                DropHintView(label: "Drop PDFs or URLs to import into this project")
                    .padding(24)
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.plainText.identifier],
            isTargeted: $isPaperListDropTargeted,
            perform: { providers in
                guard let projectID = selectedProjectID else { return false }
                return handleDrop(providers, into: projectID)
            }
        )
        .navigationTitle("Research Reader")
    }

    @ViewBuilder
    private func sidebarProjectHeader(for project: Project) -> some View {
        let isExpanded = expandedProjectIDs.contains(project.id)
        let papers = filteredPapers(in: project.id)

        ProjectSidebarRow(
            project: project,
            isExpanded: isExpanded,
            canDelete: store.projects.count > 1,
            onDropProviders: { providers in
                handleDrop(providers, into: project.id)
            },
            onRename: {
                projectRenameTargetID = project.id
                projectRenameDraft = project.name
                showingRenameProjectSheet = true
            },
            onDelete: {
                let shouldReselect = selectedProjectID == project.id
                store.deleteProject(project.id)
                if shouldReselect {
                    selectedProjectID = store.projects.first?.id
                }
            }
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedProjectID = project.id
            if isExpanded {
                expandedProjectIDs.remove(project.id)
            } else {
                expandedProjectIDs.insert(project.id)
                if let selectedPaperID,
                   store.paper(for: selectedPaperID)?.projectID != project.id {
                    self.selectedPaperID = papers.first?.id
                }
            }
        }
        .onHover { isHovering in
            if isHovering {
                hoveredProjectID = project.id
            } else if hoveredProjectID == project.id {
                hoveredProjectID = nil
            }
        }
        .listRowBackground(projectRowBackground(for: project.id))
        .listRowSeparator(.hidden)
    }

    @ViewBuilder
    private func sidebarPaperRow(paper: Paper, projectID: UUID) -> some View {
        Button {
            selectedProjectID = projectID
            selectedPaperID = paper.id
        } label: {
            SidebarPaperRow(paper: paper)
                .padding(.leading, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .simultaneousGesture(TapGesture(count: 2).onEnded {
            selectedProjectID = projectID
            selectedPaperID = paper.id
            expandSelectedPaper()
        })
        .onHover { isHovering in
            if isHovering {
                hoveredPaperID = paper.id
            } else if hoveredPaperID == paper.id {
                hoveredPaperID = nil
            }
        }
        .contextMenu {
            paperContextMenu(for: paper)
        }
        .listRowBackground(paperRowBackground(for: paper.id))
        .listRowSeparator(.hidden)
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
                DropHintView(label: "Drop PDFs or URLs to import into this project")
                    .padding(24)
            }
        }
        .onDrop(
            of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.plainText.identifier],
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
                project: selectedProject,
                isNotebookVisible: isNotebookVisible,
                paper: paper,
                pdfURL: store.pdfURL(for: paper),
                readerController: readerController,
                notebookText: notebookBinding,
                notebookLastSavedAt: notebookStore.lastSavedAt,
                onRefreshMetadata: {
                    Task { await store.refreshMetadata(for: paper.id) }
                },
                onLookupIdentifier: { identifier in
                    Task { await store.lookupMetadata(for: paper.id, identifier: identifier) }
                }
            )
        } else if let project = selectedProject {
            if isNotebookVisible {
                ProjectNotebookView(
                    project: project,
                    markdown: notebookBinding,
                    lastSavedAt: notebookStore.lastSavedAt
                )
            } else {
                ContentUnavailableView(
                    "Select a Paper",
                    systemImage: "doc.richtext",
                    description: Text("Choose a paper to view its PDF, or open the notebook from the toolbar.")
                )
            }
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

    private var selectedProject: Project? {
        store.project(for: selectedProjectID)
    }

    private var selectedPaperPDFURL: URL? {
        guard let selectedPaper else { return nil }
        return store.pdfURL(for: selectedPaper)
    }

    private var agentContext: AgentContextSnapshot {
        AgentContextSnapshot(
            projectName: selectedProject?.name,
            projectPaperCount: store.papers(in: selectedProjectID).count,
            projectPapers: store.papers(in: selectedProjectID).map { ProjectPaperSummary(paper: $0) },
            collections: store.projects.map { ProjectCollectionSummary(project: $0) },
            paper: selectedPaper,
            pdfURL: selectedPaperPDFURL,
            currentPage: selectedPaper != nil ? readerController.currentPageNumber : nil,
            pageCount: selectedPaper != nil ? readerController.pageCount : nil,
            currentSelection: selectedPaper != nil ? readerController.currentSelection : nil,
            annotations: selectedPaper != nil ? readerController.annotationSummaries : [],
            notebook: notebookStore.snapshot(project: selectedProject, papers: store.papers(in: selectedProjectID)),
            isFocusReaderVisible: isReaderExpanded,
            isNotebookVisible: isNotebookVisible
        )
    }

    private var notebookBinding: Binding<String> {
        Binding(
            get: { notebookStore.markdown },
            set: { notebookStore.updateMarkdown($0, for: selectedProject) }
        )
    }

    private var filteredPapers: [Paper] {
        filteredPapers(in: selectedProjectID)
    }

    private func filteredPapers(in projectID: UUID?) -> [Paper] {
        let papers = store.papers(in: projectID)
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
        let hasFileURL = providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        let hasURL = providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) })
        let hasPlainText = providers.contains(where: { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) })

        guard hasFileURL || hasURL || hasPlainText else { return false }

        Task {
            let (localPDFs, webURLs) = await loadDroppedURLs(from: providers)

            guard !localPDFs.isEmpty || !webURLs.isEmpty else { return }

            selectedProjectID = projectID

            if !localPDFs.isEmpty {
                await store.importPDFs(urls: localPDFs, into: projectID)
            }

            for webURL in webURLs {
                await store.importFromURL(webURL, into: projectID)
            }

            selectedPaperID = store.papers(in: projectID).last?.id
        }

        return true
    }

    /// Returns (localPDFFiles, webURLs) from the drop providers.
    private func loadDroppedURLs(from providers: [NSItemProvider]) async -> ([URL], [URL]) {
        var localPDFs: [URL] = []
        var webURLs: [URL] = []

        for provider in providers {
            // Try loading as file URL first
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
               let fileURL = await loadItemURL(from: provider, typeIdentifier: UTType.fileURL.identifier) {
                if fileURL.isFileURL, fileURL.pathExtension.lowercased() == "pdf" {
                    localPDFs.append(fileURL)
                } else if !fileURL.isFileURL, let scheme = fileURL.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                    webURLs.append(fileURL)
                }
                continue
            }

            // Try loading as generic URL (browser drags often use this)
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
               let url = await loadItemURL(from: provider, typeIdentifier: UTType.url.identifier),
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                webURLs.append(url)
                continue
            }

            // Fall back to plain text (some apps drag URLs as plain text)
            if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
               let url = await loadPlainTextURL(from: provider),
               let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) {
                webURLs.append(url)
            }
        }

        return (localPDFs, webURLs)
    }

    private func loadItemURL(from provider: NSItemProvider, typeIdentifier: String) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: typeIdentifier, options: nil) { item, error in
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

    private func loadPlainTextURL(from provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { item, error in
                guard error == nil else {
                    continuation.resume(returning: nil)
                    return
                }

                if let string = item as? String,
                   let url = URL(string: string.trimmingCharacters(in: .whitespacesAndNewlines)),
                   url.scheme != nil {
                    continuation.resume(returning: url)
                    return
                }

                continuation.resume(returning: nil)
            }
        }
    }

    private func syncExpandedProjects() {
        let validIDs = Set(store.projects.map(\.id))
        expandedProjectIDs = expandedProjectIDs.intersection(validIDs)

        if let selectedProjectID {
            expandedProjectIDs.insert(selectedProjectID)
        } else if expandedProjectIDs.isEmpty,
                  let first = store.projects.first?.id {
            expandedProjectIDs.insert(first)
        }
    }

    private func projectRowBackground(for projectID: UUID) -> Color {
        if selectedProjectID == projectID {
            return Color.accentColor.opacity(0.18)
        }
        if hoveredProjectID == projectID {
            return Color.accentColor.opacity(0.08)
        }
        return Color.clear
    }

    private func paperRowBackground(for paperID: UUID) -> Color {
        if selectedPaperID == paperID {
            return Color.accentColor.opacity(0.20)
        }
        if hoveredPaperID == paperID {
            return Color.accentColor.opacity(0.10)
        }
        return Color.clear
    }

    private func syncPaperSelection() {
        let paperIDs = Set(filteredPapers.map(\.id))
        if let selectedPaperID, paperIDs.contains(selectedPaperID) {
            return
        }
        selectedPaperID = filteredPapers.first?.id
    }

    private var visibleSidebarPapers: [Paper] {
        store.projects.flatMap { project -> [Paper] in
            guard expandedProjectIDs.contains(project.id) else { return [] }
            return filteredPapers(in: project.id)
        }
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        guard !isReaderExpanded else { return }

        switch direction {
        case .down:
            movePaperSelection(by: 1)
        case .up:
            movePaperSelection(by: -1)
        default:
            break
        }
    }

    private func movePaperSelection(by step: Int) {
        let papers = visibleSidebarPapers
        guard !papers.isEmpty else { return }

        guard let currentSelectedPaperID = selectedPaperID,
              let currentIndex = papers.firstIndex(where: { $0.id == currentSelectedPaperID }) else {
            let first = papers[0]
            selectedProjectID = first.projectID
            self.selectedPaperID = first.id
            return
        }

        let nextIndex = max(0, min(papers.count - 1, currentIndex + step))
        guard nextIndex != currentIndex else { return }

        let next = papers[nextIndex]
        selectedProjectID = next.projectID
        expandedProjectIDs.insert(next.projectID)
        self.selectedPaperID = next.id
    }

    private func expandSelectedPaper() {
        guard selectedPaper != nil, selectedPaperPDFURL != nil else { return }
        isReaderExpanded = true
    }

    private func deleteSelectedPaper() {
        guard let paper = selectedPaper else { return }
        let deletedID = paper.id
        store.deletePaper(deletedID)
        if selectedPaperID == deletedID {
            selectedPaperID = filteredPapers.first?.id
        }
        if isReaderExpanded, selectedPaper == nil {
            isReaderExpanded = false
        }
    }

    private func configureVoiceInputCallbacks() {
        voiceInput.onTranscript = { text in
            enqueueVoicePrompt(text)
        }

        voiceInput.onError = { _ in
            NSSound.beep()
        }
    }

    private func enqueueVoicePrompt(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        if !showingAgentChat {
            hasUnreadChatActivity = true
        }

        if piChatManager.isProcessing {
            queuedVoicePrompts.append(trimmed)
            return
        }

        piChatManager.send(trimmed, context: agentContext)
    }

    private func flushQueuedVoicePromptIfNeeded() {
        guard !piChatManager.isProcessing,
              !queuedVoicePrompts.isEmpty else {
            return
        }

        let next = queuedVoicePrompts.removeFirst()
        enqueueVoicePrompt(next)
    }

    private func executeAgentCommands() {
        let commands = piChatManager.consumePendingCommands()
        guard !commands.isEmpty else { return }

        for command in commands {
            _ = executeBridgeCommand(command)
        }
    }

    private func executeBridgeCommand(_ command: AgentUICommand) -> String {
        switch command {
        case .goToPage(let page):
            guard prepareReaderForNavigation() == nil else {
                return "No active paper PDF is open."
            }
            readerController.goToPage(page)
            return "Moved to page \(page)."

        case .focusAnnotation(let annotationID):
            guard prepareReaderForNavigation() == nil else {
                return "No active paper PDF is open."
            }
            readerController.focusAnnotation(id: annotationID)
            return "Focused annotation \(annotationID)."

        case .previewAnnotation(let annotationID):
            guard prepareReaderForNavigation() == nil else {
                return "No active paper PDF is open."
            }
            readerController.previewAnnotation(id: annotationID)
            return "Previewed annotation \(annotationID)."

        case .previewText(let page, let text):
            guard prepareReaderForNavigation() == nil else {
                return "No active paper PDF is open."
            }
            readerController.previewText(page: page, text: text)
            return "Previewed text on page \(page): \(text)"

        case .clearPreview:
            readerController.clearPreview()
            return "Cleared PDF preview."

        case .replaceProjectNotebook(let markdown):
            guard let project = selectedProject else {
                return "No active project is selected."
            }
            notebookStore.replaceNotebook(with: markdown, for: project)
            syncPiBridgeContext()
            return "Replaced the notebook for \(project.name)."

        case .appendProjectNotebook(let markdown):
            guard let project = selectedProject else {
                return "No active project is selected."
            }
            notebookStore.appendToNotebook(markdown, for: project)
            syncPiBridgeContext()
            return "Appended to the notebook for \(project.name)."

        case .selectPaper(let paperID, let openInFocusReader):
            return selectPaperForAgent(paperID: paperID, openInFocusReader: openInFocusReader)

        case .setNotebookVisibility(let action):
            guard selectedProject != nil else {
                return "No active project is selected."
            }
            switch action {
            case .open:
                isNotebookVisible = true
                syncPiBridgeContext()
                return "Opened notebook panel."
            case .close:
                isNotebookVisible = false
                syncPiBridgeContext()
                return "Closed notebook panel."
            case .toggle:
                isNotebookVisible.toggle()
                syncPiBridgeContext()
                return isNotebookVisible ? "Opened notebook panel." : "Closed notebook panel."
            }

        case .setFocusReaderVisibility(let action):
            switch action {
            case .open:
                guard selectedPaper != nil, selectedPaperPDFURL != nil else {
                    return "No paper with a local PDF is selected."
                }
                isReaderExpanded = true
                syncPiBridgeContext()
                return "Opened Focus Reader."
            case .close:
                isReaderExpanded = false
                syncPiBridgeContext()
                return "Closed Focus Reader."
            case .toggle:
                if isReaderExpanded {
                    isReaderExpanded = false
                    syncPiBridgeContext()
                    return "Closed Focus Reader."
                }
                guard selectedPaper != nil, selectedPaperPDFURL != nil else {
                    return "No paper with a local PDF is selected."
                }
                isReaderExpanded = true
                syncPiBridgeContext()
                return "Opened Focus Reader."
            }

        case .addNote(let text):
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                return "Note text is empty."
            }
            guard prepareReaderForEditing() == nil else {
                return "PDF view is not ready yet. Open Focus Reader and try again."
            }
            readerController.addNote(trimmed)
            return "Added note."

        case .highlightSelection:
            guard prepareReaderForEditing() == nil else {
                return "PDF view is not ready yet. Select text in the PDF first."
            }
            readerController.highlightSelection()
            return "Applied highlight to current selection."

        case .removeHighlightsInSelection:
            guard prepareReaderForEditing() == nil else {
                return "PDF view is not ready yet."
            }
            readerController.removeHighlightsInSelection()
            return "Removed highlight(s) from current selection/context."

        case .addPaperToCollection(let draft):
            let title = draft.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else {
                return "Paper title is required."
            }

            guard let project = resolveCollectionProject(named: draft.collectionName) else {
                if let requested = draft.collectionName,
                   !requested.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    return "Collection '\(requested)' was not found."
                }
                return "No active collection is selected."
            }

            guard let paper = store.addPaperToProject(
                projectID: project.id,
                title: title,
                authors: draft.authors,
                venue: draft.venue,
                year: draft.year,
                doi: draft.doi,
                arxivID: draft.arxivID,
                abstractText: draft.abstractText,
                sourceLabel: draft.sourceURL ?? title,
                pdfURL: draft.pdfURL,
                sourceURL: draft.sourceURL
            ) else {
                return "Failed to add paper to collection '\(project.name)'."
            }

            selectedProjectID = project.id
            selectedPaperID = paper.id
            syncPiBridgeContext()

            if paper.pdfRelativePath.isEmpty {
                return "Added '\(paper.title)' to collection '\(project.name)' without a PDF. Provide a direct PDF URL to attach the file."
            }
            return "Added '\(paper.title)' to collection '\(project.name)' with PDF attached."

        case .getActivePDFText(let maxPages, let startPage, let endPage):
            guard let paper = selectedPaper,
                  let pdfURL = selectedPaperPDFURL else {
                return "No active paper PDF is available."
            }

            let text = PDFTextExtractor.extractText(
                from: pdfURL,
                maxPages: maxPages ?? 12,
                startPage: startPage,
                endPage: endPage
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)

            guard !text.isEmpty else {
                return "Could not extract readable text from '\(paper.title)'."
            }

            return "[PDF_TEXT_BEGIN]\nTitle: \(paper.title)\n\n\(text)\n[PDF_TEXT_END]"
        }
    }

    private func prepareReaderForNavigation() -> String? {
        guard selectedPaper != nil, selectedPaperPDFURL != nil else {
            return "No paper with a local PDF is selected."
        }
        if !isReaderExpanded {
            isReaderExpanded = true
        }
        return nil
    }

    private func prepareReaderForEditing() -> String? {
        if let error = prepareReaderForNavigation() {
            return error
        }
        guard readerController.isDocumentLoaded else {
            return "PDF is not loaded yet."
        }
        return nil
    }

    private func resolveCollectionProject(named collectionName: String?) -> Project? {
        if let collectionName {
            let trimmed = collectionName.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                if let exact = store.projects.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
                    return exact
                }

                if let contains = store.projects.first(where: { $0.name.localizedCaseInsensitiveContains(trimmed) }) {
                    return contains
                }

                return nil
            }
        }

        return selectedProject
    }

    private func selectPaperForAgent(paperID: String, openInFocusReader: Bool) -> String {
        guard let id = UUID(uuidString: paperID) else {
            return "Invalid paper ID: \(paperID)"
        }
        guard let paper = store.paper(for: id) else {
            return "Paper not found for ID: \(paperID)"
        }

        selectedProjectID = paper.projectID
        selectedPaperID = paper.id

        if openInFocusReader {
            isReaderExpanded = true
        }

        syncPiBridgeContext()
        return openInFocusReader
            ? "Selected paper '\(paper.title)' and opened Focus Reader."
            : "Selected paper '\(paper.title)'."
    }

    private func syncPiBridgeContext() {
        piBridge.updateContext(agentContext)
    }

    private func handleShortcutEvent(_ event: NSEvent) -> Bool {
        guard let action = shortcuts.matchedAction(for: event) else {
            return false
        }
        executeShortcutAction(action)
        return true
    }

    private func executeShortcutAction(_ action: AppShortcutAction) {
        switch action {
        case .focusReader:
            expandSelectedPaper()
        case .backToLibrary:
            if isReaderExpanded {
                isReaderExpanded = false
            } else {
                expandSelectedPaper()
            }
        case .togglePiChat:
            withAnimation(.spring(duration: 0.24)) {
                if showingAgentChat {
                    showingAgentChat = false
                } else {
                    showingAgentChat = true
                    hasUnreadChatActivity = false
                }
            }
        case .toggleVoiceInput:
            voiceInput.toggle()
        case .highlightSelection:
            if readerController.isDocumentLoaded {
                readerController.highlightSelection()
            }
        case .addNote:
            if readerController.isDocumentLoaded {
                noteDraft = ""
                showingNoteSheet = true
            }
        case .toggleNotebook:
            if selectedProject != nil {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isNotebookVisible.toggle()
                }
            }
        case .undo:
            if readerController.canUndo {
                readerController.undo()
            }
        }
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

private struct SidebarPaperRow: View {
    let paper: Paper

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "doc.richtext")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(paper.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                if let venueLine = [paper.venue, paper.year.map(String.init)].compactMap({ $0 }).joined(separator: " · ").nonEmpty {
                    Text(venueLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 4)
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
    let project: Project?
    let isNotebookVisible: Bool
    let paper: Paper
    let pdfURL: URL?
    @ObservedObject var readerController: PDFReaderController
    @Binding var notebookText: String
    let notebookLastSavedAt: Date?
    let onRefreshMetadata: () -> Void
    let onLookupIdentifier: (String) -> Void

    var body: some View {
        Group {
            if isNotebookVisible, let project {
                HSplitView {
                    pdfPane
                        .frame(minWidth: 520, maxWidth: .infinity, maxHeight: .infinity)

                    ProjectNotebookView(
                        project: project,
                        markdown: $notebookText,
                        lastSavedAt: notebookLastSavedAt
                    )
                    .frame(minWidth: 340, idealWidth: 420, maxWidth: 560, maxHeight: .infinity)
                }
            } else {
                pdfPane
            }
        }
        .navigationTitle(paper.title)
    }

    @ViewBuilder
    private var pdfPane: some View {
        if let pdfURL {
            PDFDocumentView(url: pdfURL, paperID: paper.id, readerController: readerController)
        } else {
            ContentUnavailableView(
                "PDF Missing",
                systemImage: "exclamationmark.triangle",
                description: Text("The imported PDF file is no longer available in app storage.")
            )
        }
    }
}

private struct FocusedReaderView: View {
    let paper: Paper
    let pdfURL: URL
    let project: Project?
    let isNotebookVisible: Bool
    @Binding var notebookText: String
    let notebookLastSavedAt: Date?
    @ObservedObject var readerController: PDFReaderController

    var body: some View {
        Group {
            if isNotebookVisible, let project {
                HSplitView {
                    PDFDocumentView(url: pdfURL, paperID: paper.id, readerController: readerController)
                        .frame(minWidth: 640, maxWidth: .infinity, maxHeight: .infinity)

                    ProjectNotebookView(
                        project: project,
                        markdown: $notebookText,
                        lastSavedAt: notebookLastSavedAt
                    )
                    .frame(minWidth: 360, idealWidth: 440, maxWidth: 580, maxHeight: .infinity)
                }
            } else {
                PDFDocumentView(url: pdfURL, paperID: paper.id, readerController: readerController)
            }
        }
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
    let isExpanded: Bool
    let canDelete: Bool
    let onDropProviders: ([NSItemProvider]) -> Bool
    let onRename: () -> Void
    let onDelete: () -> Void

    @State private var isDropTargeted = false

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 12)

            Image(systemName: isExpanded ? "folder.fill" : "folder")
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
            of: [UTType.fileURL.identifier, UTType.url.identifier, UTType.plainText.identifier],
            isTargeted: $isDropTargeted,
            perform: onDropProviders
        )
        .contextMenu {
            Button("Rename Project", action: onRename)

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

private struct RenameProjectSheet: View {
    @Binding var name: String
    let onCancel: () -> Void
    let onSave: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Rename Project")
                .font(.title3.weight(.semibold))

            TextField("Project name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(onSave)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                Button("Save", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
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
