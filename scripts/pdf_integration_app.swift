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
                if CommandLine.arguments.contains("--live-ink"), noteID != nil,
                   let note = store.library.notebooks.last(where: { $0.title == "Long canvas regression" }) {
                    LiveCanvasRegressionView(note: note)
                } else if let noteID { NavigationStack { EditorView(noteID: noteID) } }
                else { ProgressView("PDF integration checks") }
            }.environmentObject(store).task {
                guard !ran else { return }; ran = true
                do { noteID = try PDFIntegrationChecks.run(store) }
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

    static func run(_ store: NoteStore) throws -> UUID {
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
        report("PASS: bounded native PencilKit viewport; deep scrolling; zoom/background coordinates; repeated update stability; rotated and mixed-size PDF preparation; prepare without commit; both layouts; joined background pixel order; cross-boundary drawing save/reopen; continuous and paged PDF export; PNG export; duplicated assets")
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
