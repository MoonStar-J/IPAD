import UIKit
import PDFKit
import PencilKit

@MainActor
enum PageRenderer {
    private static let documents = NSCache<NSURL, PDFDocument>()
    private static let images = NSCache<NSURL, UIImage>()

    static func pdfPage(note: Notebook, page: NotePage, store: NoteStore) -> PDFPage? {
        guard let name = note.pdfAssetName, let index = page.pdfPageIndex,
              let url = store.assetURL(noteID: note.id, name: name) else { return nil }
        let key = url as NSURL
        let document: PDFDocument?
        if let cached = documents.object(forKey: key) { document = cached }
        else {
            document = PDFDocument(url: url)
            if let document { documents.setObject(document, forKey: key); documents.countLimit = 4 }
        }
        return document?.page(at: index)
    }

    static func image(noteID: UUID, name: String, store: NoteStore) -> UIImage? {
        guard let url = store.assetURL(noteID: noteID, name: name) else { return nil }
        let key = url as NSURL
        if let cached = images.object(forKey: key) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        images.setObject(image, forKey: key, cost: Int(image.size.width * image.size.height * 4))
        images.totalCostLimit = 64 * 1024 * 1024
        return image
    }

    static func drawBackground(page: NotePage, note: Notebook, store: NoteStore, context: CGContext) {
        let bounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
        context.setFillColor(UIColor.white.cgColor)
        context.fill(bounds)
        if let pdf = pdfPage(note: note, page: page, store: store)?.pageRef {
            context.saveGState()
            context.translateBy(x: 0, y: bounds.height)
            context.scaleBy(x: 1, y: -1)
            context.concatenate(pdf.getDrawingTransform(.mediaBox, rect: bounds, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(pdf)
            context.restoreGState()
        } else {
            context.setStrokeColor(UIColor(red: 0.78, green: 0.81, blue: 0.84, alpha: 0.65).cgColor)
            context.setFillColor(UIColor(red: 0.69, green: 0.73, blue: 0.78, alpha: 0.65).cgColor)
            context.setLineWidth(0.6)
            switch page.paper {
            case .plain: break
            case .ruled:
                for y in stride(from: 80.0, to: page.height - 36, by: 32) {
                    context.move(to: CGPoint(x: 40, y: y)); context.addLine(to: CGPoint(x: page.width - 40, y: y))
                }
                context.strokePath()
            case .grid:
                for x in stride(from: 32.0, to: page.width, by: 24) {
                    context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: page.height))
                }
                for y in stride(from: 32.0, to: page.height, by: 24) {
                    context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: page.width, y: y))
                }
                context.strokePath()
            case .dotted:
                for x in stride(from: 32.0, to: page.width - 20, by: 24) {
                    for y in stride(from: 32.0, to: page.height - 20, by: 24) {
                        context.fillEllipse(in: CGRect(x: x, y: y, width: 1.8, height: 1.8))
                    }
                }
            }
        }
        for element in page.elements {
            let rect = CGRect(x: element.x, y: element.y, width: element.width, height: element.height)
            switch element.kind {
            case .text:
                let paragraph = NSMutableParagraphStyle()
                paragraph.lineBreakMode = .byWordWrapping
                (element.text as NSString).draw(in: rect, withAttributes: [
                    .font: UIFont.systemFont(ofSize: element.fontSize),
                    .foregroundColor: UIColor.black,
                    .paragraphStyle: paragraph
                ])
            case .image:
                if let name = element.assetName, let image = image(noteID: note.id, name: name, store: store) {
                    let ratio = min(rect.width / image.size.width, rect.height / image.size.height)
                    let size = CGSize(width: image.size.width * ratio, height: image.size.height * ratio)
                    image.draw(in: CGRect(x: rect.midX - size.width / 2, y: rect.midY - size.height / 2, width: size.width, height: size.height))
                }
            }
        }
    }

    static func snapshot(page: NotePage, note: Notebook, drawing: PKDrawing, store: NoteStore, width: CGFloat) -> UIImage {
        let size = CGSize(width: width, height: width * page.height / page.width)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        return UIGraphicsImageRenderer(size: size, format: format).image { output in
            output.cgContext.scaleBy(x: width / page.width, y: width / page.width)
            drawBackground(page: page, note: note, store: store, context: output.cgContext)
            let rect = CGRect(x: 0, y: 0, width: page.width, height: page.height)
            drawing.image(from: rect, scale: max(width / page.width, 0.2)).draw(in: rect)
        }
    }
}

final class PaperView: UIView {
    var render: ((CGContext) -> Void)? { didSet { setNeedsDisplay() } }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        render?(context)
    }
}
