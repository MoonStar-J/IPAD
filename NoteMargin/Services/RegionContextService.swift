import UIKit
import PencilKit
import PDFKit

struct CapturedRegion {
    let pageID: UUID
    let rect: CGRect
    let imageData: Data
    let extractedText: String
    let sourceDescription: String
    let pdfPageNumbers: [Int]
}

@MainActor enum RegionContextService {
    static func capture(note: Notebook, page: NotePage, drawing: PKDrawing, store: NoteStore, rect requested: CGRect) throws -> CapturedRegion {
        guard requested.origin.x.isFinite, requested.origin.y.isFinite,
              requested.width.isFinite, requested.height.isFinite,
              page.width.isFinite, page.height.isFinite, page.width > 0, page.height > 0 else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let rect = requested.standardized.intersection(CGRect(x: 0, y: 0, width: page.width, height: page.height))
        guard !rect.isNull, rect.width >= 8, rect.height >= 8,
              rect.width.isFinite, rect.height.isFinite,
              PageRenderer.hasValidPDFBackground(page: page, note: note, store: store) else { throw CocoaError(.fileReadCorruptFile) }
        let scale = min(2, 1800 / max(rect.width, rect.height))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let size = CGSize(width: ceil(rect.width * scale), height: ceil(rect.height * scale))
        let image = UIGraphicsImageRenderer(size: size, format: format).image { output in
            // Rounding to whole pixels may leave a fractional edge outside the
            // document clip. Keep that edge white instead of opaque black.
            UIColor.white.setFill()
            output.fill(CGRect(origin: .zero, size: size))
            output.cgContext.scaleBy(x: scale, y: scale)
            output.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            output.cgContext.clip(to: rect)
            PageRenderer.drawBackground(page: page, note: note, store: store, context: output.cgContext)
            // Only the crop is rasterized, including on a 100-page continuous canvas.
            drawing.image(from: rect, scale: scale).draw(in: rect)
        }
        guard let data = image.pngData() else { throw CocoaError(.fileWriteUnknown) }
        var texts: [String] = []
        var pageNumbers: [Int] = []
        for region in page.pdfRegions where CGRect(x: 0, y: region.y, width: page.width, height: region.height).intersects(rect) {
            var source = page
            source.pdfPageIndex = region.pageIndex
            guard let pdfPage = PageRenderer.pdfPage(note: note, page: source, store: store), let pdf = pdfPage.pageRef else { continue }
            if !pageNumbers.contains(region.pageIndex + 1) { pageNumbers.append(region.pageIndex + 1) }
            // Mirror PageRenderer's PDF transform exactly, including older imports.
            // PDF selections use the original unrotated PDF coordinate system.
            var transform = CGAffineTransform(translationX: 0, y: region.y + region.height).scaledBy(x: 1, y: -1)
            var target = CGSize(width: page.width, height: region.height)
            if page.pdfFitToPage == true || page.isContinuousPDF {
                let box = pdf.getBoxRect(.mediaBox)
                let rotated = abs(pdf.rotationAngle) % 180 == 90
                let native = CGSize(width: rotated ? box.height : box.width, height: rotated ? box.width : box.height)
                if native.width > 0 && native.height > 0 {
                    transform = transform.scaledBy(x: page.width / native.width, y: region.height / native.height)
                    target = native
                }
            }
            transform = pdf.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: target), rotate: 0, preserveAspectRatio: true).concatenating(transform)
            let clipped = rect.intersection(CGRect(x: 0, y: region.y, width: page.width, height: region.height))
            let pdfRect = clipped.applying(transform.inverted()).intersection(pdf.getBoxRect(.mediaBox))
            guard !pdfRect.isNull, !pdfRect.isEmpty else { continue }
            if let text = pdfPage.selection(for: pdfRect)?.string, !text.isEmpty {
                texts.append("[PDF \(region.pageIndex + 1)페이지 선택 영역]\n\(text)")
            }
        }
        for element in page.elements where element.kind == .text {
            if rect.contains(CGRect(x: element.x, y: element.y, width: element.width, height: element.height)) {
                texts.append("[삽입한 텍스트]\n\(element.text)")
            }
        }
        let index = note.pages.firstIndex(where: { $0.id == page.id }).map { $0 + 1 } ?? 1
        return CapturedRegion(pageID: page.id, rect: rect, imageData: data,
                              extractedText: String(texts.joined(separator: "\n\n").prefix(24_000)),
                              sourceDescription: "\(note.title) · 노트 \(index)페이지" + (pageNumbers.isEmpty ? "" : " · PDF \(pageNumbers.map(String.init).joined(separator: ", "))페이지"),
                              pdfPageNumbers: pageNumbers)
    }
}
