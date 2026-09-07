import Foundation

// A portable executable suite: also runs with Command Line Tools, where XCTest
// is not shipped. The app and these checks compile the same Core sources.
struct CheckFailure: Error, CustomStringConvertible {
    let description: String
}

func expect(_ condition: @autoclosure () throws -> Bool, _ message: String = "Assertion failed") throws {
    if try !condition() { throw CheckFailure(description: message) }
}

func expectThrows(_ action: () throws -> Void) throws {
    do { try action() } catch { return }
    throw CheckFailure(description: "Expected an error")
}

struct CoreCheck {
    let name: String
    let run: (LibraryRepository) throws -> Void
}

let checks: [CoreCheck] = [
    CoreCheck(name: "Fresh library is empty") { repository in
        try expect(repository.load() == Library())
    },
    CoreCheck(name: "Round trip preserves pages, folders and attachments") { repository in
        let folder = NoteFolder(title: "강의")
        var note = Notebook(title: "물리학", cover: .sage, folderID: folder.id, isFavorite: true)
        note.pdfAssetName = "original.pdf"
        note.pages = [NotePage(paper: .grid, width: 768, height: 600, pdfPageIndex: 2,
                               elements: [PageElement(kind: .text, text: "관성"), PageElement(kind: .image, assetName: "photo.jpg")])]
        let expected = Library(folders: [folder], notebooks: [note])
        try repository.save(expected)
        try expect(LibraryRepository(root: repository.root).load() == expected)
    },
    CoreCheck(name: "Drawing replacement survives reopening") { repository in
        let noteID = UUID(), pageID = UUID()
        try expect(repository.readDrawing(noteID: noteID, pageID: pageID) == nil)
        try repository.writeDrawing(Data([1, 2]), noteID: noteID, pageID: pageID)
        try repository.writeDrawing(Data([3, 4, 5]), noteID: noteID, pageID: pageID)
        try expect(LibraryRepository(root: repository.root).readDrawing(noteID: noteID, pageID: pageID) == Data([3, 4, 5]))
    },
    CoreCheck(name: "Duplicated notes have independent assets") { repository in
        let source = UUID(), destination = UUID(), pageID = UUID()
        try repository.writeDrawing(Data([42]), noteID: source, pageID: pageID)
        try repository.writeAsset(Data([9]), noteID: source, name: "original.pdf")
        try repository.copyAssets(from: source, to: destination)
        try repository.writeDrawing(Data([7]), noteID: destination, pageID: pageID)
        try repository.deleteAssets(noteID: source)
        try expect(repository.readDrawing(noteID: destination, pageID: pageID) == Data([7]))
        try expect(Data(contentsOf: repository.assetURL(noteID: destination, name: "original.pdf")) == Data([9]))
    },
    CoreCheck(name: "Corrupt library is preserved and rejected") { repository in
        let original = Data("not json".utf8)
        let url = repository.root.appendingPathComponent("library.json")
        try original.write(to: url)
        try expectThrows { _ = try repository.load() }
        try expect(Data(contentsOf: url) == original)
    },
    CoreCheck(name: "Unknown schema versions are rejected") { repository in
        var library = Library()
        library.version = 999
        try repository.save(library)
        try expectThrows { _ = try repository.load() }
    },
    CoreCheck(name: "Asset paths cannot escape their notebook") { repository in
        for name in ["../library.json", "a/b", "..", ".", "", "a\\b"] {
            try expectThrows { try repository.writeAsset(Data(), noteID: UUID(), name: name) }
        }
    },
    CoreCheck(name: "Removing a folder preserves active and trashed notes") { _ in
        let folder = NoteFolder(title: "프로젝트")
        var deleted = Notebook(title: "삭제한 노트", folderID: folder.id)
        deleted.deletedAt = Date()
        var library = Library(folders: [folder], notebooks: [Notebook(title: "노트", folderID: folder.id), deleted])
        library.removeFolder(folder.id)
        try expect(library.folders.isEmpty)
        try expect(library.notebooks.count == 2)
        try expect(library.notebooks.allSatisfy { $0.folderID == nil })
        try expect(library.notebooks[1].deletedAt != nil)
    },
    CoreCheck(name: "Trash filtering and restoration") { _ in
        let folderID = UUID()
        var note = Notebook(title: "노트", folderID: folderID, isFavorite: true)
        note.deletedAt = Date()
        for filter in [LibraryFilter.all, .favorites, .folder(folderID)] { try expect(!filter.includes(note)) }
        try expect(LibraryFilter.trash.includes(note))
        note.deletedAt = nil
        try expect(LibraryFilter.all.includes(note))
        try expect(LibraryFilter.favorites.includes(note))
        try expect(!LibraryFilter.trash.includes(note))
    },
    CoreCheck(name: "Text search respects folders and whitespace") { _ in
        let folderID = UUID()
        var note = Notebook(title: "강의", folderID: folderID)
        note.pages[0].elements = [PageElement(kind: .text, text: "Newton's law")]
        let library = Library(notebooks: [note, Notebook(title: "Newton elsewhere")])
        try expect(library.notes(in: .folder(folderID), query: " newton ", sort: .title).map(\.id) == [note.id])
        try expect(library.notes(in: .all, query: "존재하지않음", sort: .modified).isEmpty)
    },
    CoreCheck(name: "Sorting by modification, creation and title") { _ in
        let early = Date(timeIntervalSince1970: 1), late = Date(timeIntervalSince1970: 2)
        let a = Notebook(title: "A", createdAt: late, updatedAt: early)
        let b = Notebook(title: "B", createdAt: early, updatedAt: late)
        let library = Library(notebooks: [b, a])
        try expect(library.notes(in: .all, query: "", sort: .modified).map(\.id) == [b.id, a.id])
        try expect(library.notes(in: .all, query: "", sort: .created).map(\.id) == [a.id, b.id])
        try expect(library.notes(in: .all, query: "", sort: .title).map(\.id) == [a.id, b.id])
    },
    CoreCheck(name: "Invalid numeric data cannot replace a saved library") { repository in
        let saved = Library(notebooks: [Notebook(title: "보존할 노트")])
        try repository.save(saved)
        var invalid = saved
        invalid.notebooks[0].pages[0].width = .nan
        try expectThrows { try repository.save(invalid) }
        try expect(repository.load() == saved)
    }
]

var failures = 0
for check in checks {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("YeobaekChecks-\(UUID())")
    do {
        let repository = try LibraryRepository(root: root)
        defer { try? FileManager.default.removeItem(at: root) }
        try check.run(repository)
        print("PASS  \(check.name)")
    } catch {
        failures += 1
        print("FAIL  \(check.name): \(error)")
    }
}
print("\(checks.count - failures)/\(checks.count) checks passed")
if failures > 0 { exit(1) }
