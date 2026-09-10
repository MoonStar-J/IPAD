import Foundation
import CoreGraphics

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

func sampleConversation(for note: Notebook) -> MarginConversation {
    MarginConversation(noteID: note.id, pageID: note.pages[0].id, projectID: note.projectID,
                       projectTitle: "학습 프로젝트", rect: CGRect(x: 30, y: 40, width: 120, height: 180),
                       imageData: Data([137, 80, 78, 71]), extractedText: "선택한 PDF 내용",
                       sourceDescription: "\(note.title) · 1페이지")
}

let checks: [CoreCheck] = [
    CoreCheck(name: "Continuous PDF preserves source order and mixed page heights") { repository in
        let pages = [NotePage(height: 1024, pdfPageIndex: 0), NotePage(height: 576, pdfPageIndex: 1), NotePage(height: 1300, pdfPageIndex: 2)]
        let joined = try NotePage.importedPDFPages(pages, layout: .continuous)
        try expect(joined.count == 1 && joined[0].height == 2900)
        try expect(joined[0].pdfRegions == [PDFSegment(pageIndex: 0, y: 0, height: 1024), PDFSegment(pageIndex: 1, y: 1024, height: 576), PDFSegment(pageIndex: 2, y: 1600, height: 1300)])
        let note = Notebook(title: "연속 PDF", pages: joined, pdfAssetName: "original.pdf")
        try repository.save(Library(notebooks: [note]))
        try expect(repository.load().notebooks[0] == note)
    },
    CoreCheck(name: "Paged and single-page imports retain original page identities") { _ in
        let pages = [NotePage(pdfPageIndex: 0), NotePage(height: 576, pdfPageIndex: 1)]
        try expect(NotePage.importedPDFPages(pages, layout: .paged) == pages)
        try expect(NotePage.importedPDFPages([pages[0]], layout: .continuous) == [pages[0]])
        try expect(!pages[0].isContinuousPDF)
    },
    CoreCheck(name: "Old notebooks decode without continuous PDF fields") { _ in
        let page = NotePage(pdfPageIndex: 2)
        let data = try JSONEncoder().encode(page)
        var fields = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        fields.removeValue(forKey: "pdfSegments")
        let decoded = try JSONDecoder().decode(NotePage.self, from: JSONSerialization.data(withJSONObject: fields))
        try expect(decoded == page)
        try expect(decoded.pdfRegions == [PDFSegment(pageIndex: 2, y: 0, height: 1024)])
    },
    CoreCheck(name: "Malformed PDF dimensions are rejected before import") { _ in
        for pages in [[], [NotePage()], [NotePage(height: .infinity, pdfPageIndex: 0)], [NotePage(height: -1, pdfPageIndex: 0)]] as [[NotePage]] {
            try expectThrows { _ = try NotePage.importedPDFPages(pages, layout: .continuous) }
        }
    },
    CoreCheck(name: "Renaming the app preserves the complete existing library") { repository in
        let documents = repository.root.appendingPathComponent("Documents")
        let old = try LibraryRepository(root: documents.appendingPathComponent("Yeobaek"))
        let note = Notebook(title: "보존할 학습 노트", isFavorite: true)
        let saved = Library(notebooks: [note])
        try old.save(saved)
        try old.writeDrawing(Data([1, 2, 3]), noteID: note.id, pageID: note.pages[0].id)
        try old.writeAsset(Data([7, 8]), noteID: note.id, name: "original.pdf")
        let migrated = try LibraryRepository.applicationLibrary(in: documents)
        try expect(migrated.root.lastPathComponent == "NoteMargin")
        try expect(migrated.load() == saved)
        try expect(migrated.readDrawing(noteID: note.id, pageID: note.pages[0].id) == Data([1, 2, 3]))
        try expect(Data(contentsOf: migrated.assetURL(noteID: note.id, name: "original.pdf")) == Data([7, 8]))
        try expect(!FileManager.default.fileExists(atPath: old.root.path))
        try expect(LibraryRepository.applicationLibrary(in: documents).load() == saved)
    },
    CoreCheck(name: "Renaming never overwrites a new library with old data") { repository in
        let documents = repository.root.appendingPathComponent("Documents")
        let old = try LibraryRepository(root: documents.appendingPathComponent("Yeobaek"))
        let new = try LibraryRepository(root: documents.appendingPathComponent("NoteMargin"))
        let oldLibrary = Library(notebooks: [Notebook(title: "이전 노트")])
        let newLibrary = Library(notebooks: [Notebook(title: "현재 노트")])
        try old.save(oldLibrary)
        try new.save(newLibrary)
        try expect(LibraryRepository.applicationLibrary(in: documents).load() == newLibrary)
        try expect(old.load() == oldLibrary)
    },
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
    CoreCheck(name: "Libraries saved before projects reopen without losing note data") { repository in
        let folder = NoteFolder(title: "기존 강의")
        var note = Notebook(title: "이전 버전 노트", folderID: folder.id, isFavorite: true)
        note.pdfAssetName = "original.pdf"
        note.pages[0].elements = [PageElement(kind: .text, text: "기존 필기")]
        let expected = Library(folders: [folder], notebooks: [note])
        var fields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(expected)) as! [String: Any]
        fields.removeValue(forKey: "projects")
        var notebooks = fields["notebooks"] as! [[String: Any]]
        notebooks[0].removeValue(forKey: "projectID")
        fields["notebooks"] = notebooks
        try JSONSerialization.data(withJSONObject: fields).write(to: repository.root.appendingPathComponent("library.json"))
        try repository.writeDrawing(Data([4, 8, 15]), noteID: note.id, pageID: note.pages[0].id)
        try repository.writeAsset(Data([16, 23, 42]), noteID: note.id, name: "original.pdf")
        let reopened = try repository.load()
        try expect(reopened == expected)
        try expect(reopened.projects.isEmpty && reopened.notebooks[0].projectID == nil)
        try repository.save(reopened)
        try expect(repository.load() == expected)
        try expect(repository.readDrawing(noteID: note.id, pageID: note.pages[0].id) == Data([4, 8, 15]))
        try expect(Data(contentsOf: repository.assetURL(noteID: note.id, name: "original.pdf")) == Data([16, 23, 42]))
    },
    CoreCheck(name: "Projects retain instructions, provider preferences and notebook membership") { repository in
        let project = NoteProject(title: "물리학", agentInstructions: "단위를 설명하고 단계별로 풀이해 주세요.",
                                  preferredProvider: "openai", preferredModel: "gpt-5-mini")
        let other = NoteProject(title: "수학", agentInstructions: "먼저 힌트를 주세요.")
        let note = Notebook(title: "운동량", projectID: project.id)
        let expected = Library(projects: [project, other], notebooks: [note, Notebook(title: "미분", projectID: other.id)])
        try repository.save(expected)
        try expect(LibraryRepository(root: repository.root).load() == expected)
    },
    CoreCheck(name: "Project assignment rejects unknown identifiers and preserves notebook content") { _ in
        let first = NoteProject(title: "첫 프로젝트"), second = NoteProject(title: "다음 프로젝트")
        let folder = NoteFolder(title: "강의 자료")
        let note = Notebook(title: "이동할 노트", folderID: folder.id, projectID: first.id,
                            updatedAt: Date(timeIntervalSince1970: 1), pdfAssetName: "original.pdf")
        var library = Library(folders: [folder], projects: [first, second], notebooks: [note])
        let original = library
        try expect(!library.assignProject(noteID: note.id, projectID: UUID()))
        try expect(library == original, "Unknown projects must not change membership or timestamps")
        try expect(!library.assignProject(noteID: UUID(), projectID: second.id))
        try expect(!library.assignProject(noteID: UUID(), projectID: nil))
        try expect(library == original, "Unknown notebooks must not change the library")
        try expect(library.assignProject(noteID: note.id, projectID: second.id))
        var expected = note
        expected.projectID = second.id
        expected.updatedAt = library.notebooks[0].updatedAt
        try expect(library.notebooks == [expected])
        try expect(expected.updatedAt > note.updatedAt)
        try expect(library.assignProject(noteID: note.id, projectID: nil))
        expected.projectID = nil
        expected.updatedAt = library.notebooks[0].updatedAt
        try expect(library.notebooks == [expected])
        try expect(library.folders == original.folders && library.projects == original.projects)
    },
    CoreCheck(name: "Removing a project preserves active notes, trash, folders and stored ink") { repository in
        let removed = NoteProject(title: "삭제할 프로젝트"), retained = NoteProject(title: "남길 프로젝트")
        let folder = NoteFolder(title: "유지할 폴더")
        let active = Notebook(title: "활성 노트", folderID: folder.id, projectID: removed.id, pdfAssetName: "original.pdf")
        let trashed = Notebook(title: "휴지통 노트", projectID: removed.id, deletedAt: Date(timeIntervalSince1970: 10))
        let unrelated = Notebook(title: "다른 프로젝트 노트", projectID: retained.id)
        var library = Library(folders: [folder], projects: [removed, retained], notebooks: [active, trashed, unrelated])
        try repository.writeDrawing(Data([1, 9, 2]), noteID: active.id, pageID: active.pages[0].id)
        try repository.writeAsset(Data([6, 5]), noteID: active.id, name: "original.pdf")
        library.removeProject(removed.id)
        var expectedActive = active, expectedTrashed = trashed
        expectedActive.projectID = nil
        expectedTrashed.projectID = nil
        try expect(library.projects == [retained])
        try expect(library.folders == [folder])
        try expect(library.notebooks == [expectedActive, expectedTrashed, unrelated])
        let afterRemoval = library
        library.removeProject(removed.id)
        try expect(library == afterRemoval, "Repeated project deletion must be harmless")
        try repository.save(library)
        try expect(repository.load() == afterRemoval)
        try expect(repository.readDrawing(noteID: active.id, pageID: active.pages[0].id) == Data([1, 9, 2]))
        try expect(Data(contentsOf: repository.assetURL(noteID: active.id, name: "original.pdf")) == Data([6, 5]))
    },
    CoreCheck(name: "Project filters isolate membership, search and trash") { _ in
        let first = NoteProject(title: "물리학"), second = NoteProject(title: "수학")
        let folderID = UUID()
        let assigned = Notebook(title: "공통 키워드 A", folderID: folderID, projectID: first.id)
        let other = Notebook(title: "공통 키워드 B", folderID: folderID, projectID: second.id)
        let unassigned = Notebook(title: "공통 키워드 C", folderID: folderID)
        let trashed = Notebook(title: "공통 키워드 D", projectID: first.id, deletedAt: Date())
        let unassignedTrash = Notebook(title: "공통 키워드 E", deletedAt: Date())
        let library = Library(projects: [first, second], notebooks: [assigned, other, unassigned, trashed, unassignedTrash])
        try expect(library.notes(in: .project(first.id), query: " 공통 ", sort: .title).map(\.id) == [assigned.id])
        try expect(library.notes(in: .project(second.id), query: "", sort: .title).map(\.id) == [other.id])
        try expect(library.notes(in: .unassigned, query: "", sort: .title).map(\.id) == [unassigned.id])
        try expect(library.notes(in: .project(UUID()), query: "", sort: .title).isEmpty)
        try expect(library.notes(in: .project(first.id), query: "키워드 B", sort: .title).isEmpty)
        try expect(library.notes(in: .folder(folderID), query: "", sort: .title).map(\.id) == [assigned.id, other.id, unassigned.id])
        try expect(library.notes(in: .trash, query: "", sort: .title).map(\.id) == [trashed.id, unassignedTrash.id])
    },
    CoreCheck(name: "A missing chat directory loads empty without writing files") { repository in
        let root = repository.root.appendingPathComponent("MarginChats")
        let chats = MarginChatRepository(root: root)
        try expect(chats.load(noteID: UUID()).isEmpty)
        try expect(!FileManager.default.fileExists(atPath: root.path))
    },
    CoreCheck(name: "Margin chats reopen with the original region, image, messages and order") { repository in
        let root = repository.root.appendingPathComponent("MarginChats")
        let chats = MarginChatRepository(root: root)
        let note = Notebook(title: "물리학", projectID: UUID())
        var first = sampleConversation(for: note)
        first.createdAt = Date(timeIntervalSince1970: 1)
        first.messages = [MarginMessage(role: .user, text: "이 공식의 의미는?"),
                          MarginMessage(role: .assistant, text: "운동량 보존을 나타냅니다.")]
        first.lastProvider = "openai"
        first.lastModel = "gpt-5-mini"
        first.draft = "아직 보내지 않은 후속 질문"
        var second = sampleConversation(for: note)
        second.createdAt = Date(timeIntervalSince1970: 2)
        try chats.save(second)
        try chats.save(first)
        try expect(MarginChatRepository(root: root).load(noteID: note.id) == [first, second])
        first.messages.append(MarginMessage(role: .user, text: "예제도 보여 줘."))
        first.updatedAt = Date(timeIntervalSince1970: 3)
        try chats.save(first)
        let reopened = try MarginChatRepository(root: root).load(noteID: note.id)
        try expect(reopened == [first, second], "Saving a reply must replace one chat without duplicating or changing another")
        try expect(reopened[0].title == "이 공식의 의미는?")
        try expect(reopened[1].title == "선택 영역 질문")
    },
    CoreCheck(name: "Margin conversations stay isolated by both notebook and project") { _ in
        let firstProject = UUID(), secondProject = UUID()
        let first = Notebook(title: "첫 노트", projectID: firstProject)
        let other = Notebook(title: "같은 프로젝트의 다른 노트", projectID: firstProject)
        let chat = sampleConversation(for: first)
        try expect(chat.belongs(to: first))
        try expect(!chat.belongs(to: other), "A shared project must not expose another notebook's margin pins")
        var moved = first
        moved.projectID = secondProject
        try expect(!chat.belongs(to: moved), "Moving a notebook must not expose the old project's conversation")
        moved.projectID = nil
        try expect(!chat.belongs(to: moved))
        let unassignedChat = sampleConversation(for: moved)
        try expect(unassignedChat.belongs(to: moved))
        try expect(!unassignedChat.belongs(to: Notebook(title: "다른 미지정 노트")))
        try expect(!unassignedChat.belongs(to: first), "Assigning a project must not inherit unassigned conversations")
        moved.projectID = firstProject
        try expect(chat.belongs(to: moved), "Returning to the original project should recover its conversation")
    },
    CoreCheck(name: "Corrupt chat data is reported without replacing valid or broken files") { repository in
        let root = repository.root.appendingPathComponent("MarginChats")
        let chats = MarginChatRepository(root: root)
        let note = Notebook(title: "보존할 노트")
        let chat = sampleConversation(for: note)
        try chats.save(chat)
        let directory = root.appendingPathComponent(note.id.uuidString)
        let validURL = directory.appendingPathComponent(chat.id.uuidString + ".json")
        let validData = try Data(contentsOf: validURL)
        let brokenURL = directory.appendingPathComponent(UUID().uuidString + ".json")
        let brokenData = Data("{\"messages\": interrupted save".utf8)
        try brokenData.write(to: brokenURL)
        try expectThrows { _ = try chats.load(noteID: note.id) }
        try expect(Data(contentsOf: brokenURL) == brokenData)
        try expect(Data(contentsOf: validURL) == validData)
    },
    CoreCheck(name: "Misfiled chat identities are rejected without crossing notebook boundaries") { repository in
        let root = repository.root.appendingPathComponent("MarginChats")
        let chats = MarginChatRepository(root: root)
        let note = Notebook(title: "원래 노트")
        let chat = sampleConversation(for: note)
        try chats.save(chat)
        let data = try JSONEncoder().encode(chat)
        let otherNoteID = UUID()
        let otherDirectory = root.appendingPathComponent(otherNoteID.uuidString)
        try FileManager.default.createDirectory(at: otherDirectory, withIntermediateDirectories: true)
        let wrongNoteURL = otherDirectory.appendingPathComponent(chat.id.uuidString + ".json")
        try data.write(to: wrongNoteURL)
        try expectThrows { _ = try chats.load(noteID: otherNoteID) }
        try expect(Data(contentsOf: wrongNoteURL) == data)
        try expect(chats.load(noteID: note.id) == [chat])
        let wrongIDURL = root.appendingPathComponent(note.id.uuidString).appendingPathComponent(UUID().uuidString + ".json")
        try data.write(to: wrongIDURL)
        try expectThrows { _ = try chats.load(noteID: note.id) }
        try expect(Data(contentsOf: wrongIDURL) == data)
    },
    CoreCheck(name: "Deleting a conversation or notebook preserves unrelated chat history") { repository in
        let root = repository.root.appendingPathComponent("MarginChats")
        let chats = MarginChatRepository(root: root)
        let first = Notebook(title: "첫 노트"), other = Notebook(title: "다른 노트")
        let removed = sampleConversation(for: first), sibling = sampleConversation(for: first)
        let unrelated = sampleConversation(for: other)
        try chats.save(removed)
        try chats.save(sibling)
        try chats.save(unrelated)
        try chats.delete(removed)
        try expect(chats.load(noteID: first.id) == [sibling])
        try expect(chats.load(noteID: other.id) == [unrelated])
        try chats.deleteNote(first.id)
        try expect(chats.load(noteID: first.id).isEmpty)
        try expect(chats.load(noteID: other.id) == [unrelated])
        try chats.deleteNote(first.id)
        try expect(MarginChatRepository(root: root).load(noteID: other.id) == [unrelated])
    },
    CoreCheck(name: "An invalid chat update cannot replace its last valid save") { repository in
        let root = repository.root.appendingPathComponent("MarginChats")
        let chats = MarginChatRepository(root: root)
        let note = Notebook(title: "학습 노트")
        var chat = sampleConversation(for: note)
        try chats.save(chat)
        let saved = chat
        chat.updatedAt = Date(timeIntervalSince1970: .nan)
        try expectThrows { try chats.save(chat) }
        try expect(chats.load(noteID: note.id) == [saved])
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
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("NoteMarginChecks-\(UUID())")
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
