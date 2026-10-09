import Foundation
import CoreGraphics

struct MarginMessage: Codable, Identifiable, Equatable {
    enum Role: String, Codable { case user, assistant }
    var id = UUID()
    var role: Role
    var text: String
    var createdAt = Date()
    var status: AnswerStatus?
    var mode: TutorMode?
    var preset: AIQuestionPreset?
    var model: String?
    var diagnosticCode: String?
    var diagnostic: PlanDiagnostic?
    var revision: Int?
    var attachmentIDs: [UUID]?
    var replyTo: MessageReference?
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
    var webConversationURL: URL? // Legacy link retained; never used for authentication.
    var mode: TutorMode?
    var presetID: String?
    var preset: AIQuestionPreset?
    var draftPreset: AIQuestionPreset?
    var draftInstructions: String?
    var pinnedConditions: String?
    var includeImage: Bool?
    var accountRegistrationID: String?
    var schemaVersion: Int?
    var contextRevision: Int?
    var originalAttachment: ConversationAttachment?
    var attachments: [ConversationAttachment]?
    var draftReply: MessageReference?
    var draftMessageID: UUID?
    var corrections: [SourceCorrection]?
    var snapshots: [MemorySnapshot]?
    var runs: [ContextRun]?
    var contextBudget: ContextBudget?

    var title: String { messages.first(where: { $0.role == .user })?.text ?? "선택 영역 질문" }
    func belongs(to note: Notebook) -> Bool { note.id == noteID && note.projectID == projectID }
}
