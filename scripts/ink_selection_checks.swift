import SwiftUI
import PencilKit

@MainActor private final class InkCheckController: UIViewController {
    let history = UndoManager()
    override var undoManager: UndoManager? { history }
}

@MainActor func checkRectangularInk(_ store: NoteStore) throws {
    try checkInkGeometry()
    try checkInkAppearance()
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        try PDFIntegrationChecks.check(try condition(), "rectangle: " + message)
    }
    func sameInk(_ lhs: PKDrawing, _ rhs: PKDrawing) -> Bool {
        guard lhs.strokes.count == rhs.strokes.count else { return false }
        return zip(lhs.strokes, rhs.strokes).allSatisfy { a, b in
            a.transform == b.transform && a.renderBounds == b.renderBounds && a.ink.inkType == b.ink.inkType && a.ink.color == b.ink.color && a.path.count == b.path.count && a.mask?.cgPath == b.mask?.cgPath &&
            (0..<a.path.count).allSatisfy { a.path[$0].location == b.path[$0].location && a.path[$0].size == b.path[$0].size && a.path[$0].opacity == b.path[$0].opacity }
        }
    }
    let note = try PDFIntegrationChecks.pageSwapFixture(store)
    let original = try store.drawing(noteID: note.id, pageID: note.pages[0].id)
    let bounds = original.bounds
    let selected = RectangularInkSelection(drawing: original, rect: bounds.insetBy(dx: -4, dy: -4))
    try check(selected.indices == [0], "enclosing box selects whole stroke")
    try check(RectangularInkSelection(drawing: original, rect: CGRect(x: 0, y: 0, width: 20, height: 20)).indices.isEmpty, "empty box selects nothing")
    try check(RectangularInkSelection(drawing: original, rect: CGRect(x: 145, y: 460, width: 12, height: 12)).indices.isEmpty, "empty area within diagonal stroke bounds is not selected")
    try check(RectangularInkSelection(drawing: original, rect: CGRect(x: 370, y: 414, width: 24, height: 24)).indices == [0], "crossing visible ink selects whole stroke")
    var masked = original.strokes[0]
    masked.mask = UIBezierPath(rect: CGRect(x: 130, y: 300, width: 100, height: 200))
    let maskedDrawing = PKDrawing(strokes: [masked])
    try check(RectangularInkSelection(drawing: maskedDrawing, rect: CGRect(x: 380, y: 410, width: 20, height: 20)).indices.isEmpty, "pixel-erased hole is not selected")
    try check(RectangularInkSelection(drawing: maskedDrawing, rect: CGRect(x: 160, y: 365, width: 20, height: 20)).indices == [0], "remaining masked ink is selectable")
    let deep = selected.transformed(CGAffineTransform(translationX: 20, y: 70000))
    try check(RectangularInkSelection(drawing: deep, rect: deep.bounds).indices == [0], "deep transformed PDF ink selected in document space")
    try check(original.dataRepresentation() == selected.original.dataRepresentation(), "selection preserves source")
    var second = original.strokes[0]; second.transform = CGAffineTransform(translationX: 0, y: 200)
    let pair = PKDrawing(strokes: [original.strokes[0], second])
    let one = RectangularInkSelection(drawing: pair, rect: bounds)
    let moved = one.transformed(CGAffineTransform(translationX: 30, y: 40))
    try check(moved.strokes.count == 2 && sameInk(PKDrawing(strokes: [moved.strokes[1]]), PKDrawing(strokes: [pair.strokes[1]])), "move preserves unselected stroke and z-order")
    try check(abs(moved.strokes[0].renderBounds.minX - bounds.minX - 30) < 0.1, "move translates selected stroke")
    try check(sameInk(one.removing, PKDrawing(strokes: [second])), "delete preserves unselected ink")
    let session = DrawingSession()
    let host = CanvasHostView(session: session); session.host = host
    let owner = InkCheckController(); owner.view.addSubview(host)
    host.frame = CGRect(x: 0, y: 0, width: 820, height: 1000)
    session.load(noteID: note.id, pageID: note.pages[0].id, store: store)
    session.selectTool(.rectangle)
    try check(!(session.canvas.tool is PKLassoTool), "rectangle never activates the native freeform lasso")
    host.configure(note: note, page: note.pages[0], store: store, fingerDrawing: true,
                   editingObjects: false, toolsVisible: true, onSelect: { _ in }, onMove: { _, _, _ in }, onTurnPage: { _ in false })
    host.layoutIfNeeded()
    let fit = session.canvas.zoomScale
    try check(abs(session.canvas.minimumZoomScale - fit * 0.5) < 0.001, "minimum zoom is half the fit scale")
    session.canvas.zoomScale = fit * 0.5
    host.canvasDidZoom()
    try check(abs(session.canvas.zoomScale - fit * 0.5) < 0.001, "native canvas reaches half-fit overview")
    try check(host.backgroundViewportTransform == host.documentToViewport, "paper compositor uses exact native viewport transform")
    host.fitPage(animated: false)
    let rasterCount = host.backgroundRasterizationCount
    for _ in 0..<20 { host.canvasDidScroll() }
    try check(host.backgroundRasterizationCount == rasterCount, "unchanged viewport never rerasterizes PDF")
    try check(!session.canvas.drawingGestureRecognizer.isEnabled && session.canvas.panGestureRecognizer.minimumNumberOfTouches == 2, "rectangle mode stops new ink but retains two-finger viewport")
    host.selectInk(in: bounds.insetBy(dx: -4, dy: -4))
    try check(session.selectedStrokeCount == 1, "production host publishes selection")
    let selectedRect = host.inkSelectionRect!
    let gestureOrigin = CGPoint(x: selectedRect.midX, y: selectedRect.midY)
    host.beginInkTransform(at: gestureOrigin)
    for delta in [CGFloat(8), 24, 48] {
        host.updateInkDrag(to: CGPoint(x: gestureOrigin.x + delta, y: gestureOrigin.y + 20))
        try check(host.isShowingInkPreview && host.liveInkTransform == host.liveSelectionTransform,
                  "ink and rectangle share live transform before lift")
        try check(sameInk(session.canvas.drawing, original), "live move never mutates original or creates undo steps")
        let frame = UIGraphicsImageRenderer(bounds: host.bounds).image { output in host.layer.render(in: output.cgContext) }
        let location = CGPoint(x: 370 + delta, y: 440).applying(host.documentToViewport)
        let crop = frame.cgImage!.cropping(to: CGRect(x: location.x * frame.scale, y: location.y * frame.scale, width: 1, height: 1))!
        var rgba = [UInt8](repeating: 0, count: 4)
        rgba.withUnsafeMutableBytes { bytes in
            let c = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            c.draw(crop, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        }
        try check(rgba[0] > 180 && rgba[1] < 120 && rgba[2] < 120, "rendered selected ink follows finger before lift")
    }
    host.clearInkSelection()
    try check(!host.isShowingInkPreview && session.canvas.layer.opacity == 1 && sameInk(session.canvas.drawing, original), "cancel restores original native ink")
    host.selectInk(in: selectedRect)
    host.beginInkTransform(at: CGPoint(x: selectedRect.maxX, y: selectedRect.maxY))
    host.updateInkDrag(to: CGPoint(x: selectedRect.minX + selectedRect.width * 0.5, y: selectedRect.minY + selectedRect.height * 0.5))
    try check(abs(host.liveInkTransform.a - 0.5) < 0.001 && abs(host.liveInkTransform.d - 0.5) < 0.001,
              "corner drag scales selected ink live about opposite corner")
    try check(host.liveInkTransform == host.liveSelectionTransform, "resize outline cannot precede ink")
    host.clearInkSelection(); host.selectInk(in: selectedRect)
    guard let undo = session.canvas.undoManager else { throw NSError(domain: "rectangle missing test undo manager", code: 1) }
    undo.removeAllActions(); undo.groupsByEvent = false
    undo.beginUndoGrouping()
    host.transformSelectedInk(CGAffineTransform(translationX: 20, y: 40), action: "필기 이동")
    undo.endUndoGrouping()
    let committed = session.canvas.drawing
    try check(abs(committed.bounds.minY - original.bounds.minY - 40) < 0.1, "host move commits coordinates")
    session.undo()
    try check(sameInk(session.canvas.drawing, original), "one undo restores original ink")
    session.redo()
    try check(sameInk(session.canvas.drawing, committed), "redo restores moved ink")
    host.selectInk(in: committed.bounds)
    host.copySelectedInk()
    try check(sameInk(DrawingSession.copiedInk ?? PKDrawing(), committed), "copy preserves editable ink")
    undo.beginUndoGrouping(); host.pasteInk(duplicate: true); undo.endUndoGrouping()
    try check(session.canvas.drawing.strokes.count == 2 && session.selectedStrokeCount == 1, "duplicate selects only new ink")
    undo.beginUndoGrouping(); host.copySelectedInk(cut: true); undo.endUndoGrouping()
    try check(session.canvas.drawing.strokes.count == 1, "cut removes only selected ink")
    undo.beginUndoGrouping(); host.pasteInk(); undo.endUndoGrouping()
    try check(session.canvas.drawing.strokes.count == 2 && session.selectedStrokeCount == 1, "paste inserts clipboard ink")
    let beforeResize = session.canvas.drawing
    undo.beginUndoGrouping(); host.scaleSelectedInk(by: 0.5); undo.endUndoGrouping()
    try check(abs(session.canvas.drawing.strokes[1].renderBounds.width / beforeResize.strokes[1].renderBounds.width - 0.5) < 0.01, "resize changes selected stroke scale")
    undo.beginUndoGrouping(); host.deleteSelectedInk(); undo.endUndoGrouping()
    try check(sameInk(session.canvas.drawing, committed), "delete preserves other ink")
    try check(store.flushDrawings(), "flush edited ink")
    let reopened = NoteStore()
    try check(sameInk(try reopened.drawing(noteID: note.id, pageID: note.pages[0].id), committed), "edits persist after store reopen")
    session.load(noteID: note.id, pageID: note.pages[1].id, store: store)
    try check(session.canvas.drawing.strokes.isEmpty, "page switch does not carry selected ink")
    let emptyRect = CGRect(x: 80, y: 80, width: 200, height: 160)
    host.selectInk(in: emptyRect)
    try check(host.inkSelectionRect == emptyRect && session.selectedStrokeCount == 0, "empty rectangular region remains available for resizing")
    try check(session.canvas.drawing.strokes.isEmpty, "adjusting selection never creates or scales ink")
    session.selectTool(.pen)
    try check(session.canvas.tool is PKInkingTool, "pen still available after rectangle")
    DrawingSession.copiedInk = nil
    session.stop()
    withExtendedLifetime(owner) {}
    try checkRetainedInkPresentation(store)
    try checkInkGroups(store: store)
}


