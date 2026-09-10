import Foundation

/// Each chat and its original region image are replaced together, atomically.
/// A malformed chat is reported and retained; loading never writes an empty file.
final class MarginChatRepository {
    let root: URL
    init(root: URL) { self.root = root }

    private func directory(_ noteID: UUID) -> URL { root.appendingPathComponent(noteID.uuidString, isDirectory: true) }
    func load(noteID: UUID) throws -> [MarginConversation] {
        let directory = directory(noteID)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.map { url in
                let chat = try JSONDecoder().decode(MarginConversation.self, from: Data(contentsOf: url))
                guard chat.noteID == noteID, url.deletingPathExtension().lastPathComponent == chat.id.uuidString else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return chat
            }.sorted { $0.createdAt < $1.createdAt }
    }
    func save(_ chat: MarginConversation) throws {
        let directory = directory(chat.noteID)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(chat).write(to: directory.appendingPathComponent(chat.id.uuidString + ".json"), options: .atomic)
    }
    func delete(_ chat: MarginConversation) throws {
        try FileManager.default.removeItem(at: directory(chat.noteID).appendingPathComponent(chat.id.uuidString + ".json"))
    }
    func deleteNote(_ noteID: UUID) throws {
        let directory = directory(noteID)
        if FileManager.default.fileExists(atPath: directory.path) { try FileManager.default.removeItem(at: directory) }
    }
}
