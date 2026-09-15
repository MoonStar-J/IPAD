import Foundation
import CoreGraphics

struct MarginMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var createdAt = Date()
}

struct MarginConversation: Codable, Identifiable, Equatable {
    var id = UUID()
    let noteID: UUID
    let pageID: UUID
    let projectID: UUID?
    let projectTitle: String
    let rect: CGRect
    let imageData: Data
    let extractedText: String
    let sourceDescription: String
    var messages: [MarginMessage] = []
    var createdAt = Date()
    var updatedAt = Date()
    var lastProvider: String?
    var lastModel: String?
    var draft: String?
    var webConversationURL: URL?

    var title: String { messages.first(where: { $0.role == .user })?.text ?? "선택 영역 질문" }
    func belongs(to note: Notebook) -> Bool { note.id == noteID && note.projectID == projectID }
}