@MainActor func checkToolDocking() throws {
    let suite = "NoteMargin.ToolDockChecks.\(UUID())"
    let preferences = UserDefaults(suiteName: suite)!
    defer { preferences.removePersistentDomain(forName: suite) }
    let session = DrawingSession(preferences: preferences)
    session.selectTool(.pen)
    func check(_ condition: Bool, _ message: String) throws { try PDFIntegrationChecks.check(condition, message) }
    session.inkWidth = 0.1; session.applyTool()
    try check(abs(((session.canvas.tool as? PKInkingTool)?.width ?? 99) - 0.1) < 0.001, "native PencilKit accepts fine 0.1pt pen width")
    let palette = ["13579B", "2468AC", "FEDCBA", "AB1023", "102030"]
    try check(InkPalette.values(palette.joined(separator: ",")) == palette, "five independently customized colors round trip")
    for hex in palette { try check(InkPalette.hex(InkPalette.color(hex)) == hex, "arbitrary sRGB palette color retained") }
    try check(InkPalette.values("INVALID,123456").count == 5 && InkPalette.values("INVALID,123456")[1] == "123456", "damaged preferences recover missing slots independently")
    for inkTool in [InkTool.pen, .pencil, .marker] {
        for eraser in [InkTool.eraser, .pixelEraser] {
            session.selectTool(inkTool); session.inkColor = .purple; session.inkWidth = 2.5; session.rulerActive = true
            session.selectTool(.lasso); session.selectTool(eraser)
            session.eraserWidth = session.eraserWidthRange.upperBound; session.applyTool()
            let before = session.canvas.drawing.dataRepresentation()
            session.finishErasing()
            try check(session.selectedTool == inkTool && session.inkColor == .purple && session.inkWidth == 2.5 && session.rulerActive, "eraser restores last ink type color width and ruler through selection tools")
            try check(session.canvas.tool is PKInkingTool && session.canvas.drawing.dataRepresentation() == before, "returning to ink never changes drawing")
        }
    }
    for edge in ToolDock.Edge.allCases {
        let dock = ToolDock(edge: edge, fraction: 0.5)
        let size = dock.paletteSize(viewport: CGSize(width: 820, height: 1000), expanded: true)
        try check(edge.isVertical ? size.height > size.width * 4 : size.width > size.height * 3, "dock orientation follows its edge")
        try check(dock.paletteSize(viewport: CGSize(width: 400, height: 500), expanded: false) == CGSize(width: 60, height: 60), "collapsed tool remains circular at every edge")
    }
    for viewport in [CGSize(width: 1032, height: 1200), CGSize(width: 1376, height: 880), CGSize(width: 320, height: 620)] {
        for tool in [CGSize(width: min(430, viewport.width - 24), height: 214), CGSize(width: 60, height: 60)] {
            let limits = ToolDock.limits(viewport: viewport, tool: tool)
            for point in [CGPoint(x: -500, y: -500), CGPoint(x: 5000, y: 5000), CGPoint(x: viewport.width / 2, y: viewport.height / 2), CGPoint(x: 0, y: viewport.height / 2), CGPoint(x: viewport.width / 2, y: 0)] {
                let dock = ToolDock.nearest(to: point, viewport: viewport, tool: tool)
                let p = dock.center(viewport: viewport, tool: tool)
                try PDFIntegrationChecks.check(p.x >= limits.minX && p.x <= limits.maxX && p.y >= limits.minY && p.y <= limits.maxY, "dock remains inside viewport")
                try PDFIntegrationChecks.check(p.x == limits.minX || p.x == limits.maxX || p.y == limits.minY || p.y == limits.maxY, "dock is always on one edge")
            }
            for edge in ToolDock.Edge.allCases {
                let p = ToolDock(edge: edge, fraction: 0.4).center(viewport: viewport, tool: tool)
                try PDFIntegrationChecks.check(ToolDock.nearest(to: p, viewport: viewport, tool: tool).center(viewport: viewport, tool: tool) == p, "all four edges reachable")
            }
        }
    }
}


