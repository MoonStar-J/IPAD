import SwiftUI
import PencilKit
import PDFKit

struct PreparedPDFImport: Identifiable {
    let id = UUID()
    var title: String
    let contents: PDFImportContents
    let pages: [NotePage]
    let folderID: UUID?
    var projectID: UUID? = nil
}

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var library = Library()
    @Published var errorMessage: AppMessage?
    @Published private(set) var loadingError: AppMessage?
    @Published private(set) var hasUnsavedChanges = false
    private var repository: LibraryRepository?
    private var aiStore = MarginAIStore.shared
    lazy var summaries = NoteSummaryService(store: self)
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
                    if ProcessInfo.processInfo.arguments.contains("--live-summary-fixture") {
                        note.pages[0].elements = [PageElement(kind: .text, text: "미분 학습 노트\nf(x) = x²의 도함수는 f′(x) = 2x이다.\nx = 3에서 접선의 기울기는 6이다.\n아래 손으로 그린 도형은 원이다.", x: 40, y: 60, width: 640, height: 200)]
                    }
                    var fixtureLibrary = Library(); fixtureLibrary.notebooks = [note]
                    if ProcessInfo.processInfo.arguments.contains("--trashed-editing-fixture") {
                        fixtureLibrary.notebooks[0].deletedAt = Date()
                    }
                    var fixtureDrawing = PKDrawing(strokes: [stroke])
                    if ProcessInfo.processInfo.arguments.contains("--marker-editing-fixture") {
                        let colors: [UIColor] = [.black, .systemBlue, .systemRed, .systemYellow, .systemGreen]
                        let highlights = (0..<25).map { i in
                            PKStroke(ink: PKInk(.marker, color: colors[i % 5]), path: PKStrokePath(controlPoints: [80.0, 680.0].map {
                                PKStrokePoint(location: CGPoint(x: $0, y: 300 + Double(i % 5)*60), timeOffset: $0/1000,
                                              size: CGSize(width: 36, height: 36), opacity: 1, force: 0.8, azimuth: 0, altitude: 1)
                            }, creationDate: Date(timeIntervalSince1970: Double(i))), randomSeed: UInt32(i))
                        }
                        fixtureDrawing = PKDrawing(strokes: highlights)
                        fixtureLibrary.notebooks[0].pages[0].inkShapes = nil
                        fixtureLibrary.notebooks[0].pages[0].elements = (0..<5).map {
                            PageElement(kind: .text, text: "Readable text · 겹친 형광펜 \($0+1)", x: 100, y: 282 + Double($0)*60, width: 540, height: 44, fontSize: 24)
                        }
                    }
                    try repository.writeDrawing(fixtureDrawing.dataRepresentation(), noteID: note.id, pageID: note.pages[0].id)
                    if ProcessInfo.processInfo.arguments.contains("--summary-reader-fixture") {
                        var summary = Notebook(title: "Summary rendering fixture", cover: .sage)
                        summary.pages = []
                        summary.summary = NoteSummary(sourceID: note.id, sourceTitle: note.title, createdAt: Date(), model: "fixture", account: "fixture", state: .completed)
                        let source = SummarySource(id: "S1", pageID: note.pages[0].id, label: "1페이지", rect: CGRect(x: 0, y: 0, width: 768, height: 1024))
                        var work = SummaryWork(snapshot: note, sources: [source])
                        work.final = "# 학습 요약\n\n정의와 조건 [S1]\n\n" + #"\(a^2+b^2=c^2\)"# + "\n\n" + #"\[\sum_{k=1}^{n} k = \frac{n(n+1)}{2}\]"# + "\n\n" + String(repeating: "## 핵심 주제\n\n- 성립 조건과 예외를 확인합니다. [S1]\n\n", count: 20) + "<script>window.location='https://example.invalid'</script>"
                        fixtureLibrary.notebooks.append(summary)
                        try repository.writeAsset(JSONEncoder().encode(work), noteID: summary.id, name: "summary-work.json")
                        try repository.writeAsset(Data(work.final!.utf8), noteID: summary.id, name: "summary.md")
                    }
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
        } catch { loadingError = AppMessage(error) }
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
            errorMessage = AppMessage("이 위치로 이동할 수 없습니다. 프로젝트는 자신이나 하위 프로젝트 안으로 이동할 수 없습니다.")
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
        } catch { errorMessage = AppMessage("저장하지 못했습니다. %@", error: error); return false }
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
    @discardableResult func setAIElement(noteID: UUID, pageID: UUID, element: PageElement, present: Bool, undoManager: UndoManager?) -> Bool {
        guard updatePage(noteID: noteID, pageID: pageID, { page in
            page.elements.removeAll { $0.id == element.id }
            if present {
                page.elements.append(element)
                if !page.isInfinite && element.y + element.height + 24 > page.height {
                    if page.pdfPageIndex != nil && page.pdfBackgroundHeight == nil { page.pdfBackgroundHeight = page.height }
                    page.height = max(page.height, element.y + element.height + 24)
                }
            }
        }) else { return false }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] target in
            target.setAIElement(noteID: noteID, pageID: pageID, element: element, present: !present, undoManager: undoManager)
        }
        undoManager?.setActionName(localized("AI 답변 카드"))
        return true
    }

    @discardableResult func updateElement(noteID: UUID, pageID: UUID, element: PageElement, undoManager: UndoManager?) -> Bool {
        guard let old = note(noteID)?.pages.first(where: { $0.id == pageID })?.elements.first(where: { $0.id == element.id }), old != element else { return true }
        guard updatePage(noteID: noteID, pageID: pageID, { page in
            if let index = page.elements.firstIndex(where: { $0.id == element.id }) { page.elements[index] = element }
        }) else { return false }
        undoManager?.registerUndo(withTarget: self) { [weak undoManager] target in
            target.updateElement(noteID: noteID, pageID: pageID, element: old, undoManager: undoManager)
        }
        undoManager?.setActionName(localized("항목 편집"))
        return true
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
            errorMessage = AppMessage("필기 그룹을 저장하지 못했습니다. 기존 필기는 보존되어 있습니다. 저장을 다시 시도해 주세요. %@", error: error)
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
        note.pages = [NotePage(paper: paper, canvasMode: infinite ? "infinite" : "continuous")]
        return commit { $0.notebooks.append(note) } ? note.id : nil
    }

    func summaryDestination(for source: Notebook) -> NoteProject? {
        if let parent = source.projectID.flatMap({ project($0) }), parent.isSummaryDestination == true { return parent }
        return library.projects.first { $0.parentID == source.projectID && $0.isSummaryDestination == true }
    }

    func summaryLocation(for source: Notebook) -> String {
        if let destination = summaryDestination(for: source) {
            return library.projectPath(destination.id).map(\.title).joined(separator: " / ")
        }
        let path = source.projectID.map { library.projectPath($0).map(\.title) } ?? []
        return (path + [localized("요약")]).joined(separator: " / ")
    }

    func createSummary(source: Notebook, sources: [SummarySource], title: String, model: String, account: String, instructions: String? = nil) throws -> UUID {
        guard let repository, !sources.isEmpty, note(source.id) != nil else { throw CocoaError(.fileReadNoSuchFile) }
        var destination = summaryDestination(for: source)
        if destination == nil {
            destination = NoteProject(title: localized("요약"), parentID: source.projectID.flatMap { project($0)?.id }, isSummaryDestination: true)
        }
        var result = Notebook(title: title.trimmedOrUntitled, cover: source.cover, projectID: destination!.id)
        result.pages = [NotePage(canvasMode: "continuous")]
        result.summary = NoteSummary(sourceID: source.id, sourceTitle: source.title, createdAt: Date(), model: model, account: account)
        var snapshot = source
        snapshot.id = result.id
        snapshot.pages = source.pages.filter { page in sources.contains { $0.pageID == page.id } }
        let work = SummaryWork(snapshot: snapshot, sources: sources, instructions: instructions)
        do {
            // File copies freeze PDF, drawings and inserted images before any await.
            try repository.copyAssets(from: source.id, to: result.id)
            try repository.writeAsset(JSONEncoder().encode(work), noteID: result.id, name: result.summary!.workAsset)
            try repository.writeAsset(Data(work.markdown.utf8), noteID: result.id, name: result.summary!.bodyAsset)
            guard commit({ library in
                if !library.projects.contains(where: { $0.id == destination!.id }) { library.projects.append(destination!) }
                library.notebooks.append(result)
            }) else { throw SummaryError.message(errorMessage ?? AppMessage("요약 노트를 저장하지 못했습니다.")) }
        } catch {
            try? repository.deleteAssets(noteID: result.id)
            throw error
        }
        return result.id
    }

    func summaryWork(_ id: UUID) throws -> SummaryWork {
        guard let name = note(id)?.summary?.workAsset else { throw CocoaError(.fileReadNoSuchFile) }
        return try JSONDecoder().decode(SummaryWork.self, from: summaryAsset(id, name: name))
    }
    func summaryAsset(_ id: UUID, name: String) throws -> Data {
        guard let url = assetURL(noteID: id, name: name) else { throw CocoaError(.fileReadNoSuchFile) }
        return try Data(contentsOf: url)
    }
    func writeSummaryAsset(_ data: Data, id: UUID, name: String) throws {
        guard note(id)?.summary != nil, let repository else { throw CocoaError(.fileNoSuchFile) }
        try repository.writeAsset(data, noteID: id, name: name)
    }
    func saveSummary(_ id: UUID, work: SummaryWork, state: NoteSummary.State) throws {
        guard let summary = note(id)?.summary else { throw CocoaError(.fileNoSuchFile) }
        // The checkpoint is authoritative for retry. A body/manifest write failure
        // never forces a completed model request to be sent again.
        try writeSummaryAsset(JSONEncoder().encode(work), id: id, name: summary.workAsset)
        try writeSummaryAsset(Data(work.markdown.utf8), id: id, name: summary.bodyAsset)
        guard updateNote(id, { $0.summary?.state = state }) else {
            throw SummaryError.message(errorMessage ?? AppMessage("요약을 저장하지 못했습니다."))
        }
    }

    func prepareSummaryCanvas(_ id: UUID) async throws {
        guard let original = note(id), let summary = original.summary else { return }
        if original.pages.isEmpty, !updateNote(id, { $0.pages = [NotePage(canvasMode: "continuous")] }) {
            throw SummaryError.message(errorMessage ?? AppMessage("요약 노트를 저장하지 못했습니다."))
        }
        guard !summary.state.running else { return }
        guard let text = String(data: try summaryAsset(id, name: summary.bodyAsset), encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let old = original.pages.flatMap(\.elements).first { $0.id == summary.canvasElementID }
        if summary.canvasElementID != nil && old == nil { return } // A user-deleted object stays deleted.
        if old?.text == text { return }
        let rendered = try await MathAnswerView.document(text: text, width: 688)
        defer { try? FileManager.default.removeItem(at: rendered.url) }
        try Task.checkCancellation()
        guard let current = note(id), current.deletedAt == nil, current.summary?.state == summary.state,
              try summaryAsset(id, name: summary.bodyAsset) == Data(text.utf8), let repository else { throw CancellationError() }
        // Another editor/export may have prepared the same body while rendering.
        if current.summary?.canvasElementID != summary.canvasElementID { return }
        if let old, current.pages.flatMap(\.elements).first(where: { $0.id == old.id }) != old { throw CancellationError() }
        let name = UUID().uuidString + ".pdf"
        let target = try repository.assetURL(noteID: id, name: name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: rendered.url, to: target)
        var element = old ?? PageElement(kind: .text, x: 40, y: 40, width: 688, height: rendered.height, fontSize: 18)
        element.text = text; element.assetName = name; element.height = rendered.height * element.width / 688
        guard updateNote(id, { note in
            if note.pages.isEmpty { note.pages = [NotePage(canvasMode: "continuous")] }
            let index = note.pages.firstIndex { $0.elements.contains { $0.id == element.id } } ?? 0
            note.pages[index].elements.removeAll { $0.id == element.id }
            note.pages[index].elements.insert(element, at: 0)
            note.pages[index].height = max(note.pages[index].height, ceil((element.y + element.height + 80) / 1024) * 1024)
            note.summary?.canvasElementID = element.id
        }) else {
            try? FileManager.default.removeItem(at: target)
            throw SummaryError.message(errorMessage ?? AppMessage("요약 노트를 저장하지 못했습니다."))
        }
    }

    func insertAnswer(_ message: MarginMessage, conversationID: UUID, summarized: Bool, ai: MarginAIStore, undoManager: UndoManager?) async throws {
        func source() throws -> (MarginConversation, NotePage) {
            guard let chat = ai.conversation(conversationID), let current = note(chat.noteID), current.deletedAt == nil,
                  chat.belongs(to: current), chat.messages.contains(where: { $0.id == message.id && $0.text == message.text && $0.role == .assistant }),
                  let target = current.pages.first(where: { $0.id == chat.pageID }), !chat.rect.isEmpty, !chat.rect.isNull, !chat.rect.isInfinite,
                  target.isInfinite || CGRect(x: 0, y: 0, width: target.width, height: target.height).contains(chat.rect) else {
                throw SummaryError.message(AppMessage("질문 위치를 찾을 수 없습니다. 원래 페이지와 질문 영역을 확인해 주세요."))
            }
            return (chat, target)
        }
        let (chat, target) = try source()
        if target.elements.contains(where: { $0.sourceMessageID == message.id && $0.isAnswerSummary == summarized }) { return }
        let text = summarized ? try await ai.summarizeAnswer(conversationID: conversationID, messageID: message.id) : message.text
        try Task.checkCancellation()
        var element = try await renderedElement(text: text, width: min(600, target.width - 48), noteID: chat.noteID)
        var inserted = false
        defer {
            if !inserted, let name = element.assetName, let url = assetURL(noteID: chat.noteID, name: name) { try? FileManager.default.removeItem(at: url) }
        }
        try Task.checkCancellation()
        let (_, current) = try source()
        if current.elements.contains(where: { $0.sourceMessageID == message.id && $0.isAnswerSummary == summarized }) { return }
        element.sourceMessageID = message.id; element.isAnswerSummary = summarized
        element.x = current.isInfinite ? chat.rect.minX : 24
        element.y = chat.rect.maxY + 24
        let drawing = try drawing(noteID: chat.noteID, pageID: current.id)
        let occupied = drawing.strokes.map(\.renderBounds) + current.elements.map { CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height) } + current.pdfRegions.map { CGRect(x: 0, y: $0.y, width: current.width, height: $0.height) }
        for rect in occupied.sorted(by: { $0.minY < $1.minY }) {
            if rect.intersects(CGRect(x: element.x, y: element.y, width: element.width, height: element.height)) { element.y = rect.maxY + 24 }
        }
        guard setAIElement(noteID: chat.noteID, pageID: current.id, element: element, present: true, undoManager: undoManager) else {
            throw SummaryError.message(errorMessage ?? AppMessage("받은 결과를 저장하지 못했습니다. 다시 누르면 저장만 재시도합니다."))
        }
        inserted = true
    }

    func renderedElement(text: String, width: Double, noteID: UUID) async throws -> PageElement {
        let rendered = try await MathAnswerView.document(text: text, width: width)
        defer { try? FileManager.default.removeItem(at: rendered.url) }
        try Task.checkCancellation()
        guard note(noteID)?.deletedAt == nil, let repository else { throw CocoaError(.fileNoSuchFile) }
        let name = UUID().uuidString + ".pdf"
        let target = try repository.assetURL(noteID: noteID, name: name)
        try FileManager.default.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: rendered.url, to: target)
        return PageElement(kind: .text, text: text, assetName: name, width: width, height: rendered.height, fontSize: 18)
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
            errorMessage = AppMessage("노트 목록에서는 삭제했지만 %@개 노트의 첨부·대화 정리를 완료하지 못했습니다. 최근 삭제된 항목에서 ‘첨부 정리 다시 시도’를 눌러 주세요.", "\(remaining.count)")
            return false
        }
        return true
    }

    func duplicate(_ id: UUID) -> UUID? {
        guard flushDrawings(), var copy = note(id), let repository else { return nil }
        copy.id = UUID()
        copy.title += localized(" 사본")
        copy.createdAt = Date()
        copy.updatedAt = Date()
        copy.deletedAt = nil
        if copy.summary?.state.running == true { copy.summary?.state = .interrupted }
        do {
            try repository.copyAssets(from: id, to: copy.id)
            return commit { $0.notebooks.append(copy) } ? copy.id : nil
        } catch { errorMessage = AppMessage(error); return nil }
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
        let message = AppMessage("필기를 저장하지 못했습니다. 여유 공간을 확인한 후 다시 저장해 주세요. %@", error: error)
        if errorMessage?.text != message.text { errorMessage = message }
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
        } catch { errorMessage = AppMessage(error); return nil }
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
        } catch { errorMessage = AppMessage("PDF를 가져오지 못했습니다. %@", error: error); return nil }
    }

    func preparePDF(data: Data, title: String, folderID: UUID?) -> PreparedPDFImport? {
        do { return preparePDF(try PDFImportContents(title: title, data: data), folderID: folderID) }
        catch { errorMessage = AppMessage(error); return nil }
    }

    func preparePDF(_ contents: PDFImportContents, folderID: UUID?) -> PreparedPDFImport? {
        do {
            guard let document = PDFDocument(url: contents.url), !document.isLocked, document.pageCount > 0 else {
                throw CocoaError(.fileReadCorruptFile)
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
            return PreparedPDFImport(title: contents.title, contents: contents, pages: pages, folderID: folderID)
        } catch { errorMessage = AppMessage("PDF를 가져오지 못했습니다. %@", error: error); return nil }
    }

    func importPDF(_ prepared: PreparedPDFImport, layout: PDFImportLayout) async -> UUID? {
        await importPDFs([prepared], title: prepared.title, layout: layout)
    }

    func importPDFs(_ files: [PreparedPDFImport], title: String, layout: PDFImportLayout) async -> UUID? {
        guard let repository, let first = files.first else { return nil }
        var note = Notebook(title: title.trimmedOrUntitled, cover: .sand, folderID: first.folderID,
                            projectID: first.projectID.flatMap { project($0)?.id })
        note.pdfAssetName = "original.pdf"
        do {
            var pages: [NotePage] = []
            for (index, file) in files.enumerated() {
                await Task.yield()
                try Task.checkCancellation()
                let name = index == 0 ? "original.pdf" : "original-\(index).pdf"
                let destination = try repository.assetURL(noteID: note.id, name: name)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: file.contents.url, to: destination)
                pages += file.pages.map { page in var page = page; page.pdfAssetName = name; return page }
            }
            await Task.yield()
            try Task.checkCancellation()
            note.pages = try NotePage.importedPDFPages(pages, layout: layout)
            guard commit({ $0.notebooks.append(note) }) else {
                try? repository.deleteAssets(noteID: note.id)
                return nil
            }
            return note.id
        } catch is CancellationError {
            try? repository.deleteAssets(noteID: note.id)
            return nil
        } catch {
            try? repository.deleteAssets(noteID: note.id)
            errorMessage = AppMessage("PDF를 가져오지 못했습니다. %@", error: error)
            return nil
        }
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
        } catch { errorMessage = AppMessage(error) }
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
        return value.isEmpty ? localized("제목 없는 노트") : value
    }
}
