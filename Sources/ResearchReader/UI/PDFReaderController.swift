import AppKit
import Foundation
import PDFKit
import SwiftUI

private enum LocalAnnotationKind: String, Codable {
    case highlight
    case note
}

private struct LocalAnnotationRecord: Codable, Identifiable {
    let id: String
    let paperID: UUID
    let kind: LocalAnnotationKind
    let page: Int // 1-based
    let rects: [CGRect] // page-space rects
    let text: String?
    let note: String?
    let colorHex: String
    let createdAt: Date
    let updatedAt: Date
}

private struct LocalAnnotationSnapshot: Codable {
    var annotations: [LocalAnnotationRecord]
}

@MainActor
private final class LocalAnnotationStore {
    private let fileURL: URL
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()
    private var loaded = false
    private var records: [LocalAnnotationRecord] = []

    init() {
        let fileURL: URL
        if let paths = try? AppPaths.make() {
            fileURL = paths.annotationStoreFile
        } else {
            fileURL = URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Application Support/ResearchReader/annotations.json")
        }
        self.fileURL = fileURL
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    }

    func annotations(for paperID: UUID) -> [LocalAnnotationRecord] {
        ensureLoaded()
        return records
            .filter { $0.paperID == paperID }
            .sorted { lhs, rhs in
                if lhs.page != rhs.page { return lhs.page < rhs.page }
                return lhs.createdAt < rhs.createdAt
            }
    }

    func append(_ newRecords: [LocalAnnotationRecord]) {
        guard !newRecords.isEmpty else { return }
        ensureLoaded()
        records.append(contentsOf: newRecords)
        save()
    }

    func remove(ids: Set<String>, for paperID: UUID) {
        guard !ids.isEmpty else { return }
        ensureLoaded()
        records.removeAll { $0.paperID == paperID && ids.contains($0.id) }
        save()
    }

    private func ensureLoaded() {
        guard !loaded else { return }
        loaded = true

        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            records = []
            return
        }

        do {
            let data = try Data(contentsOf: fileURL)
            let snapshot = try decoder.decode(LocalAnnotationSnapshot.self, from: data)
            records = snapshot.annotations
        } catch {
            records = []
        }
    }

    private func save() {
        do {
            let parent = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            let data = try encoder.encode(LocalAnnotationSnapshot(annotations: records))
            try data.write(to: fileURL, options: [.atomic])
        } catch {
            assertionFailure("Unable to save annotations store: \(error.localizedDescription)")
        }
    }
}

@MainActor
final class PDFReaderController: ObservableObject {
    @Published private(set) var hasSelection = false
    @Published private(set) var isDocumentLoaded = false
    @Published private(set) var currentPageNumber = 1
    @Published private(set) var pageCount = 0
    @Published private(set) var currentSelection: PDFSelectionSummary?
    @Published private(set) var annotationSummaries: [PDFAnnotationSummary] = []
    @Published private(set) var canUndo = false

    private weak var pdfView: PDFView?
    private var selectionObserver: NSObjectProtocol?
    private var pageChangeObserver: NSObjectProtocol?

    private var activePaperID: UUID?
    private var activeDocumentIdentity: ObjectIdentifier?

    private var annotationRefMap: [String: (pageIndex: Int, bounds: CGRect)] = [:]
    private var previewAnnotations: [(page: PDFPage, annotation: PDFAnnotation)] = []
    private var previewClearTask: Task<Void, Never>?
    private var cachedSelection: PDFSelection?
    private weak var lastHitAnnotation: PDFAnnotation?

    private var localAnnotationIDByObject: [ObjectIdentifier: String] = [:]
    private let store = LocalAnnotationStore()

    private let previewUserName = "ResearchReaderPreview"
    private let localUserName = "ResearchReaderLocal"

    // MARK: - Undo stack

