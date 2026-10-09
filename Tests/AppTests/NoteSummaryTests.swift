import XCTest
import PencilKit
import PDFKit
@testable import NoteMargin

@MainActor final class NoteSummaryTests: XCTestCase {
    private var root: URL!
    private var store: NoteStore!
    private var http: PlanHTTP!
    private var connection: ChatGPTPlanConnection!
    private var service: NoteSummaryService!
    override func setUp() async throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        store = try NoteStore(repository: LibraryRepository(root: root))
        SummaryProtocol.bodies = []; SummaryProtocol.failAt = nil; SummaryProtocol.hold = false; SummaryProtocol.onResponse = nil; SummaryProtocol.verboseImages = false
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [SummaryProtocol.self]
        http = PlanHTTP(session: URLSession(configuration: config))
        let vault = SummaryVault()
        connection = ChatGPTPlanConnection(vault: vault, http: http)
        await connection.refreshModels()
        service = NoteSummaryService(store: store, connection: connection, http: http)
    }
    override func tearDown() async throws {
        service.cancel(); http.session.invalidateAndCancel()
        try? FileManager.default.removeItem(at: root)
    }
    private func note(_ labels: [String] = ["definition"]) throws -> UUID {
        let id = try XCTUnwrap(store.createNote(title: "원본", paper: .plain, cover: .blue, folderID: nil))
        XCTAssertTrue(store.updateNote(id) { $0.pages = labels.map { NotePage(width: 400, height: 400, elements: [PageElement(kind: .text, text: $0, x: 30, y: 30, width: 300, height: 100)]) } })
        return id
    }
    private func finish() async throws {
        for _ in 0..<1000 {
            if !service.busy { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("summary did not finish"); service.cancel()
    }
    private func awaitRequest(_ count: Int) async throws {
        for _ in 0..<500 {
            if SummaryProtocol.bodies.count >= count { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("request not sent")
    }
    func testSmallSelectionUsesOneRequestAndFrozenSources() async throws {
        let id = try note(["SELECTED-A", "NOT-SELECTED", "SELECTED-C"])
        let source = store.note(id)!, choices = NoteSummaryService.pageChoices(source)
        let result = try XCTUnwrap(service.start(sourceID: id, title: "학습 요약", choices: [choices[0].id, choices[2].id], region: nil))
        XCTAssertNil(service.start(sourceID: id, title: "duplicate", choices: nil, region: nil))
        store.updatePage(noteID: id, pageID: source.pages[0].id) { $0.elements[0].text = "CHANGED-AFTER-START" }
        try await finish()
        XCTAssertEqual(store.note(result)?.summary?.state, .completed, service.failure ?? "")
        XCTAssertEqual(SummaryProtocol.bodies.count, 1)
        let body = String(data: SummaryProtocol.bodies[0], encoding: .utf8)!
        XCTAssertTrue(body.contains("SELECTED-A")); XCTAssertTrue(body.contains("SELECTED-C"))
        XCTAssertFalse(body.contains("NOT-SELECTED")); XCTAssertFalse(body.contains("CHANGED-AFTER-START"))
        XCTAssertFalse(body.contains("과거 대화")); XCTAssertFalse(body.contains("TutorMode"))
        let work = try store.summaryWork(result)
        XCTAssertEqual(work.sources.map(\.pageID), [source.pages[0].id, source.pages[2].id])
        XCTAssertTrue(work.inputs.allSatisfy { $0.imageBytes > 0 })
        XCTAssertEqual(store.library.notebooks.count, 2)
    }
    func testProjectReuseHomeAndLifecyclePreserveMarkdown() throws {
        let parent = try XCTUnwrap(store.createProject(title: "미적분학"))
        let userProject = try XCTUnwrap(store.createProject(title: "요약", parentID: parent))
        let sourceID = try note()
        store.assignProject(noteID: sourceID, projectID: parent)
        let source = store.note(sourceID)!, sources = try NoteSummaryService.sources(note: source, choices: nil, region: nil, store: store)
        let first = try store.createSummary(source: source, sources: sources, title: source.title, model: connection.model, account: connection.selected!)
        let second = try store.createSummary(source: source, sources: sources, title: source.title, model: connection.model, account: connection.selected!)
        let destination = try XCTUnwrap(store.note(first)?.projectID)
        XCTAssertNotEqual(destination, userProject); XCTAssertEqual(store.note(second)?.projectID, destination)
        XCTAssertEqual(store.project(destination)?.parentID, parent)
        var work = try store.summaryWork(first); work.final = "# 정의\n\n\\(a^2\\) [S1]"
        try store.saveSummary(first, work: work, state: .completed)
        store.updateNote(first) { $0.title = "이름 변경" }
        let copy = try XCTUnwrap(store.duplicate(first))
        store.move(.note(copy), to: nil); store.trash(copy); store.restore(copy)
        store.trash(sourceID); XCTAssertTrue(store.permanentlyDelete(sourceID))
        let reopened = try NoteStore(repository: LibraryRepository(root: root))
        XCTAssertEqual(String(data: try reopened.summaryAsset(copy, name: "summary.md"), encoding: .utf8), work.final)
        let url = try ExportService.exportPDF(note: reopened.note(copy)!, store: reopened)
        XCTAssertEqual(url.pathExtension, "md")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), work.final)
        let loose = try note()
        let home = try store.createSummary(source: store.note(loose)!, sources: sources, title: "home", model: connection.model, account: connection.selected!)
        let homeProject = try XCTUnwrap(store.note(home)?.projectID)
        XCTAssertNil(store.project(homeProject)?.parentID)
        store.assignProject(noteID: loose, projectID: destination)
        let nested = try store.createSummary(source: store.note(loose)!, sources: sources, title: "same", model: connection.model, account: connection.selected!)
        XCTAssertEqual(store.note(nested)?.projectID, destination)
    }
    func testCompositeCaptureIncludesPDFInkTextAndImage() async throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 400, height: 400))
        let pdf = renderer.pdfData { output in
            output.beginPage()
            UIColor.blue.setFill(); output.cgContext.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
            ("PDF definition" as NSString).draw(at: CGPoint(x: 120, y: 40), withAttributes: [.font: UIFont.systemFont(ofSize: 18)])
        }
        let prepared = try XCTUnwrap(store.preparePDF(data: pdf, title: "합성", folderID: nil))
        let id = try XCTUnwrap(store.importPDF(prepared, layout: .paged))
        let pageID = store.note(id)!.pages[0].id
        let image = UIGraphicsImageRenderer(size: CGSize(width: 40, height: 40)).image { output in
            UIColor.red.setFill(); output.fill(CGRect(x: 0, y: 0, width: 40, height: 40))
        }
        try LibraryRepository(root: root).writeAsset(image.pngData()!, noteID: id, name: "inserted.png")
        store.updatePage(noteID: id, pageID: pageID) { page in
            page.elements = [PageElement(kind: .text, text: "Inserted definition", x: 80, y: 300, width: 500, height: 80),
                             PageElement(kind: .image, assetName: "inserted.png", x: 500, y: 500, width: 80, height: 80)]
        }
        let points = [CGPoint(x: 80, y: 430), CGPoint(x: 280, y: 430), CGPoint(x: 280, y: 530), CGPoint(x: 80, y: 530), CGPoint(x: 80, y: 430)]
        let stroke = PKStroke(ink: PKInk(.pen, color: .green), path: PKStrokePath(controlPoints: points.enumerated().map { i, point in
            PKStrokePoint(location: point, timeOffset: Double(i)*0.1, size: CGSize(width: 8, height: 8), opacity: 1, force: 1, azimuth: 0, altitude: .pi/2)
        }, creationDate: Date()))
        store.queueDrawing(PKDrawing(strokes: [stroke]), noteID: id, pageID: pageID)
        let result = try XCTUnwrap(service.start(sourceID: id, title: "합성 요약", choices: nil, region: nil))
        try await finish()
        XCTAssertEqual(store.note(result)?.summary?.state, .completed, service.failure ?? "")
        let work = try store.summaryWork(result), input = try XCTUnwrap(work.inputs.first)
        XCTAssertTrue(input.text.contains("PDF definition")); XCTAssertTrue(input.text.contains("Inserted definition"))
        let captured = try XCTUnwrap(UIImage(data: store.summaryAsset(result, name: input.imageAsset))?.cgImage)
        var pixels = [UInt8](repeating: 0, count: 256*256*4)
        let context = try XCTUnwrap(CGContext(data: &pixels, width: 256, height: 256, bitsPerComponent: 8, bytesPerRow: 256*4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.draw(captured, in: CGRect(x: 0, y: 0, width: 256, height: 256))
        var red = 0, blue = 0, green = 0, dark = 0
        for i in stride(from: 0, to: pixels.count, by: 4) {
            if pixels[i] > 180 && pixels[i+1] < 80 && pixels[i+2] < 80 { red += 1 }
            if pixels[i+2] > 180 && pixels[i] < 80 && pixels[i+1] < 80 { blue += 1 }
            if pixels[i+1] > 180 && pixels[i] < 80 && pixels[i+2] < 80 { green += 1 }
            if pixels[i] < 100 && pixels[i+1] < 100 && pixels[i+2] < 100 { dark += 1 }
        }
        XCTAssertGreaterThan(red, 100); XCTAssertGreaterThan(blue, 100)
        XCTAssertGreaterThan(green, 50); XCTAssertGreaterThan(dark, 30)
    }
    func testContinuousPDFAndSparseInfiniteRanges() throws {
        let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400))
        let data = renderer.pdfData { output in for _ in 0..<3 { output.beginPage() } }
        let prepared = try XCTUnwrap(store.preparePDF(data: data, title: "PDF", folderID: nil))
        let id = try XCTUnwrap(store.importPDF(prepared, layout: .continuous))
        let source = store.note(id)!, options = NoteSummaryService.pageChoices(source)
        XCTAssertEqual(options.map(\.label), ["PDF 1페이지", "PDF 2페이지", "PDF 3페이지"])
        let units = try NoteSummaryService.sources(note: source, choices: [options[1].id], region: nil, store: store)
        XCTAssertTrue(units.allSatisfy { options[1].rect.contains($0.rect) && $0.label.hasPrefix("PDF 2페이지") })
        XCTAssertEqual(units.map(\.rect).reduce(CGRect.null) { $0.union($1) }, options[1].rect)
        let infinite = try note()
        store.updateNote(infinite) { $0.pages = [NotePage(canvasMode: "infinite", elements: [PageElement(kind: .text, text: "left", x: -2000, y: -100, width: 100, height: 50), PageElement(kind: .text, text: "right", x: 200000, y: 200000, width: 100, height: 50)])] }
        let all = try NoteSummaryService.sources(note: store.note(infinite)!, choices: nil, region: nil, store: store)
        XCTAssertLessThan(all.count, 8, "empty gap must not be captured")
        let rect = CGRect(x: -2100, y: -150, width: 400, height: 300)
        let chosen = try NoteSummaryService.sources(note: store.note(infinite)!, choices: nil, region: rect, store: store)
        XCTAssertTrue(chosen.allSatisfy { rect.contains($0.rect) && $0.label.hasPrefix("영역") })
    }
    func testLongNoteBatchesAndRetryReuseCompletedWork() async throws {
        let id = try note((1...5).map { "definition-\($0)" })
        let source = store.note(id)!, sources = try NoteSummaryService.sources(note: source, choices: nil, region: nil, store: store)
        let result = try store.createSummary(source: source, sources: sources, title: "긴 요약", model: connection.model, account: connection.selected!)
        var work = try store.summaryWork(result)
        work.policy.inputTokens = SummaryPrompt.instructions.utf8.count + 3000 + work.policy.reserveTokens
        try store.saveSummary(result, work: work, state: .preparing)
        SummaryProtocol.failAt = 1
        service.resume(result); try await finish()
        XCTAssertEqual(store.note(result)?.summary?.state, .failed)
        XCTAssertEqual(try store.summaryWork(result).fragments.count, 1)
        XCTAssertEqual(SummaryProtocol.bodies.count, 2)
        SummaryProtocol.failAt = nil
        // Removing the original cannot affect the frozen retry input.
        store.trash(id); XCTAssertTrue(store.permanentlyDelete(id))
        service = NoteSummaryService(store: store, connection: connection, http: http)
        service.resume(result); try await finish()
        XCTAssertEqual(store.note(result)?.summary?.state, .completed, service.failure ?? "")
        work = try store.summaryWork(result)
        XCTAssertEqual(work.fragments.count, work.batches.count)
        XCTAssertEqual(work.batches.flatMap { $0 }, Array(work.inputs.indices))
        XCTAssertEqual(work.fragments.flatMap(\.sources), sources.map(\.id))
        XCTAssertEqual(SummaryProtocol.bodies.count, 7, "five successful image requests, one failed request and one merge")
        for data in SummaryProtocol.bodies { XCTAssertLessThanOrEqual(data.count, work.policy.maxHTTPBytes) }
    }
    func testOversizedMergeUsesStagesWithoutLosingSources() async throws {
        let id = try note((1...5).map { "definition-\($0)" })
        let source = store.note(id)!, sources = try NoteSummaryService.sources(note: source, choices: nil, region: nil, store: store)
        let result = try store.createSummary(source: source, sources: sources, title: "단계 통합", model: connection.model, account: connection.selected!)
        var work = try store.summaryWork(result)
        work.policy.inputTokens = SummaryPrompt.instructions.utf8.count + 3000 + work.policy.reserveTokens
        try store.saveSummary(result, work: work, state: .preparing)
        SummaryProtocol.verboseImages = true
        service.resume(result); try await finish()
        XCTAssertEqual(store.note(result)?.summary?.state, .completed, service.failure ?? "")
        work = try store.summaryWork(result)
        XCTAssertGreaterThan(SummaryProtocol.bodies.count, 6)
        XCTAssertEqual(Set(work.mergeInputs.flatMap(\.sources)), Set(sources.map(\.id)))
        XCTAssertTrue(sources.allSatisfy { work.final!.contains("[\($0.id)]") })
        for data in SummaryProtocol.bodies {
            let body = try JSONSerialization.jsonObject(with: data) as! [String: Any]
            let texts = (body["input"] as! [[String: Any]]).flatMap { $0["content"] as! [[String: Any]] }.compactMap { $0["text"] as? String }
            XCTAssertLessThanOrEqual(SummaryPrompt.instructions.utf8.count + texts.joined().utf8.count, work.policy.usable)
        }
    }
    func testCancellationAccountChangeAndRelaunch() async throws {
        let source = try note()
        SummaryProtocol.hold = true
        let result = try XCTUnwrap(service.start(sourceID: source, title: "중단", choices: nil, region: nil))
        try await awaitRequest(1)
        try await Task.sleep(for: .milliseconds(80))
        connection.interruptRequests()
        try await finish()
        XCTAssertEqual(store.note(result)?.summary?.state, .cancelled)
        XCTAssertFalse(try store.summaryWork(result).partial.isEmpty)
        SummaryProtocol.hold = false
        await connection.refreshModels()
        service.resume(result); try await finish()
        XCTAssertEqual(store.note(result)?.summary?.state, .completed, service.failure ?? "")
        var work = try store.summaryWork(result); work.final = nil
        try store.saveSummary(result, work: work, state: .summarizing)
        let reopened = try NoteStore(repository: LibraryRepository(root: root))
        XCTAssertEqual(reopened.note(result)?.summary?.state, .interrupted)
        XCTAssertEqual(SummaryProtocol.bodies.count, 2, "relaunch must not send automatically")
    }
    func testSaveFailureRetainsFinalWithoutAnotherRequest() async throws {
        let source = try note()
        var blocked: URL?
        SummaryProtocol.onResponse = {
            guard let result = self.service.activeID else { return }
            let url = self.root.appendingPathComponent(result.uuidString).appendingPathComponent("summary.md")
            try? FileManager.default.removeItem(at: url)
            try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            blocked = url
        }
        let result = try XCTUnwrap(service.start(sourceID: source, title: "저장 복구", choices: nil, region: nil))
        try await finish()
        XCTAssertTrue(service.unsaved)
        XCTAssertNotNil(try service.checkpoint(result).final)
        try FileManager.default.removeItem(at: XCTUnwrap(blocked))
        service.saveAgain()
        XCTAssertFalse(service.unsaved); XCTAssertEqual(store.note(result)?.summary?.state, .completed)
        XCTAssertEqual(SummaryProtocol.bodies.count, 1)
    }
    func testEmptyCorruptAndInvalidCitationsDoNotComplete() async throws {
        let empty = try XCTUnwrap(store.createNote(title: "empty", paper: .plain, cover: .blue, folderID: nil))
        XCTAssertNil(service.start(sourceID: empty, title: "empty", choices: nil, region: nil))
        XCTAssertTrue(store.library.projects.isEmpty); XCTAssertTrue(SummaryProtocol.bodies.isEmpty)
        let id = try note()
        store.updatePage(noteID: id, pageID: store.note(id)!.pages[0].id) { $0.elements.append(PageElement(kind: .image, assetName: "missing.png")) }
        let result = try XCTUnwrap(service.start(sourceID: id, title: "broken", choices: nil, region: nil))
        try await finish()
        XCTAssertEqual(store.note(result)?.summary?.state, .failed)
        XCTAssertTrue(SummaryProtocol.bodies.isEmpty)
        let blankPDF = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 300, height: 400)).pdfData { $0.beginPage() }
        let prepared = try XCTUnwrap(store.preparePDF(data: blankPDF, title: "blank", folderID: nil))
        let blankID = try XCTUnwrap(store.importPDF(prepared, layout: .paged))
        let blankResult = try XCTUnwrap(service.start(sourceID: blankID, title: "blank summary", choices: nil, region: nil))
        try await finish()
        XCTAssertEqual(store.note(blankResult)?.summary?.state, .failed)
        XCTAssertTrue(SummaryProtocol.bodies.isEmpty)
        XCTAssertThrowsError(try SummaryPrompt.validate("내용 [S99]", sources: ["S1"]))
        XCTAssertThrowsError(try SummaryPrompt.validate("출처 없음", sources: ["S1"]))
    }
}

