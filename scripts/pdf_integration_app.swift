import SwiftUI
import PencilKit
import PDFKit

@main
struct NoteMarginApp: App {
    @StateObject private var store = NoteStore()
    @State private var noteID: UUID?
    @State private var ran = false
    var body: some Scene {
        WindowGroup {
            Group {
                if CommandLine.arguments.contains("--eraser"), let noteID, let note = store.note(noteID) {
                    EraserRegressionView(note: note)
                } else if CommandLine.arguments.contains("--live-ink"), noteID != nil,
                   let note = store.library.notebooks.last(where: { $0.title == "Long canvas regression" }) {
                    LiveCanvasRegressionView(note: note)
                } else if let noteID { NavigationStack { EditorView(noteID: noteID) } }
                else { ProgressView("PDF integration checks") }
            }.environmentObject(store).task {
                guard !ran else { return }; ran = true
                do {
                    let checked = try PDFIntegrationChecks.run(store)
                    noteID = CommandLine.arguments.contains("--page-swap") || CommandLine.arguments.contains("--eraser") ? try PDFIntegrationChecks.pageSwapFixture(store).id : checked
                }
                catch { PDFIntegrationChecks.report("FAIL: \(error)") }
            }
        }
    }
}

@MainActor enum PDFIntegrationChecks {
    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw NSError(domain: message, code: 1) }
    }
    static var directory: URL { FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0] }
    static func report(_ text: String) { try? text.write(to: directory.appendingPathComponent("results.txt"), atomically: true, encoding: .utf8) }
    static func color(_ image: UIImage, y: CGFloat) -> [UInt8] {
        let crop = image.cgImage!.cropping(to: CGRect(x: 100, y: y, width: 1, height: 1))!
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
        try check(!ai.send("other project", conversationID: id, note: store.note(noteID)!, project: store.project(second)),
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
        report("PASS: bounded region capture; PDF/ink seam alignment; rotated region PDF text; page render replacement; blank and existing ink destinations; stale callback rejection; selected pen preservation; bounded native PencilKit viewport; deep scrolling; zoom/background coordinates; repeated update stability; rotated and mixed-size PDF preparation; prepare without commit; both layouts; joined background pixel order; cross-boundary drawing save/reopen; continuous and paged PDF export; PNG export; duplicated assets")
        return joinedID
    }
}

// Test-only delegate observes genuine touch strokes without changing their coordinates.
@MainActor final class LiveInkProbe: NSObject, ObservableObject, PKCanvasViewDelegate {
    @Published var status = "READY"
    weak var session: DrawingSession?
    weak var host: CanvasHostView?
    private var offset = CGPoint.zero
    private var zoom: CGFloat = 1
    private var previousBounds: [CGRect] = []
    private var startPoint = CGPoint.zero
    private var active = false
    private var failure: String?
    private var frames = 0
    private var timer: Timer?

    func attach(session: DrawingSession, host: CanvasHostView) {
        self.session = session; self.host = host
        session.canvas.delegate = self
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
        guard let host else { return }
        offset = canvasView.contentOffset; zoom = canvasView.zoomScale
        previousBounds = canvasView.drawing.strokes.map(\.renderBounds)
        startPoint = canvasView.drawingGestureRecognizer.location(in: host).applying(host.documentToViewport.inverted())
        failure = nil; frames = 0; active = true; status = "DRAWING"
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.sample() }
        }
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
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
            self.status = self.failure.map { "FAIL: \($0)" } ?? "PASS: \(strokes.count) strokes, \(self.frames) live samples"
        }
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { session?.canvasViewDrawingDidChange(canvasView) }
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
            if previewSamples < 3 { failure = "no held preview samples" }
            if whiteTrailSamples < 3 { failure = "no white trail after crossing ink" }
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
        let image = UIGraphicsImageRenderer(bounds: host.bounds).image { _ in
            host.drawHierarchy(in: host.bounds, afterScreenUpdates: false)
        }
        try? image.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("eraser-held.png"))
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
        // The stroke fades as soon as its edge is touched; its center only turns
        // white after the eraser reaches it. Require several samples after crossing.
        if white.prefix(3).allSatisfy({ $0 >= 240 }) { whiteTrailSamples += 1 }
        if cancelWhileHeld && whiteTrailSamples == 3 { host.cancelStrokeErasing() }
    }
    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) { session?.canvasViewDrawingDidChange(canvasView) }
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
                Button("Cancel while held") { probe.cancelWhileHeld = true }
                Button("Fit") { session.fitPage() }
            }.buttonStyle(.bordered).padding()
            Text(probe.status).accessibilityIdentifier("eraser-status")
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
        session.canvas.tool = PKEraserTool(.vector, width: 24)
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
