import Foundation

enum RepositoryError: LocalizedError {
    case unsupportedVersion(Int)
    case invalidAssetName
    var errorDescription: String? {
        switch self {
        case .unsupportedVersion(let version): return "지원하지 않는 보관함 버전입니다: \(version)"
        case .invalidAssetName: return "파일 이름이 올바르지 않습니다."
        }
    }
}

/// Disk operations are invoked on the main actor by NoteStore. Atomic replacement
/// keeps an interrupted write from leaving a partially written library or drawing.
final class LibraryRepository {
    let root: URL
    private let files = FileManager.default
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    init(root: URL) throws {
        self.root = root
        try files.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func load() throws -> Library {
        let url = root.appendingPathComponent("library.json")
        guard files.fileExists(atPath: url.path) else { return Library() }
        let library = try JSONDecoder().decode(Library.self, from: Data(contentsOf: url))
        guard library.version == 1 else { throw RepositoryError.unsupportedVersion(library.version) }
        return library
    }

    func save(_ library: Library) throws {
        try encoder.encode(library).write(to: root.appendingPathComponent("library.json"), options: .atomic)
    }

    func noteDirectory(_ id: UUID) -> URL {
        root.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func assetURL(noteID: UUID, name: String) throws -> URL {
        guard !name.isEmpty, name != ".", name != "..",
              !name.contains("/"), !name.contains("\\") else { throw RepositoryError.invalidAssetName }
        return noteDirectory(noteID).appendingPathComponent(name)
    }

    func writeAsset(_ data: Data, noteID: UUID, name: String) throws {
        let url = try assetURL(noteID: noteID, name: name)
        try files.createDirectory(at: noteDirectory(noteID), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
    }

    func readDrawing(noteID: UUID, pageID: UUID) throws -> Data? {
        let url = try assetURL(noteID: noteID, name: "\(pageID).drawing")
        guard files.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    func writeDrawing(_ data: Data, noteID: UUID, pageID: UUID) throws {
        try writeAsset(data, noteID: noteID, name: "\(pageID).drawing")
    }

    func copyAssets(from source: UUID, to destination: UUID) throws {
        let sourceURL = noteDirectory(source)
        guard files.fileExists(atPath: sourceURL.path) else { return }
        try files.copyItem(at: sourceURL, to: noteDirectory(destination))
    }

    func deleteAssets(noteID: UUID) throws {
        let url = noteDirectory(noteID)
        if files.fileExists(atPath: url.path) { try files.removeItem(at: url) }
    }
}
