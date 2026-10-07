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

    static func hasValidPDFBackground(page: NotePage, note: Notebook, store: NoteStore) -> Bool {
        page.pdfRegions.allSatisfy { region in
            var source = page
            source.pdfPageIndex = region.pageIndex
            return pdfPage(note: note, page: source, store: store) != nil
        }
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
        if !page.pdfRegions.isEmpty {
            for region in page.pdfRegions {
                let rect = CGRect(x: 0, y: region.y, width: page.width, height: region.height)
                guard context.boundingBoxOfClipPath.intersects(rect) else { continue }
                var source = page
                source.pdfPageIndex = region.pageIndex
                guard let pdf = pdfPage(note: note, page: source, store: store)?.pageRef else { continue }
                context.saveGState()
                context.clip(to: rect)
                context.translateBy(x: 0, y: rect.maxY)
                context.scaleBy(x: 1, y: -1)
                var target = CGSize(width: page.width, height: region.height)
                if page.pdfFitToPage == true || page.isContinuousPDF {
                    // Quartz centers small PDFs without enlarging them. Explicitly scale
                    // new imports; keep older notebooks' background/ink alignment unchanged.
                    let box = pdf.getBoxRect(.mediaBox)
                    let rotated = abs(pdf.rotationAngle) % 180 == 90
                    let native = CGSize(width: rotated ? box.height : box.width, height: rotated ? box.width : box.height)
                    if native.width > 0 && native.height > 0 {
                        context.scaleBy(x: page.width / native.width, y: region.height / native.height)
                        target = native
                    }
                }
                context.concatenate(pdf.getDrawingTransform(.mediaBox, rect: CGRect(origin: .zero, size: target), rotate: 0, preserveAspectRatio: true))
                context.drawPDFPage(pdf)
                context.restoreGState()
            }
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
            drawing.image(from: rect, scale: max(width / page.width, 0.001)).draw(in: rect)
        }
    }
}

/// The PDF is rasterized only when a tile enters the viewport or its content
/// changes. Pan/pinch moves existing tiles in the same transaction as native ink.
/// A long stitched PDF never allocates a page-sized bitmap.
final class PaperView: UIView {
    var render: ((CGContext) -> Void)? { didSet { invalidateTiles() } }
    var documentBounds = CGRect.zero
    private let documentLayer = CALayer()
    private var tiles: [String: CALayer] = [:]
    private var rasterScale: CGFloat = 0
    private var lastTransform = CGAffineTransform.identity
    private var lastViewport = CGRect.zero
    private var refinement: Task<Void, Never>?
    private var drawingActive = false
    private(set) var rasterizationCount = 0
    private(set) var viewportTransform = CGAffineTransform.identity

    override init(frame: CGRect) {
        super.init(frame: frame)
        clipsToBounds = true
        documentLayer.anchorPoint = .zero
        layer.addSublayer(documentLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func invalidateTiles() {
        refinement?.cancel()
        tiles.values.forEach { $0.removeFromSuperlayer() }
        tiles.removeAll()
        rasterScale = 0
    }

    func updateViewport(_ transform: CGAffineTransform, viewport: CGRect, interacting: Bool) {
        guard !viewport.isEmpty, !documentBounds.isEmpty, transform.a > 0 else { return }
        let changed = transform != lastTransform || viewport != lastViewport || tiles.isEmpty
        lastTransform = transform; lastViewport = viewport
        viewportTransform = transform
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Native UIScrollView bounds already supplies -contentOffset. Paper is
        // its document-space child, so applying that translation again is wrong.
        layer.anchorPoint = .zero
        layer.position = .zero
        bounds = documentBounds
        layer.setAffineTransform(CGAffineTransform(scaleX: transform.a, y: transform.d))
        documentLayer.setAffineTransform(.identity)
        CATransaction.commit()
        // Quantized levels avoid rerasterizing at every fractional pinch scale.
        let desired = pow(2, ceil(log2(max(0.0625, transform.a * traitCollection.displayScale))))
        // A large zoom-out must not retain hundreds of high-resolution tiles.
        let area = viewport.width * viewport.height / (transform.a * transform.a)
        if rasterScale == 0 || area * rasterScale * rasterScale / (768 * 768) > 64 { rasterScale = desired }
        if changed { fillVisibleTiles() }
        refinement?.cancel()
        if rasterScale != desired && !drawingActive {
            refinement = Task { [weak self] in
                do { try await Task.sleep(for: .milliseconds(interacting ? 180 : 80)) } catch { return }
                guard let self else { return }
                self.rasterScale = desired
                self.fillVisibleTiles()
            }
        }
    }

    /// Share immutable tile CGImages with interaction overlays. No image render
    /// or GPU readback; document coordinates remain unchanged.
    func copyCachedTiles(to target: CALayer, fill: CGColor? = UIColor.white.cgColor) {
        target.sublayers?.forEach { $0.removeFromSuperlayer() }
        target.anchorPoint = .zero; target.position = .zero
        target.bounds = documentBounds; target.backgroundColor = fill
        for tile in tiles.values {
            let copy = CALayer(); copy.frame = tile.frame
            copy.contents = tile.contents; copy.contentsScale = tile.contentsScale
            target.addSublayer(copy)
        }
    }

    func setDrawingActive(_ active: Bool) {
        drawingActive = active
        if active { refinement?.cancel() }
        else { updateViewport(lastTransform, viewport: lastViewport, interacting: false) }
    }

    private func fillVisibleTiles() {
        guard let render, rasterScale > 0 else { return }
        // 768px tiles, one tile of overscan. Cache size follows the viewport,
        // not document length; old resolution remains until replacements exist.
        let side = 768 / rasterScale
        let visible = lastViewport.applying(lastTransform.inverted())
            .insetBy(dx: -side, dy: -side).intersection(documentBounds)
        guard !visible.isNull, !visible.isEmpty else { return }
        var retained = Set<String>()
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for row in Int(floor(visible.minY / side))...Int(floor(visible.maxY / side)) {
            for column in Int(floor(visible.minX / side))...Int(floor(visible.maxX / side)) {
                let key = "\(rasterScale):\(column):\(row)"
                let rect = CGRect(x: CGFloat(column) * side, y: CGFloat(row) * side, width: side, height: side).intersection(documentBounds)
                guard !rect.isEmpty, !rect.isNull else { continue }
                retained.insert(key)
                guard tiles[key] == nil else { continue }
                let format = UIGraphicsImageRendererFormat(); format.scale = rasterScale; format.opaque = true
                let image = UIGraphicsImageRenderer(size: rect.size, format: format).image { output in
                    output.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
                    output.cgContext.clip(to: rect)
                    render(output.cgContext)
                }
                let tile = CALayer(); tile.frame = rect; tile.contents = image.cgImage
                tile.contentsScale = rasterScale
                documentLayer.addSublayer(tile); tiles[key] = tile
                rasterizationCount += 1
            }
        }
        for key in Array(tiles.keys) where !retained.contains(key) {
            tiles.removeValue(forKey: key)?.removeFromSuperlayer()
        }
        CATransaction.commit()
    }
}