private final class SummaryVault: PlanVault {
    var state: PlanVaultState
    init() {
        let tokens = PlanTokens(access_token: "fixture", token_type: "Bearer", expires_in: 3600, scope: "chatgpt.tokens.use.direct")
        state = PlanVaultState(selected: "fixture", registrations: [PlanRegistration(id: "fixture", identity: OpenAIIdentity(subject: "fixture", email: "fixture@example.invalid"), tokens: tokens, receivedAt: Date())])
    }
    func read() throws -> PlanVaultState { state }
    func write(_ value: PlanVaultState) throws { state = value }
}
private final class SummaryProtocol: URLProtocol, @unchecked Sendable {
    static var bodies: [Data] = []
    static var failAt: Int?
    static var hold = false
    static var verboseImages = false
    static var onResponse: (@MainActor () -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if request.url?.path == "/v1/models" {
            respond(Data(#"{"models":[{"slug":"gpt-6-astra","display_name":"Fixture","visibility":"list"}]}"#.utf8), mime: "application/json")
            return
        }
        var data = request.httpBody ?? Data()
        if let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 8192)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }
        }
        Self.bodies.append(data)
        if Self.bodies.count - 1 == Self.failAt { respond(Data(#"{"error":{"code":"fixture_failure"}}"#.utf8), status: 503, mime: "application/json"); return }
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let inputs = body?["input"] as? [[String: Any]] ?? []
        let text = inputs.flatMap { $0["content"] as? [[String: Any]] ?? [] }.compactMap { $0["text"] as? String }.joined(separator: "\n")
        let regex = try! NSRegularExpression(pattern: #"\[S[0-9]+\]"#)
        let ns = text as NSString
        let citations = Set(regex.matches(in: text, range: NSRange(location: 0, length: ns.length)).map { ns.substring(with: $0.range) }).sorted().joined(separator: " ")
        var answer = "# 핵심\n\n정의와 조건 \\(a^2 + b^2\\) " + citations
        if Self.verboseImages && inputs.flatMap({ $0["content"] as? [[String: Any]] ?? [] }).contains(where: { $0["type"] as? String == "input_image" }) {
            answer += "\n" + String(repeating: "definition ", count: 70)
        }
        let delta = try! JSONSerialization.data(withJSONObject: ["type": "response.output_text.delta", "delta": answer])
        let final = try! JSONSerialization.data(withJSONObject: ["type": "response.completed", "response": ["output": [["type": "message", "content": [["type": "output_text", "text": answer]]]]]])
        let payload = Data("data: ".utf8) + delta + Data("\n\n".utf8) + (Self.hold ? Data() : Data("data: ".utf8) + final + Data("\n\n".utf8))
        Task { @MainActor in
            Self.onResponse?()
            self.respond(payload, mime: "text/event-stream", finish: !Self.hold)
        }
    }
    private func respond(_ data: Data, status: Int = 200, mime: String, finish: Bool = true) {
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": mime])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        if finish { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() {}
}
