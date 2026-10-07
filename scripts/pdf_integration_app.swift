import SwiftUI
import PencilKit
import PDFKit
import WebKit

@main
struct NoteMarginApp: App {
    @StateObject private var store = NoteStore()
    @State private var noteID: UUID?
    @State private var ran = false
    var body: some Scene {
        WindowGroup {
            Group {
                if CommandLine.arguments.contains("--library-ui") { LibraryView() }
                else if CommandLine.arguments.contains("--auth-probe") || CommandLine.arguments.contains("--plan-ui") || CommandLine.arguments.contains("--plan-self-check") {
                    ChatGPTPlanFixtureView()
                } else { ordinaryContent }
            }.preferredColorScheme(CommandLine.arguments.contains("--tools-dark") ? .dark : CommandLine.arguments.contains("--tools-light") ? .light : nil).environmentObject(store).task {
                guard !ran else { return }; ran = true
                if CommandLine.arguments.contains("--drawing-engine") {
                    var passed: [String] = [], failures: [String] = []
                    do { passed.append("\(try checkInkSpatialRevisions()) spatial revision checks") }
                    catch { failures.append("spatial: \(error)") }
                    do { passed.append("\(try await checkDrawingSnapshots()) active drawing snapshot checks") }
                    catch { failures.append("snapshots: \(error)") }
                    do { passed.append("\(try await checkShapeCompletion()) shape lifecycle/attribute/undo checks") }
                    catch { failures.append("shape: \(error)") }
                    do { passed.append("\(try await checkShapeDirectEditing()) direct shape editing checks") }
                    catch { failures.append("shape editing: \(error)") }
                    do { _ = try PDFIntegrationChecks.run(store); passed.append("existing PDF/ink/selection/viewport regressions") }
                    catch { failures.append("canvas: \(error)") }
                    do { passed.append("\(try await checkInkSavingPerformance(store)) persistence checks") }
                    catch { failures.append("persistence: \(error)") }
                    PDFIntegrationChecks.report((failures.isEmpty ? "PASS: " : "FAIL: " + failures.joined(separator: "; ") + "\nPassed: ") + passed.joined(separator: "; "))
                    return
                }
                if let index = CommandLine.arguments.firstIndex(of: "--drawing-performance") {
                    do {
                        let label = CommandLine.arguments[index + 1]
                        var count = try checkDrawingPerformance(reportName: "drawing-performance-" + label + ".json")
                        if CommandLine.arguments.contains("--profile-drawing") {
                            // Disposable fixture only: give Instruments time to
                            // attach to a sustained, reproducible CPU workload.
                            let deadline = ContinuousClock.now.advanced(by: .seconds(25))
                            while ContinuousClock.now < deadline {
                                try await Task.sleep(for: .milliseconds(20))
                                count = try checkDrawingPerformance(reportName: "drawing-performance-profile.json")
                            }
                        }
                        PDFIntegrationChecks.report("PASS: \(count) drawing performance/correctness checks (" + label + ")")
                    } catch { PDFIntegrationChecks.report("FAIL: \(error)") }
                    return
                }
                if CommandLine.arguments.contains("--library-ui") {
                    if CommandLine.arguments.contains("--library-reset"), Bundle.main.bundleIdentifier == "com.notemargin.integrationcheck" {
                        do {
                            let documents = try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                            let repository = try LibraryRepository.applicationLibrary(in: documents)
                            let first = NoteProject(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, title: "수학")
                            let second = NoteProject(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, title: "물리")
                            let note = Notebook(id: UUID(uuidString: "33333333-3333-3333-3333-333333333333")!, title: "강의 노트")
                            var library = Library(projects: [first, second], notebooks: [note]); library.projectsMigrated = true
                            if CommandLine.arguments.contains("--library-tree") {
                                let child = NoteProject(id: UUID(uuidString: "44444444-4444-4444-4444-444444444444")!, title: "전공", parentID: first.id)
                                let leaf = NoteProject(id: UUID(uuidString: "55555555-5555-5555-5555-555555555555")!, title: "정수론", parentID: child.id)
                                library.projects += [child, leaf]
                            }
                            try repository.save(library); store.loadLibrary()
                        } catch { PDFIntegrationChecks.report("FAIL: library fixture") }
                    }
                    return
                }
                guard !CommandLine.arguments.contains("--auth-probe"), !CommandLine.arguments.contains("--plan-ui"), !CommandLine.arguments.contains("--plan-self-check") else { return }
                do {
                    let checked = try PDFIntegrationChecks.run(store)
                    noteID = CommandLine.arguments.contains("--page-swap") || CommandLine.arguments.contains("--eraser") ? try PDFIntegrationChecks.pageSwapFixture(store).id : checked
                    if CommandLine.arguments.contains("--tools-ui"), let noteID, let note = store.note(noteID) {
                        let image = UIGraphicsImageRenderer(size: CGSize(width: 80, height: 60)).image { ctx in UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 80, height: 60)) }
                        let region = CapturedRegion(pageID: note.pages[0].id, rect: CGRect(x: 40, y: 100, width: 80, height: 60), imageData: image.pngData()!, extractedText: "가독성 테스트", sourceDescription: "UI fixture", pdfPageNumbers: [1])
                        _ = MarginAIStore.shared.create(note: note, project: nil, region: region)
                    }
                }
                catch { PDFIntegrationChecks.report("FAIL: \(error)") }
            }
        }
    }
    @ViewBuilder private var ordinaryContent: some View {
                if CommandLine.arguments.contains("--eraser"), let noteID, let note = store.note(noteID) {
                    EraserRegressionView(note: note)
                } else if CommandLine.arguments.contains("--live-ink"), noteID != nil,
                   let note = store.library.notebooks.last(where: { $0.title == "Long canvas regression" }) {
                    LiveCanvasRegressionView(note: note)
                } else if let noteID {
                    NavigationStack {
                        EditorView(noteID: noteID)
                            .overlay {
                                if CommandLine.arguments.contains("--zoomed-eraser") {
                                    FixtureZoomControl().frame(width: 100, height: 44)
                                }
                            }
                    }
                }
                else { ProgressView("PDF integration checks") }
    }
}

// Test setup only: the UI test checks native partial erasing at an actual
// enlarged canvas scale. This does not claim to validate synthesized pinching.
private struct FixtureZoomControl: UIViewRepresentable {
    func makeUIView(context: Context) -> UIButton { FixtureZoomButton(type: .system) }
    func updateUIView(_ uiView: UIButton, context: Context) { }
}