/// Dense/deep synthetic ink exercises the production geometry and coalesced
/// eraser path without relying on a single red line or image equality alone.
@MainActor func checkInkGeometry() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        try PDFIntegrationChecks.check(condition(), "ink geometry: " + message)
    }
    func stroke(_ locations: [CGPoint], width: CGFloat = 2) -> PKStroke {
        let points = locations.enumerated().map { index, point in
            PKStrokePoint(location: point, timeOffset: Double(index) * 0.02,
                          size: CGSize(width: width, height: width), opacity: 1,
                          force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
    }
    let seed = stroke([CGPoint(x: 0, y: 0), CGPoint(x: 12, y: 0), CGPoint(x: 24, y: 0)])
    let strokes = (0..<420).map { index -> PKStroke in
        var result = seed
        result.transform = CGAffineTransform(translationX: CGFloat(index % 20) * 80 + 80,
                                             y: CGFloat(index / 20) * 48 + 70_020)
        return result
    }
    let dense = PKDrawing(strokes: strokes)
    let sourceBytes = dense.dataRepresentation()
    let cache = InkGeometryCache(drawing: dense)
    try check(cache.geometryBuildCount == 0, "420-stroke spatial index does not eagerly render/build outlines")
    let candidates = cache.candidates(intersecting: CGRect(x: 75, y: 70_015, width: 35, height: 10))
    try check(candidates == [0] && cache.geometryBuildCount == 0, "deep viewport bounds narrow 420 strokes to one without rasterizing")
    let first = cache.geometry(at: 0)
    _ = cache.geometry(at: 0)
    try check(cache.geometryBuildCount == 1 && first.path.contains(CGPoint(x: 90, y: 70_020)),
              "repeated geometry access reuses one pressure-aware document outline")
    let reusedSelection = RectangularInkSelection(drawing: dense, rect: CGRect(x: 75, y: 70_015, width: 35, height: 10), geometryCache: cache)
    let reusedErase = StrokeEraserTransaction(drawing: dense, width: 4, geometryCache: cache)
    try check(reusedSelection.geometryCache === cache && reusedErase.geometryCache === cache && cache.geometryBuildCount == 1,
              "selection and eraser share the same unchanged drawing geometry")
    let rejectedCache = StrokeEraserTransaction(drawing: PKDrawing(), width: 4, geometryCache: cache)
    try check(rejectedCache.geometryCache !== cache && rejectedCache.geometryCache.drawing.strokes.isEmpty,
              "a cache from another drawing is rejected")
    let erase = StrokeEraserTransaction(drawing: dense, width: 4)
    erase.extend(to: CGPoint(x: 70, y: 69_990))
    try check(erase.erasedIndices.isEmpty && erase.geometryCache.geometryBuildCount == 0,
              "empty-space erasing avoids geometry work despite hundreds of strokes")
    erase.extend(along: [CGPoint(x: 70, y: 70_020), CGPoint(x: 180, y: 70_020), CGPoint(x: 280, y: 70_020)])
    try check(erase.erasedIndices == [0, 1, 2], "one fast coalesced sweep hits each crossed stroke exactly once")
    let built = erase.geometryCache.geometryBuildCount
    for _ in 0..<12 { erase.extend(along: [CGPoint(x: 70, y: 70_020), CGPoint(x: 280, y: 70_020)]) }
    try check(erase.geometryCache.geometryBuildCount == built && built == 3,
              "revisiting already faded strokes never rebuilds their paths")
    try check(erase.remainingDrawing.strokes.count == 417 && erase.erasedDrawing.strokes.count == 3,
              "eraser preserves every untouched stroke")
    try check(erase.original.dataRepresentation() == sourceBytes && dense.dataRepresentation() == sourceBytes,
              "all held eraser/geometry work preserves original editable PencilKit data")

    let diagonal = PKDrawing(strokes: [stroke([.zero, CGPoint(x: 100, y: 100)])])
    let emptyCorner = CGRect(x: 2, y: 88, width: 6, height: 6)
    try check(RectangularInkSelection(drawing: diagonal, rect: emptyCorner).indices.isEmpty,
              "rectangle within a diagonal bounding box cannot select empty space")
    let emptyErase = StrokeEraserTransaction(drawing: diagonal, width: 3)
    emptyErase.extend(to: CGPoint(x: 5, y: 91))
    try check(emptyErase.erasedIndices.isEmpty, "eraser uses geometry beyond bounding-box broad phase")

    let pair = PKDrawing(strokes: [
        stroke([CGPoint(x: 18, y: 20), CGPoint(x: 24, y: 20)]),
        stroke([CGPoint(x: 76, y: 80), CGPoint(x: 82, y: 80)])
    ])
    let triangle = CGMutablePath()
    triangle.move(to: .zero); triangle.addLine(to: CGPoint(x: 100, y: 0))
    triangle.addLine(to: CGPoint(x: 0, y: 100)); triangle.closeSubpath()
    let freeform = RectangularInkSelection(drawing: pair, path: triangle)
    try check(freeform.indices == [0], "freeform selects only inside its actual shape")
    try check(RectangularInkSelection(drawing: pair, rect: triangle.boundingBoxOfPath).indices == [0, 1],
              "box and freeform with equal bounds have distinct selection behavior")
    try check(freeform.original.dataRepresentation() == pair.dataRepresentation(), "freeform leaves the source drawing unchanged")

    let enclosedCache = InkGeometryCache(drawing: dense)
    let enclosedPath = CGPath(rect: dense.bounds.insetBy(dx: -5, dy: -5), transform: nil)
    let enclosedSelection = RectangularInkSelection(drawing: dense, path: enclosedPath, geometryCache: enclosedCache)
    try check(enclosedSelection.indices.count == 420 && enclosedCache.geometryBuildCount == 0,
              "fully contained freeform selection proves bounds containment without building 420 outlines")

    // All four rendered bounding-box corners are in this concave lasso, yet
    // the circular handwriting itself is completely in the excluded cutout.
    let circularPoints = (0...32).map { index -> CGPoint in
        let angle = CGFloat(index) * .pi / 16
        return CGPoint(x: 50 + cos(angle) * 40, y: 50 + sin(angle) * 40)
    }
    let circularInk = PKDrawing(strokes: [stroke(circularPoints)])
    let outer = CGPath(rect: CGRect(x: 0, y: 0, width: 100, height: 100), transform: nil)
    let hole = CGPath(ellipseIn: CGRect(x: 5, y: 5, width: 90, height: 90), transform: nil)
    let notch = CGPath(rect: CGRect(x: 45, y: -5, width: 10, height: 60), transform: nil)
    let concave = outer.subtracting(hole.union(notch))
    let circularBounds = circularInk.bounds
    let corners = [CGPoint(x: circularBounds.minX, y: circularBounds.minY),
                   CGPoint(x: circularBounds.maxX, y: circularBounds.minY),
                   CGPoint(x: circularBounds.minX, y: circularBounds.maxY),
                   CGPoint(x: circularBounds.maxX, y: circularBounds.maxY)]
    try check(corners.allSatisfy { concave.contains($0) }, "concave fixture has all four stroke-bounds corners inside")
    try check(RectangularInkSelection(drawing: circularInk, path: concave).indices.isEmpty,
              "concave lasso cannot select excluded curved ink merely because all bounds corners are inside")
    let centerIsland = CGPath(rect: CGRect(x: 48, y: 48, width: 4, height: 4), transform: nil)
    let holed = outer.subtracting(hole).union(centerIsland)
    try check(corners.allSatisfy { holed.contains($0) } && holed.contains(CGPoint(x: 50, y: 50)),
              "holed fixture includes four corners and the center while excluding the ink")
    try check(RectangularInkSelection(drawing: circularInk, path: holed).indices.isEmpty,
              "freeform containment proof respects holes even when corners and center are filled")

    var maskedAway = seed
    maskedAway.mask = UIBezierPath(rect: CGRect(x: 500, y: 500, width: 10, height: 10))
    var clearInk = seed; clearInk.ink = PKInk(.pen, color: .clear)
    let invisiblePoints = [CGPoint.zero, CGPoint(x: 24, y: 0)].enumerated().map { index, point in
        PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 4, height: 4),
                      opacity: 0, force: 0, azimuth: 0, altitude: .pi / 2)
    }
    let invisibleStroke = PKStroke(ink: PKInk(.pen, color: .black),
                                   path: PKStrokePath(controlPoints: invisiblePoints, creationDate: Date(timeIntervalSince1970: 0)))
    let invisibleDrawing = PKDrawing(strokes: [maskedAway, clearInk, invisibleStroke])
    let enclosingRect = CGRect(x: -20, y: -20, width: 600, height: 600)
    try check(RectangularInkSelection(drawing: invisibleDrawing, rect: enclosingRect).indices.isEmpty,
              "contained-box fast path rejects fully masked, clear-color and zero-opacity strokes")
    try check(RectangularInkSelection(drawing: invisibleDrawing, path: CGPath(rect: enclosingRect, transform: nil)).indices.isEmpty,
              "contained-freeform fast path rejects fully masked, clear-color and zero-opacity strokes")

    var masked = stroke([.zero, CGPoint(x: 50, y: 0), CGPoint(x: 100, y: 0)], width: 8)
    masked.mask = UIBezierPath(rect: CGRect(x: -5, y: -10, width: 50, height: 20))
    masked.transform = CGAffineTransform(a: 0, b: 2, c: -1.5, d: 0, tx: 200, ty: 70_000)
    let maskedDrawing = PKDrawing(strokes: [masked])
    let visible = CGRect(x: 195, y: 70_035, width: 10, height: 10)
    let missing = CGRect(x: 195, y: 70_135, width: 10, height: 10)
    try check(RectangularInkSelection(drawing: maskedDrawing, rect: visible).indices == [0],
              "mask clips before rotation/nonuniform scale/deep translation")
    try check(RectangularInkSelection(drawing: maskedDrawing, rect: missing).indices.isEmpty,
              "transformed pixel-erased portion cannot be selected")
    let maskedErase = StrokeEraserTransaction(drawing: maskedDrawing, width: 4)
    maskedErase.extend(to: CGPoint(x: 200, y: 70_140))
    try check(maskedErase.erasedIndices.isEmpty, "eraser respects transformed mask outside visible ink")
    maskedErase.extend(to: CGPoint(x: 200, y: 70_040))
    try check(maskedErase.erasedIndices == [0], "swept eraser reaches surviving transformed masked ink")
    let maskedGeometry = InkGeometryCache(drawing: maskedDrawing).geometry(at: 0)
    try check(maskedGeometry.path.contains(CGPoint(x: 200, y: 70_040)) && !maskedGeometry.path.contains(CGPoint(x: 200, y: 70_140)),
              "preview and hit testing share the exact clipped geometry")

    let taperedPoints = [
        PKStrokePoint(location: .zero, timeOffset: 0, size: CGSize(width: 2, height: 2), opacity: 1, force: 0.1, azimuth: 0, altitude: .pi / 2),
        PKStrokePoint(location: CGPoint(x: 100, y: 0), timeOffset: 1, size: CGSize(width: 20, height: 20), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
    ]
    let tapered = PKStroke(ink: PKInk(.pen, color: .black), path: PKStrokePath(controlPoints: taperedPoints, creationDate: Date(timeIntervalSince1970: 0)))
    let taperedGeometry = InkGeometryCache(drawing: PKDrawing(strokes: [tapered])).geometry(at: 0)
    try check(taperedGeometry.path.contains(CGPoint(x: 95, y: 6)) && !taperedGeometry.path.contains(CGPoint(x: 5, y: 6)),
              "outline follows pressure width instead of a uniform bounding rectangle")
}


