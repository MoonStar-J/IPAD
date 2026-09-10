import SwiftUI
import PencilKit

struct NotebookCanvas: UIViewRepresentable {
    let note: Notebook
    let page: NotePage
    @ObservedObject var session: DrawingSession
    let store: NoteStore
    let fingerDrawing: Bool
    let editingObjects: Bool
    let toolsVisible: Bool
    var onTurnPage: (Int) -> Bool
    var onSelectElement: (UUID?) -> Void
    var onMoveElement: (UUID, Double, Double) -> Void

    func makeUIView(context: Context) -> CanvasHostView {
        let view = CanvasHostView(session: session)
        session.host = view
        return view
    }

    func updateUIView(_ view: CanvasHostView, context: Context) {
        view.configure(note: note, page: page, store: store, fingerDrawing: fingerDrawing,
                       editingObjects: editingObjects, toolsVisible: toolsVisible,
                       onSelect: onSelectElement, onMove: onMoveElement, onTurnPage: onTurnPage)
    }

    static func dismantleUIView(_ view: CanvasHostView, coordinator: ()) {
        view.session.stop()
    }
}

final class CanvasHostView: UIView, UIGestureRecognizerDelegate {
    let session: DrawingSession
    private var canvas: PagingCanvasView { session.canvas }
    private let paper = PaperView()
    private let eraserPreview = StrokeEraserPreviewView()
    private var strokeEraser: StrokeEraserGestureRecognizer!
    private var eraserTransaction: StrokeEraserTransaction?
    private var waitingForEraserRender = false
    private var canErase = true
    private let selectionLayer = CAShapeLayer()
    private var objectPan: UIPanGestureRecognizer!
    private var pageSwipes: [UISwipeGestureRecognizer] = []
    private var onTurnPage: ((Int) -> Bool)?
    private var objectTap: UITapGestureRecognizer!
    private var currentPage: NotePage?
    private var currentNote: Notebook?
    private var selectedID: UUID?
    private var dragOrigin = CGPoint.zero
    private var lastSize = CGSize.zero
    private var needsFit = true
    private var showTools = true
    private var onSelect: ((UUID?) -> Void)?
    private var onMove: ((UUID, Double, Double) -> Void)?

