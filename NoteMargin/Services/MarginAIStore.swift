import SwiftUI

@MainActor
final class MarginAIStore: ObservableObject {
    static let shared = MarginAIStore()
    @Published private(set) var conversations: [MarginConversation] = []
    @Published private(set) var sending = Set<UUID>()
    @Published private(set) var failures: [UUID: String] = [:]
    @Published var errorMessage: String?
    private var repository: MarginChatRepository?
    private var loaded = Set<UUID>()
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var draftSaves: [UUID: Task<Void, Never>] = [:]
    // Retain a response even when the disk is full; retrying its save must not
    // send another billable request.
    private var unsaved = Set<UUID>()
    private var planRequestIDs: [UUID: UUID] = [:]

    init(repository: MarginChatRepository? = nil) {
        do {
            if let repository { self.repository = repository }
            else {
                let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                let library = try LibraryRepository.applicationLibrary(in: documents)
                self.repository = MarginChatRepository(root: library.root.appendingPathComponent("MarginChats", isDirectory: true))
            }
        } catch { errorMessage = "AI 대화 저장소를 열지 못했습니다. \(error.localizedDescription)" }
    }

    func load(noteID: UUID) {
        guard !loaded.contains(noteID), let repository else { return }
        do {
            var chats = try repository.load(noteID: noteID)
            for i in chats.indices {
                var recovered = false
                for j in chats[i].messages.indices where chats[i].messages[j].status == .streaming {
                    chats[i].messages[j].status = .interrupted; recovered = true
                }
                if recovered { try repository.save(chats[i]) }
            }
            conversations.removeAll { $0.noteID == noteID }
            conversations.append(contentsOf: chats)
            loaded.insert(noteID)
        } catch { errorMessage = "이 노트의 AI 대화를 불러오지 못했습니다. 원본은 보존됩니다. \(error.localizedDescription)" }
    }
    func conversation(_ id: UUID) -> MarginConversation? { conversations.first { $0.id == id } }
    @discardableResult func linkWebConversation(_ url: URL, to id: UUID) -> Bool {
        guard let clean = ChatGPTWebContext.conversationURL(url), var chat = conversation(id) else { return false }
        chat.webConversationURL = clean; chat.updatedAt = Date()
        return persist(chat)
    }
    func setDraft(_ text: String, for id: UUID) {
        guard var chat = conversation(id) else { return }
        chat.draft = text; replace(chat)
        draftSaves[id]?.cancel()
        draftSaves[id] = Task { [weak self] in
            do { try await Task.sleep(for: .milliseconds(400)) } catch { return }
            self?.flushDraft(id)
        }
    }
    func flushDraft(_ id: UUID) {
        guard draftSaves[id] != nil, let chat = conversation(id) else { return }
        draftSaves[id]?.cancel(); draftSaves[id] = nil
        persist(chat, retainOnFailure: true)
    }
    func flushDrafts(noteID: UUID) {
        for id in conversations.filter({ $0.noteID == noteID }).map(\.id) { flushDraft(id) }
    }
    func create(note: Notebook, project: NoteProject?, region: CapturedRegion) -> UUID? {
        load(noteID: note.id)
        guard loaded.contains(note.id) else { return nil }
        let chat = MarginConversation(noteID: note.id, pageID: region.pageID, projectID: note.projectID,
                                      projectTitle: project?.title ?? "프로젝트 미지정", rect: region.rect,
                                      imageData: region.imageData, extractedText: region.extractedText,
                                      sourceDescription: region.sourceDescription)
        return persist(chat) ? chat.id : nil
    }
    @discardableResult private func persist(_ chat: MarginConversation, retainOnFailure: Bool = false) -> Bool {
        guard let repository else { return false }
        do {
            try repository.save(chat)
            replace(chat)
            if unsaved.remove(chat.id) != nil { failures[chat.id] = nil }
            return true
        } catch {
            if retainOnFailure {
                replace(chat); unsaved.insert(chat.id)
                failures[chat.id] = "저장하지 못한 내용이 있습니다. 저장 공간을 확인한 뒤 ‘저장 다시 시도’를 눌러 주세요."
            }
            errorMessage = "AI 대화를 저장하지 못했습니다. \(error.localizedDescription)"
            return false
        }
    }
    private func replace(_ chat: MarginConversation) {
        if let index = conversations.firstIndex(where: { $0.id == chat.id }) { conversations[index] = chat }
        else { conversations.append(chat) }
    }
    func retrySave(_ id: UUID) {
        guard let chat = conversation(id) else { return }
        if persist(chat) { failures[id] = nil }
    }
    func needsSaving(_ id: UUID) -> Bool { unsaved.contains(id) }
    func cancel(_ id: UUID) { requests[id]?.cancel() }
    func delete(_ id: UUID) {
        guard let chat = conversation(id), !sending.contains(id) else { return }
        do {
            try repository?.delete(chat)
            draftSaves[id]?.cancel(); draftSaves[id] = nil
            conversations.removeAll { $0.id == id }; failures[id] = nil; unsaved.remove(id)
        } catch { errorMessage = "대화를 삭제하지 못했습니다. \(error.localizedDescription)" }
    }
    func deleteNote(_ noteID: UUID) {
        let ids = conversations.filter { $0.noteID == noteID }.map(\.id)
        for id in ids {
            requests[id]?.cancel(); requests[id] = nil; sending.remove(id); failures[id] = nil
            draftSaves[id]?.cancel(); draftSaves[id] = nil; unsaved.remove(id)
        }
        // Remove from memory first so a late, cancelled response cannot restore it.
        conversations.removeAll { $0.noteID == noteID }; loaded.remove(noteID)
        do { try repository?.deleteNote(noteID) }
        catch { errorMessage = "삭제된 노트의 AI 대화를 정리하지 못했습니다. \(error.localizedDescription)" }
    }

