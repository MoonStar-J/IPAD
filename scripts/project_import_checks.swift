import Foundation

@main struct ProjectImportChecks {
    static func main() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ProjectImportChecks-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let repository = try LibraryRepository(root: temporary.appendingPathComponent("Library"))

        let original = NoteProject(title: "기존 프로젝트", agentInstructions: "학습 지침")
        var legacyFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        legacyFields.removeValue(forKey: "cover")
        let legacy = try JSONDecoder().decode(NoteProject.self, from: JSONSerialization.data(withJSONObject: legacyFields))
        precondition(legacy.id == original.id && legacy.agentInstructions == original.agentInstructions)
        precondition((legacy.cover ?? .blue) == .blue)

        let projects = CoverColor.allCases.map { NoteProject(title: $0.title, parentID: original.id, cover: $0) }
        var library = Library(projects: [legacy] + projects, notebooks: [Notebook(title: "보존할 노트", projectID: projects[0].id)])
        try repository.save(library)
        let reopened = try repository.load()
        precondition(reopened == library)
        precondition(library.move(.project(projects[0].id), to: nil))
        precondition(library.projects.first { $0.id == projects[0].id }?.cover == projects[0].cover)
        precondition(library.notebooks[0].projectID == projects[0].id)
        print("PASS project colors survive decoding, disk persistence and hierarchy moves; legacy projects remain blue")

        let source = temporary.appendingPathComponent("강의 자료.pdf")
        let bytes = Data("%PDF-1.7\nselected file bytes".utf8)
        try bytes.write(to: source)
        let contents = try await PDFImportReader.read(source)
        precondition(contents.title == "강의 자료" && contents.data == bytes)
        let unchanged = try Data(contentsOf: source)
        precondition(unchanged == bytes)
        try FileManager.default.removeItem(at: source)
        precondition(contents.data == bytes)
        print("PASS coordinated import owns original bytes after the source disappears and never changes the source")

        do {
            _ = try await PDFImportReader.read(source)
            preconditionFailure("Missing source must fail")
        } catch { }
        do {
            _ = try await PDFImportReader.read(URL(string: "https://example.invalid/document.pdf")!)
            preconditionFailure("Remote URL must not trigger a network download")
        } catch { }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PDFImportReader.read(source)
        }
        do {
            _ = try await cancelled.value
            preconditionFailure("Cancelled import must not continue")
        } catch is CancellationError { }
        print("PASS missing file, unsupported URL and cancellation are rejected without importing")
    }
}
