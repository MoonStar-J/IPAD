import SwiftUI
import PencilKit

@MainActor
final class DrawingSession: NSObject, ObservableObject, PKCanvasViewDelegate {
    private(set) var canvas = PagingCanvasView()
    let toolPicker = PKToolPicker()
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var zoomPercent = 100
    @Published var loadError: String?
    weak var host: CanvasHostView?
    private weak var store: NoteStore?
    private var noteID: UUID?
    private var pageID: UUID?
    private var loading = false
    private var toolsAreVisible = false
    private var undoObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        configureCanvas(canvas)
        toolPicker.addObserver(canvas)
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshUndo() }
            })
        }
    }

    deinit { for observer in undoObservers { NotificationCenter.default.removeObserver(observer) } }

    private func configureCanvas(_ canvas: PagingCanvasView) {
        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = true
        canvas.overrideUserInterfaceStyle = .light
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.drawingPolicy = .pencilOnly
    }

    func load(noteID: UUID, pageID: UUID, store: NoteStore) {
        guard self.noteID != noteID || self.pageID != pageID else { return }
        host?.cancelStrokeErasing()
        store.flushDrawings()
        self.store = store
        self.noteID = noteID
        self.pageID = pageID
        loading = true
        loadError = nil
        let previous = canvas
        let selectedTool = previous.tool
        let replacement = PagingCanvasView()
        configureCanvas(replacement)
        // An empty drawing can leave old PencilKit render tiles alive on a reused
        // view. Give each page its own render surface, without changing ink coordinates.
        previous.delegate = nil
        toolPicker.setVisible(false, forFirstResponder: previous)
        toolPicker.removeObserver(previous)
        if previous.isFirstResponder { previous.resignFirstResponder() }
        toolsAreVisible = false
        canvas = replacement
        toolPicker.addObserver(replacement)
        replacement.tool = selectedTool
        host?.replaceCanvas(previous)
        do {
            if let note = store.note(noteID), let page = note.pages.first(where: { $0.id == pageID }), !PageRenderer.hasValidPDFBackground(page: page, note: note, store: store) {
                throw CocoaError(.fileReadCorruptFile)
            }
            canvas.drawing = try store.drawing(noteID: noteID, pageID: pageID)
        }
        catch {
            loadError = "이 페이지의 필기를 불러올 수 없습니다. 원본을 보호하기 위해 편집을 중지했습니다. \(error.localizedDescription)"
            canvas.drawing = PKDrawing()
        }
        canvas.undoManager?.removeAllActions()
        loading = false
        refreshUndo()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard canvasView === canvas, !loading, loadError == nil, let noteID, let pageID else { return }
        host?.cancelEraserIfDrawingChanged(canvasView.drawing)
        store?.queueDrawing(canvasView.drawing, noteID: noteID, pageID: pageID)
        // Undo groups close at the end of the current event.
        DispatchQueue.main.async { [weak self] in self?.refreshUndo() }
    }

    func commitStrokeErasing(_ drawing: PKDrawing) {
        replaceDrawing(drawing, on: canvas)
    }

    private func replaceDrawing(_ drawing: PKDrawing, on target: PagingCanvasView) {
        guard target === canvas else { return }
        let previous = target.drawing
        target.undoManager?.registerUndo(withTarget: target) { [weak self] target in
            self?.replaceDrawing(previous, on: target)
        }
        target.undoManager?.setActionName("획 지우기")
        target.drawing = drawing
        canvasViewDrawingDidChange(target)
    }

    func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
        guard canvasView === canvas else { return }
        host?.finishEraserRendering()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === canvas { host?.canvasDidScroll() }
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if scrollView === canvas { host?.canvasDidZoom() }
    }

    func refreshUndo() {
        let undo = canvas.undoManager?.canUndo ?? false
        let redo = canvas.undoManager?.canRedo ?? false
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
    }
    func undo() { host?.cancelStrokeErasing(); canvas.undoManager?.undo(); refreshUndo() }
    func redo() { host?.cancelStrokeErasing(); canvas.undoManager?.redo(); refreshUndo() }
    func fitPage() { host?.fitPage(animated: true) }

    func setToolsVisible(_ visible: Bool) {
        // SwiftUI updates while ink is being saved. Do not repeatedly reattach the
        // picker / first responder during an active stroke.
        let shouldShow = visible && canvas.window != nil
        if toolsAreVisible != shouldShow {
            toolPicker.setVisible(shouldShow, forFirstResponder: canvas)
            toolsAreVisible = shouldShow
        }
        if shouldShow && !canvas.isFirstResponder { canvas.becomeFirstResponder() }
        else if !shouldShow && canvas.isFirstResponder { canvas.resignFirstResponder() }
    }

    func stop() { host?.cancelStrokeErasing(); store?.flushDrawings(); setToolsVisible(false) }
}

