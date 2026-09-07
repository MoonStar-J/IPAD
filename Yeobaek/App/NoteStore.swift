import SwiftUI
import PencilKit
import PDFKit

@MainActor
final class NoteStore: ObservableObject {
    @Published private(set) var library = Library()
    @Published var errorMessage: String?
    @Published private(set) var loadingError: String?
    @Published private(set) var hasUnsavedChanges = false
    private var repository: LibraryRepository?
    private var pending: [DrawingKey: Data] = [:]
    private var saveTask: Task<Void, Never>?
    private struct DrawingKey: Hashable { let noteID: UUID; let pageID: UUID }

    init() { loadLibrary() }

    func loadLibrary() {
        do {
            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask,
                                                       appropriateFor: nil, create: true)
            let repository = try LibraryRepository(root: documents.appendingPathComponent("Yeobaek", isDirectory: true))
            library = try repository.load()
            self.repository = repository
            loadingError = nil
        } catch { loadingError = error.localizedDescription }
    }

    func note(_ id: UUID) -> Notebook? { library.notebooks.first { $0.id == id } }

    @discardableResult
    private func commit(_ change: (inout Library) -> Void) -> Bool {
        guard let repository else { return false }
        var next = library
        change(&next)
        do {
            try repository.save(next)
            library = next
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

    @discardableResult
    func updatePage(noteID: UUID, pageID: UUID, _ change: (inout NotePage) -> Void) -> Bool {
        updateNote(noteID) { note in
            guard let index = note.pages.firstIndex(where: { $0.id == pageID }) else { return }
            change(&note.pages[index])
        }
    }

    func createNote(title: String, paper: PaperStyle, cover: CoverColor, folderID: UUID?) -> UUID? {
        var note = Notebook(title: title.trimmedOrUntitled, cover: cover, folderID: folderID)
        note.pages = [NotePage(paper: paper)]
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

    func permanentlyDelete(_ id: UUID) {
        guard flushDrawings(), commit({ $0.notebooks.removeAll { $0.id == id } }) else { return }
        do { try repository?.deleteAssets(noteID: id) }
        catch { errorMessage = "노트는 삭제했지만 첨부 파일을 정리하지 못했습니다. \(error.localizedDescription)" }
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
        if let data = pending[key] { return try PKDrawing(data: data) }
        if let data = try repository?.readDrawing(noteID: noteID, pageID: pageID) {
            return try PKDrawing(data: data)
        }
        return PKDrawing()
    }

    func queueDrawing(_ drawing: PKDrawing, noteID: UUID, pageID: UUID) {
        pending[DrawingKey(noteID: noteID, pageID: pageID)] = drawing.dataRepresentation()
        hasUnsavedChanges = true
        saveTask?.cancel()
        saveTask = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(350)) } catch { return }
            self?.flushDrawings()
        }
    }

    @discardableResult
    func flushDrawings() -> Bool {
        saveTask?.cancel()
        guard !pending.isEmpty else { return true }
        guard let repository else { return false }
        do {
            for (key, data) in pending {
                try repository.writeDrawing(data, noteID: key.noteID, pageID: key.pageID)
            }
            let changed = Set(pending.keys.map(\.noteID))
            guard commit({ library in
                for index in library.notebooks.indices where changed.contains(library.notebooks[index].id) {
                    library.notebooks[index].updatedAt = Date()
                }
            }) else { return false }
            pending.removeAll()
            hasUnsavedChanges = false
            return true
        } catch {
            errorMessage = "필기를 저장하지 못했습니다. 여유 공간을 확인한 후 다시 저장해 주세요. \(error.localizedDescription)"
            return false
        }
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

    func importPDF(_ url: URL, folderID: UUID?) -> UUID? {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            guard let repository else { return nil }
            let data = try Data(contentsOf: url)
            guard let document = PDFDocument(data: data), !document.isLocked, document.pageCount > 0 else {
                errorMessage = "이 PDF를 열 수 없습니다. 암호가 해제된 PDF를 선택해 주세요."
                return nil
            }
            var note = Notebook(title: url.deletingPathExtension().lastPathComponent, cover: .sand, folderID: folderID)
            note.pdfAssetName = "original.pdf"
            note.pages = try (0..<document.pageCount).map { index in
                guard let pdfPage = document.page(at: index) else { throw CocoaError(.fileReadCorruptFile) }
                let bounds = pdfPage.bounds(for: .mediaBox)
                let rotated = abs(pdfPage.rotation) % 180 == 90
                let width = rotated ? bounds.height : bounds.width
                let height = rotated ? bounds.width : bounds.height
                return NotePage(width: 768, height: 768 * height / max(width, 1), pdfPageIndex: index)
            }
            try repository.writeAsset(data, noteID: note.id, name: "original.pdf")
            return commit { $0.notebooks.append(note) } ? note.id : nil
        } catch { errorMessage = "PDF를 가져오지 못했습니다. \(error.localizedDescription)"; return nil }
    }

    func addImage(_ data: Data, noteID: UUID, pageID: UUID) {
        guard let image = UIImage(data: data), let page = note(noteID)?.pages.first(where: { $0.id == pageID }),
              let normalized = image.jpegData(compressionQuality: 0.9), let repository else { return }
        let name = "\(UUID()).jpg"
        do {
            try repository.writeAsset(normalized, noteID: noteID, name: name)
            let width = min(page.width - 80, 420)
            let height = min(page.height - 80, width * image.size.height / max(image.size.width, 1))
            let element = PageElement(kind: .image, assetName: name, x: 40, y: 40, width: width, height: height)
            updatePage(noteID: noteID, pageID: pageID) { $0.elements.append(element) }
        } catch { errorMessage = error.localizedDescription }
    }
}

extension String {
    var trimmedOrUntitled: String {
        let value = trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? "제목 없는 노트" : value
    }
}
