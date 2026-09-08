import UIKit
import PDFKit
import PencilKit
import SwiftUI

@MainActor
enum ExportService {
    static func exportPDF(note: Notebook, store: NoteStore) throws -> URL {
        let url = try exportURL(title: note.title, extension: "pdf")
        let defaultBounds = CGRect(x: 0, y: 0, width: 768, height: 1024)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: note.title, kCGPDFContextCreator as String: AppIdentity.displayName]
        // Read every drawing before starting the export so a corrupt page cannot
        // silently disappear from the shared document.
        let drawings = try note.pages.map { try store.drawing(noteID: note.id, pageID: $0.id) }
        for page in note.pages where page.pdfPageIndex != nil {
            guard PageRenderer.pdfPage(note: note, page: page, store: store) != nil else {
                throw CocoaError(.fileReadCorruptFile)
            }
        }
        try UIGraphicsPDFRenderer(bounds: defaultBounds, format: format).writePDF(to: url) { output in
            for (page, drawing) in zip(note.pages, drawings) {
                let bounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
                output.beginPage(withBounds: bounds, pageInfo: [:])
                PageRenderer.drawBackground(page: page, note: note, store: store, context: output.cgContext)
                let scale = min(2, 4096 / max(page.width, page.height))
                drawing.image(from: bounds, scale: scale).draw(in: bounds)
            }
        }
        return url
    }

    static func exportPNG(note: Notebook, page: NotePage, store: NoteStore) throws -> URL {
        if page.pdfPageIndex != nil && PageRenderer.pdfPage(note: note, page: page, store: store) == nil {
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
