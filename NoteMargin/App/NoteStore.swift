import SwiftUI
import PencilKit
import PDFKit

struct PreparedPDFImport: Identifiable {
    let id = UUID()
    let title: String
    let data: Data
    let pages: [NotePage]
    let folderID: UUID?
    var projectID: UUID? = nil
}

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var library = Library()
    @Published var errorMessage: String?
    @Published private(set) var loadingError: String?
    @Published private(set) var hasUnsavedChanges = false
    private var repository: LibraryRepository?
    private var aiStore = MarginAIStore.shared
    // PKDrawing is a value snapshot. Do not serialize the entire drawing on the
    // PencilKit callback thread; late pressure updates may replace this value.
    private var pending: [DrawingKey: PendingDrawing] = [:]
    private var saveTask: Task<Void, Never>?
    private var drawingRevision: UInt64 = 0
    private var activeDrawingInteractions: Set<DrawingKey> = []
    // An active PencilKit stroke stays owned by its canvas. Explicit flushes
    // (backgrounding/export/navigation) request its current real-data snapshot;
    // ordinary Pencil updates only mark it dirty, without copying the document.
    private var activeDrawingSnapshots: [DrawingKey: () -> PKDrawing?] = [:]
    private var dirtyActiveDrawings: Set<DrawingKey> = []
    private var savingID: UUID?
    private var deferredSaveCompletion: (() -> Void)?
    private struct DrawingKey: Hashable, Sendable { let noteID: UUID; let pageID: UUID }
    private struct PendingDrawing: Sendable {
        let drawing: PKDrawing
        let revision: UInt64
        let modifiedAt: Date
    }

    init() { loadLibrary() }
    init(repository: LibraryRepository) throws {
        self.repository = repository
        aiStore = MarginAIStore(repository: MarginChatRepository(root: repository.root.appendingPathComponent("MarginChats")))
        library = try repository.loadProjectLibrary()
    }

    func loadLibrary() {
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let repository: LibraryRepository
            #if DEBUG
            if let fixture = ProcessInfo.processInfo.environment["NOTEMARGIN_UI_FIXTURE"], UUID(uuidString: fixture) != nil {
                repository = try LibraryRepository(root: documents.appendingPathComponent("UITestLibraries/" + fixture))
                aiStore = MarginAIStore(repository: MarginChatRepository(root: repository.root.appendingPathComponent("MarginChats")))
                if try repository.load().notebooks.isEmpty {
                    var note = Notebook(title: "Editing fixture", cover: .blue, folderID: nil)
                    let points = (0...64).map { i in
                        CGPoint(x: 350 + 90 * cos(Double(i) * .pi / 32), y: 410 + 90 * sin(Double(i) * .pi / 32))
                    }
                    let result = ShapeRecognizer().recognize(documentPoints: points)!
                    let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points.enumerated().map { i, p in
                        PKStrokePoint(location: p, timeOffset: Double(i) * 0.01, size: CGSize(width: 2, height: 2), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                    }, creationDate: Date()))
                    note.pages = [NotePage(paper: .ruled, canvasMode: ProcessInfo.processInfo.arguments.contains("--infinite-editing-fixture") ? "infinite" : nil, inkShapes: [InkShape(strokeID: InkStrokeID(stroke), kind: result.kind.rawValue, points: result.fittedPoints, fingerprint: DrawingSession.fingerprint(stroke))])]
                    var fixtureLibrary = Library(); fixtureLibrary.notebooks = [note]
                    if ProcessInfo.processInfo.arguments.contains("--trashed-editing-fixture") {
                        fixtureLibrary.notebooks[0].deletedAt = Date()
                    }
                    try repository.writeDrawing(PKDrawing(strokes: [stroke]).dataRepresentation(), noteID: note.id, pageID: note.pages[0].id)
                    try repository.save(fixtureLibrary)
                }
            } else { repository = try LibraryRepository.applicationLibrary(in: documents) }
            #else
            repository = try LibraryRepository.applicationLibrary(in: documents)
            #endif
            guard (pending.isEmpty && dirtyActiveDrawings.isEmpty) || flushDrawings() else { return }
            library = try DrawingPersistence.queue.sync { try repository.loadProjectLibrary() }
            self.repository = repository
            loadingError = nil
        } catch { loadingError = error.localizedDescription }
    }

    func note(_ id: UUID) -> Notebook? { library.notebooks.first { $0.id == id } }
    func project(_ id: UUID) -> NoteProject? { library.projects.first { $0.id == id } }

    func createProject(title: String, agentInstructions: String = "", parentID: UUID? = nil, cover: CoverColor = .blue) -> UUID? {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, parentID == nil || project(parentID!) != nil else { return nil }
        let project = NoteProject(title: title, agentInstructions: agentInstructions, parentID: parentID, cover: cover)
        return commit { $0.projects.append(project) } ? project.id : nil
    }
    @discardableResult func updateProject(_ id: UUID, title: String, agentInstructions: String) -> Bool {
        updateProject(id, title: title, agentInstructions: agentInstructions, parentID: project(id)?.parentID)
    }
    @discardableResult func updateProject(_ id: UUID, title: String, agentInstructions: String, parentID: UUID?, cover: CoverColor? = nil) -> Bool {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, library.canMove(.project(id), to: parentID) else { return false }
        return commit { library in
            guard let index = library.projects.firstIndex(where: { $0.id == id }) else { return }
            library.projects[index].title = title
            library.projects[index].agentInstructions = agentInstructions
            library.projects[index].parentID = parentID
            if let cover { library.projects[index].cover = cover }
        }
    }
    @discardableResult func assignProject(noteID: UUID, projectID: UUID?) -> Bool {
        guard note(noteID) != nil, projectID == nil || project(projectID!) != nil else { return false }
        guard flushDrawings() else { return false }
        return commit { $0.assignProject(noteID: noteID, projectID: projectID) }
    }
    @discardableResult func move(_ item: LibraryItem, to parentID: UUID?) -> Bool {
        guard library.canMove(item, to: parentID) else {
            errorMessage = "이 위치로 이동할 수 없습니다. 프로젝트는 자신이나 하위 프로젝트 안으로 이동할 수 없습니다."
            return false
        }
        guard flushDrawings() else { return false }
        return commit { $0.move(item, to: parentID) }
    }
    func deleteProject(_ id: UUID) { commit { $0.removeProject(id) } }

    @discardableResult
    private func commit(_ change: (inout Library) -> Void) -> Bool {
        guard let repository else { return false }
        var next = library
        change(&next)
        applyDrawingDates(pending, to: &next)
        do {
            // Synchronous edits must follow an already queued autosave. Otherwise
            // an older background library snapshot could undo a rename or move.
            try DrawingPersistence.queue.sync { try repository.save(next) }
            if library != next { library = next }
            return true
        } catch { errorMessage = "저장하지 못했습니다. \(error.localizedDescription)"; return false }
    }

    @discardableResult
    func updateNote(_ id: UUID, _ change: (inout Notebook) -> Void) -> Bool {
        commit { library in
            guard let index = library.notebooks.firstIndex(where: { $0.id == id }) else { return }
            change(&library.notebooks[index])
            library.notebooks[index].updatedAt = Date()
        }
    }

    /// Registers a non-destructive answer card with the same undo manager as ink.
    func setAIElement(noteID: UUID, pageID: UUID, element: PageElement, present: Bool, undoManager: UndoManager?) {
        guard updatePage(noteID: noteID, pageID: pageID, { page in
            page.elements.removeAll { $0.id == element.id }
            if present { page.elements.append(element) }
        }) else { return }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] target in
            target.setAIElement(noteID: noteID, pageID: pageID, element: element, present: !present, undoManager: undoManager)
        }
        undoManager?.setActionName("AI 답변 카드")
    }

    @discardableResult
    func setInkGroups(noteID: UUID, pageID: UUID, groups: [InkGroup], undoManager: UndoManager?, action: String) -> Bool {
        guard let page = note(noteID)?.pages.first(where: { $0.id == pageID }) else { return false }
        let previous = page.inkGroups ?? []
        guard previous != groups else { return true }
        // A group may refer to a just-finished stroke. Persist its latest pressure
        // snapshot before committing metadata, and retain it on a write failure.
        guard flushDrawings(), updatePage(noteID: noteID, pageID: pageID, { page in
            page.inkGroups = groups.isEmpty ? nil : groups
        }) else { return false }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] target in
            target.setInkGroups(noteID: noteID, pageID: pageID, groups: previous, undoManager: undoManager, action: action)
        }
        undoManager?.setActionName(action)
        return true
    }

    /// Commits the rare legacy-copy identity repair together with its group
    /// metadata. The session owns a single undo entry for this paired change.
    @discardableResult
    func setInkGroupsAndDrawing(noteID: UUID, pageID: UUID, drawing: PKDrawing, groups: [InkGroup]) -> Bool {
        guard let repository,
              let noteIndex = library.notebooks.firstIndex(where: { $0.id == noteID }),
              let pageIndex = library.notebooks[noteIndex].pages.firstIndex(where: { $0.id == pageID }),
              flushDrawings() else { return false }
        let original: PKDrawing
        do { original = try self.drawing(noteID: noteID, pageID: pageID) }
        catch { reportDrawingSaveError(error); return false }
        var next = library
        next.notebooks[noteIndex].pages[pageIndex].inkGroups = groups.isEmpty ? nil : groups
        next.notebooks[noteIndex].updatedAt = Date()
        let root = repository.root
        do {
            try DrawingPersistence.queue.sync {
                let writer = try LibraryRepository(root: root)
                let previousData = try writer.readDrawing(noteID: noteID, pageID: pageID)
                try writer.writeDrawing(drawing.dataRepresentation(), noteID: noteID, pageID: pageID)
                do { try writer.save(next) }
                catch {
                    // Library replacement is atomic; if it fails, restore the
                    // preceding drawing before exposing any change to the UI.
                    if let previousData {
                        try? writer.writeDrawing(previousData, noteID: noteID, pageID: pageID)
                    } else if let url = try? writer.assetURL(noteID: noteID, name: "\(pageID).drawing") {
                        try? FileManager.default.removeItem(at: url)
                    }
                    throw error
                }
            }
            if library != next { library = next }
            return true
        } catch {
            // Even if disk rollback is blocked (for example by a full volume),
            // the original remains available to readers and to a later retry.
            queueDrawing(original, noteID: noteID, pageID: pageID)
            errorMessage = "필기 그룹을 저장하지 못했습니다. 기존 필기는 보존되어 있습니다. 저장을 다시 시도해 주세요. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult func updatePage(noteID: UUID, pageID: UUID, _ change: (inout NotePage) -> Void) -> Bool {
        updateNote(noteID) { note in
            guard let index = note.pages.firstIndex(where: { $0.id == pageID }) else { return }
            change(&note.pages[index])
        }
    }

    func createNote(title: String, paper: PaperStyle, cover: CoverColor, folderID: UUID?, projectID: UUID? = nil, infinite: Bool = false) -> UUID? {
        var note = Notebook(title: title.trimmedOrUntitled, cover: cover, folderID: folderID, projectID: projectID.flatMap { project($0)?.id })
        note.pages = [NotePage(paper: paper, canvasMode: infinite ? "infinite" : nil)]
        return commit { $0.notebooks.append(note) } ? note.id : nil
    }

    func createFolder(_ title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        commit { $0.folders.append(NoteFolder(title: title)) }
    }

    func renameFolder(_ id: UUID, title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        commit { library in
            guard let index = library.folders.firstIndex(where: { $0.id == id }) else { return }
            library.folders[index].title = title
        }
    }

    func deleteFolder(_ id: UUID) { commit { $0.removeFolder(id) } }
    func trash(_ id: UUID) {
        guard flushDrawings() else { return }
        updateNote(id) { $0.deletedAt = Date() }
    }
    func restore(_ id: UUID) { updateNote(id) { $0.deletedAt = nil } }

    @discardableResult
    func permanentlyDelete(_ id: UUID) -> Bool { permanentlyDelete([id]) }

    @discardableResult
    func permanentlyDelete(_ requested: Set<UUID>) -> Bool {
        // Revalidate at confirmation time. A restored/live note is never eligible.
        let ids = Set(library.notebooks.filter { $0.deletedAt != nil && requested.contains($0.id) }.map(\.id))
        guard !ids.isEmpty else { return true }
        guard flushDrawings(), commit({ library in
            library.notebooks.removeAll { ids.contains($0.id) && $0.deletedAt != nil }
            library.pendingAssetDeletions = Array(Set(library.pendingAssetDeletions ?? []).union(ids))
        }) else { return false }
        return finishPermanentDeletion()
    }

    @discardableResult
    func finishPermanentDeletion() -> Bool {
        guard let repository else { return false }
        let pending = Set(library.pendingAssetDeletions ?? [])
        guard !pending.isEmpty else { return true }
        var remaining = Set<UUID>()
        for id in pending where note(id) == nil {
            do {
                try aiStore.deleteNote(id)
                try DrawingPersistence.queue.sync { try repository.deleteAssets(noteID: id) }
            } catch { remaining.insert(id) }
        }
        // One library write for the batch, not one per note. If it fails, the
        // persisted IDs make an idempotent retry possible after restarting.
        if remaining != pending {
            guard commit({ $0.pendingAssetDeletions = remaining.isEmpty ? nil : Array(remaining) }) else { return false }
        }
        if !remaining.isEmpty {
            errorMessage = "노트 목록에서는 삭제했지만 \(remaining.count)개 노트의 첨부·대화 정리를 완료하지 못했습니다. 최근 삭제된 항목에서 ‘첨부 정리 다시 시도’를 눌러 주세요."
            return false
        }
        return true
    }

    func duplicate(_ id: UUID) -> UUID? {
        guard flushDrawings(), var copy = note(id), let repository else { return nil }
        copy.id = UUID()
        copy.title += " 사본"
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.deletedAt = nil
        do {
            try repository.copyAssets(from: id, to: copy.id)
            return commit { $0.notebooks.append(copy) } ? copy.id : nil
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func drawing(noteID: UUID, pageID: UUID) throws -> PKDrawing {
        let key = DrawingKey(noteID: noteID, pageID: pageID)
        captureActiveDrawing(key)
        if let snapshot = pending[key] { return snapshot.drawing }
        if let data = try DrawingPersistence.queue.sync(execute: { try repository?.readDrawing(noteID: noteID, pageID: pageID) }) {
            return try PKDrawing(data: data)
        }
        return PKDrawing()
    }

    func queueDrawing(_ drawing: PKDrawing, noteID: UUID, pageID: UUID) {
        dirtyActiveDrawings.remove(DrawingKey(noteID: noteID, pageID: pageID))
        drawingRevision &+= 1
        pending[DrawingKey(noteID: noteID, pageID: pageID)] = PendingDrawing(
            drawing: drawing, revision: drawingRevision, modifiedAt: Date())
        if !hasUnsavedChanges { hasUnsavedChanges = true }
        scheduleDrawingSave()
    }

    func beginDrawingInteraction(noteID: UUID, pageID: UUID, snapshot: (() -> PKDrawing?)? = nil) {
        let key = DrawingKey(noteID: noteID, pageID: pageID)
        activeDrawingInteractions.insert(key)
        activeDrawingSnapshots[key] = snapshot
        saveTask?.cancel()
        saveTask = nil
    }

    func endDrawingInteraction(noteID: UUID, pageID: UUID) {
        let key = DrawingKey(noteID: noteID, pageID: pageID)
        captureActiveDrawing(key)
        activeDrawingSnapshots.removeValue(forKey: key)
        activeDrawingInteractions.remove(key)
        guard activeDrawingInteractions.isEmpty else { return }
        let completion = deferredSaveCompletion
        deferredSaveCompletion = nil
        completion?()
        scheduleDrawingSave()
    }

    func markActiveDrawingChanged(noteID: UUID, pageID: UUID) {
        let key = DrawingKey(noteID: noteID, pageID: pageID)
        guard activeDrawingSnapshots[key] != nil else { return }
        dirtyActiveDrawings.insert(key)
        if !hasUnsavedChanges { hasUnsavedChanges = true }
    }

    private func captureActiveDrawing(_ key: DrawingKey) {
        guard dirtyActiveDrawings.contains(key), let drawing = activeDrawingSnapshots[key]?() else { return }
        queueDrawing(drawing, noteID: key.noteID, pageID: key.pageID)
    }

    private func scheduleDrawingSave() {
        saveTask?.cancel()
        saveTask = nil
        guard !pending.isEmpty, activeDrawingInteractions.isEmpty, savingID == nil else { return }
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(700)) } catch { return }
            self?.saveDrawingsInBackground()
        }
    }

    private func saveDrawingsInBackground() {
        saveTask = nil
        guard activeDrawingInteractions.isEmpty, savingID == nil,
              !pending.isEmpty, let root = repository?.root else { return }
        let id = UUID(), batch = pending
        var next = library
        applyDrawingDates(batch, to: &next)
        savingID = id
        DrawingPersistence.queue.async { [weak self, next] in
            let result = Result { try Self.writeDrawingBatch(batch, library: next, root: root) }
            Task { @MainActor [weak self] in
                guard let self, self.savingID == id else { return }
                let finish: () -> Void = { [weak self] in self?.finishDrawingSave(id: id, batch: batch, result: result) }
                if self.activeDrawingInteractions.isEmpty { finish() }
                else { self.deferredSaveCompletion = finish }
            }
        }
    }

    private func finishDrawingSave(id: UUID, batch: [DrawingKey: PendingDrawing], result: Result<Void, Error>) {
        guard savingID == id else { return }
        savingID = nil
        switch result {
        case .success:
            var next = library
            applyDrawingDates(batch, to: &next)
            if library != next { library = next }
            removeSavedDrawings(batch)
            scheduleDrawingSave()
        case .failure(let error):
            // Keep every original snapshot for an explicit retry or the next edit.
            reportDrawingSaveError(error)
        }
    }

    @discardableResult
    func flushDrawings() -> Bool {
        for key in Array(dirtyActiveDrawings) { captureActiveDrawing(key) }
        guard dirtyActiveDrawings.isEmpty else {
            reportDrawingSaveError(CocoaError(.fileWriteUnknown))
            return false
        }
        saveTask?.cancel()
        saveTask = nil
        // Queued disk work still finishes in order. Its later UI callback must
        // not clear newer revisions or overwrite this synchronous flush result.
        savingID = nil
        deferredSaveCompletion = nil
        guard !pending.isEmpty else { return true }
        guard let root = repository?.root else { return false }
        let batch = pending
        var next = library
        applyDrawingDates(batch, to: &next)
        do {
            try DrawingPersistence.queue.sync { try Self.writeDrawingBatch(batch, library: next, root: root) }
            if library != next { library = next }
            removeSavedDrawings(batch)
            return true
        } catch {
            reportDrawingSaveError(error)
            return false
        }
    }

    private func removeSavedDrawings(_ batch: [DrawingKey: PendingDrawing]) {
        for (key, snapshot) in batch where pending[key]?.revision == snapshot.revision {
            pending.removeValue(forKey: key)
        }
        let unsaved = !pending.isEmpty || !dirtyActiveDrawings.isEmpty
        if hasUnsavedChanges != unsaved { hasUnsavedChanges = unsaved }
    }

    private func applyDrawingDates(_ batch: [DrawingKey: PendingDrawing], to library: inout Library) {
        var dates: [UUID: Date] = [:]
        for (key, snapshot) in batch {
            dates[key.noteID] = max(dates[key.noteID] ?? .distantPast, snapshot.modifiedAt)
        }
        for index in library.notebooks.indices {
            if let date = dates[library.notebooks[index].id], date > library.notebooks[index].updatedAt {
                library.notebooks[index].updatedAt = date
            }
        }
    }

    private nonisolated static func writeDrawingBatch(_ batch: [DrawingKey: PendingDrawing], library: Library, root: URL) throws {
        // This repository/encoder belongs only to this serial write operation.
        let writer = try LibraryRepository(root: root)
        for (key, snapshot) in batch {
            try writer.writeDrawing(snapshot.drawing.dataRepresentation(), noteID: key.noteID, pageID: key.pageID)
        }
        try writer.save(library)
    }

    private func reportDrawingSaveError(_ error: Error) {
        let message = "필기를 저장하지 못했습니다. 여유 공간을 확인한 후 다시 저장해 주세요. \(error.localizedDescription)"
        if errorMessage != message { errorMessage = message }
    }

    func addPage(noteID: UUID, after pageID: UUID?, paper: PaperStyle) -> UUID? {
        let page = NotePage(paper: paper)
        return updateNote(noteID) { note in
            let index = pageID.flatMap { id in note.pages.firstIndex { $0.id == id } }.map { $0 + 1 } ?? note.pages.count
            note.pages.insert(page, at: index)
        } ? page.id : nil
    }

    func duplicatePage(noteID: UUID, pageID: UUID) -> UUID? {
        guard flushDrawings(), let note = note(noteID), let index = note.pages.firstIndex(where: { $0.id == pageID }),
              let repository else { return nil }
        var page = note.pages[index]
        page.id = UUID()
        do {
            if let data = try repository.readDrawing(noteID: noteID, pageID: pageID) {
                try repository.writeDrawing(data, noteID: noteID, pageID: page.id)
            }
            return updateNote(noteID) { $0.pages.insert(page, at: index + 1) } ? page.id : nil
        } catch { errorMessage = error.localizedDescription; return nil }
    }

    func deletePage(noteID: UUID, pageID: UUID) {
        guard flushDrawings(), let note = note(noteID), note.pages.count > 1 else { return }
        updateNote(noteID) { $0.pages.removeAll { $0.id == pageID } }
    }

    func assetURL(noteID: UUID, name: String) -> URL? { try? repository?.assetURL(noteID: noteID, name: name) }

    func preparePDF(_ url: URL, folderID: UUID?) -> PreparedPDFImport? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            return preparePDF(data: data, title: url.deletingPathExtension().lastPathComponent, folderID: folderID)
        } catch { errorMessage = "PDF를 가져오지 못했습니다. \(error.localizedDescription)"; return nil }
    }

    func preparePDF(data: Data, title: String, folderID: UUID?) -> PreparedPDFImport? {
        do {
            guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
                errorMessage = "이 PDF를 열 수 없습니다. 암호가 해제된 PDF를 선택해 주세요."
                return nil
            }
            let pages = try (0..<document.pageCount).map { index in
                guard let pdfPage = document.page(at: index) else { throw CocoaError(.fileReadCorruptFile) }
                let bounds = pdfPage.bounds(for: .mediaBox)
                let rotated = abs(pdfPage.rotation) % 180 == 90
                let width = rotated ? bounds.height : bounds.width
                let height = rotated ? bounds.width : bounds.height
                guard width.isFinite, height.isFinite, width > 0, height > 0 else { throw CocoaError(.fileReadCorruptFile) }
                return NotePage(width: 768, height: 768 * height / width, pdfPageIndex: index, pdfFitToPage: true)
            }
            // Own the bytes before releasing file-provider access while the user chooses a layout.
            return PreparedPDFImport(title: title, data: data, pages: pages, folderID: folderID)
        } catch { errorMessage = "PDF를 가져오지 못했습니다. \(error.localizedDescription)"; return nil }
    }

    func importPDF(_ prepared: PreparedPDFImport, layout: PDFImportLayout) -> UUID? {
        guard let repository else { return nil }
        var note = Notebook(title: prepared.title, cover: .sand, folderID: prepared.folderID, projectID: prepared.projectID.flatMap { project($0)?.id })
        note.pdfAssetName = "original.pdf"
        do {
            note.pages = try NotePage.importedPDFPages(prepared.pages, layout: layout)
            try repository.writeAsset(prepared.data, noteID: note.id, name: "original.pdf")
            guard commit({ $0.notebooks.append(note) }) else {
                try? repository.deleteAssets(noteID: note.id)
                return nil
            }
            return note.id
        } catch { errorMessage = "PDF를 가져오지 못했습니다. \(error.localizedDescription)"; return nil }
    }

    func addImage(_ data: Data, noteID: UUID, pageID: UUID, center: CGPoint? = nil) {
        guard let image = UIImage(data: data), let page = note(noteID)?.pages.first(where: { $0.id == pageID }),
              let normalized = image.jpegData(compressionQuality: 0.9), let repository else { return }
        let name = "\(UUID()).jpg"
        do {
            try repository.writeAsset(normalized, noteID: noteID, name: name)
            let width = min(page.width - 80, 420)
            let height = min(page.height - 80, width * image.size.height / max(image.size.width, 1))
            let origin = page.isInfinite ? center.map { CGPoint(x: $0.x-width/2, y: $0.y-height/2) } : nil
            let element = PageElement(kind: .image, assetName: name, x: Double(origin?.x ?? 40), y: Double(origin?.y ?? 40), width: width, height: height)
            updatePage(noteID: noteID, pageID: pageID) { $0.elements.append(element) }
        } catch { errorMessage = error.localizedDescription }
    }
}

// Shared across stores, including a freshly reopened store. A lifecycle flush
// waits for older autosaves without waiting for any callback on the main actor.
private enum DrawingPersistence {
    static let queue = DispatchQueue(label: "com.notemargin.drawing-persistence", qos: .utility)
}

extension String {
    var trimmedOrUntitled: String {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "제목 없는 노트" : value
    }
}