final class PagingCanvasView: PKCanvasView {
    var pageTurningEnabled = false
    // The canvas owns three-finger paging; toolbar undo/redo remain available.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        pageTurningEnabled ? .none : .default
    }
}

/// One eraser contact is one transaction. Hit-testing uses rendered alpha, so
/// lasso transforms, pressure widths and holes from the pixel eraser are respected.
@MainActor
final class StrokeEraserTransaction {
    let original: PKDrawing
    let width: CGFloat
    private(set) var erasedIndices = Set<Int>()
    private var previousPoint: CGPoint?

    init(drawing: PKDrawing, width: CGFloat) {
        original = drawing
        self.width = width.isFinite && width > 0 ? width : 12
    }
    var remainingDrawing: PKDrawing {
        PKDrawing(strokes: original.strokes.enumerated().compactMap { erasedIndices.contains($0.offset) ? nil : $0.element })
    }
    var erasedDrawing: PKDrawing {
        PKDrawing(strokes: original.strokes.enumerated().compactMap { erasedIndices.contains($0.offset) ? $0.element : nil })
    }
    func extend(to point: CGPoint) {
        let start = previousPoint ?? point
        previousPoint = point
        let radius = width / 2
        let sweptBounds = CGRect(x: min(start.x, point.x) - radius, y: min(start.y, point.y) - radius,
                                 width: abs(point.x - start.x) + width, height: abs(point.y - start.y) + width)
        for (index, stroke) in original.strokes.enumerated() where !erasedIndices.contains(index) {
            let region = stroke.renderBounds.intersection(sweptBounds).integral
            guard !region.isNull, region.width > 0, region.height > 0 else { continue }
            if hits(stroke, region: region, start: start, end: point, radius: radius) {
                erasedIndices.insert(index)
            }
        }
    }
    private func hits(_ stroke: PKStroke, region: CGRect, start: CGPoint, end: CGPoint, radius: CGFloat) -> Bool {
        // Tile the swept area: neither a tall PDF nor a rapid long drag can allocate
        // a document-sized bitmap. Ignore transparent pixels, including stroke masks.
        let tileSize: CGFloat = 128
        var y = region.minY
        while y < region.maxY {
            var x = region.minX
            while x < region.maxX {
                let tile = CGRect(x: x, y: y, width: min(tileSize, region.maxX - x), height: min(tileSize, region.maxY - y))
                let image = PKDrawing(strokes: [stroke]).image(from: tile, scale: 1).cgImage!
                let w = image.width, h = image.height
                var pixels = [UInt8](repeating: 0, count: w * h * 4)
                pixels.withUnsafeMutableBytes { bytes in
                    let context = CGContext(data: bytes.baseAddress, width: w, height: h, bitsPerComponent: 8,
                                            bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue)!
                    context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
                }
                let dx = end.x - start.x, dy = end.y - start.y
                let lengthSquared = dx * dx + dy * dy
                for row in 0..<h {
                    for column in 0..<w where pixels[(row * w + column) * 4 + 3] > 2 {
                        let px = tile.minX + CGFloat(column) + 0.5
                        let py = tile.minY + CGFloat(row) + 0.5
                        let fraction = lengthSquared > 0 ? min(1, max(0, ((px - start.x) * dx + (py - start.y) * dy) / lengthSquared)) : 0
                        if hypot(px - start.x - fraction * dx, py - start.y - fraction * dy) <= radius {
                            return true
                        }
                    }
                }
                x += tileSize
            }
            y += tileSize
        }
        return false
    }
}
