import SwiftUI

@MainActor
final class MarginAIStore: ObservableObject {
    static let shared = MarginAIStore()
    @Published private(set) var conversations: [MarginConversation] = []
    @Published private(set) var sending = Set<UUID>()
    @Published private(set) var failures: [UUID: String] = [:]
    @Published var errorMessage: String?
    private let connection: ChatGPTPlanConnection
    private let http: PlanHTTP
    private var repository: MarginChatRepository?
    private var loaded = Set<UUID>()
    private var requests: [UUID: Task<Void, Never>] = [:]
    private var draftSaves: [UUID: Task<Void, Never>] = [:]
    // Retain a response even when the disk is full; retrying its save must not
    // send another billable request.
    private var unsaved = Set<UUID>()
    private var planRequestIDs: [UUID: UUID] = [:]

    init(repository: MarginChatRepository? = nil, connection: ChatGPTPlanConnection? = nil, http: PlanHTTP = .shared) {
        self.connection = connection ?? .shared; self.http = http
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
                let before = chats[i]
                chats[i].migrateMemory()
                chats[i].recoverMemoryRuns()
                if chats[i] != before { try repository.save(chats[i]) }
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
        var chat = MarginConversation(noteID: note.id, pageID: region.pageID, projectID: note.projectID,
                                      projectTitle: project?.title ?? "프로젝트 미지정", rect: region.rect,
                                      imageData: region.imageData, extractedText: region.extractedText,
                                      sourceDescription: region.sourceDescription)
        chat.migrateMemory()
        chat.originalAttachment?.documentModifiedAt = note.updatedAt
        chat.originalAttachment?.pdfPageNumbers = region.pdfPageNumbers
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
        if let conditions, chat.pinnedConditions != conditions { chat.pinnedConditions = conditions; chat.sourceChanged() }
        if let includeImage { chat.includeImage = includeImage }
        chat.schemaVersion = 3
        persist(chat, retainOnFailure: true)
    }
    func cancelPlanRequests() {
        for id in Array(planRequestIDs.keys) {
            requests[id]?.cancel(); requests[id] = nil; planRequestIDs[id] = nil; sending.remove(id)
            if var chat = conversation(id), let j = chat.messages.lastIndex(where: { $0.status == .streaming }) {
                chat.messages[j].status = .interrupted; chat.recoverMemoryRuns(); persist(chat, retainOnFailure: true)
            } else if var chat = conversation(id) {
                chat.recoverMemoryRuns(); persist(chat, retainOnFailure: true)
            }
        }
    }
    private func appendPendingQuestion(_ question: String, to chat: inout MarginConversation, model: String) {
        // Explicit retry of an unanswered HTTP 400 keeps its existing user turn.
        // Several rejected attempts may follow that turn; keep all error records visible.
        let rejected = chat.messages.last
        let previousUser = chat.messages.last(where: { $0.role == .user })
        let reuse = rejected?.role == .assistant && rejected?.text.isEmpty == true &&
            rejected?.diagnostic?.httpStatus == 400 && previousUser?.text == question &&
            previousUser?.replyTo == chat.draftReply
        if !reuse {
            chat.messages.append(MarginMessage(id: chat.draftMessageID ?? UUID(), role: .user, text: question,
                mode: chat.mode ?? .free, model: model, revision: 1, replyTo: chat.draftReply))
        }
    }
    @discardableResult func sendPlan(_ question: String, conversationID id: UUID, project: NoteProject?) -> Bool {
        let connection = self.connection
        guard var chat = conversation(id), !sending.contains(id), !unsaved.contains(id),
              connection.state == .ready, let account = connection.selected,
              connection.models.contains(where: { $0.slug == connection.model }) else { return false }
        guard chat.projectID == project?.id else { failures[id] = "프로젝트가 변경되었습니다. 새 영역 대화를 만들어 주세요."; return false }
        if let previous = chat.accountRegistrationID, previous != account {
            failures[id] = "다른 계정에서 만든 대화입니다. 원래 계정을 선택하거나 새 영역 대화를 만들어 주세요."; return false
        }
        let question = (chat.mode ?? .free).question(for: question)
        let model = connection.model, generation = connection.generation, requestID = UUID()
        chat.migrateMemory()
        chat.contextRevision = chat.revision + 1
        let reply = chat.draftReply
        appendPendingQuestion(question, to: &chat, model: model)
        let body: PlanRequest
        let manifest: ContextManifest
        do {
            let plan = try ContextBuilder.build(chat: chat, projectInstructions: project?.agentInstructions ?? "")
            (body, manifest) = try PlanRequest.serialize(plan, model: model, policy: chat.policy)
        } catch { failures[id] = error.localizedDescription; return false }
        let assistant = MarginMessage(role: .assistant, text: "", status: .streaming, mode: chat.mode ?? .free, model: model)
        chat.runs = (chat.runs ?? []) + [ContextRun(id: requestID, kind: .answer, manifest: manifest, model: model,
            authGeneration: generation, responseMessageID: assistant.id, frozenInstructions: body.instructions)]
        chat.messages.append(assistant); chat.draft = ""; chat.draftReply = nil; chat.draftMessageID = UUID(); chat.lastModel = model; chat.lastProvider = "chatgpt-plan"
        chat.accountRegistrationID = account; chat.schemaVersion = 3; chat.updatedAt = Date()
        guard persist(chat) else { return false }
        failures[id] = nil; sending.insert(id); planRequestIDs[id] = requestID
        requests[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.planRequestIDs[id] == requestID {
                    self.finishRequest(id, requestID: requestID)
                }
            }
            var lastSaved = Date.distantPast
            @MainActor func apply(_ result: PlanStreamAccumulator) {
                // Model choice affects future requests, not an accepted answer
                // in another panel. Account changes still invalidate this stream.
                guard self.planRequestIDs[id] == requestID, generation == connection.generation,
                      let current = self.conversation(id), let index = current.messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                var updated = current
                updated.messages[index].text = result.text; updated.messages[index].status = result.status
                updated.messages[index].diagnosticCode = result.failure?.code
                updated.messages[index].diagnostic = result.failure.map(PlanDiagnostic.init)
                updated.updatedAt = Date()
                if result.failure?.kind == .context, updated.draft?.isEmpty != false {
                    updated.draft = question; updated.draftReply = reply
                }
                if let run = updated.runs?.firstIndex(where: { $0.id == requestID }) {
                    updated.runs?[run].state = result.status
                    if !result.text.isEmpty && updated.runs?[run].firstTextMilliseconds == nil {
                        let elapsed = Int(Date().timeIntervalSince(updated.runs![run].startedAt) * 1000)
                        updated.runs?[run].firstTextMilliseconds = elapsed
                    }
                    updated.runs?[run].reportedInputTokens = result.inputTokens
                    updated.runs?[run].reportedOutputTokens = result.outputTokens
                    updated.runs?[run].reportedCachedTokens = result.cachedTokens
                }
                self.replace(updated)
                if result.status != .streaming || Date().timeIntervalSince(lastSaved) > 1 {
                    self.persist(updated, retainOnFailure: true); lastSaved = Date()
                }
            }
            do {
                let tokens = try await connection.credentials.credentials(client: account)
                try Task.checkCancellation()
                guard self.planRequestIDs[id] == requestID, generation == connection.generation, connection.selected == account else { throw CancellationError() }
                let result = try await ChatGPTPlanTransport.stream(request: body, token: tokens.access_token, http: self.http) { update in
                    // A cancellation/account change cannot restore a former request.
                    guard !Task.isCancelled || update.status == .cancelled else { return }
                    apply(update)
                }
                try Task.checkCancellation()
                apply(result)
                if let failure = result.failure { self.failures[id] = failure.localizedDescription; connection.handle(failure, duringInference: true) }
                else if result.status != .completed { self.failures[id] = "답변이 완료되지 않았습니다. 부분 답변을 보존했으며 자동으로 재전송하지 않습니다." }
            } catch {
                guard self.planRequestIDs[id] == requestID, generation == connection.generation,
                      var current = self.conversation(id), let j = current.messages.firstIndex(where: { $0.id == assistant.id }) else { return }
                let cancelled = Task.isCancelled || error is CancellationError
                let failure = error as? PlanFailure ?? PlanFailure(kind: cancelled ? .cancelled : .network, code: cancelled ? "cancelled" : "network_error")
                if current.messages[j].status == .streaming { current.messages[j].status = cancelled ? .cancelled : .interrupted }
                if failure.httpStatus == 400 && current.messages[j].text.isEmpty { current.messages[j].status = .failed }
                if !cancelled && (failure.kind == .context || failure.httpStatus == 400), current.draft?.isEmpty != false {
                    current.draft = question; current.draftReply = reply
                }
                if let run = current.runs?.firstIndex(where: { $0.id == requestID }) { current.runs?[run].state = current.messages[j].status ?? .interrupted }
                current.messages[j].diagnosticCode = failure.code
                current.messages[j].diagnostic = PlanDiagnostic(failure)
                self.persist(current, retainOnFailure: true); self.failures[id] = failure.localizedDescription
                if !cancelled { connection.handle(failure, duringInference: true) }
            }
        }
        return true
    }

    private func finishRequest(_ id: UUID, requestID: UUID) {
        if var chat = conversation(id), let index = chat.runs?.firstIndex(where: { $0.id == requestID }), chat.runs?[index].state == .streaming {
            chat.runs?[index].state = .interrupted
            if let messageID = chat.runs?[index].responseMessageID, let j = chat.messages.firstIndex(where: { $0.id == messageID }), chat.messages[j].status == .streaming { chat.messages[j].status = .interrupted }
            persist(chat, retainOnFailure: true)
        }
        planRequestIDs[id] = nil; sending.remove(id); requests[id] = nil
    }
    @discardableResult func addCapture(_ region: CapturedRegion, to id: UUID, note: Notebook) -> Bool {
        guard var chat = conversation(id), chat.belongs(to: note), !sending.contains(id), !unsaved.contains(id) else { return false }
        chat.migrateMemory(); chat.sourceChanged()
        var message = MarginMessage(role: .user, text: "내 풀이 / 추가 자료 스크린샷", revision: 1)
        var image = ConversationAttachment(data: region.imageData, noteID: note.id, pageID: region.pageID, rect: region.rect,
            source: region.sourceDescription, text: region.extractedText, revision: chat.revision, introducedBy: message.id)
        image.documentModifiedAt = note.updatedAt; image.pdfPageNumbers = region.pdfPageNumbers
        message.attachmentIDs = [image.id]
        chat.attachments = (chat.attachments ?? []) + [image]; chat.messages.append(message)
        return persist(chat, retainOnFailure: true)
    }
    func setReply(_ reply: MessageReference?, for id: UUID) {
        guard var chat = conversation(id), !sending.contains(id) else { return }
        chat.draftReply = reply; persist(chat, retainOnFailure: true)
    }
    func correct(_ id: UUID, before: String, after: String) {
        guard var chat = conversation(id), !before.isEmpty, !after.isEmpty else { return }
        if chat.runs?.last?.kind == .answer && sending.contains(id) {
            requests[id]?.cancel(); requests[id] = nil; planRequestIDs[id] = nil; sending.remove(id)
            chat.recoverMemoryRuns()
        }
        chat.correct(before: before, after: after); persist(chat, retainOnFailure: true)
    }
    func setBudget(_ id: UUID, tokens: Int) {
        guard var chat = conversation(id), !sending.contains(id) else { return }
        var policy = chat.policy; policy.inputTokens = max(6000, min(200_000, tokens)); chat.contextBudget = policy
        persist(chat, retainOnFailure: true)
    }
    func setTranscription(_ id: UUID, imageID: UUID, text: String, use: Bool) {
        guard var chat = conversation(id), !sending.contains(id) else { return }
        chat.migrateMemory(); chat.sourceChanged()
        if imageID == chat.originalAttachment?.id {
            let history = (chat.originalAttachment?.transcriptionHistory ?? []) + [TranscriptionRecord(text: text, use: use, revision: chat.revision)]
            chat.originalAttachment?.transcriptionHistory = history
            chat.originalAttachment?.approvedTranscription = text; chat.originalAttachment?.useApprovedText = use
        } else if let index = chat.attachments?.firstIndex(where: { $0.id == imageID }) {
            let history = (chat.attachments?[index].transcriptionHistory ?? []) + [TranscriptionRecord(text: text, use: use, revision: chat.revision)]
            chat.attachments?[index].transcriptionHistory = history
            chat.attachments?[index].approvedTranscription = text; chat.attachments?[index].useApprovedText = use
        }
        persist(chat, retainOnFailure: true)
    }
    func reviewSummary(_ id: UUID, snapshotID: UUID, summary: DiscussionSummary) {
        guard var chat = conversation(id), !sending.contains(id), let index = chat.snapshots?.firstIndex(where: { $0.id == snapshotID }),
              chat.valid(chat.snapshots![index]) else { return }
        // Review creates another derived version; in-flight manifests keep their original snapshot ID.
        let old = chat.snapshots![index]
        var revised = MemorySnapshot(coverage: old.coverage, fingerprint: old.fingerprint, summary: summary, model: old.model)
        revised.reviewed = true; chat.snapshots?.append(revised)
        persist(chat, retainOnFailure: true)
    }
    func previewContext(_ id: UUID, project: NoteProject?, model: String) throws -> (ContextPlan, ContextManifest) {
        guard var chat = conversation(id), chat.projectID == project?.id else { throw ContextAction.invalidScope }
        chat.contextRevision = chat.revision + 1
        appendPendingQuestion((chat.mode ?? .free).question(for: chat.draft ?? ""), to: &chat, model: model)
        let plan: ContextPlan
        do { plan = try ContextBuilder.build(chat: chat, projectInstructions: project?.agentInstructions ?? "") }
        catch ContextAction.overflow { plan = try ContextBuilder.assemble(chat: chat, projectInstructions: project?.agentInstructions ?? "", snapshot: nil) }
        return (plan, try PlanRequest.serialize(plan, model: model, policy: chat.policy).manifest)
    }
    /// Only explicit UI action invokes this separate billable request. There is no automatic mode.
    @discardableResult func compress(_ id: UUID, project: NoteProject?) -> Bool {
        let connection = self.connection
        guard var chat = conversation(id), !sending.contains(id), !unsaved.contains(id), chat.projectID == project?.id,
              connection.state == .ready, let account = connection.selected,
              chat.accountRegistrationID == nil || chat.accountRegistrationID == account,
              connection.models.contains(where: { $0.slug == connection.model }) else { return false }
        let generation = connection.generation, model = connection.model, requestID = UUID()
        let job: CompressionJob, body: PlanRequest, manifest: ContextManifest
        do {
            job = try CompressionJob.prepare(chat: chat)
            (body, manifest) = try PlanRequest.serialize(job.plan, model: model, policy: chat.policy)
        } catch { failures[id] = error.localizedDescription; return false }
        chat.accountRegistrationID = account
        chat.runs = (chat.runs ?? []) + [.init(id: requestID, kind: .compression, manifest: manifest, model: model, authGeneration: generation, responseMessageID: nil, frozenInstructions: body.instructions)]
        guard persist(chat) else { return false }
        failures[id] = nil; sending.insert(id); planRequestIDs[id] = requestID
        requests[id] = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.planRequestIDs[id] == requestID { self.finishRequest(id, requestID: requestID) }
            }
            do {
                let tokens = try await connection.credentials.credentials(client: account)
                try Task.checkCancellation()
                guard self.planRequestIDs[id] == requestID, generation == connection.generation, connection.selected == account else { throw CancellationError() }
                let result = try await ChatGPTPlanTransport.stream(request: body, token: tokens.access_token, http: self.http) { _ in }
                try Task.checkCancellation()
                guard self.planRequestIDs[id] == requestID, generation == connection.generation, model == connection.model, var latest = self.conversation(id) else { return }
                guard result.status == .completed else {
                    if let i = latest.runs?.firstIndex(where: { $0.id == requestID }) { latest.runs?[i].state = result.status }
                    self.persist(latest, retainOnFailure: true)
                    throw result.failure ?? PlanFailure(kind: .network, code: "compression_interrupted")
                }
                let snapshot = try job.result(result.text, model: model)
                try latest.install(snapshot)
                if let i = latest.runs?.firstIndex(where: { $0.id == requestID }) {
                    latest.runs?[i].state = .completed
                    latest.runs?[i].reportedInputTokens = result.inputTokens
                    latest.runs?[i].reportedOutputTokens = result.outputTokens
                    latest.runs?[i].reportedCachedTokens = result.cachedTokens
                }
                self.persist(latest, retainOnFailure: true)
            } catch {
                guard self.planRequestIDs[id] == requestID, generation == connection.generation, var latest = self.conversation(id) else { return }
                if let i = latest.runs?.firstIndex(where: { $0.id == requestID }) {
                    if Task.isCancelled { latest.runs?[i].state = .cancelled }
                    else if latest.runs?[i].state == .streaming { latest.runs?[i].state = .failed }
                }
                self.persist(latest, retainOnFailure: true)
                self.failures[id] = Task.isCancelled ? "대화 압축을 취소했습니다. 원본 대화는 보존됩니다." : error.localizedDescription
            }
        }
        return true
    }

}
