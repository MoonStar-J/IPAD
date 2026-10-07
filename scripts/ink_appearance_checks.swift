import UIKit
import PencilKit

/// Compare production interaction presentation to PencilKit's renderer, rather
/// than to a second approximation of its pressure/opacity/texture semantics.
@MainActor func checkInkAppearance() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        try PDFIntegrationChecks.check(condition(), "ink appearance: " + message)
    }
    let viewport = CGRect(x: 0, y: 0, width: 360, height: 390)
    let rows: [CGFloat] = [50, 140, 230, 320]
    let kinds: [PKInkingTool.InkType] = [.pen, .pencil, .marker, .monoline]
    let names = ["pen", "pencil", "marker", "monoline"]
    var report = ["scope=synthetic PencilKit native-image vs production-preview comparison; not live Pencil latency"]
    func saveReport() throws {
        try report.joined(separator: "\n").write(to: PDFIntegrationChecks.directory.appendingPathComponent("ink-appearance.txt"), atomically: true, encoding: .utf8)
    }
    struct Pixels {
        let image: CGImage
        let scale: CGFloat
        init(_ image: UIImage) { self.image = image.cgImage!; scale = image.scale }
        func metrics(in rect: CGRect) -> (mass: Double, area: Int) {
            let x0 = max(0, Int(floor(rect.minX * scale))), x1 = min(image.width, Int(ceil(rect.maxX * scale)))
            let y0 = max(0, Int(floor(rect.minY * scale))), y1 = min(image.height, Int(ceil(rect.maxY * scale)))
            guard x1 > x0, y1 > y0,
                  let crop = image.cropping(to: CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)) else { return (0, 0) }
            // Crop in UIImage/CGImage pixel space before conversion, so aggregate
            // metrics do not depend on CGContext's vertical coordinate direction.
            var bytes = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
            bytes.withUnsafeMutableBytes { storage in
                let context = CGContext(data: storage.baseAddress, width: crop.width, height: crop.height,
                                        bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                        space: CGColorSpaceCreateDeviceRGB(),
                                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
            }
            var mass = 0.0, area = 0
            for i in stride(from: 0, to: bytes.count, by: 4) {
                let darkness = 255 - (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3
                mass += darkness
                if darkness > 16 { area += 1 }
            }
            return (mass, area)
        }
    }
    func assertMatches(_ reference: UIImage, _ actual: UIImage, label: String, onlyRows: [Int] = [0, 1, 2, 3]) throws {
        let original = Pixels(reference), preview = Pixels(actual)
        for row in onlyRows {
            let region = CGRect(x: 20, y: rows[row] - 33, width: 320, height: 66)
            let before = original.metrics(in: region), after = preview.metrics(in: region)
            try check(before.mass > 200 && before.area > 10, "\(label) \(names[row]) native reference contains visible ink")
            let massRatio = after.mass / max(1, before.mass)
            let areaRatio = Double(after.area) / Double(max(1, before.area))
            report.append("\(label)_\(names[row])_darkness_ratio=\(String(format: "%.5f", massRatio)); threshold_area_ratio=\(String(format: "%.5f", areaRatio))")
            try saveReport()
            // Independent bitmap crops may differ at subpixel edges; a shape
            // renderer's systematic thickening/darkening is far larger than this.
            try check((0.94...1.06).contains(massRatio), "\(label) \(names[row]) preserves native ink darkness instead of multiplying opacity")
            try check((0.92...1.08).contains(areaRatio), "\(label) \(names[row]) preserves native visible stroke width")
        }
    }

    for depth in [CGFloat.zero, 70_000] {
        let suffix = depth == 0 ? "origin" : "deep"
        let transform = CGAffineTransform(translationX: 0, y: -depth)
        let documentViewport = viewport.applying(transform.inverted())
        let strokes = kinds.indices.map { index -> PKStroke in
            let points = (0..<7).map { sample -> PKStrokePoint in
                let width: CGFloat = index == 2 ? 14 + CGFloat(sample % 3) : 2.5 + CGFloat(sample % 3) * 1.8
                let opacity: CGFloat = [0.65, 1.65, 0.9, 1.8, 0.7, 1.35, 1][sample]
                return PKStrokePoint(location: CGPoint(x: 45 + CGFloat(sample) * 42,
                                                       y: rows[index] + sin(CGFloat(sample) * 0.9) * 14),
                                     timeOffset: Double(sample) * 0.08,
                                     size: CGSize(width: width, height: index == 2 ? width * 0.6 : width),
                                     opacity: opacity, force: 0.4 + CGFloat(sample % 3) * 0.25,
                                     azimuth: CGFloat(sample) * 0.13 + .pi / 6, altitude: .pi / 3)
            }
            var stroke = PKStroke(ink: PKInk(kinds[index], color: index == 2 ? .systemBlue : .black),
                                  path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: Double(index))),
                                  transform: CGAffineTransform(translationX: 0, y: depth),
                                  mask: nil, randomSeed: UInt32(2100 + index))
            if index == 2 {
                stroke.mask = UIBezierPath(rect: CGRect(x: 95, y: rows[index] - 30, width: 160, height: 70))
            }
            return stroke
        }
        let drawing = PKDrawing(strokes: strokes)
        let originalBytes = drawing.dataRepresentation()
        let cache = InkGeometryCache(drawing: drawing)
        let selection = RectangularInkSelection(drawing: drawing, indices: [0, 2], geometryCache: cache)
        let paper = PaperView()
        paper.overrideUserInterfaceStyle = .light
        paper.documentBounds = CGRect(x: 0, y: 0, width: viewport.width, height: depth + viewport.height)
        let paperBounds = paper.documentBounds
        paper.render = { context in context.setFillColor(UIColor.white.cgColor); context.fill(paperBounds) }
        paper.updateViewport(transform, viewport: viewport, interacting: false)
        let preview = InkTransformPreview(frame: viewport)
        preview.overrideUserInterfaceStyle = .light
        let format = UIGraphicsImageRendererFormat()
        format.scale = max(1, preview.traitCollection.displayScale)
        format.opaque = true; format.preferredRange = .standard
        func renderNative(_ source: PKDrawing) -> UIImage {
            var native: UIImage!
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                native = source.image(from: documentViewport, scale: format.scale)
            }
            return UIGraphicsImageRenderer(bounds: viewport, format: format).image { output in
                UIColor.white.setFill(); output.fill(viewport)
                native.draw(in: viewport)
            }
        }
        func renderPreview(_ view: UIView) -> UIImage {
            UIGraphicsImageRenderer(bounds: viewport, format: format).image { output in
                UIColor.white.setFill(); output.fill(viewport)
                view.layer.render(in: output.cgContext)
            }
        }
        let reference = renderNative(drawing)
        preview.prepare(selection: selection, paper: paper, viewport: viewport, transform: transform)
        let identity = renderPreview(preview)
        try reference.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("ink-appearance-native-\(suffix).png"))
        try identity.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("ink-appearance-identity-\(suffix).png"))
        try assertMatches(reference, identity, label: "identity_\(suffix)")
        let rasterCount = preview.rasterizationCount
        let geometryCount = preview.geometryBuildCount
        for index in 0..<120 {
            let delta = CGAffineTransform(translationX: CGFloat(index % 15) - 7, y: 0)
            preview.moveSelection(delta, viewportTransform: transform)
        }
        let moved = CGAffineTransform(translationX: 12, y: 0)
        preview.moveSelection(moved, viewportTransform: transform)
        try check(preview.rasterizationCount == rasterCount && preview.geometryBuildCount == geometryCount,
                  "\(suffix) 120 pointer moves reuse appearance and hit geometry without new rasterization")
        let movedImage = renderPreview(preview)
        let movedReference = renderNative(selection.transformed(moved))
        try movedImage.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("ink-appearance-moved-\(suffix).png"))
        try assertMatches(movedReference, movedImage, label: "moved_\(suffix)")
        preview.clear()

        let eraser = StrokeEraserTransaction(drawing: drawing, width: 12, geometryCache: cache)
        let eraserPreview = StrokeEraserPreviewView(frame: viewport)
        eraserPreview.overrideUserInterfaceStyle = .light
        eraserPreview.begin(transaction: eraser, paper: paper, viewport: viewport, transform: transform)
        let beforeTouch = renderPreview(eraserPreview)
        try assertMatches(reference, beforeTouch, label: "eraser_down_\(suffix)")
        eraserPreview.setErased([0])
        let faded = renderPreview(eraserPreview)
        try faded.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("ink-appearance-erasing-\(suffix).png"))
        try assertMatches(reference, faded, label: "eraser_untouched_\(suffix)", onlyRows: [1, 2, 3])
        let sourceMass = Pixels(reference).metrics(in: CGRect(x: 20, y: rows[0] - 33, width: 320, height: 66)).mass
        let fadedMass = Pixels(faded).metrics(in: CGRect(x: 20, y: rows[0] - 33, width: 320, height: 66)).mass
        let fadeRatio = fadedMass / max(1, sourceMass)
        report.append("eraser_\(suffix)_selected_darkness_ratio=\(String(format: "%.5f", fadeRatio))")
        try saveReport()
        try check((0.31...0.39).contains(fadeRatio), "\(suffix) eraser changes only selected native alpha to 35 percent")
        eraserPreview.end()
        try check(drawing.dataRepresentation() == originalBytes && selection.original.dataRepresentation() == originalBytes,
                  "\(suffix) native appearance rendering never modifies saved pressure, opacity, mask or randomSeed")
        // Rendering each stroke separately must also preserve how PencilKit
        // composites overlapping translucent marker strokes as one drawing.
        var secondMarker = strokes[2]
        secondMarker.transform = CGAffineTransform(translationX: 6, y: depth + 5)
        secondMarker.randomSeed = 9123
        let markerGroup = PKDrawing(strokes: [strokes[2], secondMarker])
        let markerSelection = RectangularInkSelection(drawing: markerGroup, indices: [0, 1])
        let markerPreview = InkTransformPreview(frame: viewport)
        markerPreview.overrideUserInterfaceStyle = .light
        markerPreview.prepare(selection: markerSelection, paper: paper, viewport: viewport, transform: transform)
        let groupNative = renderNative(markerGroup)
        let groupActual = renderPreview(markerPreview)
        try groupNative.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("ink-appearance-marker-group-native-\(suffix).png"))
        try groupActual.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("ink-appearance-marker-group-preview-\(suffix).png"))
        try assertMatches(groupNative, groupActual, label: "marker_overlap_\(suffix)", onlyRows: [2])
        let overlap = CGRect(x: 155, y: rows[2] + 4, width: 30, height: 14)
        let nativeOverlap = Pixels(groupNative).metrics(in: overlap).mass
        let actualOverlap = Pixels(groupActual).metrics(in: overlap).mass
        let overlapRatio = actualOverlap / max(1, nativeOverlap)
        report.append("marker_overlap_\(suffix)_intersection_darkness_ratio=\(String(format: "%.5f", overlapRatio))")
        try saveReport()
        try check(nativeOverlap > 100 && (0.94...1.06).contains(overlapRatio),
                  "\(suffix) per-stroke cache matches the native full-drawing blend inside overlapping marker ink")
        markerPreview.clear()
        // Ordinary visible ink can be a composite tile. Explicitly prepare a
        // standalone texture before checking standalone reuse across reindexing.
        _ = cache.nativeRasterCache.tiles(for: 1, visible: documentViewport, scale: UIScreen.main.scale)
        let remaining = PKDrawing(strokes: Array(drawing.strokes.dropFirst()))
        let reused = NativeInkRasterCache(drawing: remaining)
        reused.reuseUnchangedStrokes(from: cache.nativeRasterCache)
        let reusedTiles = reused.tiles(for: 0, visible: documentViewport, scale: UIScreen.main.scale)
        try check(!reusedTiles.isEmpty && reused.rasterizationCount == 0,
                  "\(suffix) erasing a prior stroke reuses unchanged native images despite shifted indices")
        var movedStroke = remaining.strokes[0]
        movedStroke.transform = movedStroke.transform.concatenating(CGAffineTransform(translationX: 20, y: 0))
        let changed = NativeInkRasterCache(drawing: PKDrawing(strokes: [movedStroke]))
        changed.reuseUnchangedStrokes(from: cache.nativeRasterCache)
        _ = changed.tiles(for: 0, visible: documentViewport, scale: UIScreen.main.scale)
        try check(changed.rasterizationCount > 0,
                  "\(suffix) a changed transform cannot inherit stale native image contents")
        paper.render = nil
    }

    // A long selected stroke shrunk to 5% must not rasterize its newly visible
    // source area at the unscaled document resolution during a pointer update.
    let tallPoints = (0..<120).map { index in
        PKStrokePoint(location: CGPoint(x: 80 + CGFloat(index % 2) * 120, y: CGFloat(index) * 80),
                      timeOffset: Double(index) * 0.01, size: CGSize(width: 8, height: 8),
                      opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    }
    let tallDrawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
        path: PKStrokePath(controlPoints: tallPoints, creationDate: Date(timeIntervalSince1970: 200)))])
    let tallOriginal = tallDrawing.dataRepresentation()
    let tallPaper = PaperView()
    tallPaper.documentBounds = CGRect(x: 0, y: 0, width: 360, height: 10_000)
    tallPaper.render = { context in context.setFillColor(UIColor.white.cgColor); context.fill(tallPaper.documentBounds) }
    tallPaper.updateViewport(.identity, viewport: viewport, interacting: false)
    let smallPreview = InkTransformPreview(frame: viewport)
    smallPreview.prepare(selection: RectangularInkSelection(drawing: tallDrawing, indices: [0]),
                         paper: tallPaper, viewport: viewport, transform: .identity)
    let beforeShrink = smallPreview.rasterizationCount
    smallPreview.moveSelection(CGAffineTransform(scaleX: 0.05, y: 0.05), viewportTransform: .identity)
    let shrinkRasters = smallPreview.rasterizationCount - beforeShrink
    try check(shrinkRasters > 0 && shrinkRasters <= 8, "5 percent shrink uses bounded display-resolution tiles for a 9,520pt stroke")
    let afterShrink = smallPreview.rasterizationCount
    for index in 0..<120 {
        let factor = 0.05 + CGFloat(index % 5) * 0.0001
        smallPreview.moveSelection(CGAffineTransform(scaleX: factor, y: factor), viewportTransform: .identity)
    }
    try check(smallPreview.rasterizationCount == afterShrink, "small resize deltas reuse quantized native textures")
    try check(tallDrawing.dataRepresentation() == tallOriginal, "downsampled preview never changes original stroke width")
    report.append("long_selection_5_percent_new_tiles=\(shrinkRasters); resize_updates=120; repeated_rasterizations=0")
    try saveReport()
    smallPreview.clear(); tallPaper.render = nil
}
