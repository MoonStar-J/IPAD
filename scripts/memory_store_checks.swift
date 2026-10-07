// Included only in the isolated simulator integration app, never in the shipping target.
private final class MemoryFixtureVault: PlanVault {
    var state = PlanVaultState()
    func read() throws -> PlanVaultState { state }
    func write(_ value: PlanVaultState) throws { state = value }
}
private final class MemoryFixtureProtocol: URLProtocol {
    static var bodies: [Data] = []
    static var answer = #"A1 exact \(n^3 + 1\)."#
    static var hold = false
    static var completionDelay: TimeInterval = 0
    private var completion: DispatchWorkItem?
    static var status = 200
    static var invalidBodies = 0
    static var errorCode = "fixture_failure"
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/v1/models" {
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"models":[{"slug":"gpt-6-astra","display_name":"Fixture","visibility":"list"}]}"#.utf8))
            client?.urlProtocolDidFinishLoading(self); return
        }
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }; stream.close()
        }
        Self.bodies.append(data)
        let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let inputs = object?["input"] as? [[String: Any]] ?? []
        if inputs.contains(where: { $0["role"] as? String == "assistant" && !($0["content"] is String) }) {
            Self.invalidBodies += 1
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 400, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"error":{"code":"invalid_value","param":"input[2].content[0]"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self); return
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        if Self.status != 200 { client?.urlProtocol(self, didLoad: try! JSONSerialization.data(withJSONObject: ["error": ["code": Self.errorCode]])); client?.urlProtocolDidFinishLoading(self); return }
        let delta = try! JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": Self.answer])
        client?.urlProtocol(self, didLoad: Data("data: ".utf8) + delta + Data("\n\n".utf8))
        if Self.hold { return }
        let final = try! JSONSerialization.data(withJSONObject: ["type": "response.completed", "response": ["output": [["type": "message", "content": [["type": "output_text", "text": Self.answer]]]], "usage": ["input_tokens": 120, "output_tokens": 30, "input_tokens_details": ["cached_tokens": 0]]]])
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.client?.urlProtocol(self, didLoad: Data("data: ".utf8) + final + Data("\n\n".utf8))
            self.client?.urlProtocolDidFinishLoading(self)
        }
        completion = work
        if Self.completionDelay > 0 { DispatchQueue.main.asyncAfter(deadline: .now() + Self.completionDelay, execute: work) }
        else { work.perform() }
    }
    override func stopLoading() { completion?.cancel(); completion = nil }
}
@MainActor private func checkMemoryStore() async throws -> Int {
    var count = 0
    func check(_ value: Bool, _ reason: String) throws {
        try PDFIntegrationChecks.check(value, "memory: " + reason); count += 1
    }
    let vault = MemoryFixtureVault()
    vault.state.selected = "memory-fixture"
    vault.state.registrations = [.init(id: "memory-fixture", identity: .init(subject: "fixture-user", email: nil), tokens: .init(access_token: "fixture-only-never-live", token_type: "Bearer", expires_in: 3600, scope: "chatgpt.tokens.use.direct"), receivedAt: Date())]
    let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [MemoryFixtureProtocol.self]
    let http = PlanHTTP(session: URLSession(configuration: config))
    let connection = ChatGPTPlanConnection(vault: vault, http: http); await connection.refreshModels()
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let repository = MarginChatRepository(root: root)
    let ai = MarginAIStore(repository: repository, connection: connection, http: http)
    let note = Notebook(title: "memory fixture")
    let points = [CGPoint(x: 20, y: 40), CGPoint(x: 75, y: 40)].enumerated().map { index, point in
        PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    let ink = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))])
    var captured: Result<CapturedRegion, Error>!
    UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
        captured = Result { try RegionContextService.capture(note: note, page: note.pages[0], drawing: ink, store: NoteStore(), rect: CGRect(x: 10, y: 10, width: 80, height: 80)) }
    }
    let capture = try captured.get(), image = capture.imageData
    let id = ai.create(note: note, project: nil, region: capture)!
    func finish(_ target: UUID? = nil) async throws {
        for _ in 0..<300 { if !ai.sending.contains(target ?? id) { return }; try await Task.sleep(for: .milliseconds(10)) }
        throw NSError(domain: "memory request timed out", code: 1)
    }
    func decoded(_ index: Int) throws -> [String: Any] { try JSONSerialization.jsonObject(with: MemoryFixtureProtocol.bodies[index]) as! [String: Any] }
    func inputText(_ object: [String: Any]) -> [String] { (object["input"] as! [[String: Any]]).flatMap { item -> [String] in
        if let text = item["content"] as? String { return [text] }
        return (item["content"] as? [[String: Any]] ?? []).compactMap { $0["text"] as? String }
    } }
    func imageCount(_ object: [String: Any]) -> Int { (object["input"] as! [[String: Any]]).flatMap { $0["content"] as? [[String: Any]] ?? [] }.filter { $0["type"] as? String == "input_image" }.count }
    MemoryFixtureProtocol.bodies = []
    ai.setDraft("U1", for: id)
    let previewManifest = try ai.previewContext(id, project: nil, model: connection.model).1
    try check(ai.sendPlan("U1", conversationID: id, project: nil), "first send accepted")
    try check((try repository.load(noteID: note.id)).first?.messages.first?.text == "U1", "source and run saved before network starts")
    try await finish()
    try check(ai.conversation(id)!.runs!.last!.manifest == previewManifest, "preview manifest equals persisted actual request manifest")
    let firstBody = try decoded(0)
    let firstInput = firstBody["input"] as! [[String: Any]]
    let sentURL = firstInput.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["image_url"] as? String }.first!
    let sentBytes = Data(base64Encoded: String(sentURL.split(separator: ",", maxSplits: 1)[1]))!
    try check(sentBytes == capture.imageData, "actual HTTP body embeds the exact captured PNG, not a path or PDF text")
    let cg = UIImage(data: sentBytes)!.cgImage!.cropping(to: CGRect(x: 80, y: 60, width: 1, height: 1))!
    var rgba = [UInt8](repeating: 0, count: 4)
    rgba.withUnsafeMutableBytes { buffer in
        let context = CGContext(data: buffer.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(cg, in: CGRect(x: 0, y: 0, width: 1, height: 1))
    }
    try check(rgba.prefix(3).allSatisfy { $0 < 80 }, "HTTP screenshot contains visible black handwriting captured in dark mode")
    let answer = ai.conversation(id)!.messages.last!
    ai.setReply(.init(messageID: answer.id, revision: answer.sourceRevision, quote: #"\(n^3 + 1\)"#), for: id)
    MemoryFixtureProtocol.answer = "Earlier expression needs justification. This is only an assistant claim."
    try check(ai.sendPlan("U2", conversationID: id, project: nil), "followup accepted")
    try await finish()
    let second = try decoded(1), text = inputText(second)
    try check(MemoryFixtureProtocol.bodies.count == 2, "two ordinary questions, exactly two requests and no auxiliary calls")
    try check(imageCount(second) == 1 && text.contains("U1") && text.filter { $0 == answer.text }.count == 1, "final wire replays first image and answer once")
    try check(text.filter { $0.contains("[이번 질문]\nU2") }.count == 1, "current question once with exact quote")
    try check(ai.addCapture(capture, to: id, note: note), "same problem solution capture persisted")
    try check(ai.sendPlan("U3", conversationID: id, project: nil), "solution followup accepted")
    try await finish()
    try check(imageCount(decoded(2)) == 2, "wire includes both image occurrences")
    let stored = ai.conversation(id)!
    let restored = MarginAIStore(repository: repository, connection: connection, http: http); restored.load(noteID: note.id)
    try check(restored.conversation(id) == stored, "new store cold loads exact original thread")
    try check(MemoryFixtureProtocol.bodies.count == 3, "restart never sends automatically")
    try check(stored.runs?.last?.reportedInputTokens == 120 && stored.runs?.last?.reportedCachedTokens == 0, "only reported metrics saved")
    let lastManifest = stored.runs!.last!.manifest
    try check(!lastManifest.redactedJSON.contains("fixture-only-never-live") && !lastManifest.redactedJSON.contains(image.base64EncodedString()), "safe manifest excludes token/image bytes")
    // Freeze a pending request, then cancel. Further source edits must not rewrite its manifest.
    MemoryFixtureProtocol.hold = true
    try check(ai.sendPlan("cancel me", conversationID: id, project: nil), "held request starts")
    for _ in 0..<100 { if MemoryFixtureProtocol.bodies.count == 4 { break }; try await Task.sleep(for: .milliseconds(10)) }
    ai.cancel(id); try await finish(); MemoryFixtureProtocol.hold = false
    try check(ai.conversation(id)?.messages.last?.status == .cancelled, "cancelled distinct from complete")
    let frozen = ai.conversation(id)!.runs!.last!.manifest
    ai.correct(id, before: "n^3", after: "n^2")
    try check(ai.conversation(id)!.runs!.last!.manifest == frozen, "past manifest immutable after correction")
    // Explicit compression failure cannot replace messages or draft.
    ai.setDraft("draft stays", for: id); ai.flushDraft(id)
    MemoryFixtureProtocol.answer = "malformed summary"
    let originals = ai.conversation(id)!.messages
    try check(ai.compress(id, project: nil), "manual compression invokes existing inference path")
    try await finish()
    try check(ai.conversation(id)!.messages == originals && ai.conversation(id)!.snapshots == nil && ai.conversation(id)!.draft == "draft stays", "malformed summary keeps source and draft")
    try check(MemoryFixtureProtocol.bodies.count == 5, "compression one request, no repair or retry")
    // Missing evidence prevents transmission and preserves the draft.
    let brokenNote = Notebook(title: "missing image")
    let brokenRegion = CapturedRegion(pageID: brokenNote.pages[0].id, rect: .zero, imageData: Data(), extractedText: "", sourceDescription: "missing", pdfPageNumbers: [])
    let broken = ai.create(note: brokenNote, project: nil, region: brokenRegion)!
    ai.setDraft("retain broken question", for: broken)
    try check(!ai.sendPlan("retain broken question", conversationID: broken, project: nil) && ai.conversation(broken)?.draft == "retain broken question", "missing image blocks and keeps draft")
    try check(MemoryFixtureProtocol.bodies.count == 5, "validation failure sends zero requests")
    MemoryFixtureProtocol.answer = #"{"approaches":["Earlier attempt"],"assistantClaims":["Unverified claim"],"rejectedApproaches":[],"openQuestions":["Verify the exponent"],"uncertainties":["Needs review"]}"#
    try check(ai.compress(id, project: nil), "valid manual compression starts")
    try await finish()
    try check(ai.conversation(id)!.snapshots?.count == 1 && ai.conversation(id)!.messages == originals, "valid compression adds derived record only")
    let snapshot = ai.conversation(id)!.snapshots![0]
    ai.correct(id, before: "n^2", after: "n squared, n positive")
    try check(!ai.conversation(id)!.valid(snapshot), "store correction invalidates successful snapshot")
    MemoryFixtureProtocol.hold = true
    try check(ai.compress(id, project: nil), "cancellable compression starts")
    for _ in 0..<100 { if MemoryFixtureProtocol.bodies.count == 7 { break }; try await Task.sleep(for: .milliseconds(10)) }
    ai.cancel(id); try await finish(); MemoryFixtureProtocol.hold = false
    try check(ai.conversation(id)!.runs!.last!.state == .cancelled && ai.conversation(id)!.messages == originals && ai.conversation(id)!.snapshots?.count == 1, "compression cancellation preserves source and previous snapshot")
    // Lightweight ordinary conversation: no quote, attachment changes or memory UI required.
    let lightNote = Notebook(title: "separate light conversation")
    let lightCapture = CapturedRegion(pageID: lightNote.pages[0].id, rect: capture.rect, imageData: image, extractedText: "light source", sourceDescription: "light problem", pdfPageNumbers: [1])
    let light = ai.create(note: lightNote, project: nil, region: lightCapture)!
    let start = MemoryFixtureProtocol.bodies.count
    for turn in 1...3 {
        MemoryFixtureProtocol.answer = "Light answer \(turn)"
        try check(ai.sendPlan("Light question \(turn)", conversationID: light, project: nil), "light turn \(turn) accepted")
        try await finish(light)
        try check(ai.conversation(light)?.messages.last?.status == .completed, "light turn \(turn) completed through strict HTTP mock")
        let wire = try decoded(start + turn - 1), contents = inputText(wire)
        let expected = (1...turn).flatMap { n in n == turn ? ["Light question \(n)"] : ["Light question \(n)", "Light answer \(n)"] }
        try check(Array(contents.dropFirst()) == expected && imageCount(wire) == 1, "light turn \(turn): exact chronological history and one readable original image")
        try check(!contents.contains("U1") && !contents.contains(answer.text), "new conversation excludes old thread")
    }
    try check(MemoryFixtureProtocol.bodies.count == start + 3 && MemoryFixtureProtocol.invalidBodies == 0, "three questions use three valid answer requests only")
    // Provider-side context errors also keep the typed question, not only local validation errors.
    MemoryFixtureProtocol.status = 400; MemoryFixtureProtocol.errorCode = "context_length_exceeded"
    ai.setDraft("limit question", for: light)
    try check(ai.sendPlan("limit question", conversationID: light, project: nil), "provider limit request starts")
    try await finish(light)
    try check(ai.conversation(light)?.draft == "limit question" && ai.conversation(light)?.messages.last?.status == .failed, "provider input limit preserves draft and conversation")
    try check(ai.sendPlan("limit question", conversationID: light, project: nil), "second explicit rejected attempt starts")
    try await finish(light)
    MemoryFixtureProtocol.status = 200; MemoryFixtureProtocol.answer = "Retry answer"
    let retryPreview = try ai.previewContext(light, project: nil, model: connection.model).1
    try check(ai.sendPlan("limit question", conversationID: light, project: nil), "explicit rejected-question retry starts")
    try await finish(light)
    try check(inputText(decoded(MemoryFixtureProtocol.bodies.count - 1)).filter { $0 == "limit question" }.count == 1, "explicit retry reuses rejected question once")
    try check(ai.conversation(light)?.messages.last?.status == .completed, "explicit retry completes")
    try check(ai.conversation(light)?.runs?.last?.manifest == retryPreview, "repeated retry and preview both reuse saved question")
    // Exercise the real SwiftUI panel disappearing, not just two store calls.
    let scene = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first!
    let window = UIWindow(windowScene: scene)
    let host = UIHostingController(rootView: AnyView(EmptyView()))
    window.rootViewController = host; window.isHidden = false
    defer { window.isHidden = true; window.rootViewController = nil; MemoryFixtureProtocol.completionDelay = 0 }
    var appeared = false, disappeared = false
    host.rootView = AnyView(ChatGPTMarginView(conversationID: light, project: nil, ai: ai, connection: connection)
        .onAppear { appeared = true }.onDisappear { disappeared = true }.id(light))
    for _ in 0..<100 { if appeared { break }; try await Task.sleep(for: .milliseconds(10)) }
    try check(appeared, "real question panel mounted")
    let beforeSwitch = MemoryFixtureProtocol.bodies.count
    MemoryFixtureProtocol.completionDelay = 0.6
    MemoryFixtureProtocol.answer = "Answer A survives switching panels."
    try check(ai.sendPlan("Continue A", conversationID: light, project: nil), "A starts before panel switch")
    for _ in 0..<100 { if ai.conversation(light)?.messages.last?.text.isEmpty == false { break }; try await Task.sleep(for: .milliseconds(10)) }
    try check(ai.conversation(light)?.messages.last?.status == .streaming, "A is receiving text at switch")
    host.rootView = AnyView(ChatGPTMarginView(conversationID: id, project: nil, ai: ai, connection: connection).id(id))
    for _ in 0..<100 { if disappeared { break }; try await Task.sleep(for: .milliseconds(10)) }
    try check(disappeared, "A panel actually disappeared")
    MemoryFixtureProtocol.answer = "Independent answer B."
    try check(ai.sendPlan("Continue B", conversationID: id, project: nil), "B sends while A completes")
    try await finish(light); try await finish(id)
    try check(ai.conversation(light)?.messages.last?.status == .completed && ai.conversation(light)?.messages.last?.text == "Answer A survives switching panels.", "switching panels retains A through completion")
    try check(ai.conversation(id)?.messages.last?.status == .completed && ai.conversation(id)?.messages.last?.text == "Independent answer B.", "B completes in its own conversation")
    try check(MemoryFixtureProtocol.bodies.count == beforeSwitch + 2, "switching does not resend or add requests")
    let reloaded = MarginAIStore(repository: repository, connection: connection, http: http)
    reloaded.load(noteID: lightNote.id); reloaded.load(noteID: note.id)
    try check(reloaded.conversation(light) == ai.conversation(light) && reloaded.conversation(id) == ai.conversation(id), "both completed responses survive reopening storage")
    // Closing the only panel and choosing a future model also keeps the accepted request.
    MemoryFixtureProtocol.answer = "Finished with the original request model."
    let requestModel = connection.model
    try check(ai.sendPlan("Finish even when closed", conversationID: id, project: nil), "request starts before closing panel")
    for _ in 0..<100 { if ai.conversation(id)?.messages.last?.text == MemoryFixtureProtocol.answer { break }; try await Task.sleep(for: .milliseconds(10)) }
    host.rootView = AnyView(EmptyView())
    connection.model = "future-model-selection"
    try await finish(id)
    try check(ai.conversation(id)?.messages.last?.status == .completed && ai.conversation(id)?.messages.last?.model == requestModel, "closed panel finishes using its captured model")
    connection.model = requestModel
    let example = stored.runs![1].manifest
    let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    try Data(example.redactedJSON.utf8).write(to: documents.appendingPathComponent("memory-manifest-fixture.json"), options: .atomic)
    return count
}

// Persistence regression fixtures. These exercise the production store and its
// actual files; they do not measure Apple Pencil latency or touch prediction.
@MainActor func checkInkSavingPerformance(_ store: NoteStore) async throws -> Int {
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        try PDFIntegrationChecks.check(try condition(), "ink persistence: " + message)
        count += 1
    }
    func waitFor(_ condition: () throws -> Bool, _ message: String) async throws {
        for _ in 0..<250 {
            if try condition() { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        try check(false, "timed out: " + message)
    }
    func ink(_ y: CGFloat, lines: Int = 1) -> PKDrawing {
        PKDrawing(strokes: (0..<lines).map { line in
            let points = (0..<12).map { index in
                PKStrokePoint(location: CGPoint(x: 30 + CGFloat(index) * 12, y: y + CGFloat(line) * 18),
                              timeOffset: Double(index) * 0.01, size: CGSize(width: 2, height: 2),
                              opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            return PKStroke(ink: PKInk(.pen, color: .black),
                            path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 100)))
        })
    }
    func sameInk(_ lhs: PKDrawing, _ rhs: PKDrawing) -> Bool {
        lhs.strokes.count == rhs.strokes.count && zip(lhs.strokes, rhs.strokes).allSatisfy { a, b in
            a.transform == b.transform && a.ink.inkType == b.ink.inkType && a.ink.color == b.ink.color &&
            a.path.count == b.path.count && (0..<a.path.count).allSatisfy {
                a.path[$0].location == b.path[$0].location && a.path[$0].size == b.path[$0].size &&
                a.path[$0].force == b.path[$0].force && a.path[$0].opacity == b.path[$0].opacity
            }
        }
    }
    try check(Bundle.main.bundleIdentifier == "com.notemargin.integrationcheck", "only disposable simulator app may alter fixture files")
    try check(store.flushDrawings(), "existing fixture edits flushed before test")
    guard let noteID = store.createNote(title: "Ink save fixture", paper: .plain, cover: .blue, folderID: nil),
          let pageID = store.note(noteID)?.pages.first?.id,
          let file = store.assetURL(noteID: noteID, name: "\(pageID).drawing") else {
        throw NSError(domain: "ink persistence: fixture creation", code: 1)
    }
    let previousError = store.errorMessage
    defer {
        store.endDrawingInteraction(noteID: noteID, pageID: pageID)
        if store.flushDrawings() { store.trash(noteID); store.permanentlyDelete(noteID) }
        store.errorMessage = previousError
    }
    let seed = ink(90), first = ink(150), latest = ink(210, lines: 2)
    func queued(_ value: PKDrawing) { store.queueDrawing(value, noteID: noteID, pageID: pageID) }
    func diskInk() throws -> PKDrawing { try PKDrawing(data: Data(contentsOf: file)) }
    queued(seed)
    try check(store.flushDrawings(), "initial persisted stroke")
    let initialBytes = try Data(contentsOf: file)

    // Even a long contact cannot kick off the idle writer. The newest in-memory
    // revision remains available to capture/export consumers without serializing.
    store.beginDrawingInteraction(noteID: noteID, pageID: pageID)
    queued(first)
    try await Task.sleep(for: .milliseconds(950))
    try check(try Data(contentsOf: file) == initialBytes, "active tool leaves saved file unchanged past debounce")
    try check(sameInk(try store.drawing(noteID: noteID, pageID: pageID), first), "active drawing returns pending snapshot")
    queued(latest)
    try await Task.sleep(for: .milliseconds(800))
    try check(try Data(contentsOf: file) == initialBytes, "later pressure revision also stays off the write path during contact")
    try check(store.hasUnsavedChanges && sameInk(try store.drawing(noteID: noteID, pageID: pageID), latest), "latest pending revision and dirty state retained")
    store.endDrawingInteraction(noteID: noteID, pageID: pageID)
    try await waitFor({ !store.hasUnsavedChanges }, "idle save after tool ends")
    try check(sameInk(try diskInk(), latest), "tool end automatically persists latest revision")
    try check(sameInk(try NoteStore().drawing(noteID: noteID, pageID: pageID), latest), "idle save survives reopening")

    // New edits across the autosave deadline must win over any older callback.
    // Multiple offsets cover both before and after the background task is queued;
    // no assertion relies on a particular disk speed or completion ordering.
    for delay in [680, 705, 740] {
        queued(first)
        try await Task.sleep(for: .milliseconds(delay))
        queued(latest)
        try check(store.flushDrawings(), "new revision flush succeeds at autosave boundary \(delay)")
        try await Task.sleep(for: .milliseconds(80))
        try check(!store.hasUnsavedChanges && sameInk(try diskInk(), latest), "old completion does not restore/clear newer revision \(delay)")
        try check(sameInk(try NoteStore().drawing(noteID: noteID, pageID: pageID), latest), "latest revision restored after boundary flush \(delay)")
    }

    for delay in [680, 705, 740] {
        queued(ink(CGFloat(delay)))
        try await Task.sleep(for: .milliseconds(delay))
        let title = "Renamed during autosave \(delay)"
        try check(store.updateNote(noteID) { $0.title = title }, "rename accepted near autosave \(delay)")
        try await waitFor({ !store.hasUnsavedChanges }, "save with metadata edit")
        try check(store.note(noteID)?.title == title && NoteStore().note(noteID)?.title == title, "background snapshot cannot revert renamed title \(delay)")
    }

    // Force an atomic-file write error in this newly created fixture only. The
    // prior drawing is backed up and restored even when an assertion fails.
    store.beginDrawingInteraction(noteID: noteID, pageID: pageID)
    let backup = file.appendingPathExtension("fixture-backup")
    let originalBytes = try Data(contentsOf: file)
    try FileManager.default.moveItem(at: file, to: backup)
    var restored = false
    defer {
        if !restored {
            store.beginDrawingInteraction(noteID: noteID, pageID: pageID)
            _ = store.flushDrawings() // Join any old worker before repairing its path.
            try? FileManager.default.removeItem(at: file)
            try? FileManager.default.moveItem(at: backup, to: file)
            _ = store.flushDrawings()
            store.endDrawingInteraction(noteID: noteID, pageID: pageID)
        }
    }
    try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
    let retryInk = ink(400, lines: 3)
    store.errorMessage = nil
    queued(retryInk)
    store.endDrawingInteraction(noteID: noteID, pageID: pageID)
    try await waitFor({ store.errorMessage != nil }, "background error surfaced")
    try check(store.hasUnsavedChanges && sameInk(try store.drawing(noteID: noteID, pageID: pageID), retryInk), "failed autosave preserves pending original and dirty state")
    try check(try Data(contentsOf: backup) == originalBytes, "write failure leaves prior original intact")
    try check(!store.flushDrawings(), "synchronous flush reports the same blocked destination")
    try check(sameInk(try store.drawing(noteID: noteID, pageID: pageID), retryInk), "failed synchronous flush also retains latest snapshot")
    try FileManager.default.removeItem(at: file)
    try FileManager.default.moveItem(at: backup, to: file)
    restored = true
    try check(store.flushDrawings(), "explicit retry saves retained ink after path is repaired")
    try check(!store.hasUnsavedChanges && sameInk(try NoteStore().drawing(noteID: noteID, pageID: pageID), retryInk), "retry persists original pending strokes through reopen")
    return count
}
