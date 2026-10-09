import UIKit
import PDFKit
import PencilKit
import SwiftUI

@MainActor
enum ExportService {
    static func exportMarkdown(note: Notebook, store: NoteStore) throws -> URL {
        guard let summary = note.summary else { throw CocoaError(.fileReadCorruptFile) }
        let data = try store.summaryAsset(note.id, name: summary.bodyAsset)
        let url = try exportURL(title: note.title, extension: "md")
        try data.write(to: url, options: .atomic)
        return url
    }
    static func pageChoices(note: Notebook, store: NoteStore) throws -> [SummarySource] {
        try NoteSummaryService.pageChoices(note).flatMap { choice in
            guard let page = note.pages.first(where: { $0.id == choice.pageID }), page.isInfinite else { return [choice] }
            let drawing = try store.drawing(noteID: note.id, pageID: page.id)
            return try CanvasExtent.exportPages(CanvasExtent.usedBounds(ink: drawing.bounds, elements: page.elements)).enumerated().map { index, rect in
                SummarySource(id: "\(page.id)-\(index)", pageID: page.id, label: "영역 \(index + 1)", rect: rect)
            }
        }
    }

    static func exportPDF(note: Notebook, store: NoteStore, selection: Set<String>? = nil,
                          progress: (Int, Int) -> Void = { _, _ in }) async throws -> URL {
        if note.summary != nil { return try exportMarkdown(note: note, store: store) }
        guard store.flushDrawings() else { throw CocoaError(.fileWriteUnknown) }
        try Task.checkCancellation()
        let choices = try pageChoices(note: note, store: store).filter { selection == nil || selection!.contains($0.id) }
        guard !choices.isEmpty else { throw SummaryError.message("내보낼 페이지를 선택해 주세요.") }
        let url = try exportURL(title: note.title, extension: "pdf")
        let directory = url.deletingLastPathComponent()
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: directory) } }
        let assets = directory.appendingPathComponent("Inputs", isDirectory: true)
        try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: assets) }
        // Freeze only selected inputs before the first suspension. Copies remain
        // valid if another editor saves, removes a page, or deletes the source.
        var names = Set<String>()
        for page in note.pages where choices.contains(where: { $0.pageID == page.id }) {
            let drawingName = "\(page.id).drawing"
            if let source = store.assetURL(noteID: note.id, name: drawingName), FileManager.default.fileExists(atPath: source.path) { names.insert(drawingName) }
            if !page.pdfRegions.isEmpty, let name = note.pdfAssetName { names.insert(name) }
            for element in page.elements where element.kind == .image && choices.contains(where: { $0.pageID == page.id && $0.rect.intersects(CGRect(x: element.x, y: element.y, width: element.width, height: element.height)) }) {
                guard let name = element.assetName else { throw CocoaError(.fileReadCorruptFile) }
                names.insert(name)
            }
        }
        for name in names {
            guard let source = store.assetURL(noteID: note.id, name: name) else { throw CocoaError(.fileReadCorruptFile) }
            try FileManager.default.copyItem(at: source, to: assets.appendingPathComponent(name))
        }
        guard let output = CGContext(url as CFURL, mediaBox: nil, [kCGPDFContextTitle: note.title, kCGPDFContextCreator: AppIdentity.displayName] as CFDictionary) else { throw CocoaError(.fileWriteUnknown) }
        var closed = false
        defer { if !closed { output.closePDF() } }
        var count = 0
        progress(0, choices.count)
        await Task.yield()
        for page in note.pages {
            let regions = choices.filter { $0.pageID == page.id }
            guard !regions.isEmpty else { continue }
            try Task.checkCancellation()
            // One drawing is retained per canvas, including all continuous PDF segments.
            let drawingURL = assets.appendingPathComponent("\(page.id).drawing")
            let drawing = try autoreleasepool {
                try FileManager.default.fileExists(atPath: drawingURL.path) ? PKDrawing(data: Data(contentsOf: drawingURL)) : PKDrawing()
            }
            for choice in regions {
                try Task.checkCancellation()
                try autoreleasepool {
                    let region = choice.rect
                    for segment in page.pdfRegions where region.intersects(CGRect(x: 0, y: segment.y, width: page.width, height: segment.height)) {
                        var source = page; source.pdfPageIndex = segment.pageIndex
                        guard PageRenderer.pdfPage(note: note, page: source, store: store, assetDirectory: assets) != nil else { throw CocoaError(.fileReadCorruptFile) }
                    }
                    for element in page.elements where element.kind == .image && region.intersects(CGRect(x: element.x, y: element.y, width: element.width, height: element.height)) {
                        guard let name = element.assetName, PageRenderer.image(noteID: note.id, name: name, store: store, assetDirectory: assets) != nil else { throw CocoaError(.fileReadCorruptFile) }
                    }
                    var bounds = CGRect(origin: .zero, size: region.size)
                    output.beginPDFPage([kCGPDFContextMediaBox: NSData(bytes: &bounds, length: MemoryLayout<CGRect>.size)] as CFDictionary)
                    output.saveGState()
                    output.translateBy(x: 0, y: region.height)
                    output.scaleBy(x: 1, y: -1)
                    output.translateBy(x: -region.minX, y: -region.minY)
                    output.clip(to: region)
                    UIGraphicsPushContext(output)
                    UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                        PageRenderer.drawBackground(page: page, note: note, store: store, context: output, assetDirectory: assets)
                        let scale = min(2, 4096 / max(region.width, region.height))
                        if drawing.bounds.intersects(region) { drawing.image(from: region, scale: scale).draw(in: region) }
                    }
                    UIGraphicsPopContext()
                    output.restoreGState()
                    output.endPDFPage()
                }
                count += 1; progress(count, choices.count)
                // UIKit/PencilKit rendering stays on the main actor; release each
                // raster and return control between pages so UI/cancellation can run.
                await Task.yield()
            }
        }
        try Task.checkCancellation()
        output.closePDF(); closed = true
        guard let document = PDFDocument(url: url), document.pageCount == choices.count else { throw CocoaError(.fileWriteUnknown) }
        completed = true
        return url
    }

    static func exportPNG(note: Notebook, page: NotePage, store: NoteStore) throws -> URL {
        if !PageRenderer.hasValidPDFBackground(page: page, note: note, store: store) {
            throw CocoaError(.fileReadCorruptFile)
        }
        let url = try exportURL(title: note.title, extension: "png")
        let drawing = try store.drawing(noteID: note.id, pageID: page.id)
        let width = min(1536, 4096 * page.width / max(page.width, page.height))
        guard let data = PageRenderer.snapshot(page: page, note: note, drawing: drawing, store: store, width: width).pngData() else {
            throw CocoaError(.fileWriteUnknown)
        }
        try data.write(to: url, options: .atomic)
        return url
    }

    private static func exportURL(title: String, extension suffix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Exports", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeTitle = String(title.map { "/\\:?%*|\"<>".contains($0) ? "_" : $0 }.prefix(80))
        return directory.appendingPathComponent(safeTitle.isEmpty ? "노트" : safeTitle).appendingPathExtension(suffix)
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let urls: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: urls, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) { }
}