    init(session: DrawingSession) {
        self.session = session
        super.init(frame: .zero)
        backgroundColor = .secondarySystemBackground
        // PencilKit owns the viewport, scrolling, zooming and live ink rendering.
        // The PDF is a noninteractive sibling behind it, never a parent transform.
        paper.isOpaque = false
        paper.backgroundColor = .clear
        paper.isUserInteractionEnabled = false
        addSubview(paper)
        selectionLayer.strokeColor = UIColor.systemBlue.cgColor
        selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.07).cgColor
        selectionLayer.lineWidth = 2
        selectionLayer.lineDashPattern = [6, 4]
        layer.addSublayer(selectionLayer)
        objectPan = UIPanGestureRecognizer(target: self, action: #selector(moveObject(_:)))
        objectPan.maximumNumberOfTouches = 1
        objectTap = UITapGestureRecognizer(target: self, action: #selector(selectObject(_:)))
        addGestureRecognizer(objectPan)
        addGestureRecognizer(objectTap)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(turnPage(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 3
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            addGestureRecognizer(swipe)
            pageSwipes.append(swipe)
        }
        isAccessibilityElement = false
        installCanvas()
    }

    private func installCanvas() {
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        canvas.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvas.frame = bounds
        addSubview(canvas)
        addSubview(eraserPreview)
        strokeEraser = StrokeEraserGestureRecognizer(target: self, action: #selector(eraseStroke(_:)))
        strokeEraser.delegate = self
        canvas.addGestureRecognizer(strokeEraser)
        canvas.drawingGestureRecognizer.require(toFail: strokeEraser)
        // Selection must stay above the new render surface.
        layer.addSublayer(selectionLayer)
        canvas.panGestureRecognizer.require(toFail: objectPan)
        for swipe in pageSwipes {
            canvas.panGestureRecognizer.require(toFail: swipe)
            canvas.drawingGestureRecognizer.require(toFail: swipe)
            strokeEraser.require(toFail: swipe)
        }
        canvas.accessibilityLabel = "필기 용지"
        canvas.accessibilityIdentifier = "notebook-canvas"
        canvas.accessibilityHint = "Apple Pencil로 필기합니다. 손가락으로 화면을 확대하거나 이동할 수 있습니다."
    }

    func replaceCanvas(_ previous: PKCanvasView) {
        cancelStrokeErasing()
        previous.removeFromSuperview()
        installCanvas()
        // Force configuration of the new page even if SwiftUI delivered its
        // page metadata before onChange loaded that page's drawing.
        currentPage = nil
        needsFit = true
        setNeedsLayout()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func configure(note: Notebook, page: NotePage, store: NoteStore, fingerDrawing: Bool,
                   editingObjects: Bool, toolsVisible: Bool,
                   onSelect: @escaping (UUID?) -> Void, onMove: @escaping (UUID, Double, Double) -> Void, onTurnPage: @escaping (Int) -> Bool) {
        let pageChanged = currentPage?.id != page.id
        let contentChanged = currentPage != page || currentNote?.pdfAssetName != note.pdfAssetName
        currentNote = note
        currentPage = page
        self.onSelect = onSelect
        self.onMove = onMove
        self.onTurnPage = onTurnPage
        let canTurn = note.pages.count > 1 && !page.isContinuousPDF && !editingObjects && toolsVisible
        pageSwipes.forEach { if $0.isEnabled != canTurn { $0.isEnabled = canTurn } }
        session.canvas.pageTurningEnabled = canTurn
        if pageChanged {
            canvas.minimumZoomScale = min(canvas.minimumZoomScale, 1)
            canvas.maximumZoomScale = max(canvas.maximumZoomScale, 1)
            canvas.zoomScale = 1
            canvas.contentSize = CGSize(width: page.width, height: page.height)
            selectedID = nil
            needsFit = true
        }
        if contentChanged {
            paper.render = { [weak self, weak store] context in
                guard let self, let store else { return }
                context.saveGState()
                context.concatenate(self.documentToViewport)
                context.clip(to: CGRect(x: 0, y: 0, width: page.width, height: page.height))
                PageRenderer.drawBackground(page: page, note: note, store: store, context: context)
                context.restoreGState()
            }
        }
        let policy: PKCanvasViewDrawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
        let canDraw = !editingObjects && session.loadError == nil
        canErase = canDraw
        if !canDraw { cancelStrokeErasing() }
        if canvas.drawingGestureRecognizer.isEnabled != canDraw {
            canvas.drawingGestureRecognizer.isEnabled = canDraw
        }
        if objectPan.isEnabled != editingObjects { objectPan.isEnabled = editingObjects }
        if objectTap.isEnabled != editingObjects { objectTap.isEnabled = editingObjects }
        canvas.panGestureRecognizer.minimumNumberOfTouches = (fingerDrawing || editingObjects) ? 2 : 1
        if !editingObjects { selectedID = nil }
        updateSelection()
        showTools = toolsVisible && !editingObjects && session.loadError == nil
        DispatchQueue.main.async { [weak self] in
            guard let self, self.window != nil else { return }
            self.session.setToolsVisible(self.showTools)
        }
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if window != nil { session.setToolsVisible(showTools) }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        if eraserTransaction != nil && lastSize != bounds.size { cancelStrokeErasing() }
        if canvas.frame != bounds { canvas.frame = bounds }
        if paper.frame != bounds { paper.frame = bounds }
        if eraserPreview.frame != bounds { eraserPreview.frame = bounds }
        if needsFit || lastSize != bounds.size {
            lastSize = bounds.size
            if bounds.width > 0 && bounds.height > 0 { fitPage(animated: false); needsFit = false }
        }
        centerSheet()
        updateVisiblePaper()
    }

    func fitPage(animated: Bool) {
        guard let page = currentPage, bounds.width > 0 else { return }
        let fitWidth = (bounds.width - 48) / page.width
        let fit = max(0.01, page.isContinuousPDF ? fitWidth : min(fitWidth, (bounds.height - 110) / page.height))
        canvas.minimumZoomScale = fit
        canvas.maximumZoomScale = max(4, fit * 6)
        let changes = {
            self.canvas.setZoomScale(fit, animated: false)
            self.centerSheet()
            self.canvas.setContentOffset(CGPoint(x: -self.canvas.contentInset.left, y: -self.canvas.contentInset.top), animated: false)
        }
        if animated { UIView.animate(withDuration: 0.25, animations: changes) }
        else { changes() }
    }

    private func centerSheet() {
        let horizontal = max(24, (canvas.bounds.width - ((currentPage?.width ?? 0) * canvas.zoomScale)) / 2)
        let vertical = max(24, (canvas.bounds.height - 80 - ((currentPage?.height ?? 0) * canvas.zoomScale)) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical + 80, right: horizontal)
        if canvas.contentInset != inset { canvas.contentInset = inset }
    }

    @objc private func turnPage(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended, onTurnPage?(gesture.direction == .left ? 1 : -1) == true else { return }
        // Do not snapshot/crossfade the whole host: that includes the previous ink.
    }

    // The same transform is used for the PDF, selections and object hit-testing.
    // Ink uses these exact offset/zoom values internally in PKCanvasView.
    var documentToViewport: CGAffineTransform {
        CGAffineTransform(a: canvas.zoomScale, b: 0, c: 0, d: canvas.zoomScale,
                          tx: -canvas.contentOffset.x, ty: -canvas.contentOffset.y)
    }

    private func updateVisiblePaper() {
        paper.setNeedsDisplay()
        eraserPreview.documentToViewport = documentToViewport
        if !eraserPreview.isHidden { eraserPreview.paperImage = eraserPaperImage() }
        updateSelection()
    }

    private func eraserPaperImage() -> UIImage {
        UIGraphicsImageRenderer(bounds: bounds).image { renderer in
            (backgroundColor ?? .secondarySystemBackground).resolvedColor(with: traitCollection).setFill()
            renderer.fill(bounds)
            paper.render?(renderer.cgContext)
        }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard gestureRecognizer === strokeEraser, canErase,
              let tool = canvas.tool as? PKEraserTool, tool.eraserType == .vector else { return false }
        return touch.type == .pencil || (touch.type == .direct && canvas.drawingPolicy == .anyInput)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        gestureRecognizer === strokeEraser &&
            (other === canvas.pinchGestureRecognizer ||
             (other === canvas.panGestureRecognizer && other.numberOfTouches >= 2))
    }

    @objc private func eraseStroke(_ gesture: StrokeEraserGestureRecognizer) {
        guard gesture === strokeEraser else { return }
        switch gesture.state {
        case .began:
            guard let tool = canvas.tool as? PKEraserTool else { return }
            waitingForEraserRender = false
            eraserTransaction = StrokeEraserTransaction(drawing: canvas.drawing, width: tool.width)
            eraserPreview.begin(width: eraserTransaction!.width,
                                pageSize: CGSize(width: currentPage?.width ?? 0, height: currentPage?.height ?? 0))
            eraserPreview.paperImage = eraserPaperImage()
            eraserPreview.setDrawings(normal: canvas.drawing, faded: PKDrawing())
            // Keep native input/scroll geometry intact. Only replace ink presentation
            // during vector erasing; the saved PKDrawing stays unchanged until lift.
            // Cover ink with an opaque paper snapshot instead of hiding the canvas:
            // a second finger must still hit the canvas to cancel erasing and zoom.
            consumeEraserSamples(gesture)
        case .changed:
            consumeEraserSamples(gesture)
        case .ended:
            consumeEraserSamples(gesture)
            guard let transaction = eraserTransaction else { return }
            eraserTransaction = nil
            if transaction.erasedIndices.isEmpty { cancelStrokeErasing(); return }
            eraserPreview.clearTrail()
            eraserPreview.setDrawings(normal: transaction.remainingDrawing, faded: PKDrawing())
            waitingForEraserRender = true
            session.commitStrokeErasing(transaction.remainingDrawing)
        case .cancelled, .failed:
            cancelStrokeErasing()
        default: break
        }
    }

    private func consumeEraserSamples(_ gesture: StrokeEraserGestureRecognizer) {
        guard let transaction = eraserTransaction else { return }
        guard let tool = canvas.tool as? PKEraserTool, tool.eraserType == .vector else {
            cancelStrokeErasing()
            return
        }
        let previousCount = transaction.erasedIndices.count
        for point in gesture.takeSamples(in: self) {
            let documentPoint = point.applying(documentToViewport.inverted())
            transaction.extend(to: documentPoint)
            eraserPreview.extend(at: documentPoint)
        }
        if transaction.erasedIndices.count != previousCount {
            eraserPreview.setDrawings(normal: transaction.remainingDrawing, faded: transaction.erasedDrawing)
        }
    }

    func cancelStrokeErasing() {
        eraserTransaction = nil
        waitingForEraserRender = false
        eraserPreview.end()
    }

    func cancelEraserIfDrawingChanged(_ drawing: PKDrawing) {
        // Final Pencil pressure data can arrive after the previous pen was lifted.
        // Never overwrite that late ink with an earlier eraser snapshot.
        if let transaction = eraserTransaction,
           drawing.dataRepresentation() != transaction.original.dataRepresentation() {
            cancelStrokeErasing()
        }
    }

    func finishEraserRendering() {
        guard waitingForEraserRender else { return }
        waitingForEraserRender = false
        eraserPreview.end()
    }

    func canvasDidScroll() {
        if eraserTransaction != nil { cancelStrokeErasing() }
        updateVisiblePaper()
    }
    func canvasDidZoom() {
        if eraserTransaction != nil { cancelStrokeErasing() }
        centerSheet()
        updateVisiblePaper()
        let value = Int((canvas.zoomScale / max(canvas.minimumZoomScale, 0.01) * 100).rounded())
        DispatchQueue.main.async { [weak session] in
            if session?.zoomPercent != value { session?.zoomPercent = value }
        }
    }

    private func element(at point: CGPoint) -> PageElement? {
        currentPage?.elements.reversed().first {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(point)
        }
    }

    @objc private func selectObject(_ gesture: UITapGestureRecognizer) {
        selectedID = element(at: gesture.location(in: self).applying(documentToViewport.inverted()))?.id
        updateSelection()
        onSelect?(selectedID)
    }

    @objc private func moveObject(_ gesture: UIPanGestureRecognizer) {
        guard var page = currentPage else { return }
        if gesture.state == .began {
            guard let element = element(at: gesture.location(in: self).applying(documentToViewport.inverted())) else { selectedID = nil; updateSelection(); return }
            selectedID = element.id
            dragOrigin = CGPoint(x: element.x, y: element.y)
            onSelect?(selectedID)
        }
        guard let id = selectedID, let index = page.elements.firstIndex(where: { $0.id == id }) else { return }
        let translation = gesture.translation(in: self)
        let delta = CGPoint(x: translation.x / canvas.zoomScale, y: translation.y / canvas.zoomScale)
        let x = min(max(0, dragOrigin.x + delta.x), max(0, page.width - page.elements[index].width))
        let y = min(max(0, dragOrigin.y + delta.y), max(0, page.height - page.elements[index].height))
        page.elements[index].x = x
        page.elements[index].y = y
        // Commit once at the end; show the destination outline while dragging.
        selectionLayer.path = UIBezierPath(rect: CGRect(x: x, y: y, width: page.elements[index].width, height: page.elements[index].height).applying(documentToViewport)).cgPath
        if gesture.state == .ended { onMove?(id, x, y) }
        if gesture.state == .cancelled { updateSelection() }
    }

    private func updateSelection() {
        guard let element = currentPage?.elements.first(where: { $0.id == selectedID }) else { selectionLayer.path = nil; return }
        selectionLayer.path = UIBezierPath(rect: CGRect(x: element.x, y: element.y, width: element.width, height: element.height).applying(documentToViewport)).cgPath
    }
}

// A viewport-sized, noninteractive overlay. It never changes the live canvas's
// frame, drawing, zoom, or offset, including on very long stitched PDFs.
final class StrokeEraserPreviewView: UIView {
    var paperImage: UIImage? { didSet { setNeedsDisplay() } }
    var documentToViewport = CGAffineTransform.identity {
        didSet { if documentToViewport != oldValue { cachedInk = nil; cachedFadedInk = nil; setNeedsDisplay() } }
    }
    private(set) var normalDrawing = PKDrawing()
    private(set) var fadedDrawing = PKDrawing()
    private var cachedInk: UIImage?
    private var cachedFadedInk: UIImage?
    func setDrawings(normal: PKDrawing, faded: PKDrawing) {
        normalDrawing = normal
        fadedDrawing = faded
        cachedInk = nil
        cachedFadedInk = nil
        setNeedsDisplay()
    }
    private var trail = UIBezierPath()
    private var eraserWidth: CGFloat = 12
    private var pageSize = CGSize.zero
    private var lastPoint: CGPoint?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        isOpaque = false
        backgroundColor = .clear
        isHidden = true
        overrideUserInterfaceStyle = .light
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func begin(width: CGFloat, pageSize: CGSize) {
        end()
        self.pageSize = pageSize
        eraserWidth = width
        isHidden = false
    }
    func extend(at point: CGPoint) {
        if lastPoint == nil {
            trail.move(to: point)
            trail.addLine(to: CGPoint(x: point.x + 0.01, y: point.y))
        } else { trail.addLine(to: point) }
        lastPoint = point
        setNeedsDisplay()
    }
    func end() {
        isHidden = true
        paperImage = nil
        setDrawings(normal: PKDrawing(), faded: PKDrawing())
        trail = UIBezierPath()
        lastPoint = nil
        cachedInk = nil
    }
    func clearTrail() { trail = UIBezierPath(); lastPoint = nil; setNeedsDisplay() }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        paperImage?.draw(in: bounds)
        context.saveGState()
        context.clip(to: CGRect(origin: .zero, size: pageSize).applying(documentToViewport))
        let visible = bounds.applying(documentToViewport.inverted())
        let scale = documentToViewport.a * contentScaleFactor
        if !normalDrawing.strokes.isEmpty {
            if cachedInk == nil { cachedInk = normalDrawing.image(from: visible, scale: scale) }
            cachedInk?.draw(in: bounds)
        }
        if !fadedDrawing.strokes.isEmpty {
            if cachedFadedInk == nil { cachedFadedInk = fadedDrawing.image(from: visible, scale: scale) }
            cachedFadedInk?.draw(in: bounds, blendMode: .normal, alpha: 0.35)
        }
        context.concatenate(documentToViewport)
        UIColor.white.setStroke()
        trail.lineWidth = eraserWidth
        trail.lineCapStyle = .round
        trail.lineJoinStyle = .round
        trail.stroke()
        context.restoreGState()
    }
}

/// Receives only vector-erasing touches. Other tools fail this recognizer at
/// shouldReceive, leaving PencilKit's existing recognizer and live ink untouched.
final class StrokeEraserGestureRecognizer: UIGestureRecognizer {
    private weak var trackedTouch: UITouch?
    private var samples: [CGPoint] = []

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if let trackedTouch, trackedTouch.type == .pencil {
            for touch in touches where touch !== trackedTouch { ignore(touch, for: event) }
            return
        }
        guard trackedTouch == nil, touches.count == 1, let touch = touches.first else {
            state = state == .possible ? .failed : .cancelled
            return
        }
        trackedTouch = touch
        samples.append(touch.location(in: nil))
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        for sample in event.coalescedTouches(for: touch) ?? [touch] { samples.append(sample.location(in: nil)) }
        state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let touch = trackedTouch, touches.contains(touch) else { return }
        samples.append(touch.location(in: nil))
        state = .ended
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) { state = .cancelled }
    override func reset() { super.reset(); trackedTouch = nil; samples.removeAll(keepingCapacity: true) }
    func takeSamples(in view: UIView) -> [CGPoint] {
        let points = samples.map { view.convert($0, from: nil) }
        samples.removeAll(keepingCapacity: true)
        return points
    }
}
