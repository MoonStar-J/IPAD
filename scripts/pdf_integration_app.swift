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
                if let noteID { NavigationStack { EditorView(noteID: noteID) } }
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
        report("PASS: rotated and mixed-size PDF preparation; prepare without commit; both layouts; joined background pixel order; cross-boundary drawing save/reopen; continuous and paged PDF export; PNG export; duplicated assets")
        return joinedID
    }
}