private final class FixtureZoomButton: UIButton {
    override init(frame: CGRect) {
        super.init(frame: frame)
        setTitle("Zoom 2×", for: .normal)
        accessibilityIdentifier = "fixture-zoom-2x"
        addTarget(self, action: #selector(enlarge), for: .touchUpInside)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    @objc private func enlarge() {
        guard let window else { return }
        func findHost(_ view: UIView) -> CanvasHostView? {
            if let host = view as? CanvasHostView { return host }
            return view.subviews.lazy.compactMap(findHost).first
        }
        guard let host = findHost(window) else { return }
        let canvas = host.session.canvas
        canvas.setZoomScale(canvas.minimumZoomScale * 4, animated: false)
        host.canvasDidZoom()
        isHidden = true
    }
}

private struct ChatGPTPlanFixtureView: View {
    @State private var id: UUID?
    var body: some View {
        Group {
            if let id { ChatGPTMarginView(conversationID: id, project: nil) }
            else { ProgressView("Preparing offline fixture") }
        }.task {
            if CommandLine.arguments.contains("--auth-probe") {
                for _ in 0..<100 {
                    if UIApplication.shared.connectedScenes.contains(where: { $0.activationState == .foregroundActive }) { break }
                    try? await Task.sleep(for: .milliseconds(50))
                }
                let flow = ChatGPTSignIn(); flow.localCallbackProbe = true
                do {
                    let result = try await flow.run(hostID: "urn:uuid:" + UUID().uuidString, profile: nil)
                    PDFIntegrationChecks.report(result.1 == "local-probe-no-token" ? "PASS: system authentication session + IPv4 loopback callback; no OpenAI sign-in or inference" : "FAIL: wrong callback")
                } catch { PDFIntegrationChecks.report("FAIL: system authentication loopback probe: \(error)") }
                return
            }
            let note = Notebook(title: "Offline plan fixture")
            let image = UIGraphicsImageRenderer(size: CGSize(width: 120, height: 80)).image { c in
                UIColor.white.setFill(); c.fill(CGRect(x: 0, y: 0, width: 120, height: 80))
            }
            let region = CapturedRegion(pageID: note.pages[0].id, rect: CGRect(x: 0, y: 0, width: 120, height: 80), imageData: image.pngData()!, extractedText: "x² + 1", sourceDescription: "Offline PDF fixture", pdfPageNumbers: [1])
            id = MarginAIStore.shared.create(note: note, project: nil, region: region)
            if CommandLine.arguments.contains("--plan-self-check") {
                do {
                    guard let id else { throw CocoaError(.fileWriteUnknown) }
                    try PDFIntegrationChecks.check(!MarginAIStore.shared.sendPlan("No credentials", conversationID: id, project: nil), "Disconnected plan must block inference")
                    try PDFIntegrationChecks.check(Bundle.main.bundleIdentifier == "com.notemargin.integrationcheck", "only isolated fixture may test Keychain")
                    let vault = KeychainPlanVault(), prior = try vault.read()
                    var fixtureVault = prior
                    fixtureVault.registrations = [.init(id: "fixture-keychain", identity: .init(subject: "fixture", email: nil), tokens: PlanTokens(access_token: "fixture-not-real", refresh_token: "fixture-refresh", token_type: "Bearer", expires_in: 1, scope: "openid"), receivedAt: Date())]
                    try vault.write(fixtureVault)
                    let restored = try vault.read()
                    try vault.write(prior)
                    try PDFIntegrationChecks.check(restored.registrations.first?.tokens?.access_token == "fixture-not-real", "protected Keychain roundtrip")
                    let memoryChecks = try await checkMemoryStore()
                    try await checkMathRenderer()
                    let drawingStore = NoteStore()
                    _ = try PDFIntegrationChecks.run(drawingStore)
                    let savingChecks = try await checkInkSavingPerformance(drawingStore)
                    PDFIntegrationChecks.report("PASS: \(savingChecks) ink persistence checks; live move/resize pixels, half-fit zoom, cached paper, 0.1pt native pen; PDF/ink/selection regression checks; \(memoryChecks) memory store/wire checks; unified native ChatGPT panel, disconnected inference blocked, offline math renderer, answer card Undo/Redo, PDF capture checks")
                } catch { PDFIntegrationChecks.report("FAIL: plan fixture: \(error)") }
            }
        }
    }
}
@MainActor private func checkMathRenderer() async throws {
    let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
    let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 320, height: 180), configuration: config)
    guard let file = Bundle.main.url(forResource: "renderer", withExtension: "html", subdirectory: "MathResources") else { throw CocoaError(.fileNoSuchFile) }
    web.loadFileURL(file, allowingReadAccessTo: file.deletingLastPathComponent())
    var ready = false
    for _ in 0..<100 {
        if (try? await web.evaluateJavaScript("typeof window.drawMath === 'function' && typeof katex !== 'undefined'")) as? Bool == true { ready = true; break }
        try await Task.sleep(for: .milliseconds(50))
    }
    try PDFIntegrationChecks.check(ready, "offline KaTeX bundle loads")
    // Supply only fixture text; never credentials. The missing native size handler
    // is harmless for this standalone renderer check.
    _ = try await web.callAsyncJavaScript("window.drawMath(expression); return document.querySelectorAll('.katex').length", arguments: ["expression": #"\frac{x^2}{1+x} = \sqrt{2}"#], in: nil, contentWorld: .page)
    let count = try await web.evaluateJavaScript("document.querySelectorAll('.katex').length") as? Int
    try PDFIntegrationChecks.check(count == 1, "LaTeX renders as math")
    _ = try await web.callAsyncJavaScript("window.drawMath(expression)", arguments: ["expression": #"\href{https://example.invalid/secret}{click} + <script>alert(1)</script>"#], in: nil, contentWorld: .page)
    let links = try await web.evaluateJavaScript("document.querySelectorAll('a,img,iframe').length") as? Int
    try PDFIntegrationChecks.check(links == 0, "untrusted math cannot create links or external resources")
    // Render the entire paragraph so bold emphasis can span inline equations.
    let readable = #"**Precision about the slide.** The integers \(a,2a,\ldots,(p-1)a\) need not be a permutation. It is their **remainders modulo \(p\)** that matter."#
    _ = try await web.callAsyncJavaScript("window.drawAnswer(source)", arguments: ["source": readable], in: nil, contentWorld: .page)
    let paragraphOK = try await web.evaluateJavaScript("document.querySelectorAll('#answer > p').length === 1 && document.querySelectorAll('.math-inline').length === 2 && document.querySelectorAll('.math-display').length === 0 && document.querySelectorAll('strong .math-inline').length === 1 && document.querySelectorAll('button').length === 0") as? Bool
    try PDFIntegrationChecks.check(paragraphOK == true, "inline math and bold stay inside one paragraph without copy buttons")
    _ = try await web.callAsyncJavaScript("window.drawAnswer(source)", arguments: ["source": #"Before \(x^2\) unfinished \(x"#], in: nil, contentWorld: .page)
    let incompleteOK = try await web.evaluateJavaScript("document.querySelectorAll('.katex').length === 1 && document.getElementById('answer').textContent.includes('unfinished')") as? Bool
    try PDFIntegrationChecks.check(incompleteOK == true, "unfinished streamed math stays readable until closed")
    let korean = "핵심은 **“큰 가지를 따라가는 구간은 길게 묶는다”**는 것입니다. 그리고**(정의)**를 확인합니다."
    _ = try await web.callAsyncJavaScript("window.drawAnswer(source)", arguments: ["source": korean], in: nil, contentWorld: .page)
    let koreanOK = try await web.evaluateJavaScript("Array.from(document.querySelectorAll('strong')).map(e => e.textContent).join('|') === '“큰 가지를 따라가는 구간은 길게 묶는다”|(정의)' && !answer.textContent.includes('**')") as? Bool
    try PDFIntegrationChecks.check(koreanOK == true, "quoted Korean bold adjacent to particles renders without literal stars")
    let literal = #"\*\*별표\*\* `**“코드”**는` \(x^{**}\) **일반 강조** **“미완성"#
    _ = try await web.callAsyncJavaScript("window.drawAnswer(source)", arguments: ["source": literal], in: nil, contentWorld: .page)
    let literalsOK = try await web.evaluateJavaScript("document.querySelectorAll('strong').length === 1 && document.querySelector('strong').textContent === '일반 강조' && document.querySelector('code').textContent === '**“코드”**는' && answer.textContent.includes('**별표**') && answer.textContent.includes('**“미완성') && document.querySelector('annotation').textContent === 'x^{**}'") as? Bool
    try PDFIntegrationChecks.check(literalsOK == true, "escaped stars code LaTeX and unfinished emphasis remain unmodified")
    for source in ["핵심은 **“강조", "핵심은 **“강조”**는 정확합니다."] {
        _ = try await web.callAsyncJavaScript("window.drawAnswer(source)", arguments: ["source": source], in: nil, contentWorld: .page)
    }
    let streamedBold = try await web.evaluateJavaScript("document.querySelector('strong')?.textContent === '“강조”' && !answer.textContent.includes('**')") as? Bool
    try PDFIntegrationChecks.check(streamedBold == true, "streamed emphasis becomes bold when closing delimiter arrives")
    let hostile = #"<img src='https://example.invalid/secret' onerror='alert(1)'> [link](https://example.invalid) ![alt](https://example.invalid/a.png) \(\href{https://example.invalid}{bad}\)"#
    _ = try await web.callAsyncJavaScript("window.drawAnswer(source)", arguments: ["source": hostile], in: nil, contentWorld: .page)
    let safe = try await web.evaluateJavaScript("document.querySelectorAll('#answer a,#answer img,#answer script,#answer iframe').length === 0") as? Bool
    try PDFIntegrationChecks.check(safe == true, "whole answer Markdown cannot create active HTML or external links/images")
    let sample = #"""
    ## Fermat’s little theorem

    **Precision about the slide.** The integers \(a,2a,\ldots,(p-1)a\) themselves need not be a permutation of \(1,2,\ldots,p-1\). It is their **remainders modulo \(p\)** that form such a permutation.

    Therefore,

    \[
    a^{p-1} \equiv 1 \pmod p.
    \]

    - 가정: \(p\)는 소수이고 \(p \nmid a\)입니다.
    - 결론: 나머지의 순열을 이용해 곱을 비교합니다.

    `\(code stays literal\)`
    """#
    _ = try await web.callAsyncJavaScript("window.drawAnswer(source, 7, 17, 'dark')", arguments: ["source": sample], in: nil, contentWorld: .page)
    let blockOK = try await web.evaluateJavaScript("document.querySelectorAll('.math-display').length === 1 && document.querySelectorAll('li').length === 2 && document.querySelectorAll('code .katex').length === 0 && document.querySelectorAll('strong .math-inline').length === 1") as? Bool
    try PDFIntegrationChecks.check(blockOK == true, "block math lists code and emphasis preserve document structure")
    web.frame = CGRect(x: 0, y: 0, width: 620, height: 900)
    // Native WebKit snapshots are synthetic layout fixtures, never live account responses.
    try await Task.sleep(for: .milliseconds(200))
    let renderedHeight = try await web.evaluateJavaScript("document.getElementById('answer').getBoundingClientRect().height") as? Double ?? 0
    try PDFIntegrationChecks.check(renderedHeight > 100 && renderedHeight < 700, "answer height follows its document rather than per-equation fixed frames")
    let snapshot = try await web.takeSnapshot(configuration: nil)
    try snapshot.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("math-readable-dark.png"))
    web.frame = CGRect(x: 0, y: 0, width: 320, height: 900)
    _ = try await web.callAsyncJavaScript("window.drawAnswer(source, 8, 17, 'light')", arguments: ["source": sample], in: nil, contentWorld: .page)
    try await Task.sleep(for: .milliseconds(100))
    let narrow = try await web.takeSnapshot(configuration: nil)
    try narrow.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("math-readable-narrow.png"))
    let parts = AnswerPart.parse(#"**Proof** \(x^2\) unfinished \(x"#)
    try PDFIntegrationChecks.check(parts.filter(\.math).count == 1 && parts.last?.math == false, "streaming unfinished math stays text")
}
@MainActor enum PDFIntegrationChecks {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }
    static var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static func report(_ text: String) { try? text.write(to: directory.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8) }
    static func color(_ image: UIImage, y: CGFloat, x: CGFloat = 100) -> [UInt8] {
        let crop = image.cgImage!.cropping(to: CGRect(x: x, y: y, width: 1, height: 1))!
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                    space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        return pixel
    }
    static func pageSwapFixture(_ store: NoteStore) throws -> Notebook {
        guard let id = store.createNote(title: "Page swap regression", paper: .plain, cover: .blue, folderID: nil) else {
            throw NSError(domain: "page fixture", code: 1)
        }
        let pages = [NotePage(), NotePage(height: 1300), NotePage(height: 768)]
        try check(store.updateNote(id) { $0.pages = pages }, "fixture pages")
        for (index, color) in [(0, UIColor.red), (2, UIColor.blue)] {
            let points = [CGPoint(x: 140, y: 360), CGPoint(x: 600, y: 480)].enumerated().map { index, point in
                PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 18, height: 18), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
            }
            let stroke = PKStroke(ink: PKInk(.pen, color: color), path: PKStrokePath(controlPoints: points, creationDate: Date()))
            store.queueDrawing(PKDrawing(strokes: [stroke]), noteID: id, pageID: pages[index].id)
        }
        try check(store.flushDrawings(), "fixture ink")
        return store.note(id)!
    }

    static func checkPageReplacement(_ store: NoteStore) throws {
        let note = try pageSwapFixture(store)
        let session = DrawingSession()
        let host = CanvasHostView(session: session)
        session.host = host
        host.frame = CGRect(x: 0, y: 0, width: 820, height: 1000)
        func open(_ index: Int) {
            session.load(noteID: note.id, pageID: note.pages[index].id, store: store)
            host.configure(note: note, page: note.pages[index], store: store, fingerDrawing: true,
                           editingObjects: false, toolsVisible: false, onSelect: { _ in },
                           onMove: { _, _, _ in }, onTurnPage: { _ in false })
            host.layoutIfNeeded()
        }
        open(0)
        let oldCanvas = session.canvas
        let ink = oldCanvas.drawing.dataRepresentation()
        let chosenTool = PKInkingTool(.pen, color: .purple, width: 7)
        oldCanvas.tool = chosenTool
        open(1)
        try check(session.canvas !== oldCanvas && oldCanvas.superview == nil && oldCanvas.delegate == nil, "old render surface detached")
        try check(session.canvas.drawing.strokes.isEmpty, "blank page starts with no ink")
        try check((session.canvas.tool as? PKInkingTool) == chosenTool, "selected pen preserved across pages")
        // Simulate a queued callback from the removed page arriving after the switch.
        session.canvasViewDrawingDidChange(oldCanvas)
        try check(store.drawing(noteID: note.id, pageID: note.pages[1].id).strokes.isEmpty, "late callback cannot pollute blank page")
        let blankCanvas = session.canvas
        open(1)
        try check(session.canvas === blankCanvas, "same-page updates must retain the live canvas")
        open(2)
        try check(session.canvas.drawing.strokes.count == 1, "existing destination ink loads without new input")
        open(0)
        try check(session.canvas.drawing.dataRepresentation() == ink, "original ink survives round trip")
        session.stop()
    }

    static func checkEraserPersistence(_ store: NoteStore) throws {
        let note = try pageSwapFixture(store)
        let original = try store.drawing(noteID: note.id, pageID: note.pages[0].id)
        let transaction = StrokeEraserTransaction(drawing: original, width: 24)
        transaction.extend(to: CGPoint(x: 384, y: 250))
        try check(transaction.erasedIndices.isEmpty, "eraser in empty space must not hit")
        transaction.extend(to: CGPoint(x: 384, y: 600))
        try check(transaction.erasedIndices.count == 1 && transaction.remainingDrawing.strokes.isEmpty, "fast swept eraser must hit crossing stroke")
        try check(transaction.original.dataRepresentation() == original.dataRepresentation(), "eraser preview never mutates original ink")
        try check(store.drawing(noteID: note.id, pageID: note.pages[0].id).dataRepresentation() == original.dataRepresentation(), "preview does not change stored ink")
        // A hole in a pixel-erased stroke must stay empty to the vector eraser.
        var masked = original.strokes[0]
        masked.mask = UIBezierPath(rect: CGRect(x: 130, y: 300, width: 100, height: 200))
        let maskedDrawing = PKDrawing(strokes: [masked])
        let hole = StrokeEraserTransaction(drawing: maskedDrawing, width: 24)
        hole.extend(to: CGPoint(x: 384, y: 424))
        try check(hole.erasedIndices.isEmpty, "transparent mask region is not a hit")
        hole.extend(to: CGPoint(x: 170, y: 368))
        try check(hole.erasedIndices.count == 1, "visible masked ink is a hit")
        // Lasso-transformed ink is tested in document coordinates, including deep PDFs.
        var moved = original.strokes[0]
        moved.transform = CGAffineTransform(translationX: 20, y: 70_000)
        let deep = StrokeEraserTransaction(drawing: PKDrawing(strokes: [moved]), width: 24)
        deep.extend(to: CGPoint(x: 384, y: 424))
        try check(deep.erasedIndices.isEmpty, "old position must not erase transformed ink")
        deep.extend(to: CGPoint(x: 404, y: 70_424))
        try check(deep.erasedIndices.count == 1, "deep transformed ink hit")
        let session = DrawingSession()
        session.load(noteID: note.id, pageID: note.pages[0].id, store: store)
        session.commitStrokeErasing(transaction.remainingDrawing)
        try check(store.flushDrawings(), "erase commit saved")
        try check(store.drawing(noteID: note.id, pageID: note.pages[0].id).strokes.isEmpty, "commit persists whole stroke deletion")
        session.stop()
    }

    static func checkViewport(_ store: NoteStore, prepared: PreparedPDFImport) throws {
        let longPDF = PreparedPDFImport(title: "Long canvas regression", data: prepared.data,
                                        pages: Array(repeating: prepared.pages, count: 20).flatMap { $0 }, folderID: nil)
        guard let id = store.importPDF(longPDF, layout: .continuous), let note = store.note(id) else {
            throw NSError(domain: "long canvas import", code: 1)
        }
        let session = DrawingSession()
        let host = CanvasHostView(session: session)
        session.host = host
        host.frame = CGRect(x: 0, y: 0, width: 820, height: 1000)
        session.load(noteID: id, pageID: note.pages[0].id, store: store)
        func configure() {
            host.configure(note: note, page: note.pages[0], store: store, fingerDrawing: true,
                           editingObjects: false, toolsVisible: false, onSelect: { _ in },
                           onMove: { _, _, _ in }, onTurnPage: { _ in false })
            host.layoutIfNeeded()
        }
        configure()
        let canvas = session.canvas
        try check(canvas.superview === host && canvas.bounds.size == host.bounds.size && canvas.transform == .identity,
                  "PencilKit must stay viewport-sized without an external zoom transform")
        try check(canvas.isScrollEnabled && note.pages[0].height > 70_000, "long scrollable content")
        for factor in [1.0, 1.8, 3.0] {
            canvas.setZoomScale(canvas.minimumZoomScale * factor, animated: false)
            host.layoutIfNeeded()
            try check(abs(canvas.contentSize.height - note.pages[0].height * canvas.zoomScale) < 2, "native zoom content size")
            for fraction in [0.0, 0.5, 0.95] {
                canvas.contentOffset = CGPoint(x: 50, y: canvas.contentSize.height * fraction)
                let offset = canvas.contentOffset
                let zoom = canvas.zoomScale
                let ink = canvas.drawing.dataRepresentation()
                let pagePoint = CGPoint(x: 200, y: (offset.y + 300) / zoom)
                let screenPoint = pagePoint.applying(host.documentToViewport)
                try check(abs(screenPoint.y - 300) < 0.01, "background and ink use the same scrolling origin")
                for _ in 0..<12 { configure() }
                try check(canvas.contentOffset == offset && canvas.zoomScale == zoom && canvas.bounds.size == host.bounds.size,
                          "save/UI updates must not move the live canvas")
                try check(canvas.drawing.dataRepresentation() == ink, "UI updates must not replace ink")
            }
        }
        session.stop()
    }

    static func checkRegionCapture(_ store: NoteStore, joined: Notebook, drawing: PKDrawing) throws {
        let page = joined.pages[0]
        let original = drawing.dataRepresentation()
        func pixel(_ image: UIImage, x: Int, y: Int) throws -> [UInt8] {
            guard let cgImage = image.cgImage,
                  let crop = cgImage.cropping(to: CGRect(x: x, y: y, width: 1, height: 1)) else {
                throw NSError(domain: "region image pixel", code: 1)
            }
            var bytes = [UInt8](repeating: 0, count: 4)
            bytes.withUnsafeMutableBytes {
                let context = CGContext(data: $0.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return bytes
        }
        // The black fixture stroke crosses the red/green PDF seam at (135, 960).
        // All three layers must stay in the same coordinate system after cropping.
        let seam = try RegionContextService.capture(note: joined, page: page, drawing: drawing, store: store,
                                                     rect: CGRect(x: 100, y: 920, width: 100, height: 100))
        let image = UIImage(data: seam.imageData)!
        try check(image.size == CGSize(width: 200, height: 200), "region image contains only the selected crop")
        let red = try pixel(image, x: 10, y: 10)
        let green = try pixel(image, x: 10, y: 160)
        let ink = try pixel(image, x: 70, y: 80)
        try check(red[0] > 200 && red[1] < 80, "region crop preserves preceding PDF background")
        try check(green[1] > 200 && green[0] < 80, "region crop preserves following rotated PDF background")
        try check(ink.prefix(3).allSatisfy { $0 < 80 }, "region crop includes ink at its exact PDF seam position")
        var darkCapture: Result<CapturedRegion, Error>!
        UITraitCollection(userInterfaceStyle: .dark).performAsCurrent {
            darkCapture = Result { try RegionContextService.capture(note: joined, page: page, drawing: drawing, store: store, rect: seam.rect) }
        }
        let darkImage = UIImage(data: try darkCapture.get().imageData)!
        let darkInk = try pixel(darkImage, x: 70, y: 80)
        try check(darkInk.prefix(3).allSatisfy { $0 < 80 }, "dark-mode screenshot keeps black handwritten ink visible")
        try check(seam.pdfPageNumbers == [1, 2], "region cites both crossed PDF pages")
        try check(seam.pageID == page.id && seam.rect == CGRect(x: 100, y: 920, width: 100, height: 100), "region stores original document coordinates")

        let clipped = try RegionContextService.capture(note: joined, page: page, drawing: drawing, store: store,
                                                        rect: CGRect(x: -30, y: -30, width: 130, height: 130))
        try check(clipped.rect == CGRect(x: 0, y: 0, width: 100, height: 100), "region clips off-page selection")
        let bounded = try RegionContextService.capture(note: joined, page: page, drawing: drawing, store: store,
                                                        rect: CGRect(x: 0, y: 0, width: page.width, height: page.height))
        let boundedImage = UIImage(data: bounded.imageData)!
        try check(max(boundedImage.size.width, boundedImage.size.height) <= 1800, "region image allocation is bounded for continuous PDFs")

        let firstText = try RegionContextService.capture(note: joined, page: page, drawing: drawing, store: store,
                                                          rect: CGRect(x: 0, y: 0, width: 440, height: 180))
        try check(firstText.extractedText.contains("PAGE 1") && !firstText.extractedText.contains("PAGE 2"), "PDF text is limited to selected first-page content")
        // A 90-degree clockwise page puts its original top-left text at top-right.
        let rotatedText = try RegionContextService.capture(note: joined, page: page, drawing: drawing, store: store,
                                                            rect: CGRect(x: 560, y: 960, width: 208, height: 600))
        try check(rotatedText.extractedText.contains("PAGE 2") && !rotatedText.extractedText.contains("PAGE 1"), "rotated continuous PDF text maps back into source PDF coordinates")
        let emptyText = try RegionContextService.capture(note: joined, page: page, drawing: drawing, store: store,
                                                          rect: CGRect(x: 40, y: 1800, width: 220, height: 200))
        try check(emptyText.extractedText.isEmpty, "blank selected region does not include unrelated PDF text")
        try check(drawing.dataRepresentation() == original, "region capture never mutates handwritten strokes")
    }

    static func checkProjectAndChatWorkflow(_ store: NoteStore) throws {
        let first = store.createProject(title: "AI 프로젝트 검사", agentInstructions: "과정을 설명해 줘")!
        let second = store.createProject(title: "다른 프로젝트")!
        let noteID = store.createNote(title: "Project workflow", paper: .plain, cover: .sage, folderID: nil, projectID: first)!
        let note = store.note(noteID)!
        try check(NoteStore().note(noteID)?.projectID == first, "new notes retain selected project after reload")
        let region = try RegionContextService.capture(note: note, page: note.pages[0], drawing: PKDrawing(), store: store,
                                                     rect: CGRect(x: 100, y: 100, width: 200, height: 200))
        let repository = MarginChatRepository(root: directory.appendingPathComponent("ChatChecks-" + UUID().uuidString))
        let ai = MarginAIStore(repository: repository)
        let id = ai.create(note: note, project: store.project(first), region: region)!
        ai.setDraft("질문 작성 중", for: id); ai.flushDraft(id)
        let restored = MarginAIStore(repository: repository); restored.load(noteID: noteID)
        try check(restored.conversation(id)?.draft == "질문 작성 중", "chat draft survives reopening the store")
        try check(store.assignProject(noteID: noteID, projectID: second), "move project persists")
        try check(!ai.sendPlan("other project", conversationID: id, project: store.project(second)),
                  "old-project chat cannot send under the destination project")
        // Make atomic replacement fail in the disposable test directory, without
        // discarding the previously saved chat. No API or Keychain is accessed.
        let file = repository.root.appendingPathComponent(noteID.uuidString).appendingPathComponent(id.uuidString + ".json")
        let backup = file.appendingPathExtension("backup")
        try FileManager.default.moveItem(at: file, to: backup)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        ai.setDraft("저장 실패 후에도 보존", for: id); ai.flushDraft(id)
        try check(ai.needsSaving(id) && ai.conversation(id)?.draft == "저장 실패 후에도 보존" && ai.failures[id] != nil,
                  "failed draft save remains in memory with a visible retry action")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.moveItem(at: backup, to: file)
        ai.retrySave(id)
        try check(!ai.needsSaving(id) && ai.failures[id] == nil && repository.load(noteID: noteID).first?.draft == "저장 실패 후에도 보존",
                  "retry saves retained draft without a billable request")
        store.deleteProject(second)
        try check(store.note(noteID) != nil && store.note(noteID)?.projectID == nil, "deleting project preserves its notebook")
        store.deleteProject(first)
    }

    static func run(_ store: NoteStore) throws -> UUID {
        try checkProjectAndChatWorkflow(store)
        let sizes = [CGSize(width: 400, height: 500), CGSize(width: 600, height: 300), CGSize(width: 300, height: 500)]
        let colors: [UIColor] = [.red, .green, .blue]
        let data = UIGraphicsPDFRenderer(bounds: CGRect(origin: .zero, size: sizes[0])).pdfData { output in
            for index in sizes.indices {
                let rect = CGRect(origin: .zero, size: sizes[index])
                output.beginPage(withBounds: rect, pageInfo: [:])
                colors[index].setFill(); output.fill(rect)
                ("PAGE \(index + 1)" as NSString).draw(at: CGPoint(x: 30, y: 30), withAttributes: [.font: UIFont.boldSystemFont(ofSize: 28)])
            }
        }
        let pdf = PDFDocument(data: data)!
        pdf.page(at: 1)!.rotation = 90
        let url = directory.appendingPathComponent("mixed-pages.pdf")
        try pdf.dataRepresentation()!.write(to: url)
        guard let prepared = store.preparePDF(url, folderID: nil) else { throw NSError(domain: "prepare", code: 1) }
        try check(prepared.pages.count == 3 && prepared.pages[1].height == 1536, "rotation dimensions")
        let cancelledCount = store.library.notebooks.count
        _ = store.preparePDF(url, folderID: nil)
        try check(store.library.notebooks.count == cancelledCount, "prepare must not commit")
        guard let pagedID = store.importPDF(prepared, layout: .paged), let joinedID = store.importPDF(prepared, layout: .continuous),
              let joined = store.note(joinedID), let paged = store.note(pagedID) else { throw NSError(domain: "import", code: 1) }
        try check(paged.pages.count == 3 && joined.pages.count == 1, "layout selection")
        let page = joined.pages[0]
        try check(page.height == 3776 && PageRenderer.hasValidPDFBackground(page: page, note: joined, store: store), "joined background validation")
        let image = PageRenderer.snapshot(page: page, note: joined, drawing: PKDrawing(), store: store, width: 384)
        try image.pngData()!.write(to: directory.appendingPathComponent("joined.png"))
        try prepared.data.write(to: directory.appendingPathComponent("fixture.pdf"))
        for (index, region) in page.pdfRegions.enumerated() {
            let pixel = color(image, y: (region.y + region.height * 0.5) * 0.5)
            try check(pixel[index] > 200 && pixel[(index + 1) % 3] < 80, "background order / rotation \(index): \(pixel)")
        }
        try image.pngData()!.write(to: directory.appendingPathComponent("joined.png"))
        let points = [CGPoint(x: 120, y: 930), CGPoint(x: 150, y: 990)].enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.1, size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: points, creationDate: Date()))
        store.queueDrawing(PKDrawing(strokes: [stroke]), noteID: joinedID, pageID: page.id)
        try check(store.flushDrawings(), "save drawing")
        let reopened = NoteStore()
        let drawing = try reopened.drawing(noteID: joinedID, pageID: page.id)
        try check(drawing.strokes.count == 1 && drawing.bounds.minY < 960 && drawing.bounds.maxY > 960, "cross-boundary ink survives reopen")
        try checkRegionCapture(reopened, joined: joined, drawing: drawing)
        let output = try ExportService.exportPDF(note: joined, store: reopened)
        let exported = PDFDocument(url: output)!
        try check(exported.pageCount == 1 && exported.page(at: 0)!.bounds(for: .mediaBox).height == 3776, "continuous PDF export")
        let pagedOutput = try ExportService.exportPDF(note: paged, store: reopened)
        try check(PDFDocument(url: pagedOutput)?.pageCount == 3, "paged PDF export")
        let png = try ExportService.exportPNG(note: joined, page: page, store: reopened)
        try check(UIImage(contentsOfFile: png.path) != nil, "continuous PNG export")
        guard let copyID = reopened.duplicate(joinedID), let copy = reopened.note(copyID) else { throw NSError(domain: "duplicate", code: 1) }
        try check(copy.pages == joined.pages && PageRenderer.hasValidPDFBackground(page: copy.pages[0], note: copy, store: reopened), "continuous duplicate assets")
        try checkViewport(store, prepared: prepared)
        try checkPageReplacement(store)
        try checkEraserPersistence(store)
        try checkRectangularInk(store)
        try checkEditorViewport(store)
        try checkInkToolPreferences()
        guard let coloredProjectID = store.createProject(title: "Project color regression", cover: .rose) else {
            throw NSError(domain: "project color fixture", code: 1)
        }
        try check(store.updateProject(coloredProjectID, title: "Renamed project", agentInstructions: "Keep the color"), "legacy project editing API succeeds")
        try check(store.project(coloredProjectID)?.cover == .rose && NoteStore().project(coloredProjectID)?.cover == .rose,
                  "project color survives legacy rename path and store reopen")
        store.deleteProject(coloredProjectID)
        try checkToolDocking()
        let manager = UndoManager(); manager.groupsByEvent = false
        let card = PageElement(kind: .text, text: "Proof: \\(x^2\\)")
        manager.beginUndoGrouping()
        store.setAIElement(noteID: joinedID, pageID: joined.pages[0].id, element: card, present: true, undoManager: manager)
        manager.endUndoGrouping()
        try check(store.note(joinedID)!.pages[0].elements.contains(card), "answer card inserted without replacing ink")
        manager.undo()
        try check(!store.note(joinedID)!.pages[0].elements.contains(card), "answer card undo")
        manager.redo()
        try check(store.note(joinedID)!.pages[0].elements.contains(card), "answer card redo")
        if !CommandLine.arguments.contains("--drawing-engine") && !CommandLine.arguments.contains("--plan-self-check") {
            report("PASS: rectangle selection checks (hit/mask/move/resize/copy/cut/paste/undo/redo/reopen); bounded region capture; PDF/ink seam alignment; rotated region PDF text; page render replacement; blank and existing ink destinations; stale callback rejection; selected pen preservation; bounded native PencilKit viewport; deep scrolling; zoom/background coordinates; repeated update stability; rotated and mixed-size PDF preparation; prepare without commit; both layouts; joined background pixel order; cross-boundary drawing save/reopen; continuous and paged PDF export; PNG export; duplicated assets")
        }
        return joinedID
    }
}

// Test-only delegate observes genuine touch strokes without changing their coordinates.
@MainActor final class LiveInkProbe: NSObject, ObservableObject, PKCanvasViewDelegate {
    @Published var status = "READY"
    @Published var shapeStatus = "NO SNAP"
    @Published var shapeEditData = "{}"
    weak var session: DrawingSession?
    weak var host: CanvasHostView?
    private var offset = CGPoint.zero
    private var zoom: CGFloat = 1
    private var previousBounds: [CGRect] = []
    private var startPoint = CGPoint.zero
    private var active = false
    private var shapeBackgroundBefore: UIImage?
    private var failure: String?
    private var frames = 0
    private var timer: Timer?

    func attach(session: DrawingSession, host: CanvasHostView) {
        self.session = session; self.host = host
        session.canvas.delegate = self
        if CommandLine.arguments.contains("--shape-held") {
            session.shapeCompletionForTesting.acceptsTestTouches = true
            session.shapeCompletionForTesting.onPreviewForTesting = { [weak self, weak session, weak host] drawing in
                guard let self, let session, let host else { return }
                self.shapeStatus = self.active && session.canvas.layer.opacity == 1 ? "SNAPPED WHILE HELD" : "FAIL: not held"
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
                    guard self.active else { self.shapeStatus = "FAIL: preview needed lift"; return }
                    let format = UIGraphicsImageRendererFormat(); format.scale = 1
                    let image = UIGraphicsImageRenderer(bounds: host.bounds, format: format).image { _ in
                        host.drawHierarchy(in: host.bounds, afterScreenUpdates: true)
                    }
                    if let before=self.shapeBackgroundBefore {
                        var differences=0
                        // Probe well outside this test's diagonal stroke, on the
                        // actual displayed PDF surface while contact remains down.
                        for fraction in [CGFloat(0.15),0.25,0.7,0.85] {
                            let y=host.bounds.height*fraction
                            let a=PDFIntegrationChecks.color(before,y:y,x:host.bounds.midX), b=PDFIntegrationChecks.color(image,y:y,x:host.bounds.midX)
                            if zip(a,b).contains(where:{abs(Int($0)-Int($1))>3}) { differences += 1 }
                        }
                        if differences>0 { self.shapeStatus="FAIL: held background changed" }
                        // Verify displayed ink itself, not only the controller state
                        // and paper pixels. Sample the fitted segment on screen.
                        if let stroke=drawing.strokes.last {
                            let points=Array(stroke.path)
                            var visibleInk=0
                            for n in 1...12 where !points.isEmpty {
                                let p=points[min(points.count-1,n*(points.count-1)/13)].location.applying(stroke.transform).applying(host.documentToViewport)
                                guard host.bounds.insetBy(dx:3,dy:3).contains(p) else { continue }
                                for dx in [-1.0,0,1] {
                                    let a=PDFIntegrationChecks.color(before,y:p.y,x:p.x+dx),b=PDFIntegrationChecks.color(image,y:p.y,x:p.x+dx)
                                    if zip(a.prefix(3),b.prefix(3)).map({abs(Int($0)-Int($1))}).reduce(0,+)>50 { visibleInk += 1 }
                                }
                            }
                            if visibleInk<2 { self.shapeStatus="FAIL: snapped ink disappeared while held" }
                        }
                        try? before.pngData()?.write(to:PDFIntegrationChecks.directory.appendingPathComponent("shape-live-before.png"))
                    } else { self.shapeStatus="FAIL: missing background reference" }
                    try? image.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("shape-held.png"))
                    try? drawing.dataRepresentation().write(to: PDFIntegrationChecks.directory.appendingPathComponent("shape-preview.drawing"))
                }
            }
        }
    }
    // Fixture setup uses the production automatic-selection entry point; the
    // subsequent move/resize/deselect are real XCTest UIKit touches.
    func seedEditableShape() {
        guard let session, let host else { return }
        let center=CGPoint(x:host.bounds.width*0.5,y:host.bounds.height*0.42)
        let corners=[CGPoint(x:-90,y:-60),CGPoint(x:90,y:-60),CGPoint(x:90,y:60),CGPoint(x:-90,y:60),CGPoint(x:-90,y:-60)]
        let points=corners.map { p -> CGPoint in
            let r=ShapeEditMath.rotate(p,angle:0.25)
            return CGPoint(x:center.x+r.x,y:center.y+r.y).applying(host.documentToViewport.inverted())
        }
        let result=ShapeRecognitionResult(kind:.rectangle,confidence:1,normalizedError:0,fittedPoints:points)
        let native=PKStroke(ink:PKInk(.pen,color:.blue),path:PKStrokePath(controlPoints:points.enumerated().map { i,p in
            PKStrokePoint(location:p,timeOffset:Double(i),size:CGSize(width:3,height:3),opacity:1,force:1,azimuth:0,altitude:.pi/2)
        },creationDate:Date()))
        let fitted=ShapeStrokeCompleter.replacement(source:PKDrawing(strokes:[native]),baseline:PKDrawing(),result:result)!
        session.commitDrawing(fitted,action:"Fixture")
        host.activateAutomaticShape(result,ids:Set(fitted.strokes.map(InkStrokeID.init)))
        inspectEditableShape()
    }
    func inspectEditableShape() {
        guard let session, let host else { return }
        var data:[String:Any] = ["ready":host.hasAutomaticShapeSelection,"count":session.canvas.drawing.strokes.count,
                                "preview":host.isShowingInkPreview,"tool":session.selectedTool.rawValue]
        if let frame=host.automaticShapeFrame {
            func screen(_ p:CGPoint)->[Double] {
                let p=host.convert(p.applying(host.documentToViewport),to:nil)
                return [Double(p.x),Double(p.y)]
            }
            data["center"]=screen(frame.center); data["corners"]=frame.corners.map(screen)
            data["width"]=frame.width;data["height"]=frame.height
        }
        shapeEditData=String(data:try! JSONSerialization.data(withJSONObject:data,options:.sortedKeys),encoding:.utf8)!
    }
    func navigate(_ fraction: CGFloat, factor: CGFloat) {
        guard let canvas = session?.canvas else { return }
        canvas.setZoomScale(canvas.minimumZoomScale * factor, animated: false)
        canvas.setContentOffset(CGPoint(x: 0, y: max(0, canvas.contentSize.height - canvas.bounds.height) * fraction), animated: false)
        status = "READY"
    }
    private func sample() {
        guard active, let canvas = session?.canvas, let host else { return }
        frames += 1
        if abs(canvas.contentOffset.x - offset.x) > 0.5 || abs(canvas.contentOffset.y - offset.y) > 0.5 || canvas.zoomScale != zoom || canvas.frame != host.bounds {
            failure = "viewport shifted during touch"
        }
    }
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        session?.canvasViewDidBeginUsingTool(canvasView)
        guard let host else { return }
        offset = canvasView.contentOffset; zoom = canvasView.zoomScale
        previousBounds = canvasView.drawing.strokes.map(\.renderBounds)
        startPoint = canvasView.drawingGestureRecognizer.location(in: host).applying(host.documentToViewport.inverted())
        failure = nil; frames = 0; active = true; status = "DRAWING"
        if CommandLine.arguments.contains("--shape-held") {
            shapeStatus = "WAITING"
            let format=UIGraphicsImageRendererFormat(); format.scale=1
            shapeBackgroundBefore=UIGraphicsImageRenderer(bounds:host.bounds,format:format).image { _ in
                host.drawHierarchy(in:host.bounds,afterScreenUpdates:false)
            }
        }
        if CommandLine.arguments.contains("--native-held-probe") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self, weak canvasView] in
                guard let self, let canvasView, self.active else { return }
                let drawing = canvasView.drawing
                let value: [String: Any] = ["contactActive": self.active,
                    "beforeCount": self.previousBounds.count, "heldCount": drawing.strokes.count,
                    "lastPathCount": drawing.strokes.last?.path.count ?? 0,
                    "lastTime": drawing.strokes.last?.path.last?.timeOffset ?? -1]
                if let bytes = try? JSONSerialization.data(withJSONObject: value, options: .prettyPrinted) {
                    try? bytes.write(to: PDFIntegrationChecks.directory.appendingPathComponent("native-held-probe.json"))
                }
            }
        }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        session?.canvasViewDidEndUsingTool(canvasView)
        sample(); active = false; timer?.invalidate(); timer = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak canvasView] in
            guard let self, let canvasView else { return }
            let strokes = canvasView.drawing.strokes
            if strokes.count != self.previousBounds.count + 1 { self.failure = "stroke missing after touch" }
            if Array(strokes.prefix(self.previousBounds.count)).map(\.renderBounds) != self.previousBounds { self.failure = "existing ink changed position" }
            if let first = strokes.last?.path.first?.location,
               hypot(first.x - self.startPoint.x, first.y - self.startPoint.y) * self.zoom > 25 {
                self.failure = "ink does not begin at touch location"
            }
            if self.frames < 5 { self.failure = "too few live samples" }
            if CommandLine.arguments.contains("--shape-held"), self.shapeStatus == "SNAPPED WHILE HELD" {
                let phase = self.session?.shapeCompletionForTesting.phase
                if phase != .finished || canvasView.layer.opacity != 1 {
                    self.failure = "held shape did not finish native render handoff: \(self.session?.shapeCompletionForTesting.handoffDiagnostics ?? "missing")"
                }
            }
            self.status = self.failure.map { "FAIL: \($0)" } ?? "PASS: \(strokes.count) strokes, \(self.frames) live samples"
        }
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { session?.canvasViewDrawingDidChange(canvasView) }
    func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) { session?.canvasViewDidFinishRendering(canvasView) }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { session?.scrollViewDidScroll(scrollView); sample() }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { session?.scrollViewDidZoom(scrollView); sample() }
}

private struct LiveCanvasRegressionView: View {
    let note: Notebook
    @EnvironmentObject private var store: NoteStore
    @StateObject private var session = DrawingSession()
    @StateObject private var probe = LiveInkProbe()
    var body: some View {
        VStack {
            HStack {
                Button("Top") { probe.navigate(0, factor: 1) }.accessibilityIdentifier("top")
                Button("Middle") { probe.navigate(0.5, factor: 1.8) }.accessibilityIdentifier("middle")
                Button("Bottom") { probe.navigate(0.98, factor: 3) }.accessibilityIdentifier("bottom")
            }.buttonStyle(.bordered).padding()
            Text(probe.status).accessibilityIdentifier("ink-status")
            if CommandLine.arguments.contains("--shape-held") {
                Text(probe.shapeStatus).accessibilityIdentifier("shape-status")
            }
            if CommandLine.arguments.contains("--shape-edit") {
                HStack {
                    Button("Seed shape") { probe.seedEditableShape() }.accessibilityIdentifier("seed-shape")
                    Button("Inspect shape") { probe.inspectEditableShape() }.accessibilityIdentifier("inspect-shape")
                }
                Text(probe.shapeEditData).font(.caption2).lineLimit(1).accessibilityIdentifier("shape-edit-data")
            }
            LiveCanvasSurface(note: note, store: store, session: session, probe: probe)
        }
    }
}

private struct LiveCanvasSurface: UIViewRepresentable {
    let note: Notebook
    let store: NoteStore
    @ObservedObject var session: DrawingSession
    let probe: LiveInkProbe
    func makeUIView(context: Context) -> CanvasHostView {
        let host = CanvasHostView(session: session)
        session.host = host
        session.load(noteID: note.id, pageID: note.pages[0].id, store: store)
        probe.attach(session: session, host: host)
        return host
    }
    func updateUIView(_ host: CanvasHostView, context: Context) {
        host.configure(note: note, page: note.pages[0], store: store, fingerDrawing: true,
                       editingObjects: false, toolsVisible: false, onSelect: { _ in },
                       onMove: { _, _, _ in }, onTurnPage: { _ in false })
    }
}

@MainActor private final class EraserProbe: NSObject, ObservableObject, PKCanvasViewDelegate {
    weak var session: DrawingSession?
    @Published var status = "Ready"
    private var timer: Timer?
    private var original = Data()
    private var previewSamples = 0
    private var whiteTrailSamples = 0
    private var failure: String?
    var cancelWhileHeld = false

    @objc func track(_ gesture: UIGestureRecognizer) {
        guard let session else { return }
        if gesture.state == .began {
            original = session.canvas.drawing.dataRepresentation()
            previewSamples = 0
            whiteTrailSamples = 0
            failure = nil
            status = "Erasing"
            timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
        } else if gesture.state == .ended {
            timer?.invalidate(); timer = nil
            if previewSamples < 3 { failure = "too few held preview samples: \(previewSamples)" }
            else if whiteTrailSamples < 3 { failure = "too few white trail samples after crossing ink: \(whiteTrailSamples)" }
            if cancelWhileHeld {
                if session.canvas.drawing.dataRepresentation() != original { failure = "cancel deleted ink" }
            } else if !session.canvas.drawing.strokes.isEmpty { failure = "stroke not deleted on lift" }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self else { return }
                if session.canvas.layer.opacity != 1 { self.failure = "native canvas not restored after erase" }
                if let preview = session.host?.subviews.compactMap({ $0 as? StrokeEraserPreviewView }).first, !preview.isHidden {
                    self.failure = "eraser overlay not cleared after lift"
                }
                self.status = self.failure.map { "FAIL: \($0)" } ?? (self.cancelWhileHeld ? "PASS: cancelled without deletion" : "PASS: translucent preview until lift")
            }
        } else if gesture.state == .cancelled || gesture.state == .failed {
            timer?.invalidate(); timer = nil
            status = "Ready"
        }
    }
    private func sample() {
        guard let session, let host = session.host,
              let preview = host.subviews.compactMap({ $0 as? StrokeEraserPreviewView }).first,
              !preview.fadedDrawing.strokes.isEmpty else { return }
        previewSamples += 1
        if session.canvas.drawing.dataRepresentation() != original { failure = "drawing mutated before lift" }
        // This is a test probe, not the production rendering path. Capturing
        // and PNG-encoding a full 2x iPad image every timer tick can starve the
        // held gesture on a busy simulator. Sample at one pixel per point and
        // persist only the first observed white crossing.
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(bounds: host.bounds, format: format).image { _ in
            host.drawHierarchy(in: host.bounds, afterScreenUpdates: false)
        }
        func pixel(at point: CGPoint) -> [UInt8] {
            let location = point.applying(host.documentToViewport)
            let crop = image.cgImage!.cropping(to: CGRect(x: location.x * image.scale, y: location.y * image.scale, width: 1, height: 1))!
            var rgba = [UInt8](repeating: 0, count: 4)
            rgba.withUnsafeMutableBytes { bytes in
                let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                                        bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
            return rgba
        }
        let faded = pixel(at: CGPoint(x: 200, y: 376))
        if !(faded[0] > 230 && faded[1] > 130 && faded[1] < 210 && faded[2] > 130 && faded[2] < 210) {
            failure = "held stroke is not translucent: \(faded)"
        }
        let white = pixel(at: CGPoint(x: 384, y: 424))
        let whitePoint = CGPoint(x: 384, y: 424).applying(host.documentToViewport)
        let diagnostic = "samples=\(previewSamples) whiteSamples=\(whiteTrailSamples) white=\(white) location=\(whitePoint) transform=\(host.documentToViewport) bounds=\(host.bounds) imageScale=\(image.scale)\n"
        try? diagnostic.write(to: PDFIntegrationChecks.directory.appendingPathComponent("eraser-probe.txt"), atomically: true, encoding: .utf8)
        // The stroke fades as soon as its edge is touched; its center only turns
        // white after the eraser reaches it. Require several samples after crossing.
        if white.prefix(3).allSatisfy({ $0 >= 240 }) {
            if whiteTrailSamples == 0 {
                try? image.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("eraser-held.png"))
            }
            whiteTrailSamples += 1
        }
        if cancelWhileHeld && whiteTrailSamples == 3 { host.cancelStrokeErasing() }
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { session?.canvasViewDrawingDidChange(canvasView) }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) { session?.canvasViewDidEndUsingTool(canvasView) }
    func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) { session?.canvasViewDidFinishRendering(canvasView) }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { session?.scrollViewDidScroll(scrollView) }
    func scrollViewDidZoom(_ scrollView: UIScrollView) { session?.scrollViewDidZoom(scrollView) }
}

private struct EraserRegressionView: View {
    let note: Notebook
    @EnvironmentObject private var store: NoteStore
    @StateObject private var session = DrawingSession()
    @StateObject private var probe = EraserProbe()
    var body: some View {
        VStack {
            HStack {
                Button("Undo") { session.undo() }
                Button("Redo") { session.redo() }
                Button("Cancel while held") { session.selectTool(.eraser); probe.cancelWhileHeld = true }
                Button("부분 지우개") { session.selectTool(.pixelEraser) }
                Button("Fit") { session.fitPage() }
            }.buttonStyle(.bordered).padding()
            Text(probe.status).accessibilityIdentifier("eraser-status")
            Text(session.selectedTool.rawValue + " · " + String(session.inkWidth)).accessibilityIdentifier("eraser-current-tool")
            EraserSurface(note: note, store: store, session: session, probe: probe)
        }
    }
}

private struct EraserSurface: UIViewRepresentable {
    let note: Notebook
    let store: NoteStore
    @ObservedObject var session: DrawingSession
    let probe: EraserProbe
    func makeUIView(context: Context) -> CanvasHostView {
        let host = CanvasHostView(session: session)
        session.host = host
        session.load(noteID: note.id, pageID: note.pages[0].id, store: store)
        probe.session = session
        session.canvas.delegate = probe
        session.canvas.gestureRecognizers?.compactMap { $0 as? StrokeEraserGestureRecognizer }.first?.addTarget(probe, action: #selector(EraserProbe.track(_:)))
        session.selectTool(.pencil); session.inkColor = .blue; session.inkWidth = 2.5
        session.selectTool(.eraser); session.eraserWidth = 24; session.applyTool()
        return host
    }
    func updateUIView(_ host: CanvasHostView, context: Context) {
        host.configure(note: note, page: note.pages[0], store: store, fingerDrawing: true,
                       editingObjects: false, toolsVisible: false, onSelect: { _ in },
                       onMove: { _, _, _ in }, onTurnPage: { _ in false })
        // Exercise the production three-finger failure dependencies while keeping
        // the test-only controls free of the floating tool picker.
        session.canvas.pageTurningEnabled = true
        host.gestureRecognizers?.compactMap { $0 as? UISwipeGestureRecognizer }.forEach { $0.isEnabled = true }
    }
}