    private enum UndoableAction {
        /// Undo adding highlights — remove these record IDs.
        case addedHighlights(paperID: UUID, recordIDs: Set<String>)
        /// Undo adding a note — remove this record ID.
        case addedNote(paperID: UUID, recordID: String)
        /// Undo removing highlights — re-insert these records.
        case removedHighlights(records: [LocalAnnotationRecord])
    }

    private var undoStack: [UndoableAction] = []
    private static let maxUndoDepth = 50

    func attach(to view: PDFView, paperID: UUID?) {
        let isNewView = pdfView !== view

        if isNewView {
            unregisterObservers()
            pdfView = view
            lastHitAnnotation = nil

            selectionObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewSelectionChanged,
                object: view,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateState()
                }
            }

            pageChangeObserver = NotificationCenter.default.addObserver(
                forName: .PDFViewPageChanged,
                object: view,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.updateState()
                }
            }

        }

        let currentDocumentIdentity = view.document.map { ObjectIdentifier($0) }
        let needsReload = activePaperID != paperID || activeDocumentIdentity != currentDocumentIdentity

        activePaperID = paperID
        activeDocumentIdentity = currentDocumentIdentity

        if needsReload {
            clearLocalOverlayAnnotations()
            renderLocalAnnotationsFromStore()
        }

        updateState()
    }

    func registerAnnotationHit(_ annotation: PDFAnnotation?) {
        // Track last clicked annotation so remove can work without text selection.
        lastHitAnnotation = annotation
    }

    func highlightSelection() {
        highlightSelection(from: nil)
    }

    func highlightSelection(from explicitSelection: PDFSelection?) {
        guard let paperID = activePaperID else { return }
        guard let selection = explicitSelection ?? currentOrCachedSelection(),
              let selectedText = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedText.isEmpty else {
            return
        }

        clearPreview()

        // Group line rects by page, then persist one highlight record per page.
        var grouped: [ObjectIdentifier: (page: PDFPage, rects: [CGRect])] = [:]
        for lineSelection in selection.selectionsByLine() {
            for page in lineSelection.pages {
                let rect = lineSelection.bounds(for: page).insetBy(dx: -0.5, dy: 0.8)
                let key = ObjectIdentifier(page)
                if grouped[key] == nil {
                    grouped[key] = (page: page, rects: [rect])
                } else {
                    grouped[key]?.rects.append(rect)
                }
            }
        }

        var newRecords: [LocalAnnotationRecord] = []
        for entry in grouped.values {
            guard let document = pdfView?.document,
                  let pageNumber = safePageNumber(for: entry.page, in: document),
                  !entry.rects.isEmpty else {
                continue
            }
            let now = Date()
            let record = LocalAnnotationRecord(
                id: UUID().uuidString,
                paperID: paperID,
                kind: .highlight,
                page: pageNumber,
                rects: entry.rects,
                text: selectedText,
                note: nil,
                colorHex: "#ffd400",
                createdAt: now,
                updatedAt: now
            )
            newRecords.append(record)
            if let annotation = makePDFAnnotation(from: record, on: entry.page) {
                entry.page.addAnnotation(annotation)
                localAnnotationIDByObject[ObjectIdentifier(annotation)] = record.id
            }
        }

        store.append(newRecords)
        if !newRecords.isEmpty {
            let ids = Set(newRecords.map(\.id))
            pushUndo(.addedHighlights(paperID: paperID, recordIDs: ids))
        }
        updateState()
    }

    func removeHighlightsInSelection() {
        guard let paperID = activePaperID else { return }
        clearPreview()

        let records = store.annotations(for: paperID).filter { $0.kind == .highlight }
        guard !records.isEmpty else { return }

        var idsToRemove = Set<String>()

        // 1) If user clicked/right-clicked a highlight, remove that exact record first.
        if let annotation = lastHitAnnotation,
           let id = localAnnotationIDByObject[ObjectIdentifier(annotation)] ?? annotationPersistentID(annotation),
           records.contains(where: { $0.id == id }) {
            idsToRemove.insert(id)
        }

        // 2) Selection overlap removes all intersecting highlight records.
        if let selection = currentOrCachedSelection(),
           let document = pdfView?.document {
            for lineSelection in selection.selectionsByLine() {
                for page in lineSelection.pages {
                    guard let pageNumber = safePageNumber(for: page, in: document) else { continue }
                    let targetRect = lineSelection.bounds(for: page).insetBy(dx: -1.0, dy: -1.0)
                    for record in records where record.page == pageNumber {
                        if record.rects.contains(where: { $0.intersects(targetRect) }) {
                            idsToRemove.insert(record.id)
                        }
                    }
                }
            }
        }

        // 3) Fallback: remove nearest highlight on current page.
        if idsToRemove.isEmpty,
           let pdfView,
           let page = pdfView.currentPage,
           let document = pdfView.document,
           let pageNumber = safePageNumber(for: page, in: document) {
            let pageRecords = records.filter { $0.page == pageNumber }
            if !pageRecords.isEmpty {
                let visibleRect = pdfView.convert(pdfView.bounds, to: page)
                let target = CGPoint(x: visibleRect.midX, y: visibleRect.midY)
                let nearest = pageRecords.min { lhs, rhs in
                    let lRect = unionRect(of: lhs.rects)
                    let rRect = unionRect(of: rhs.rects)
                    let lCenter = CGPoint(x: lRect.midX, y: lRect.midY)
                    let rCenter = CGPoint(x: rRect.midX, y: rRect.midY)
                    return squaredDistance(lCenter, target) < squaredDistance(rCenter, target)
                }
                if let nearest {
                    idsToRemove.insert(nearest.id)
                }
            }
        }

        // 4) Final fallback: remove most recent highlight for this paper.
        if idsToRemove.isEmpty, let last = records.last {
            idsToRemove.insert(last.id)
        }

        guard !idsToRemove.isEmpty else { return }

        // Capture records before removal so undo can restore them.
        let removedRecords = records.filter { idsToRemove.contains($0.id) }

        store.remove(ids: idsToRemove, for: paperID)
        if !removedRecords.isEmpty {
            pushUndo(.removedHighlights(records: removedRecords))
        }

        // Deterministic rerender from DB snapshot.
        clearLocalOverlayAnnotations()
        renderLocalAnnotationsFromStore()
        updateState()
    }

    func addNote(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let paperID = activePaperID,
              let pdfView else {
            return
        }

        clearPreview()

        let notePage: PDFPage
        let noteBounds: CGRect

        if let selection = currentOrCachedSelection(),
           let page = selection.pages.first {
            let selectionBounds = selection.bounds(for: page)
            notePage = page
            noteBounds = CGRect(x: selectionBounds.maxX + 6, y: selectionBounds.maxY - 18, width: 22, height: 22)
        } else if let page = pdfView.currentPage {
            let visibleBounds = pdfView.convert(pdfView.bounds, to: page)
            notePage = page
            noteBounds = CGRect(x: visibleBounds.midX, y: visibleBounds.midY, width: 22, height: 22)
        } else {
            return
        }

        guard let document = pdfView.document,
              let pageNumber = safePageNumber(for: notePage, in: document) else {
            return
        }

        let now = Date()
        let record = LocalAnnotationRecord(
            id: UUID().uuidString,
            paperID: paperID,
            kind: .note,
            page: pageNumber,
            rects: [noteBounds],
            text: nil,
            note: trimmed,
            colorHex: "#ffd400",
            createdAt: now,
            updatedAt: now
        )

        if let annotation = makePDFAnnotation(from: record, on: notePage) {
            notePage.addAnnotation(annotation)
            localAnnotationIDByObject[ObjectIdentifier(annotation)] = record.id
        }

        store.append([record])
        pushUndo(.addedNote(paperID: paperID, recordID: record.id))
        updateState()
    }

    // MARK: - Undo

    func undo() {
        guard let action = undoStack.popLast() else { return }
        canUndo = !undoStack.isEmpty

        switch action {
        case .addedHighlights(let paperID, let recordIDs):
            store.remove(ids: recordIDs, for: paperID)
            clearLocalOverlayAnnotations()
            renderLocalAnnotationsFromStore()
            updateState()

        case .addedNote(let paperID, let recordID):
            store.remove(ids: [recordID], for: paperID)
            clearLocalOverlayAnnotations()
            renderLocalAnnotationsFromStore()
            updateState()

        case .removedHighlights(let records):
            store.append(records)
            clearLocalOverlayAnnotations()
            renderLocalAnnotationsFromStore()
            updateState()
        }
    }

    private func pushUndo(_ action: UndoableAction) {
        undoStack.append(action)
        if undoStack.count > Self.maxUndoDepth {
            undoStack.removeFirst(undoStack.count - Self.maxUndoDepth)
        }
        canUndo = true
    }

    func goToPage(_ pageNumber: Int) {
        guard let pdfView,
              let document = pdfView.document,
              document.pageCount > 0 else {
            return
        }

        let clamped = min(max(1, pageNumber), document.pageCount)
        guard let page = document.page(at: clamped - 1) else { return }
        pdfView.go(to: page)
        updateState()
    }

    func focusAnnotation(id: String) {
        guard let ref = annotationRefMap[id],
              let pdfView,
              let page = pdfView.document?.page(at: ref.pageIndex) else {
            return
        }

        let expanded = ref.bounds.insetBy(dx: -28, dy: -28)
        pdfView.go(to: expanded, on: page)
        updateState()
    }

    func previewAnnotation(id: String) {
        guard let ref = annotationRefMap[id],
              let page = pdfView?.document?.page(at: ref.pageIndex) else {
            return
        }

        clearPreview()
        addPreviewHighlight(on: page, bounds: ref.bounds)
        pdfView?.go(to: ref.bounds.insetBy(dx: -28, dy: -28), on: page)
        schedulePreviewClear()
        updateState()
    }

    func previewText(page pageNumber: Int, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let pdfView,
              let document = pdfView.document,
              let page = document.page(at: max(0, pageNumber - 1)) else {
            return
        }

        clearPreview()

        if let selection = selection(on: page, matching: trimmed) {
            for lineSelection in selection.selectionsByLine() {
                for selectionPage in lineSelection.pages {
                    let bounds = lineSelection.bounds(for: selectionPage).insetBy(dx: -0.5, dy: 0.8)
                    addPreviewHighlight(on: selectionPage, bounds: bounds)
                }
            }
            let firstBounds = selection.bounds(for: page)
            pdfView.go(to: firstBounds.insetBy(dx: -28, dy: -28), on: page)
            schedulePreviewClear()
            updateState()
        }
    }

    func clearPreview() {
        previewClearTask?.cancel()
        previewClearTask = nil

        guard !previewAnnotations.isEmpty else { return }
        for entry in previewAnnotations {
            entry.page.removeAnnotation(entry.annotation)
        }
        previewAnnotations.removeAll()
        updateState()
    }

    // MARK: - Local annotation rendering

    private func renderLocalAnnotationsFromStore() {
        guard let paperID = activePaperID,
              let document = pdfView?.document else { return }

        let records = store.annotations(for: paperID)
        for record in records {
            guard let page = document.page(at: max(0, record.page - 1)) else { continue }
            guard let annotation = makePDFAnnotation(from: record, on: page) else { continue }
            page.addAnnotation(annotation)
            localAnnotationIDByObject[ObjectIdentifier(annotation)] = record.id
        }
    }

    private func clearLocalOverlayAnnotations() {
        guard let document = pdfView?.document else {
            localAnnotationIDByObject.removeAll()
            return
        }

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }
            let localAnnotations = page.annotations.filter { $0.userName == localUserName }
            for annotation in localAnnotations {
                page.removeAnnotation(annotation)
            }
        }
        localAnnotationIDByObject.removeAll()
    }

    private func makePDFAnnotation(from record: LocalAnnotationRecord, on page: PDFPage) -> PDFAnnotation? {
        switch record.kind {
        case .highlight:
            guard !record.rects.isEmpty else { return nil }
            let unionBounds = record.rects.reduce(record.rects[0]) { $0.union($1) }
            let annotation = PDFAnnotation(bounds: unionBounds, forType: .highlight, withProperties: nil)
            annotation.color = color(fromHex: record.colorHex, fallback: NSColor.systemYellow).withAlphaComponent(0.45)
            annotation.userName = localUserName
            annotation.isReadOnly = false

            annotation.quadrilateralPoints = record.rects.flatMap { rect in
                let relMinX = rect.minX - unionBounds.minX
                let relMaxX = rect.maxX - unionBounds.minX
                let relMinY = rect.minY - unionBounds.minY
                let relMaxY = rect.maxY - unionBounds.minY
                return [
                    NSValue(point: CGPoint(x: relMinX, y: relMaxY)),
                    NSValue(point: CGPoint(x: relMaxX, y: relMaxY)),
                    NSValue(point: CGPoint(x: relMinX, y: relMinY)),
                    NSValue(point: CGPoint(x: relMaxX, y: relMinY)),
                ]
            }
            setAnnotationPersistentID(record.id, annotation: annotation)
            return annotation

        case .note:
            guard let bounds = record.rects.first else { return nil }
            let annotation = PDFAnnotation(bounds: bounds, forType: .text, withProperties: nil)
            annotation.contents = record.note
            annotation.color = color(fromHex: record.colorHex, fallback: NSColor.systemYellow)
            annotation.userName = localUserName
            annotation.isReadOnly = false
            setAnnotationPersistentID(record.id, annotation: annotation)
            return annotation
        }
    }

    private func setAnnotationPersistentID(_ id: String, annotation: PDFAnnotation) {
        annotation.setValue(id, forAnnotationKey: PDFAnnotationKey(rawValue: "NM"))
    }

    private func annotationPersistentID(_ annotation: PDFAnnotation) -> String? {
        if let value = annotation.value(forAnnotationKey: PDFAnnotationKey(rawValue: "NM")) as? String,
           !value.isEmpty {
            return value
        }
        return nil
    }

    private func unionRect(of rects: [CGRect]) -> CGRect {
        guard let first = rects.first else { return .zero }
        return rects.dropFirst().reduce(first) { $0.union($1) }
    }

    private func squaredDistance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        let dx = lhs.x - rhs.x
        let dy = lhs.y - rhs.y
        return dx * dx + dy * dy
    }

    private func color(fromHex hex: String, fallback: NSColor) -> NSColor {
        let cleaned = hex.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "#", with: "")
        guard cleaned.count == 6,
              let value = Int(cleaned, radix: 16) else {
            return fallback
        }

        let r = CGFloat((value >> 16) & 0xFF) / 255.0
        let g = CGFloat((value >> 8) & 0xFF) / 255.0
        let b = CGFloat(value & 0xFF) / 255.0
        return NSColor(calibratedRed: r, green: g, blue: b, alpha: 1.0)
    }

    // MARK: - State

    private func updateState() {
        isDocumentLoaded = pdfView?.document != nil
        pageCount = pdfView?.document?.pageCount ?? 0

        if let document = pdfView?.document,
           let page = pdfView?.currentPage,
           let safePage = safePageNumber(for: page, in: document) {
            currentPageNumber = safePage
        } else {
            currentPageNumber = 1
        }

        if let selection = pdfView?.currentSelection,
           let text = selection.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty,
           let page = selection.pages.first,
           let document = pdfView?.document,
           let safePage = safePageNumber(for: page, in: document) {
            cachedSelection = selection
            hasSelection = true
            currentSelection = PDFSelectionSummary(page: safePage, text: text)
        } else if let cached = cachedSelection,
                  let text = cached.string?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !text.isEmpty,
                  let page = cached.pages.first,
                  let document = pdfView?.document,
                  let safePage = safePageNumber(for: page, in: document) {
            hasSelection = true
            currentSelection = PDFSelectionSummary(page: safePage, text: text)
        } else {
            hasSelection = false
            currentSelection = nil
            cachedSelection = nil
        }

        refreshAnnotations()
    }

    private func currentOrCachedSelection() -> PDFSelection? {
        if let live = pdfView?.currentSelection,
           let text = live.string?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            cachedSelection = live
            return live
        }
        return cachedSelection
    }

    private func safePageNumber(for page: PDFPage, in document: PDFDocument) -> Int? {
        let index = document.index(for: page)
        guard index != NSNotFound,
              index >= 0,
              index < document.pageCount else {
            return nil
        }
        return index + 1
    }

    private func refreshAnnotations() {
        guard let document = pdfView?.document else {
            annotationSummaries = []
            annotationRefMap = [:]
            return
        }

        var summaries: [PDFAnnotationSummary] = []
        var refs: [String: (pageIndex: Int, bounds: CGRect)] = [:]

        for pageIndex in 0..<document.pageCount {
            guard let page = document.page(at: pageIndex) else { continue }

            var visibleAnnotationCount = 0
            for annotation in page.annotations {
                guard annotation.userName != previewUserName else { continue }
                guard let summary = makeAnnotationSummary(
                    annotation: annotation,
                    page: page,
                    pageIndex: pageIndex,
                    ordinal: visibleAnnotationCount + 1
                ) else {
                    continue
                }

                visibleAnnotationCount += 1
                summaries.append(summary)
                refs[summary.id] = (pageIndex: pageIndex, bounds: annotation.bounds)
            }
        }

        annotationSummaries = summaries
        annotationRefMap = refs
    }

    private func makeAnnotationSummary(annotation: PDFAnnotation, page: PDFPage, pageIndex: Int, ordinal: Int) -> PDFAnnotationSummary? {
        let subtype = annotation.type
        let id = "p\(pageIndex + 1)-a\(ordinal)"

        if subtype == PDFAnnotationSubtype.highlight.rawValue {
            let extractedText = page.selection(for: annotation.bounds)?
                .string?
                .trimmingCharacters(in: .whitespacesAndNewlines)

            return PDFAnnotationSummary(
                id: id,
                kind: .highlight,
                page: pageIndex + 1,
                text: extractedText?.isEmpty == true ? nil : extractedText,
                note: annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            )
        }

        if subtype == PDFAnnotationSubtype.text.rawValue {
            return PDFAnnotationSummary(
                id: id,
                kind: .note,
                page: pageIndex + 1,
                text: nil,
                note: annotation.contents?.trimmingCharacters(in: .whitespacesAndNewlines).nonEmpty
            )
        }

        return nil
    }

    private func addPreviewHighlight(on page: PDFPage, bounds: CGRect) {
        let annotation = PDFAnnotation(bounds: bounds, forType: .highlight, withProperties: nil)
        annotation.color = NSColor.systemCyan.withAlphaComponent(0.55)
        annotation.userName = previewUserName
        page.addAnnotation(annotation)
        previewAnnotations.append((page: page, annotation: annotation))
    }

    private func schedulePreviewClear() {
        previewClearTask?.cancel()
        previewClearTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard !Task.isCancelled else { return }
            self?.clearPreview()
        }
    }

    private func selection(on page: PDFPage, matching text: String) -> PDFSelection? {
        guard let pageText = page.string else { return nil }
        let nsText = pageText as NSString
        let searchRange = NSRange(location: 0, length: nsText.length)
        let foundRange = nsText.range(
            of: text,
            options: [.caseInsensitive, .diacriticInsensitive],
            range: searchRange
        )

        guard foundRange.location != NSNotFound else { return nil }
        return page.selection(for: foundRange)
    }

    private func unregisterObservers() {
        if let observer = selectionObserver {
            NotificationCenter.default.removeObserver(observer)
            selectionObserver = nil
        }
        if let observer = pageChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            pageChangeObserver = nil
        }
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
