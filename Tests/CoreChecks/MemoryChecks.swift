import Foundation

private func memoryChat() -> MarginConversation {
    var chat = sampleConversation(for: Notebook(title: "memory fixture"))
    chat.migrateMemory()
    chat.messages = [.init(role: .user, text: "U1 prove the problem"), .init(role: .assistant, text: #"A1 Let \(a^{p-1}\equiv1\pmod p\)."#, status: .completed), .init(role: .user, text: "U2 explain the earlier formula")]
    return chat
}
private func jsonRequest(_ chat: MarginConversation) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONEncoder().encode(PlanRequest.build(chat: chat, model: "gpt-6-astra", projectInstructions: ""))) as! [String: Any]
}
private func textParts(_ json: [String: Any]) -> [String] {
    (json["input"] as! [[String: Any]]).flatMap { item -> [String] in
        if let text = item["content"] as? String { return [text] }
        return (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    }
}
private func images(_ json: [String: Any]) -> [String] {
    (json["input"] as! [[String: Any]]).flatMap { ($0["content"] as? [[String: Any]] ?? []).compactMap { $0["image_url"] as? String } }
}
private func longMemoryChat() -> MarginConversation {
    var chat = memoryChat(); chat.messages = []; chat.pinnedConditions = "로피탈 정리는 사용하지 않음"
    for i in 0..<10 {
        chat.messages.append(.init(role: .user, text: "question \(i)"))
        chat.messages.append(.init(role: .assistant, text: i == 0 ? #"Exact formula \(n^3 + 1\)."# : String(repeating: "Assistant suggested an approach that is not established. ", count: 80), status: .completed))
    }
    return chat
}
private let summaryJSON = #"{"approaches":["A possible approach"],"assistantClaims":["The assistant asserted a conclusion, not verified"],"rejectedApproaches":[],"openQuestions":["Need justification"],"uncertainties":["Transcription unverified"]}"#
private func installSummary(_ chat: inout MarginConversation) throws {
    let job = try CompressionJob.prepare(chat: chat)
    try chat.install(job.result(summaryJSON, model: "gpt-6-astra"))
}

let memoryChecks: [CoreCheck] = [
    CoreCheck(name: "Followup serializes assistant history as documented text message") { _ in
        let json = try jsonRequest(memoryChat())
        let inputs = json["input"] as! [[String: Any]]
        try expect(inputs[2]["role"] as? String == "assistant")
        try expect(inputs[2]["content"] as? String == memoryChat().messages[1].text,
                   "assistant content must not be an input_text block")
    },
    CoreCheck(name: "Memory missing original image must block actual serialization") { _ in
        let note = Notebook(title: "missing")
        var chat = MarginConversation(noteID: note.id, pageID: UUID(), projectID: nil, projectTitle: "", rect: .zero, imageData: Data(), extractedText: "", sourceDescription: "missing source")
        chat.draft = "preserve me"
        try expectThrows { _ = try jsonRequest(chat) }
        try expect(chat.draft == "preserve me")
    },
    CoreCheck(name: "Memory second serialized question includes readable original image and first answer exactly once") { _ in
        let chat = memoryChat(), json = try jsonRequest(chat)
        let text = textParts(json)
        try expect(text.count == 4 && Array(text.suffix(3)) == chat.messages.map(\.text))
        try expect(images(json) == ["data:image/png;base64," + chat.imageData.base64EncodedString()])
        try expect(chat.sourceAttachments[0].available)
        try expect(text.filter { $0 == chat.messages.last!.text }.count == 1)
        try expect(text.filter { $0 == chat.messages[1].text }.count == 1)
        try expect(Set(json.keys) == Set(["model", "instructions", "input", "store", "stream"]))
    },
    CoreCheck(name: "Memory solution attachment preserves occurrence provenance and independent problem scope") { _ in
        var chat = memoryChat()
        var turn = MarginMessage(role: .user, text: "my solution")
        let image = ConversationAttachment(data: chat.imageData, noteID: chat.noteID, pageID: UUID(), rect: CGRect(x: 1, y: 2, width: 30, height: 40), source: "solution page 3", text: "solution", revision: 2, introducedBy: turn.id)
        turn.attachmentIDs = [image.id]; chat.attachments = [image]; chat.messages.append(turn)
        let json = try jsonRequest(chat)
        try expect(images(json).count == 2, "same bytes deliberately attached twice keep two occurrences")
        try expect(textParts(json).last?.contains("solution page 3") == true)
        try expect(chat.attachments![0].introducedBy == turn.id)
        let other = memoryChat()
        try expect(!textParts(jsonRequest(other)).joined().contains("my solution"))
        var crossed = other; crossed.attachments = [image]; crossed.messages.append(turn)
        try expectThrows { _ = try jsonRequest(crossed) }
    },
    CoreCheck(name: "Memory short threads never activate summaries and stable source order encodes deterministically") { _ in
        var chat = memoryChat()
        let coverage = Array(chat.messages.prefix(2)).map(\.coverage)
        let summary = try JSONDecoder().decode(DiscussionSummary.self, from: Data(summaryJSON.utf8))
        try chat.install(.init(coverage: coverage, fingerprint: chat.fingerprint(coverage: coverage), summary: summary, model: "gpt-6-astra"))
        let a = try ContextBuilder.build(chat: chat, projectInstructions: ""), b = try ContextBuilder.build(chat: chat, projectInstructions: "")
        try expect(a.manifest == b.manifest && a.manifest.snapshotID == nil)
        let one = try PlanRequest.serialize(a, model: "gpt-6-astra", policy: chat.policy)
        let two = try PlanRequest.serialize(b, model: "gpt-6-astra", policy: chat.policy)
        try expect(one.manifest.payloadHash == two.manifest.payloadHash)
    },
    CoreCheck(name: "Memory old quoted exact LaTex restored outside compressed recent window") { _ in
        var chat = longMemoryChat(); try installSummary(&chat)
        let old = chat.messages[0 + 1], quote = #"\(n^3 + 1\)"#
        chat.messages.append(.init(role: .user, text: "Explain this exact expression", replyTo: .init(messageID: old.id, revision: old.sourceRevision, quote: quote)))
        let full = try ContextBuilder.assemble(chat: chat, projectInstructions: "", snapshot: nil)
        let compact = try ContextBuilder.assemble(chat: chat, projectInstructions: "", snapshot: chat.snapshots!.last!)
        var budget = chat.policy; budget.inputTokens = compact.manifest.estimatedTokens + budget.reserveTokens + 50; chat.contextBudget = budget
        try expect(full.manifest.estimatedTokens > budget.usable)
        print("METRIC synthetic long thread: full estimate \(full.manifest.estimatedTokens), compact estimate \(compact.manifest.estimatedTokens), original images \(compact.manifest.images.count)")
        let plan = try ContextBuilder.build(chat: chat, projectInstructions: "")
        let json = try jsonRequest(chat), text = textParts(json)
        try expect(plan.manifest.snapshotID != nil && !plan.manifest.omitted.isEmpty)
        try expect(text.filter { $0 == old.text }.count == 1 && text.last?.contains(quote) == true)
        try expect(plan.manifest.replies.first?.id == old.id && images(json).count == 1)
        try expect((json["instructions"] as! String).contains("로피탈 정리는 사용하지 않음"))
    },
    CoreCheck(name: "Memory exponent correction invalidates summary while original evidence remains") { _ in
        var chat = longMemoryChat(); try installSummary(&chat)
        let original = chat.messages, bytes = chat.imageData
        chat.correct(before: "n^3", after: "n^2", source: chat.messages[1].id)
        try expect(chat.snapshots!.allSatisfy { !chat.valid($0) })
        let json = try jsonRequest(chat)
        try expect(textParts(json).contains { $0.contains("현재 적용): n^2") })
        try expect(!textParts(json).contains { $0.contains("과거 대화 압축") })
        try expect(chat.messages == original && chat.imageData == bytes)
    },
    CoreCheck(name: "Memory screenshot remains mandatory with optional reviewed transcription") { _ in
        var chat = memoryChat(); chat.includeImage = false
        try expect(images(jsonRequest(chat)).count == 1, "old opt-out cannot remove evidence")
        chat.originalAttachment?.useApprovedText = true
        try expect(images(jsonRequest(chat)).count == 1, "missing approval cannot remove evidence")
        chat.originalAttachment?.approvedTranscription = "User reviewed full problem"
        try expect(images(jsonRequest(chat)).count == 1)
        try expect(textParts(jsonRequest(chat)).joined().contains("User reviewed full problem"))
        chat.messages.append(.init(role: .user, text: "빨간 선은 무슨 뜻이야?"))
        try expect(images(jsonRequest(chat)).count == 1)
    },
    CoreCheck(name: "Screenshot requests do not replace handwriting with extracted PDF text") { _ in
        let source = memoryChat()
        var chat = MarginConversation(noteID: source.noteID, pageID: source.pageID, projectID: nil, projectTitle: "", rect: source.rect, imageData: source.imageData, extractedText: "PDF_EXTRACTION_ONLY_SENTINEL", sourceDescription: "capture fixture")
        chat.messages = source.messages
        chat.migrateMemory()
        chat.mode = .check
        let request = try jsonRequest(chat)
        try expect(images(request).count == 1)
        try expect(!textParts(request).joined().contains("PDF_EXTRACTION_ONLY_SENTINEL"))
        try expect(textParts(request).joined().contains("스크린샷"))
    },
    CoreCheck(name: "Memory cold restore maintains source bytes links corrections conditions and interrupts runs") { repository in
        var chat = memoryChat(); chat.pinnedConditions = "로피탈 정리는 사용하지 않음"
        let plan = try ContextBuilder.build(chat: chat, projectInstructions: "")
        let frozen = try PlanRequest.serialize(plan, model: "gpt-6-astra", policy: chat.policy).manifest
        let assistant = MarginMessage(role: .assistant, text: "partial", status: .streaming)
        chat.messages.append(assistant); chat.draft = "unsent draft"
        chat.runs = [.init(id: UUID(), kind: .answer, manifest: frozen, model: "gpt-6-astra", authGeneration: UUID(), responseMessageID: assistant.id)]
        let disk = MarginChatRepository(root: repository.root.appendingPathComponent("memory"))
        try disk.save(chat)
        var reopened = try disk.load(noteID: chat.noteID)[0]; reopened.recoverMemoryRuns()
        try expect(reopened.messages.last?.status == .interrupted && reopened.runs!.last!.state == .interrupted)
        try expect(reopened.draft == "unsent draft" && reopened.imageData == chat.imageData)
        try expect(reopened.runs!.first!.manifest == frozen)
        let json = try jsonRequest(reopened)
        try expect(images(json).count == 1 && textParts(json).last?.contains("불완전") == true)
        try expect((json["instructions"] as! String).contains("로피탈 정리는 사용하지 않음"))
    },
    CoreCheck(name: "Memory compression malformed cancelled or stale results cannot modify originals") { _ in
        var chat = longMemoryChat(), original = chat
        let job = try CompressionJob.prepare(chat: chat)
        try expectThrows { _ = try job.result("not JSON", model: "gpt-6-astra") }
        try expect(chat == original, "no mutation before completed result")
        chat.messages[1].text += "edited"; chat.messages[1].revision = 2
        try expectThrows { try chat.install(job.result(summaryJSON, model: "gpt-6-astra")) }
        original = chat
        chat.messages.remove(at: 2)
        try expectThrows { try chat.install(job.result(summaryJSON, model: "gpt-6-astra")) }
        try expect(chat.snapshots == nil && chat.imageData == original.imageData)
    },
    CoreCheck(name: "Memory corrected conditions or image policy reject concurrent compression result") { _ in
        var chat = longMemoryChat()
        let job = try CompressionJob.prepare(chat: chat)
        chat.correct(before: "n^3", after: "n^2")
        try expectThrows { try chat.install(job.result(summaryJSON, model: "gpt-6-astra")) }
        chat = longMemoryChat(); let job2 = try CompressionJob.prepare(chat: chat)
        chat.pinnedConditions = "no calculus"
        try expectThrows { try chat.install(job2.result(summaryJSON, model: "gpt-6-astra")) }
    },
    CoreCheck(name: "Memory protected minimum and HTTP overflow are explicit and preserve draft") { _ in
        var chat = memoryChat(); chat.draft = "unsent"
        var policy = chat.policy; policy.inputTokens = 4001; chat.contextBudget = policy
        try expectThrows { _ = try jsonRequest(chat) }
        policy.inputTokens = 24000; policy.maxHTTPBytes = 20; chat.contextBudget = policy
        try expectThrows { _ = try jsonRequest(chat) }
        try expect(chat.draft == "unsent")
    },
    CoreCheck(name: "Memory legacy migration additive and redacted manifests never contain private text or bytes") { repository in
        let legacy = sampleConversation(for: Notebook(title: "private-title"))
        let bytes = try JSONEncoder().encode(legacy)
        var chat = try JSONDecoder().decode(MarginConversation.self, from: bytes); chat.migrateMemory()
        try expect(chat.imageData == legacy.imageData && chat.messages == legacy.messages && chat.id == legacy.id)
        chat.messages = [.init(role: .user, text: "private question fixture")]
        let manifest = try ContextBuilder.build(chat: chat, projectInstructions: "private project").manifest.redactedJSON
        for forbidden in ["private question fixture", "private project", legacy.imageData.base64EncodedString(), "access_token", "cookie", "encrypted_content"] { try expect(!manifest.contains(forbidden)) }
    },
    CoreCheck(name: "Memory malformed quote or missing solution reference blocks request") { _ in
        var chat = memoryChat()
        chat.messages[2].replyTo = .init(messageID: chat.messages[1].id, revision: 99, quote: "made up")
        try expectThrows { _ = try jsonRequest(chat) }
        chat = memoryChat(); chat.messages[2].attachmentIDs = [UUID()]
        try expectThrows { _ = try jsonRequest(chat) }
    },
    CoreCheck(name: "Memory derived snapshot remains valid for appended turns but not source edits") { _ in
        var chat = longMemoryChat(); try installSummary(&chat)
        let snapshot = chat.snapshots![0]
        chat.messages.append(.init(role: .user, text: "one more"))
        try expect(chat.valid(snapshot))
        chat.messages[0].text = "changed problem"
        try expect(!chat.valid(snapshot))
    }
]