/// Production retained layers: measure pointer work separately from test image
/// capture/serialization. These are synthetic timings, not Pencil latency claims.
@MainActor func checkRetainedInkPresentation(_ store: NoteStore) throws {
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        try PDFIntegrationChecks.check(try condition(), "retained ink: " + message)
    }
    guard let noteID = store.createNote(title: "Retained ink presentation", paper: .plain,
                                       cover: .graphite, folderID: nil),
          let note = store.note(noteID), let page = note.pages.first else {
        throw NSError(domain: "retained ink fixture", code: 1)
    }
    let strokes = (0..<180).map { index -> PKStroke in
        let origin = CGPoint(x: 60 + CGFloat(index % 18) * 34,
                             y: 120 + CGFloat(index / 18) * 48)
        let locations = [CGPoint(x: 0, y: 0), CGPoint(x: 5, y: -5),
                         CGPoint(x: 12, y: 4), CGPoint(x: 20, y: 0)]
        let points = locations.enumerated().map { pointIndex, point in
            let width: CGFloat = pointIndex == 1 ? 2.6 : 1.8
            return PKStrokePoint(location: CGPoint(x: origin.x + point.x, y: origin.y + point.y),
                                 timeOffset: Double(pointIndex) * 0.02,
                                 size: CGSize(width: width, height: width), opacity: 1,
                                 force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))
    }
    let dense = PKDrawing(strokes: strokes)
    store.queueDrawing(dense, noteID: noteID, pageID: page.id)
    try check(store.flushDrawings(), "dense fixture persists before loading")
    let session = DrawingSession()
    let host = CanvasHostView(session: session); session.host = host
    let owner = InkCheckController(); owner.view.addSubview(host)
    host.frame = CGRect(x: 0, y: 0, width: 820, height: 1000)
    session.load(noteID: noteID, pageID: page.id, store: store)
    session.selectTool(.rectangle)
    host.configure(note: note, page: page, store: store, fingerDrawing: true,
                   editingObjects: false, toolsVisible: true, onSelect: { _ in },
                   onMove: { _, _, _ in }, onTurnPage: { _ in false })
    host.layoutIfNeeded()
    let original = session.canvas.drawing
    let originalBytes = original.dataRepresentation()
    let fit = session.canvas.zoomScale
    try check(original.strokes.count == 180, "all 180 editable strokes are loaded")
    try check(host.paperSharesNativeScroll, "paper is a child of the same native scrolling canvas as ink")
    guard let paper = session.canvas.subviews.compactMap({ $0 as? PaperView }).first else {
        throw NSError(domain: "retained ink missing native paper", code: 1)
    }
    let viewportStart = CACurrentMediaTime()
    var viewportUpdates = 0
    for index in 0..<36 {
        let factors: [CGFloat] = [0.5, 0.75, 1, 1.35, 2, 1.1]
        session.canvas.setZoomScale(fit * factors[index % factors.count], animated: false)
        host.canvasDidZoom()
        let inset = session.canvas.contentInset
        session.canvas.setContentOffset(CGPoint(x: -inset.left + CGFloat((index * 13) % 71),
                                               y: -inset.top + CGFloat((index * 17) % 97)), animated: false)
        host.canvasDidScroll()
        try check(host.paperSharesNativeScroll && paper.superview === session.canvas,
                  "rapid viewport changes never detach paper from native canvas")
        for point in [CGPoint.zero, CGPoint(x: 90, y: 160), CGPoint(x: 600, y: 560)] {
            let actual = paper.convert(point, to: host)
            let expected = point.applying(host.documentToViewport)
            try check(abs(actual.x - expected.x) < 0.01 && abs(actual.y - expected.y) < 0.01,
                      "actual paper UIView conversion agrees with native ink document coordinates")
        }
        viewportUpdates += 1
    }
    let viewportMilliseconds = (CACurrentMediaTime() - viewportStart) * 1000
    host.fitPage(animated: false)
    host.layoutIfNeeded()
    let freeformOutline = UIBezierPath(roundedRect: dense.bounds.insetBy(dx: -20, dy: -20), cornerRadius: 8)
    let freeformStart = CACurrentMediaTime()
    let freeform = RectangularInkSelection(drawing: original, path: freeformOutline.cgPath)
    let freeformMilliseconds = (CACurrentMediaTime() - freeformStart) * 1000
    try check(freeform.indices.count == 180 && freeform.geometryCache.geometryBuildCount == 0,
              "enclosing freeform uses safe bounds containment without rebuilding dense stroke outlines")
    let selectionStart = CACurrentMediaTime()
    host.selectInk(in: dense.bounds.insetBy(dx: -8, dy: -8))
    let selectionQueryMilliseconds = (CACurrentMediaTime() - selectionStart) * 1000
    try check(session.selectedStrokeCount == 180, "the production box selects every visible short stroke")
    guard let selectedRect = host.inkSelectionRect else {
        throw NSError(domain: "retained ink missing selection", code: 1)
    }
    let origin = CGPoint(x: selectedRect.midX, y: selectedRect.midY)
    let previewStart = CACurrentMediaTime()
    host.beginInkTransform(at: origin)
    let previewPreparationMilliseconds = (CACurrentMediaTime() - previewStart) * 1000
    let preparationMilliseconds = (CACurrentMediaTime() - selectionStart) * 1000
    let built = host.previewGeometryBuildCount
    let rendered = host.previewRasterizationCount
    try check(host.isShowingInkPreview && rendered >= 180, "retained preview prepares native PencilKit appearance once")
    host.clearInkSelection()
    host.selectInk(in: dense.bounds.insetBy(dx: -8, dy: -8))
    let warmStart = CACurrentMediaTime()
    host.beginInkTransform(at: origin)
    let warmPreparationMilliseconds = (CACurrentMediaTime() - warmStart) * 1000
    try check(host.previewRasterizationCount == rendered, "a repeated gesture reuses every original native image")
    var moveMilliseconds: [Double] = []
    for index in 0..<120 {
        let point = CGPoint(x: origin.x + 14 * sin(CGFloat(index) * 0.09),
                            y: origin.y + 11 * cos(CGFloat(index) * 0.07))
        let start = CACurrentMediaTime()
        host.updateInkDrag(to: point)
        moveMilliseconds.append((CACurrentMediaTime() - start) * 1000)
        try check(host.previewGeometryBuildCount == built && host.previewRasterizationCount == rendered,
                  "pointer updates reuse native textures without rebuilding or rasterizing 180 strokes")
        try check(host.liveInkTransform == host.liveSelectionTransform,
                  "retained ink and selection rectangle share every live pointer transform")
        try check(session.canvas.drawing == original,
                  "all 120 live moves preserve the original native PencilKit drawing")
    }
    try check(session.canvas.drawing.dataRepresentation() == originalBytes,
              "live manipulation preserves the complete serialized original")

    // Sample visible black paths and white spaces between handwriting. A bitmap
    // smear or an opaque selected bounding rectangle would fail these gap checks.
    let format = UIGraphicsImageRendererFormat(); format.scale = UIScreen.main.scale; format.opaque = true
    let screenshot = UIGraphicsImageRenderer(bounds: host.bounds, format: format).image { output in
        host.layer.render(in: output.cgContext)
    }
    // Save diagnostics before assertions so a failed pixel sample is inspectable.
    try screenshot.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("dense-ink-retained.png"), options: .atomic)
    func rgbSamples(in image: UIImage, at point: CGPoint, radius: Int = 1) -> [[UInt8]] {
        guard let bitmap = image.cgImage else { return [] }
        let x = Int((point.x * image.scale).rounded()), y = Int((point.y * image.scale).rounded())
        let rect = CGRect(x: x - radius, y: y - radius, width: radius * 2 + 1, height: radius * 2 + 1)
            .intersection(CGRect(x: 0, y: 0, width: bitmap.width, height: bitmap.height))
        guard !rect.isNull, !rect.isEmpty, let crop = bitmap.cropping(to: rect) else { return [] }
        var pixels = [UInt8](repeating: 0, count: crop.width * crop.height * 4)
        pixels.withUnsafeMutableBytes { bytes in
            let context = CGContext(data: bytes.baseAddress, width: crop.width, height: crop.height,
                                    bitsPerComponent: 8, bytesPerRow: crop.width * 4,
                                    space: CGColorSpaceCreateDeviceRGB(),
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
            context.draw(crop, in: CGRect(x: 0, y: 0, width: crop.width, height: crop.height))
        }
        return stride(from: 0, to: pixels.count, by: 4).map { Array(pixels[$0..<($0 + 3)]) }
    }
    func nativeReference(_ drawing: PKDrawing, viewport: CGRect, transform: CGAffineTransform, selectionTint: CGRect? = nil) -> UIImage {
        let document = viewport.applying(transform.inverted())
        var ink: UIImage!
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            ink = drawing.image(from: document, scale: transform.a * max(1, host.traitCollection.displayScale))
        }
        return UIGraphicsImageRenderer(bounds: viewport, format: format).image { output in
            UIColor.white.setFill(); output.fill(viewport)
            ink.draw(in: viewport)
            if let selectionTint {
                UIColor.systemBlue.withAlphaComponent(0.08).setFill()
                output.cgContext.setBlendMode(.normal)
                output.cgContext.fill(selectionTint)
            }
        }
    }
    func matchesNativeInk(_ actual: [[UInt8]], _ expected: [[UInt8]]) -> Bool {
        guard !actual.isEmpty, actual.count == expected.count else { return false }
        // Integrate the whole small stroke, subtracting each image's paper/
        // selection tint. A five-pixel crop overweights subpixel raster phase.
        let nativeBackground = (0..<3).map { channel in expected.map { $0[channel] }.max()! }
        let actualBackground = (0..<3).map { channel in actual.map { $0[channel] }.max()! }
        var nativeMass = 0.0, actualMass = 0.0, error = 0.0
        for (actualPixel, expectedPixel) in zip(actual, expected) {
            for channel in 0..<3 {
                let a = Double(actualPixel[channel]), e = Double(expectedPixel[channel])
                nativeMass += max(0, Double(nativeBackground[channel]) - e)
                actualMass += max(0, Double(actualBackground[channel]) - a)
                error += abs(a - e)
            }
        }
        try? "nativeMass=\(nativeMass) actualMass=\(actualMass) meanError=\(error / Double(actual.count * 3))".write(to: PDFIntegrationChecks.directory.appendingPathComponent("dense-pixel-comparison.txt"), atomically: true, encoding: .utf8)
        guard nativeMass > 15 else { return false }
        return error / Double(actual.count * 3) <= 12 && abs(actualMass - nativeMass) <= max(15, nativeMass * 0.12)
    }
    let movedNativeReference = nativeReference(original.transformed(using: host.liveSelectionTransform),
                                               viewport: host.bounds, transform: host.documentToViewport,
                                               selectionTint: host.inkSelectionRect!.applying(host.liveSelectionTransform).applying(host.documentToViewport))
    try movedNativeReference.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("dense-ink-native-reference.png"))
    func actualInkPoint(in stroke: PKStroke) throws -> CGPoint {
        // PencilKit uses a B-spline: control points need not lie on rendered ink.
        let points = Array(stroke.path.interpolatedPoints(by: .distance(1)))
        guard !points.isEmpty else { throw NSError(domain: "retained ink empty interpolation", code: 1) }
        return points[points.count / 2].location.applying(stroke.transform)
    }
    for row in [2, 4, 7] {
        let actualInk = try actualInkPoint(in: original.strokes[row * 18 + 6])
        let base = CGPoint(x: 60 + CGFloat(6) * 34, y: 120 + CGFloat(row) * 48)
        let inkPoint = actualInk.applying(host.liveSelectionTransform).applying(host.documentToViewport)
        let gapPoint = CGPoint(x: base.x + 27, y: base.y)
            .applying(host.liveSelectionTransform).applying(host.documentToViewport)
        let ink = rgbSamples(in: screenshot, at: inkPoint, radius: 12)
        let expectedInk = rgbSamples(in: movedNativeReference, at: inkPoint, radius: 12)
        let gap = rgbSamples(in: screenshot, at: gapPoint)
        try check(matchesNativeInk(ink, expectedInk),
                  "retained layers preserve native fine-stroke pixels at the moved interpolated position")
        try check(!gap.isEmpty && gap.allSatisfy { $0.allSatisfy { $0 > 210 } },
                  "white gaps between adjacent short strokes remain open")
    }
    host.clearInkSelection()
    try check(!host.isShowingInkPreview && session.canvas.drawing.dataRepresentation() == originalBytes,
              "cancelling dense selection leaves every original stroke intact")

    // Exercise the actual eraser scene/trail compositor independently of UIKit
    // gesture synthesis. Held erasing must overlay a white trail at real ink.
    let erasedIndex = 4 * 18 + 6
    let crossing = try actualInkPoint(in: original.strokes[erasedIndex])
    let erase = StrokeEraserTransaction(drawing: original, width: 12)
    let preview = StrokeEraserPreviewView(frame: host.bounds)
    host.addSubview(preview)
    preview.begin(transaction: erase, paper: paper, viewport: host.bounds, transform: host.documentToViewport)
    let sweep = [CGPoint(x: crossing.x, y: crossing.y - 8), crossing,
                 CGPoint(x: crossing.x, y: crossing.y + 8)]
    erase.extend(along: sweep)
    preview.setErased(erase.erasedIndices)
    preview.extend(along: sweep)
    let eraserScreenshot = UIGraphicsImageRenderer(bounds: host.bounds, format: format).image { output in
        host.layer.render(in: output.cgContext)
    }
    try eraserScreenshot.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("dense-ink-eraser-trail.png"), options: .atomic)
    try check(erase.erasedIndices.contains(erasedIndex), "the held eraser intersects actual interpolated ink")
    let trail = rgbSamples(in: eraserScreenshot, at: crossing.applying(host.documentToViewport))
    try check(!trail.isEmpty && trail.allSatisfy { $0.allSatisfy { $0 >= 240 } },
              "retained eraser compositor draws a white trail across the erased stroke")
    try check(erase.original.dataRepresentation() == originalBytes && session.canvas.drawing.dataRepresentation() == originalBytes,
              "held eraser preview never mutates the original native drawing")
    preview.end()
    try check(preview.isHidden && session.canvas.drawing.dataRepresentation() == originalBytes,
              "ending the eraser preview preserves every original stroke")
    preview.removeFromSuperview()

    // A stitched document is tall, but its eraser trail layer and render target
    // must stay viewport-sized even when its document coordinates exceed 70k.
    let deepViewport = CGRect(x: 0, y: 0, width: 820, height: 1000)
    let deepDocument = CGRect(x: 0, y: 0, width: 768, height: 80_000)
    let deepTransform = CGAffineTransform(translationX: 0, y: -70_000)
    let deepPaper = PaperView(frame: deepViewport)
    deepPaper.documentBounds = deepDocument
    deepPaper.render = { context in
        context.setFillColor(UIColor.white.cgColor)
        context.fill(deepDocument)
    }
    deepPaper.updateViewport(deepTransform, viewport: deepViewport, interacting: false)
    let deepDrawing = original.transformed(using: CGAffineTransform(translationX: 0, y: 70_000))
    let deepOriginalBytes = deepDrawing.dataRepresentation()
    let deepCrossing = try actualInkPoint(in: deepDrawing.strokes[erasedIndex])
    let neighborIndex = erasedIndex + 1
    let deepNeighbor = try actualInkPoint(in: deepDrawing.strokes[neighborIndex])
    let deepErase = StrokeEraserTransaction(drawing: deepDrawing, width: 12)
    let deepPreview = StrokeEraserPreviewView(frame: deepViewport)
    deepPreview.begin(transaction: deepErase, paper: deepPaper, viewport: deepViewport, transform: deepTransform)
    let deepSweep = [CGPoint(x: deepCrossing.x, y: deepCrossing.y - 8), deepCrossing,
                     CGPoint(x: deepCrossing.x, y: deepCrossing.y + 8)]
    deepErase.extend(along: deepSweep)
    deepPreview.setErased(deepErase.erasedIndices)
    deepPreview.extend(along: deepSweep)
    let deepScreenshot = UIGraphicsImageRenderer(bounds: deepViewport, format: format).image { output in
        deepPreview.layer.render(in: output.cgContext)
    }
    try deepScreenshot.pngData()?.write(to: PDFIntegrationChecks.directory.appendingPathComponent("deep-ink-eraser-trail.png"), options: .atomic)
    try check(deepScreenshot.size == deepViewport.size, "deep eraser renders only the small viewport")
    try check(deepErase.erasedIndices.contains(erasedIndex) && !deepErase.erasedIndices.contains(neighborIndex),
              "deep eraser hits the intended stroke without fading its neighbor")
    let deepTrail = rgbSamples(in: deepScreenshot, at: deepCrossing.applying(deepTransform))
    let untouched = rgbSamples(in: deepScreenshot, at: deepNeighbor.applying(deepTransform), radius: 12)
    let deepNativeReference = nativeReference(deepDrawing, viewport: deepViewport, transform: deepTransform)
    let expectedUntouched = rgbSamples(in: deepNativeReference, at: deepNeighbor.applying(deepTransform), radius: 12)
    try check(!deepTrail.isEmpty && deepTrail.allSatisfy { $0.allSatisfy { $0 >= 240 } },
              "white eraser trail stays aligned at document y 70000")
    try check(matchesNativeInk(untouched, expectedUntouched),
              "untouched neighboring ink preserves native fine-stroke pixels in the deep preview")
    guard let deepTrailLayer = deepPreview.layer.sublayers?.first?.sublayers?.last else {
        throw NSError(domain: "deep eraser missing public trail layer", code: 1)
    }
    let visibleDocument = deepViewport.applying(deepTransform.inverted()).intersection(deepDocument)
    try check(deepTrailLayer.bounds.height <= visibleDocument.height + 0.01 &&
              deepTrailLayer.bounds.width <= visibleDocument.width + 0.01 &&
              abs(deepTrailLayer.bounds.minY - visibleDocument.minY) < 0.01,
              "deep eraser trail bounds are the visible document slice rather than the entire 80000pt page")
    try check(deepTrailLayer.mask == nil && deepTrailLayer.masksToBounds,
              "deep trail uses bounded rectangular clipping without a page-sized alpha mask")
    let longTrail = (0..<2400).map { index in
        CGPoint(x: deepCrossing.x + sin(Double(index) * 0.01) * 10,
                y: deepCrossing.y + cos(Double(index) * 0.01) * 10)
    }
    for start in stride(from: 0, to: longTrail.count, by: 8) {
        deepPreview.extend(along: Array(longTrail[start..<min(start + 8, longTrail.count)]))
    }
    let chunks = deepTrailLayer.sublayers?.compactMap { $0 as? CAShapeLayer } ?? []
    let elementCounts = chunks.map { layer -> Int in
        var count = 0; layer.path?.applyWithBlock { _ in count += 1 }; return count
    }
    try check(chunks.count > 1 && elementCounts.allSatisfy { $0 <= 130 },
              "long eraser contacts keep path updates bounded instead of rebuilding the entire trail")
    let longScreenshot = UIGraphicsImageRenderer(bounds: deepViewport, format: format).image { output in
        deepPreview.layer.render(in: output.cgContext)
    }
    for point in [longTrail.first!, longTrail.last!] {
        let pixels = rgbSamples(in: longScreenshot, at: point.applying(deepTransform))
        try check(!pixels.isEmpty && pixels.allSatisfy { $0.allSatisfy { $0 >= 240 } },
                  "frozen and active eraser trail chunks retain white document-aligned pixels")
    }
    try check(deepErase.original.dataRepresentation() == deepOriginalBytes && deepDrawing.dataRepresentation() == deepOriginalBytes,
              "deep eraser preview preserves every original editable stroke")
    deepPreview.end()
    try check(deepPreview.isHidden && deepErase.original.dataRepresentation() == deepOriginalBytes,
              "ending a deep eraser preview preserves its original drawing")
    session.stop()
    try check(try store.drawing(noteID: noteID, pageID: page.id).dataRepresentation() == originalBytes,
              "cancelled movement cannot replace the persisted source drawing")
    let sorted = moveMilliseconds.sorted()
    let report = """
    fixture=180 short editable PencilKit strokes; blank page
    measurement_scope=synthetic production host calls; excludes assertion/image/serialization overhead; not Apple Pencil input latency
    selection_prepare_ms=\(String(format: "%.3f", preparationMilliseconds))
    freeform_query_ms=\(String(format: "%.3f", freeformMilliseconds))
    selection_query_ms=\(String(format: "%.3f", selectionQueryMilliseconds))
    preview_prepare_ms=\(String(format: "%.3f", previewPreparationMilliseconds))
    cached_preview_prepare_ms=\(String(format: "%.3f", warmPreparationMilliseconds))
    pointer_updates=\(moveMilliseconds.count)
    pointer_total_ms=\(String(format: "%.3f", moveMilliseconds.reduce(0, +)))
    pointer_median_ms=\(String(format: "%.3f", sorted[sorted.count / 2]))
    pointer_max_ms=\(String(format: "%.3f", sorted.last ?? 0))
    geometry_builds_before_moves=\(built)
    geometry_builds_during_moves=0
    native_viewport_updates=\(viewportUpdates)
    native_viewport_total_ms=\(String(format: "%.3f", viewportMilliseconds))
    native_view_coordinates_match=true
    original_and_cancelled_drawing_preserved=true
    white_gap_samples=3
    white_eraser_trail_verified=true
    deep_eraser_trail_verified=true
    """
    try report.write(to: PDFIntegrationChecks.directory.appendingPathComponent("ink-performance.txt"), atomically: true, encoding: .utf8)
    withExtendedLifetime(owner) {}
}