    func configure(_ id: UUID, mode: TutorMode? = nil, conditions: String? = nil, includeImage: Bool? = nil) {
        guard var chat = conversation(id), !sending.contains(id) else { return }
        if let mode { chat.mode = mode }
        if let conditions { chat.pinnedConditions = conditions }
        if let includeImage { chat.includeImage = includeImage }
        chat.schemaVersion = 2
        persist(chat, retainOnFailure: true)
    }
    func cancelPlanRequests() {
        for id in Array(planRequestIDs.keys) {
            requests[id]?.cancel(); requests[id] = nil; planRequestIDs[id] = nil; sending.remove(id)
            if var chat = conversation(id), let j = chat.messages.lastIndex(where: { $0.status == .streaming }) {
                chat.messages[j].status = .interrupted; persist(chat, retainOnFailure: true)
            }
        }
    }
    @discardableResult func sendPlan(_ question: String, conversationID id: UUID, project: NoteProject?) -> Bool {
        let connection = ChatGPTPlanConnection.shared
        guard var chat = conversation(id), !sending.contains(id), !unsaved.contains(id),
              connection.state == .ready, let account = connection.selected,
              connection.models.contains(where: { $0.slug == connection.model }) else { return false }
        guard chat.projectID == project?.id else { failures[id] = "프로젝트가 변경되었습니다. 새 영역 대화를 만들어 주세요."; return false }
        if let previous = chat.accountRegistrationID, previous != account {
            failures[id] = "다른 계정에서 만든 대화입니다. 원래 계정을 선택하거나 새 영역 대화를 만들어 주세요."; return false
        }
        let question = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return false }
        let model = connection.model, generation = connection.generation, requestID = UUID()
        chat.messages.append(MarginMessage(role: .user, text: question, mode: chat.mode ?? .free, model: model))
        let body: PlanRequest
        do { body = try PlanRequest.build(chat: chat, model: model, projectInstructions: project?.agentInstructions ?? "") }
        catch { failures[id] = error.localizedDescription; return false }
        let assistant = MarginMessage(role: .assistant, text: "", status: .streaming, mode: chat.mode ?? .free, model: model)
        chat.messages.append(assistant); chat.draft = ""; chat.lastModel = model; chat.lastProvider = "chatgpt-plan"
        chat.accountRegistrationID = account; chat.schemaVersion = 2; chat.updatedAt = Date()
        guard persist(chat) else { return false }
        failures[id] = nil; sending.insert(id); planRequestIDs[id] = requestID
        requests[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.planRequestIDs[id] == requestID {
                    self.planRequestIDs[id] = nil; self.sending.remove(id); self.requests[id] = nil
                }
            }
            var lastSaved = Date.distantPast
            @MainActor func apply(_ result: PlanStreamAccumulator) {
                guard self.planRequestIDs[id] == requestID, generation == connection.generation,
                      let current = self.conversation(id), let index = current.messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                var updated = current
                updated.messages[index].text = result.text; updated.messages[index].status = result.status
                updated.messages[index].diagnosticCode = result.failure?.code
                updated.messages[index].diagnostic = result.failure.map(PlanDiagnostic.init)
                updated.updatedAt = Date()
                self.replace(updated)
                if result.status != .streaming || Date().timeIntervalSince(lastSaved) > 1 {
                    self.persist(updated, retainOnFailure: true); lastSaved = Date()
                }
            }
            do {
                let tokens = try await connection.credentials.credentials(client: account)
                try Task.checkCancellation()
                guard self.planRequestIDs[id] == requestID, generation == connection.generation, connection.selected == account else { throw CancellationError() }
                let result = try await ChatGPTPlanTransport.stream(request: body, token: tokens.access_token) { update in
                    // A cancellation/account change cannot restore a former request.
                    guard !Task.isCancelled || update.status == .cancelled else { return }
                    apply(update)
                }
                apply(result)
                if let failure = result.failure { self.failures[id] = failure.localizedDescription; connection.handle(failure, duringInference: true) }
                else if result.status != .completed { self.failures[id] = "답변이 완료되지 않았습니다. 부분 답변을 보존했으며 자동으로 재전송하지 않습니다." }
            } catch {
                guard self.planRequestIDs[id] == requestID, generation == connection.generation,
                      var current = self.conversation(id), let j = current.messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                let cancelled = Task.isCancelled || error is CancellationError
                let failure = error as? PlanFailure ?? PlanFailure(kind: cancelled ? .cancelled : .network, code: cancelled ? "cancelled" : "network_error")
                if current.messages[j].status == .streaming { current.messages[j].status = cancelled ? .cancelled : .interrupted }
                current.messages[j].diagnosticCode = failure.code
                current.messages[j].diagnostic = PlanDiagnostic(failure)
                self.persist(current, retainOnFailure: true); self.failures[id] = failure.localizedDescription
                if !cancelled { connection.handle(failure, duringInference: true) }
            }
        }
        return true
    }

}
