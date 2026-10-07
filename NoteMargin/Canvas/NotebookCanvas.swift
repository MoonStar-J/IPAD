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
    var selectingRegion = false
    var onRegionChange: ((CGRect?) -> Void)? = nil
    var onViewportChange: ((CGAffineTransform, CGRect) -> Void)? = nil

    func makeUIView(context: Context) -> CanvasHostView {
        let view = CanvasHostView(session: session)
        session.host = view
        return view
    }

    func updateUIView(_ view: CanvasHostView, context: Context) {
        view.configure(note: note, page: page, store: store, fingerDrawing: fingerDrawing,
                       editingObjects: editingObjects, toolsVisible: toolsVisible,
                       onSelect: onSelectElement, onMove: onMoveElement, onTurnPage: onTurnPage, selectingRegion: selectingRegion,
                       onRegionChange: onRegionChange, onViewportChange: onViewportChange)
    }

    static func dismantleUIView(_ view: CanvasHostView, coordinator: ()) {
        view.session.stop()
    }
}

final class CanvasHostView: UIView, UIGestureRecognizerDelegate {
    let session: DrawingSession
    private var canvas: PagingCanvasView { session.canvas }
    private let paper = PaperView()
    private let regionSelection = RegionSelectionView()
    private var onViewportChange: ((CGAffineTransform, CGRect) -> Void)?
    private var lastReportedTransform = CGAffineTransform.identity
    private var lastReportedBounds = CGRect.zero
    private var lastReportedRegion: CGRect?
    private let eraserPreview = StrokeEraserPreviewView()
    private var strokeEraser: StrokeEraserGestureRecognizer!
    private var eraserTransaction: StrokeEraserTransaction?
    private var retainedGeometry: InkGeometryCache?
    private var previewWarmup: Task<Void, Never>?
    private var drawingActive = false
    private var waitingForEraserRender = false
    private var eraserCommitDrawing: PKDrawing?
    private var eraserHandoff: Task<Void, Never>?
    private var canErase = true
    private let inkSelectionLayer = CAShapeLayer()
    private let inkPreview = InkTransformPreview()
    private var waitingForInkRender = false
    private var inkCommitDrawing: PKDrawing?
    private var inkHandoffScheduled = false
    private var inkCommitEcho = false
    private var inkRenderGeneration: UInt64 = 0
    private var automaticShape: (ids: Set<InkStrokeID>, frame: ShapeEditFrame, points: [CGPoint])?
    private var shapeSelectionPending = false
    private var shapeResize: ShapeResizeDrag?
    var hasAutomaticShapeSelection: Bool { automaticShape != nil && !shapeSelectionPending }
    var automaticShapeFrame: ShapeEditFrame? { automaticShape?.frame }
    private var committingInk = false
    private var fitScale: CGFloat = 1
    private var adjustingViewport = false
    private var viewportNotificationPending = false
    private var inkPan: UIPanGestureRecognizer!
    private var inkTap: UITapGestureRecognizer!
    private var selectionActionsUpdatePending = false
    private var inkSelection: RectangularInkSelection?
    private(set) var inkSelectionRect: CGRect?
    private var inkResizeAnchor = CGPoint.zero
    private var inkProposedRect: CGRect?
    private var inkStart = CGPoint.zero
    private var freeformPath: UIBezierPath?
    private var inkDragTransform = CGAffineTransform.identity
    private var inkDragging = false
    private var inkResizing = false
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
        // Paper is a document-space child of the native scroll view. Scrolling
        // moves paper and ink with ONE bounds change, not two delegate updates.
        paper.isOpaque = false
        paper.backgroundColor = .clear
        paper.isUserInteractionEnabled = false
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
        inkSelectionLayer.strokeColor = UIColor.systemBlue.cgColor
        inkSelectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.08).cgColor
        inkSelectionLayer.lineWidth = 2
        inkSelectionLayer.lineDashPattern = [6, 4]
        inkPan = RectangleSelectionGestureRecognizer(target: self, action: #selector(selectInk(_:)))
        inkPan.maximumNumberOfTouches = 1
        inkPan.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue), NSNumber(value: UITouch.TouchType.pencil.rawValue)]
        inkPan.isEnabled = false
        inkPan.delegate = self
        addGestureRecognizer(inkPan)
        inkTap = UITapGestureRecognizer(target: self, action: #selector(tapInkSelection(_:)))
        inkTap.allowedTouchTypes = inkPan.allowedTouchTypes
        inkTap.delegate = self
        inkTap.require(toFail: inkPan)
        inkTap.isEnabled = false
        addGestureRecognizer(inkTap)
        isAccessibilityElement = false
        installCanvas()
    }

    private func installCanvas() {
        canvas.showsVerticalScrollIndicator = false
        canvas.showsHorizontalScrollIndicator = false
        canvas.contentInsetAdjustmentBehavior = .never
        // A minimum-scale pinch must stop at the overview, not animate through
        // an elastic scale with different centering insets and then spring back.
        canvas.bouncesZoom = false
        canvas.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        canvas.frame = bounds
        addSubview(canvas)
        canvas.insertSubview(paper, at: 0)
        addSubview(eraserPreview)
        addSubview(inkPreview)
        addSubview(regionSelection)
        strokeEraser = StrokeEraserGestureRecognizer(target: self, action: #selector(eraseStroke(_:)))
        strokeEraser.delegate = self
        canvas.addGestureRecognizer(strokeEraser)
        canvas.drawingGestureRecognizer.require(toFail: strokeEraser)
        // Selection must stay above the new render surface.
        layer.addSublayer(selectionLayer)
        layer.addSublayer(inkSelectionLayer)
        canvas.panGestureRecognizer.require(toFail: objectPan)
        canvas.panGestureRecognizer.require(toFail: inkPan)
        canvas.drawingGestureRecognizer.require(toFail: inkPan)
        canvas.drawingGestureRecognizer.require(toFail: inkTap)
        for swipe in pageSwipes {
            canvas.panGestureRecognizer.require(toFail: swipe)
            canvas.drawingGestureRecognizer.require(toFail: swipe)
            strokeEraser.require(toFail: swipe)
            inkPan.require(toFail: swipe)
        }
        canvas.accessibilityLabel = "필기 용지"
        canvas.accessibilityIdentifier = "notebook-canvas"
        canvas.accessibilityHint = "Apple Pencil로 필기합니다. 손가락으로 화면을 확대하거나 이동할 수 있습니다."
    }

    func replaceCanvas(_ previous: PKCanvasView) {
        previewWarmup?.cancel(); previewWarmup = nil
        retainedGeometry = nil
        clearInkSelection()
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
                   onSelect: @escaping (UUID?) -> Void, onMove: @escaping (UUID, Double, Double) -> Void, onTurnPage: @escaping (Int) -> Bool,
                   selectingRegion: Bool = false, onRegionChange: ((CGRect?) -> Void)? = nil,
                   onViewportChange: ((CGAffineTransform, CGRect) -> Void)? = nil) {
        let pageChanged = currentPage?.id != page.id
        let contentChanged = currentPage != page || currentNote?.pdfAssetName != note.pdfAssetName
        currentNote = note
        currentPage = page
        self.onSelect = onSelect
        self.onMove = onMove
        self.onTurnPage = onTurnPage
        self.onViewportChange = onViewportChange
        regionSelection.onChange = { [weak self] rect in
            guard let self else { return }
            let document = rect.applying(self.documentToViewport.inverted())
                .intersection(CGRect(x: 0, y: 0, width: page.width, height: page.height))
            guard document != self.lastReportedRegion else { return }
            self.lastReportedRegion = document
            DispatchQueue.main.async { onRegionChange?(document) }
        }
        regionSelection.isHidden = !selectingRegion
        if !selectingRegion { regionSelection.clear(); lastReportedRegion = nil }
        let canTurn = note.pages.count > 1 && !page.isContinuousPDF && !editingObjects && !selectingRegion && toolsVisible
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
            paper.documentBounds = CGRect(x: 0, y: 0, width: page.width, height: page.height)
            paper.render = { [weak store] context in
                guard let store else { return }
                context.saveGState()
                context.clip(to: CGRect(x: 0, y: 0, width: page.width, height: page.height))
                PageRenderer.drawBackground(page: page, note: note, store: store, context: context)
                context.restoreGState()
            }
        }
        let policy: PKCanvasViewDrawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        if canvas.drawingPolicy != policy { canvas.drawingPolicy = policy }
        let rectangular = session.selectedTool.isSelection && !editingObjects && !selectingRegion && toolsVisible && session.loadError == nil
        if pageChanged || (!rectangular && automaticShape == nil) || editingObjects || selectingRegion { clearInkSelection() }
        let selectionInput = rectangular || hasAutomaticShapeSelection
        if inkPan.isEnabled != selectionInput { inkPan.isEnabled = selectionInput }
        if inkTap.isEnabled != selectionInput { inkTap.isEnabled = selectionInput }
        let canDraw = !editingObjects && !selectingRegion && session.loadError == nil && !rectangular
        canErase = canDraw
        if !canDraw { cancelStrokeErasing() }
        if canvas.drawingGestureRecognizer.isEnabled != canDraw {
            canvas.drawingGestureRecognizer.isEnabled = canDraw
        }
        if objectPan.isEnabled != (editingObjects && !selectingRegion) { objectPan.isEnabled = editingObjects && !selectingRegion }
        if objectTap.isEnabled != (editingObjects && !selectingRegion) { objectTap.isEnabled = editingObjects && !selectingRegion }
        canvas.panGestureRecognizer.minimumNumberOfTouches = (fingerDrawing || editingObjects || rectangular) ? 2 : 1
        if !editingObjects { selectedID = nil }
        updateSelection()
        showTools = toolsVisible && !editingObjects && !selectingRegion && session.loadError == nil
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
        if regionSelection.frame != bounds { regionSelection.frame = bounds }
        if eraserPreview.frame != bounds { eraserPreview.frame = bounds }
        if inkPreview.frame != bounds { inkPreview.frame = bounds }
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
        let fit = max(0.01, page.isContinuousPDF ? fitWidth : min(fitWidth, (bounds.height - 48) / page.height))
        fitScale = fit
        canvas.minimumZoomScale = fit * 0.5
        canvas.maximumZoomScale = max(4, fit * 6)
        let changes = {
            self.canvas.setZoomScale(fit, animated: false)
            self.centerSheet()
            self.canvas.setContentOffset(CGPoint(x: -self.canvas.contentInset.left, y: -self.canvas.contentInset.top), animated: false)
        }
        // A surrounding UIView animation interpolates native ink separately from
        // the document layers. Fit is one atomic viewport change instead.
        changes()
    }

    private func centerSheet(settleOffset: Bool = false) {
        guard !adjustingViewport else { return }
        let horizontal = max(24, (canvas.bounds.width - ((currentPage?.width ?? 0) * canvas.zoomScale)) / 2)
        let vertical = max(24, (canvas.bounds.height - ((currentPage?.height ?? 0) * canvas.zoomScale)) / 2)
        let inset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical, right: horizontal)
        // A save/SwiftUI refresh can lay out the host without a viewport change.
        // Preserve its live offset; only zoom or changed centering may settle it.
        guard settleOffset || canvas.contentInset != inset else { return }
        let offset = canvas.contentOffset
        let scaled = CGSize(width: (currentPage?.width ?? 0) * canvas.zoomScale,
                            height: (currentPage?.height ?? 0) * canvas.zoomScale)
        var settled = offset
        // Once an axis fits, there is exactly one centered position. Updating
        // inset without this offset lets UIScrollView present an intermediate
        // out-of-bounds position before its own correction animation.
        if scaled.width + 48 <= canvas.bounds.width { settled.x = -inset.left }
        else if canvas.isZooming || !canvas.isTracking {
            settled.x = min(max(offset.x, -inset.left), max(-inset.left, scaled.width - canvas.bounds.width + inset.right))
        }
        if scaled.height + 48 <= canvas.bounds.height { settled.y = -inset.top }
        else if canvas.isZooming || !canvas.isTracking {
            settled.y = min(max(offset.y, -inset.top), max(-inset.top, scaled.height - canvas.bounds.height + inset.bottom))
        }
        guard canvas.contentInset != inset || canvas.contentOffset != settled else { return }
        adjustingViewport = true
        defer { adjustingViewport = false }
        UIView.performWithoutAnimation {
            CATransaction.begin(); CATransaction.setDisableActions(true)
            if canvas.contentInset != inset { canvas.contentInset = inset }
            if canvas.contentOffset != settled { canvas.setContentOffset(settled, animated: false) }
            CATransaction.commit()
        }
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

    /// Shape preview uses the same immutable paper/PDF tiles as the native
    /// scroll surface. The original paper stays in its native scroll hierarchy.
    func copyShapePreviewBackground(to target: CALayer) {
        let background = CALayer()
        paper.copyCachedTiles(to: background, fill: nil)
        background.setAffineTransform(documentToViewport)
        target.addSublayer(background)
    }

    private func updateVisiblePaper() {
        paper.updateViewport(documentToViewport, viewport: bounds,
                             interacting: canvas.isTracking || canvas.isZooming || canvas.isDecelerating)
        if !inkPreview.isHidden { inkPreview.updateViewport(documentToViewport, paper: paper) }
        if !eraserPreview.isHidden { eraserPreview.updateViewport(documentToViewport, paper: paper) }
        if !regionSelection.isHidden, let page = currentPage {
            let visiblePage = CGRect(x: 0, y: 0, width: page.width, height: page.height).applying(documentToViewport).intersection(bounds.insetBy(dx: 12, dy: 12))
            regionSelection.configure(available: visiblePage)
        }
        if lastReportedTransform != documentToViewport || lastReportedBounds != bounds {
            lastReportedTransform = documentToViewport
            lastReportedBounds = bounds
            if !viewportNotificationPending {
                viewportNotificationPending = true
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.viewportNotificationPending = false
                    self.onViewportChange?(self.lastReportedTransform, self.lastReportedBounds)
                }
            }
        }
        updateSelection()
        updateInkOutline()
        schedulePreviewWarmup()
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        if gestureRecognizer === inkPan || gestureRecognizer === inkTap {
            guard inkPan.isEnabled, touch.type == .direct || touch.type == .pencil else { return false }
            if hasAutomaticShapeSelection, gestureRecognizer === inkPan {
                return shapeContains(touch.location(in: self).applying(documentToViewport.inverted()))
            }
            return true
        }
        guard gestureRecognizer === strokeEraser, canErase,
              let tool = canvas.tool as? PKEraserTool, tool.eraserType == .vector else { return false }
        return touch.type == .pencil || (touch.type == .direct && canvas.drawingPolicy == .anyInput)
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        (gestureRecognizer === strokeEraser || gestureRecognizer === inkPan) &&
            (other === canvas.pinchGestureRecognizer ||
             (other === canvas.panGestureRecognizer && other.numberOfTouches >= 2))
    }

    @objc private func eraseStroke(_ gesture: StrokeEraserGestureRecognizer) {
        guard gesture === strokeEraser else { return }
        switch gesture.state {
        case .began:
            previewWarmup?.cancel(); previewWarmup = nil
            guard let tool = canvas.tool as? PKEraserTool, tool.eraserType == .vector else { return }
            waitingForEraserRender = false
            // PencilKit vector erasers report width 0 and ignore a supplied
            // width. Our deferred stroke eraser must use its own saved radius.
            eraserTransaction = StrokeEraserTransaction(drawing: canvas.drawing, width: session.eraserWidth, geometryCache: geometry(for: canvas.drawing))
            paper.setDrawingActive(true)
            eraserPreview.begin(transaction: eraserTransaction!, paper: paper,
                                viewport: bounds, transform: documentToViewport)
            // Reuse native PencilKit textures and paper tiles; never replace ink
            // appearance with hit-test geometry or rerender on each sample.
            consumeEraserSamples(gesture)
        case .changed:
            consumeEraserSamples(gesture)
        case .ended:
            consumeEraserSamples(gesture)
            guard let transaction = eraserTransaction else { return }
            eraserTransaction = nil
            if transaction.erasedIndices.isEmpty { cancelStrokeErasing(); session.finishErasing(); return }
            eraserPreview.clearTrail()
            eraserPreview.setErased(transaction.erasedIndices, committed: true)
            paper.setDrawingActive(false)
            waitingForEraserRender = true
            let remaining = transaction.remainingDrawing
            eraserCommitDrawing = remaining
            session.commitStrokeErasing(remaining)
            session.finishErasing()
        case .cancelled, .failed:
            cancelStrokeErasing()
        default: break
        }
    }

    private func geometry(for drawing: PKDrawing) -> InkGeometryCache {
        if let cache = retainedGeometry, cache.drawing == drawing { return cache }
        let cache = retainedGeometry?.updated(to: drawing) ?? InkGeometryCache(drawing: drawing)
        retainedGeometry = cache
        return cache
    }

    func schedulePreviewWarmup() {
        previewWarmup?.cancel(); previewWarmup = nil
        // An inking tool never needs a raster copy of finished strokes. Prepare
        // this secondary representation only when its interaction is selected.
        // Native partial erasing keeps PencilKit's own renderer/index throughout.
        guard session.selectedTool == .eraser || session.selectedTool.isSelection else { return }
        guard !drawingActive, eraserTransaction == nil, !inkDragging, !canvas.isTracking,
              !canvas.isZooming, !canvas.isDecelerating, canvas.window != nil, !bounds.isEmpty else { return }
        let target = canvas
        previewWarmup = Task { [weak self, weak target] in
            guard !Task.isCancelled else { return }
            guard let self, let target, self.canvas === target, target.window != nil, !self.drawingActive else { return }
            let drawing = target.drawing
            let sourceRevision = self.session.drawingRevision
            let cache = self.geometry(for: drawing)
            let transform = self.documentToViewport
            let scale = max(0.01, transform.a) * UIScreen.main.scale
            let visible = self.bounds.applying(transform.inverted()).insetBy(dx: -512 / scale, dy: -512 / scale)
            let frameBudget = 0.25 / Double(max(1, self.window?.screen.maximumFramesPerSecond ?? 60))
            var batchStart = CACurrentMediaTime()
            for index in cache.candidates(intersecting: visible) {
                guard !Task.isCancelled, self.canvas === target, self.session.drawingRevision == sourceRevision,
                      !self.drawingActive, self.eraserTransaction == nil, !self.inkDragging else { return }
                _ = cache.nativeRasterCache.tiles(for: index, visible: visible, scale: scale)
                // Yield between small main-actor batches so native Pencil input
                // can interrupt warming; never render PencilKit off-thread.
                if CACurrentMediaTime() - batchStart >= frameBudget {
                    await Task.yield()
                    batchStart = CACurrentMediaTime()
                }
            }
        }
    }

    private func consumeEraserSamples(_ gesture: StrokeEraserGestureRecognizer) {
        guard let transaction = eraserTransaction else { return }
        guard let tool = canvas.tool as? PKEraserTool, tool.eraserType == .vector else {
            cancelStrokeErasing()
            return
        }
        let previousCount = transaction.erasedIndices.count
        let viewToDocument = documentToViewport.inverted()
        let points = gesture.takeSamples(in: self).map { $0.applying(viewToDocument) }
        DrawingEngineMetrics.erasing {
            transaction.extend(along: points)
            eraserPreview.extend(along: points)
        }
        if transaction.erasedIndices.count != previousCount {
            eraserPreview.setErased(transaction.erasedIndices)
        }
    }

    func cancelStrokeErasing() {
        if eraserTransaction != nil { paper.setDrawingActive(false) }
        eraserTransaction = nil
        waitingForEraserRender = false
        eraserCommitDrawing = nil
        eraserHandoff?.cancel(); eraserHandoff = nil
        eraserPreview.end()
    }

    func cancelEraserIfDrawingChanged(_ drawing: PKDrawing) {
        // Final Pencil pressure data can arrive after the previous pen was lifted.
        // Never overwrite that late ink with an earlier eraser snapshot.
        if let transaction = eraserTransaction, drawing != transaction.original {
            cancelStrokeErasing()
        } else if waitingForEraserRender, drawing != eraserCommitDrawing {
            cancelStrokeErasing()
        }
    }

    func finishEraserRendering() {
        guard waitingForEraserRender, eraserHandoff == nil, let committed = eraserCommitDrawing,
              canvas.drawing == committed else { return }
        let target = canvas
        eraserHandoff = Task { [weak self] in
            // A render callback can precede presentation of its CA transaction.
            // Keep feedback through that display handoff; a new page/tool cancels it.
            do { try await Task.sleep(for: .milliseconds(34)) } catch { return }
            guard let self, self.canvas === target, self.waitingForEraserRender,
                  self.canvas.drawing == committed else { return }
            self.cancelStrokeErasing()
        }
    }

    func setDrawingActive(_ active: Bool) {
        drawingActive = active
        if active {
            previewWarmup?.cancel(); previewWarmup = nil
            if waitingForEraserRender { cancelStrokeErasing() }
            if waitingForInkRender { endInkPreview() }
        }
        paper.setDrawingActive(active)
        if !active { schedulePreviewWarmup() }
    }

    func canvasDidScroll() {
        guard !adjustingViewport else { return }
        cancelInkDrag()
        if eraserTransaction != nil { cancelStrokeErasing() }
        updateVisiblePaper()
    }
    func canvasDidZoom() {
        guard !adjustingViewport else { return }
        cancelInkDrag()
        if eraserTransaction != nil { cancelStrokeErasing() }
        centerSheet(settleOffset: true)
        updateVisiblePaper()
        let value = Int((canvas.zoomScale / max(fitScale, 0.01) * 100).rounded())
        DispatchQueue.main.async { [weak session] in
            if session?.zoomPercent != value { session?.zoomPercent = value }
        }
    }

    func showAutomaticShape(_ result: ShapeRecognitionResult) {
        automaticShape = ([], ShapeEditFrame(result: result), result.fittedPoints); shapeSelectionPending = true
        inkSelectionRect = result.fittedPoints.reduce(CGRect.null) { $0.union(CGRect(origin: $1, size: .zero)) }
        updateInkOutline()
    }
    func activateAutomaticShape(_ result: ShapeRecognitionResult, ids: Set<InkStrokeID>) {
        guard !ids.isEmpty else { return }
        automaticShape = (ids, ShapeEditFrame(result: result), result.fittedPoints); shapeSelectionPending = false
        let drawing = canvas.drawing
        let indices = Set(drawing.strokes.indices.filter { ids.contains(InkStrokeID(drawing.strokes[$0])) })
        guard indices.count == ids.count else { clearInkSelection(); return }
        inkSelection = RectangularInkSelection(drawing: drawing, indices: indices, geometryCache: geometry(for: drawing))
        inkSelectionRect = inkSelection?.bounds
        inkPan.isEnabled = true; inkTap.isEnabled = true
        session.selectedStrokeCount = indices.count
        updateInkOutline()
    }
    func cancelAutomaticShape() {
        guard automaticShape != nil, !committingInk else { return }
        clearInkSelection()
    }
    private func shapeContains(_ point: CGPoint) -> Bool {
        guard let shape = automaticShape, let first = shape.points.first else { return false }
        let padding = 22 / canvas.zoomScale
        if shape.frame.corners.contains(where: { hypot($0.x-point.x,$0.y-point.y) <= padding }) { return true }
        let path = CGMutablePath(); path.move(to: first)
        for p in shape.points.dropFirst() { path.addLine(to: p) }; path.closeSubpath()
        return path.contains(point) || path.copy(strokingWithWidth: 12/canvas.zoomScale,
            lineCap: .round, lineJoin: .round, miterLimit: 2).contains(point)
    }

    func clearInkSelection() {
        if automaticShape != nil, !committingInk {
            automaticShape = nil; shapeSelectionPending = false; shapeResize = nil
            // Only our between-contact editing recognizers change; never toggle
            // PencilKit's active drawing recognizer during a held snap.
            if inkPan.state != .began && inkPan.state != .changed {
                inkPan.isEnabled = session.selectedTool.isSelection
                inkTap.isEnabled = session.selectedTool.isSelection
            }
        }
        if inkDragging { paper.setDrawingActive(false) }
        if !committingInk { endInkPreview() }
        inkSelection = nil; inkSelectionRect = nil; inkProposedRect = nil; freeformPath = nil
        inkDragging = false; inkResizing = false
        inkDragTransform = .identity
        inkSelectionLayer.path = nil
        publishSelectionActions()
        // configure can run during a SwiftUI update.
        if session.selectedStrokeCount != 0 {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.session.selectedStrokeCount = self.inkSelection?.indices.count ?? 0
            }
        }
    }

    func validateInkSelection(_ drawing: PKDrawing) {
        // Drawing mutations invalidate the selection. Interactive transforms keep
        // one immutable original and commit once; never serialize per pointer move.
        if !committingInk, let selected = inkSelection, selected.original != drawing { clearInkSelection() }
    }

    private func cancelInkDrag() {
        if inkPan.state == .began || inkPan.state == .changed {
            inkPan.isEnabled = false
            inkPan.isEnabled = session.selectedTool.isSelection || hasAutomaticShapeSelection
        }
    }

    private func updateInkOutline(_ rect: CGRect? = nil) {
        publishSelectionActions()
        guard let rect = rect ?? inkSelectionRect ?? inkSelection?.bounds, !rect.isNull else { inkSelectionLayer.path = nil; return }
        let displayed = rect.applying(inkDragTransform).applying(documentToViewport)
        let corners = automaticShape?.frame.corners.map { $0.applying(inkDragTransform).applying(documentToViewport) } ?? rectangleCorners(displayed)
        let path = UIBezierPath(); path.move(to: corners[0])
        for point in corners.dropFirst() { path.addLine(to: point) }; path.close()
        for point in corners {
            path.append(UIBezierPath(roundedRect: CGRect(x: point.x - 5, y: point.y - 5, width: 10, height: 10), cornerRadius: 2))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        inkSelectionLayer.path = path.cgPath
        CATransaction.commit()
    }

    var selectedInkDrawing: PKDrawing? { inkSelection?.drawing }
    var selectedInkIndices: Set<Int> { inkSelection?.indices ?? [] }
    func restoreInkSelection(indices: Set<Int>) {
        endInkPreview()
        let selected = RectangularInkSelection(drawing: canvas.drawing, indices: indices, geometryCache: geometry(for: canvas.drawing))
        inkSelection = selected.indices.isEmpty ? nil : selected
        inkSelectionRect = inkSelection?.bounds
        session.selectedStrokeCount = selected.indices.count
        updateInkOutline()
    }
    func groupSelectedInk() { session.groupSelectedInk() }
    func ungroupSelectedInk() { session.ungroupSelectedInk() }

    private func publishSelectionActions() {
        // Coalesce viewport changes and avoid publishing during updateUIView.
        guard !selectionActionsUpdatePending else { return }
        selectionActionsUpdatePending = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.selectionActionsUpdatePending = false
            let rect = self.inkDragging || self.freeformPath != nil ? nil :
                self.inkSelectionRect?.applying(self.documentToViewport)
            self.session.updateSelectionActions(rect: rect, selectedDrawing: self.inkSelection?.drawing)
        }
    }
    @objc private func tapInkSelection(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended else { return }
        handleInkSelectionTap(at: gesture.location(in: self).applying(documentToViewport.inverted()))
    }
    func handleInkSelectionTap(at point: CGPoint) {
        guard let rect = inkSelectionRect else { return }
        // Handles belong to the selection too. A tap elsewhere immediately
        // dismisses selection; it cannot start drawing or a new selection.
        if automaticShape != nil ? !shapeContains(point) : !rect.insetBy(dx: -12 / canvas.zoomScale, dy: -12 / canvas.zoomScale).contains(point) {
            clearInkSelection()
        } else { publishSelectionActions() }
    }

    @objc private func selectInk(_ gesture: UIPanGestureRecognizer) {
        let point = gesture.location(in: self).applying(documentToViewport.inverted())
        switch gesture.state {
        case .began:
            let origin = (gesture as? RectangleSelectionGestureRecognizer)?.origin ?? gesture.location(in: self)
            beginInkTransform(at: origin.applying(documentToViewport.inverted()))
            updateInkDrag(to: point)
        case .changed: updateInkDrag(to: point)
        case .ended:
            updateInkDrag(to: point)
            if inkDragging, inkSelection != nil {
                transformSelectedInk(inkDragTransform, action: inkResizing ? "필기 크기 조절" : "필기 이동")
            } else if inkResizing, let rect = inkProposedRect {
                selectInk(in: rect)
            } else if let path = freeformPath {
                path.close()
                selectInk(in: path.cgPath)
            } else {
                selectInk(in: inkRect(to: point))
            }
            freeformPath = nil
            paper.setDrawingActive(false)
            inkDragging = false; inkResizing = false; inkDragTransform = .identity
            session.selectedStrokeCount = inkSelection?.indices.count ?? 0
            updateInkOutline()
        case .cancelled, .failed:
            freeformPath = nil
            paper.setDrawingActive(false)
            endInkPreview()
            inkDragTransform = .identity; inkDragging = false; inkResizing = false
            updateInkOutline()
        default: break
        }
    }

    private func inkRect(to point: CGPoint) -> CGRect {
        CGRect(x: min(inkStart.x, point.x), y: min(inkStart.y, point.y), width: abs(point.x - inkStart.x), height: abs(point.y - inkStart.y))
    }
    private func rectangleCorners(_ rect: CGRect) -> [CGPoint] {
        [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
         CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
    }
    // Separate gesture state from UIKit delivery so the same live path is testable.
    func beginInkTransform(at point: CGPoint) {
        previewWarmup?.cancel(); previewWarmup = nil
        endInkPreview()
        inkStart = point; inkDragTransform = .identity; shapeResize = nil
        // Stable IDs resolve into this immutable pointer-down snapshot only.
        if let shape = automaticShape, !shapeSelectionPending {
            let drawing = canvas.drawing
            let indices = Set(drawing.strokes.indices.filter { shape.ids.contains(InkStrokeID(drawing.strokes[$0])) })
            guard indices.count == shape.ids.count else { clearInkSelection(); return }
            inkSelection = RectangularInkSelection(drawing: drawing, indices: indices, geometryCache: geometry(for: drawing))
        }
        inkResizing = false; inkDragging = false; inkProposedRect = nil
        if let rect = inkSelectionRect {
            let corners = automaticShape?.frame.corners ?? rectangleCorners(rect)
            if let index = corners.indices.min(by: { hypot(point.x - corners[$0].x, point.y - corners[$0].y) < hypot(point.x - corners[$1].x, point.y - corners[$1].y) }),
               hypot(point.x - corners[index].x, point.y - corners[index].y) < 22 / canvas.zoomScale {
                inkResizing = true; inkDragging = true
                inkResizeAnchor = corners[(index + 2) % 4]
                if let frame = automaticShape?.frame { shapeResize = ShapeResizeDrag(frame: frame, corner: index, pointer: point) }
            } else { inkDragging = inkSelection != nil && (automaticShape != nil ? shapeContains(point) : rect.contains(point)) }
        }
        if !inkDragging {
            clearInkSelection()
            if session.selectedTool == .lasso {
                let path = UIBezierPath(); path.move(to: point); freeformPath = path
            }
        }
        paper.setDrawingActive(true)
        if inkDragging, let selected = inkSelection {
            inkPreview.frame = bounds
            inkPreview.prepare(selection: selected, paper: paper,
                               viewport: bounds, transform: documentToViewport)
            // Only cached native texture transforms change until lift. Keep native
            // canvas input available, including a second finger to pan.
        }
    }

    func updateInkDrag(to point: CGPoint) {
        if hasAutomaticShapeSelection, inkDragging {
            inkDragTransform = shapeResize?.transform(to: point) ?? ShapeEditMath.translation(start: inkStart, current: point)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            inkPreview.moveSelection(inkDragTransform, viewportTransform: documentToViewport)
            updateInkOutline(); CATransaction.commit(); return
        }
        if inkResizing, let rect = inkSelectionRect {
            if inkSelection == nil {
                inkProposedRect = CGRect(x: min(inkResizeAnchor.x, point.x), y: min(inkResizeAnchor.y, point.y),
                                         width: abs(point.x - inkResizeAnchor.x), height: abs(point.y - inkResizeAnchor.y))
                updateInkOutline(inkProposedRect); return
            }
            let page = CGRect(x: 0, y: 0, width: currentPage?.width ?? rect.maxX, height: currentPage?.height ?? rect.maxY)
            let clamped = CGPoint(x: min(page.maxX, max(0, point.x)), y: min(page.maxY, max(0, point.y)))
            // Opposite corner stays fixed; forbid crossing/reflection or zero size.
            let sx = max(0.05, (clamped.x - inkResizeAnchor.x) / (inkStart.x - inkResizeAnchor.x))
            let sy = max(0.05, (clamped.y - inkResizeAnchor.y) / (inkStart.y - inkResizeAnchor.y))
            inkDragTransform = CGAffineTransform(a: sx, b: 0, c: 0, d: sy,
                tx: inkResizeAnchor.x * (1 - sx), ty: inkResizeAnchor.y * (1 - sy))
        } else {
            guard inkDragging, let selected = inkSelection else {
                if let path = freeformPath {
                    path.addLine(to: point)
                    var transform = documentToViewport
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    inkSelectionLayer.path = path.cgPath.copy(using: &transform)
                    CATransaction.commit()
                } else { updateInkOutline(inkRect(to: point)) }
                return
            }
            let rect = inkSelectionRect ?? selected.bounds
            let dx = min(max(-rect.minX, point.x - inkStart.x), max(-rect.minX, (currentPage?.width ?? rect.maxX) - rect.maxX))
            let dy = min(max(-rect.minY, point.y - inkStart.y), max(-rect.minY, (currentPage?.height ?? rect.maxY) - rect.maxY))
            inkDragTransform = CGAffineTransform(translationX: dx, y: dy)
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        inkPreview.moveSelection(inkDragTransform, viewportTransform: documentToViewport)
        updateInkOutline()
        CATransaction.commit()
    }

    var liveInkTransform: CGAffineTransform { inkPreview.selectionTransform }
    var liveSelectionTransform: CGAffineTransform { inkDragTransform }
    var isShowingInkPreview: Bool { !inkPreview.isHidden }
    var paperSharesNativeScroll: Bool { paper.superview === canvas }
    var previewGeometryBuildCount: Int { inkPreview.geometryBuildCount }
    var previewRasterizationCount: Int { inkPreview.rasterizationCount }
    var backgroundRasterizationCount: Int { paper.rasterizationCount }
    var backgroundViewportTransform: CGAffineTransform { paper.viewportTransform }

    private func endInkPreview() {
        waitingForInkRender = false
        inkCommitDrawing = nil
        inkRenderGeneration &+= 1; inkHandoffScheduled = false; inkCommitEcho = false
        CATransaction.begin(); CATransaction.setDisableActions(true)
        inkPreview.clear()
        CATransaction.commit()
    }
    func nativeInkDrawingChanged(_ drawing: PKDrawing) {
        if waitingForInkRender, drawing == inkCommitDrawing { inkCommitEcho = true }
    }
    func finishInkRendering() {
        guard waitingForInkRender, !inkHandoffScheduled, inkCommitEcho, let committed = inkCommitDrawing,
              canvas.drawing == committed, !drawingActive else { return }
        let target = canvas, generation = inkRenderGeneration, viewport = documentToViewport
        inkHandoffScheduled = true
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak target] in
            MainActor.assumeIsolated {
                guard let self, self.canvas === target, self.inkRenderGeneration == generation else { return }
                self.inkHandoffScheduled = false
                guard self.waitingForInkRender, self.canvas.drawing == committed,
                      !self.drawingActive, self.documentToViewport == viewport else { return }
                self.endInkPreview()
            }
        }
        canvas.layer.setNeedsDisplay()
        CATransaction.commit()
    }

    func selectInk(in rect: CGRect) {
        let rect = rect.standardized.intersection(CGRect(x: 0, y: 0, width: currentPage?.width ?? .greatestFiniteMagnitude, height: currentPage?.height ?? .greatestFiniteMagnitude))
        guard !rect.isNull, rect.width > 1, rect.height > 1 else { clearInkSelection(); return }
        inkSelectionRect = rect
        let selected = RectangularInkSelection(drawing: canvas.drawing, rect: rect, geometryCache: geometry(for: canvas.drawing))
        let expanded = session.expandedSelectionIndices(in: canvas.drawing, indices: selected.indices)
        inkSelection = RectangularInkSelection(drawing: canvas.drawing, indices: expanded, geometryCache: selected.geometryCache)
        if expanded != selected.indices { inkSelectionRect = rect.union(inkSelection!.bounds) }
        if inkSelection?.indices.isEmpty == true { inkSelection = nil }
        session.selectedStrokeCount = inkSelection?.indices.count ?? 0
        updateInkOutline()
    }
    func selectInk(in path: CGPath) {
        let raw = RectangularInkSelection(drawing: canvas.drawing, path: path, geometryCache: geometry(for: canvas.drawing))
        let selection = RectangularInkSelection(drawing: canvas.drawing,
            indices: session.expandedSelectionIndices(in: canvas.drawing, indices: raw.indices), geometryCache: raw.geometryCache)
        inkSelection = selection.indices.isEmpty ? nil : selection
        inkSelectionRect = inkSelection?.bounds
        session.selectedStrokeCount = selection.indices.count
        updateInkOutline()
    }
    func transformSelectedInk(_ transform: CGAffineTransform, action: String) {
        guard let selected = inkSelection else { return }
        // Repeated menu transforms start from the last committed drawing, not
        // from an older preview still awaiting native presentation.
        if waitingForInkRender { endInkPreview() }
        let drawing = selected.transformed(transform)
        let editedShape = automaticShape.map { (ids: $0.ids, frame: $0.frame.applying(transform), points: $0.points.map { $0.applying(transform) }) }
        let rect = (inkSelectionRect ?? selected.bounds).applying(transform)
        committingInk = true
        waitingForInkRender = !inkPreview.isHidden
        // A menu transform also gets a preview so commit cannot flash old ink.
        if inkPreview.isHidden {
            inkPreview.frame = bounds
            inkPreview.prepare(selection: selected, paper: paper,
                               viewport: bounds, transform: documentToViewport)
            waitingForInkRender = true
        }
        inkPreview.moveSelection(transform, viewportTransform: documentToViewport)
        clearInkSelection()
        inkCommitDrawing = drawing; inkCommitEcho = false; inkRenderGeneration &+= 1
        session.commitDrawing(drawing, action: action)
        committingInk = false
        inkSelection = RectangularInkSelection(drawing: drawing, indices: selected.indices, geometryCache: geometry(for: drawing))
        automaticShape = editedShape; shapeResize = nil; inkDragTransform = .identity
        inkSelectionRect = rect
        session.selectedStrokeCount = selected.indices.count
        updateInkOutline()
    }
    func scaleSelectedInk(by factor: CGFloat) {
        guard let selected = inkSelection, factor.isFinite, factor > 0 else { return }
        let rect = inkSelectionRect ?? selected.bounds
        let limit = min(((currentPage?.width ?? rect.maxX) - rect.minX) / max(1, rect.width),
                        ((currentPage?.height ?? rect.maxY) - rect.minY) / max(1, rect.height))
        let scale = max(0.1, min(factor, limit))
        transformSelectedInk(CGAffineTransform(a: scale, b: 0, c: 0, d: scale,
                                              tx: rect.minX * (1 - scale), ty: rect.minY * (1 - scale)), action: "필기 크기 조절")
    }
    func copySelectedInk(cut: Bool = false) {
        guard let selected = inkSelection, !selected.indices.isEmpty else { return }
        DrawingSession.copiedInk = selected.drawing
        session.objectWillChange.send()
        if cut { deleteSelectedInk(action: "필기 잘라내기") }
    }
    func deleteSelectedInk(action: String = "필기 삭제") {
        guard let selected = inkSelection else { return }
        clearInkSelection()
        session.commitDrawing(selected.removing, action: action)
    }
    func pasteInk(duplicate: Bool = false) {
        guard session.loadError == nil,
              let copied = duplicate ? inkSelection?.drawing : DrawingSession.copiedInk, !copied.strokes.isEmpty else { return }
        let visible = bounds.insetBy(dx: 40, dy: 100).applying(documentToViewport.inverted())
        let source = copied.bounds
        let target = duplicate ? CGPoint(x: source.minX + 24, y: source.minY + 24) : CGPoint(x: visible.midX - source.width / 2, y: visible.midY - source.height / 2)
        let x = min(max(0, target.x), max(0, (currentPage?.width ?? source.width) - source.width))
        let y = min(max(0, target.y), max(0, (currentPage?.height ?? source.height) - source.height))
        let inserted = DrawingSession.reidentifiedInk(copied).transformed(using: CGAffineTransform(translationX: x - source.minX, y: y - source.minY))
        let oldCount = canvas.drawing.strokes.count
        let result = PKDrawing(strokes: canvas.drawing.strokes + inserted.strokes)
        clearInkSelection()
        session.commitDrawing(result, action: duplicate ? "필기 복제" : "필기 붙여넣기")
        inkSelection = RectangularInkSelection(drawing: result, indices: Set(oldCount..<result.strokes.count))
        inkSelectionRect = inkSelection?.bounds
        session.selectedStrokeCount = inserted.strokes.count
        updateInkOutline()
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


/// An input overlay used only while the user adjusts a question's crop.
final class RegionSelectionView: UIView {
    var onChange: ((CGRect) -> Void)?
    private var available = CGRect.zero
    private var selection = CGRect.zero
    private var start = CGRect.zero
    private var corner: Int?
    private var freshOrigin: CGPoint?
    override init(frame: CGRect) {
        super.init(frame: frame)
        isOpaque = false
        isHidden = true
        addGestureRecognizer(UIPanGestureRecognizer(target: self, action: #selector(pan(_:))))
        accessibilityIdentifier = "ai-region-selection"
        accessibilityLabel = "질문 영역 선택. 사각형을 이동하거나 모서리를 끌어 크기를 조절하세요."
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func clear() { selection = .zero }
    func configure(available: CGRect) {
        guard !available.isNull, available.width >= 40, available.height >= 40 else { return }
        self.available = available
        if selection.isEmpty {
            selection = available.insetBy(dx: available.width * 0.16, dy: available.height * 0.3)
        } else if !available.contains(selection) {
            selection = selection.intersection(available)
            if selection.isNull || selection.width < 24 || selection.height < 24 {
                selection = available.insetBy(dx: available.width * 0.16, dy: available.height * 0.3)
            }
        }
        onChange?(selection)
        setNeedsDisplay()
    }
    private var corners: [CGPoint] {
        [CGPoint(x: selection.minX, y: selection.minY), CGPoint(x: selection.maxX, y: selection.minY),
         CGPoint(x: selection.minX, y: selection.maxY), CGPoint(x: selection.maxX, y: selection.maxY)]
    }
    @objc private func pan(_ gesture: UIPanGestureRecognizer) {
        let location = gesture.location(in: self)
        let point = CGPoint(x: min(available.maxX, max(available.minX, location.x)), y: min(available.maxY, max(available.minY, location.y)))
        if gesture.state == .began {
            start = selection
            corner = corners.indices.min(by: { hypot(corners[$0].x - point.x, corners[$0].y - point.y) < hypot(corners[$1].x - point.x, corners[$1].y - point.y) })
            if let index = corner, hypot(corners[index].x - point.x, corners[index].y - point.y) > 35 { corner = nil }
            freshOrigin = corner == nil && !selection.contains(point) ? point : nil
        }
        if let origin = freshOrigin {
            selection = CGRect(x: min(origin.x, point.x), y: min(origin.y, point.y), width: max(24, abs(point.x-origin.x)), height: max(24, abs(point.y-origin.y))).intersection(available)
        } else if let corner {
            let opposite = [CGPoint(x: start.maxX, y: start.maxY), CGPoint(x: start.minX, y: start.maxY),
                            CGPoint(x: start.maxX, y: start.minY), CGPoint(x: start.minX, y: start.minY)][corner]
            selection = CGRect(x: min(opposite.x, point.x), y: min(opposite.y, point.y), width: max(24, abs(point.x-opposite.x)), height: max(24, abs(point.y-opposite.y))).intersection(available)
        } else {
            let delta = gesture.translation(in: self)
            selection.origin = CGPoint(x: min(available.maxX-start.width, max(available.minX, start.minX+delta.x)),
                                       y: min(available.maxY-start.height, max(available.minY, start.minY+delta.y)))
        }
        if gesture.state == .cancelled { selection = start }
        onChange?(selection)
        setNeedsDisplay()
    }
    override func draw(_ rect: CGRect) {
        guard !selection.isEmpty else { return }
        let dim = UIBezierPath(rect: bounds)
        dim.append(UIBezierPath(roundedRect: selection, cornerRadius: 6))
        dim.usesEvenOddFillRule = true
        UIColor.black.withAlphaComponent(0.16).setFill(); dim.fill()
        UIColor.systemBlue.setStroke()
        let border = UIBezierPath(roundedRect: selection, cornerRadius: 6)
        border.lineWidth = 2; border.stroke()
        for corner in corners {
            let handle = UIBezierPath(ovalIn: CGRect(x: corner.x-7, y: corner.y-7, width: 14, height: 14))
            UIColor.white.setFill(); handle.fill(); handle.lineWidth = 2; handle.stroke()
        }
    }
}

/// UIPan may begin after other recognizers fail; keep the actual first corner.
final class RectangleSelectionGestureRecognizer: UIPanGestureRecognizer {
    private(set) var origin: CGPoint?
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if origin == nil, let view, let touch = touches.first { origin = touch.location(in: view) }
        super.touchesBegan(touches, with: event)
    }
    override func reset() { super.reset(); origin = nil }
}

/// Native PencilKit appearance, cached independently from hit-test geometry.
/// Render on the main actor: drawing.image can disturb PencilKit's shared renderer
/// on physical devices when called concurrently from a background queue.
@MainActor
final class NativeInkRasterCache {
    struct Key: Hashable { let index: Int; let scale: CGFloat; let x: Int; let y: Int }
    struct Tile { let key: Key; let rect: CGRect; let image: CGImage }
    private let strokes: [PKStroke]
    private var tiles: [Key: Tile] = [:]
    private struct Link { var previous: Key?; var next: Key? }
    private var links: [Key: Link] = [:]
    private var oldest: Key?
    private var newest: Key?
    private var bytes = 0
    private let byteLimit = 32 * 1024 * 1024
    private(set) var rasterizationCount = 0
    init(drawing: PKDrawing) { strokes = drawing.strokes }

    func reuseUnchangedStrokes(from previous: NativeInkRasterCache) {
        // Public identity narrows candidates; appearance equality also verifies
        // transform, mask and ink. A freshly wrapped PKDrawing has its own
        // document identity, so drawing equality is not stroke equality.
        func id(_ stroke: PKStroke) -> InkStrokeID {
            InkStrokeID(creationDate: stroke.path.creationDate, randomSeed: stroke.randomSeed)
        }
        // Only cached strokes need appearance comparison. An uncached stroke
        // cannot contribute pixels; inspecting its control points is wasted work.
        let cachedIndices = Set(previous.tiles.keys.map(\.index))
        let oldIndices = Dictionary(grouping: cachedIndices, by: { id(previous.strokes[$0]) })
        var mapping: [Int: Int] = [:]
        for index in strokes.indices {
            for old in oldIndices[id(strokes[index])] ?? [] where mapping[old] == nil {
                if InkStrokeAppearance.matches(strokes[index], previous.strokes[old]) {
                    mapping[old] = index; break
                }
            }
        }
        reuseUnchangedStrokes(from: previous, retainedIndices: mapping)
    }

    /// The geometry revision has already proven these old → new stroke links.
    func reuseUnchangedStrokes(from previous: NativeInkRasterCache, retainedIndices: [Int: Int]) {
        var cursor = previous.oldest
        while let oldKey = cursor {
            cursor = previous.links[oldKey]?.next
            guard let index = retainedIndices[oldKey.index], let tile = previous.tiles[oldKey] else { continue }
            let key = Key(index: index, scale: oldKey.scale, x: oldKey.x, y: oldKey.y)
            guard tiles[key] == nil else { continue }
            tiles[key] = Tile(key: key, rect: tile.rect, image: tile.image)
            bytes += tile.image.bytesPerRow * tile.image.height
            touch(key)
        }
    }

    private func unlink(_ key: Key) {
        guard let link = links.removeValue(forKey: key) else { return }
        if let previous = link.previous { links[previous]?.next = link.next } else { oldest = link.next }
        if let next = link.next { links[next]?.previous = link.previous } else { newest = link.previous }
    }
    private func touch(_ key: Key) {
        if newest == key { return }
        unlink(key)
        links[key] = Link(previous: newest, next: nil)
        if let newest { links[newest]?.next = key } else { oldest = key }
        newest = key
    }

    func tiles(for index: Int, visible: CGRect, scale: CGFloat) -> [Tile] {
        guard strokes.indices.contains(index), scale.isFinite, scale > 0 else { return [] }
        let bounds = strokes[index].renderBounds.insetBy(dx: -2 / scale, dy: -2 / scale)
        let needed = bounds.intersection(visible)
        guard !needed.isNull, !needed.isEmpty else { return [] }
        // Each render target is at most 512px, even far down a stitched PDF.
        let side = 512 / scale
        let x0 = Int(floor(needed.minX / side)), x1 = Int(floor(needed.maxX / side))
        let y0 = Int(floor(needed.minY / side)), y1 = Int(floor(needed.maxY / side))
        var result: [Tile] = []
        var drawing: PKDrawing?
        for y in y0...y1 { for x in x0...x1 {
            let key = Key(index: index, scale: scale, x: x, y: y)
            if let cached = tiles[key] { touch(key); result.append(cached); continue }
            let cell = CGRect(x: CGFloat(x) * side, y: CGFloat(y) * side, width: side, height: side)
            let crop = bounds.intersection(cell)
            guard !crop.isNull, !crop.isEmpty else { continue }
            let rect = CGRect(x: floor(crop.minX * scale) / scale, y: floor(crop.minY * scale) / scale,
                              width: (ceil(crop.maxX * scale) - floor(crop.minX * scale)) / scale,
                              height: (ceil(crop.maxY * scale) - floor(crop.minY * scale)) / scale)
            var rendered: UIImage?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                if drawing == nil { drawing = PKDrawing(strokes: [strokes[index]]) }
                rendered = drawing?.image(from: rect, scale: scale)
            }
            guard let image = rendered?.cgImage else { continue }
            rasterizationCount += 1
            let tile = Tile(key: key, rect: rect, image: image)
            let cost = image.bytesPerRow * image.height
            while bytes + cost > byteLimit, let oldest {
                if let removed = tiles.removeValue(forKey: oldest) { bytes -= removed.image.bytesPerRow * removed.image.height }
                unlink(oldest)
            }
            tiles[key] = tile; touch(key); bytes += cost
            result.append(tile)
        } }
        return result
    }
}

/// Geometry is for hit-testing only. Display the native texture including its
/// pressure, opacity multiplier, pencil grain and masks; never fill a nib outline.
@MainActor
private final class InkInteractionScene {
    let root = CALayer()
    private let paperLayer = CALayer()
    private let inkLayer = CALayer()
    private var strokeLayers: [Int: CALayer] = [:]
    private var tileLayers: [NativeInkRasterCache.Key: CALayer] = [:]
    private var selected = Set<Int>()
    private var cache: InkGeometryCache?
    private var rasterCache: NativeInkRasterCache?
    private var viewport = CGRect.zero
    private var transform = CGAffineTransform.identity
    private var selectionTransform = CGAffineTransform.identity
    private var faded = Set<Int>()
    private var committed = false
    private var loadedViewport = CGRect.null
    private var loadedSource = CGRect.null
    private var loadedScale: CGFloat = 0
    private var loadedSelectedScale: CGFloat = 0
    var geometryBuildCount: Int { cache?.geometryBuildCount ?? 0 }
    var rasterizationCount: Int { rasterCache?.rasterizationCount ?? 0 }

    init() {
        for layer in [root, paperLayer, inkLayer] { layer.anchorPoint = .zero }
        root.addSublayer(paperLayer); root.addSublayer(inkLayer)
    }
    func prepare(cache: InkGeometryCache, selected: Set<Int> = [], paper: PaperView,
                 viewport: CGRect, transform: CGAffineTransform) {
        clear()
        self.cache = cache; self.rasterCache = cache.nativeRasterCache
        self.selected = selected; self.viewport = viewport
        updateViewport(transform, paper: paper)
    }
    func updateViewport(_ transform: CGAffineTransform, paper: PaperView) {
        self.transform = transform
        CATransaction.begin(); CATransaction.setDisableActions(true)
        root.setAffineTransform(transform)
        paper.copyCachedTiles(to: paperLayer)
        prepareVisibleInk()
        applySelectionTransform()
        setErased(faded, committed: committed)
        CATransaction.commit()
    }
    private func prepareVisibleInk() {
        guard let cache, let rasterCache else { return }
        let zoom = max(0.01, hypot(transform.a, transform.b))
        let scale = zoom * UIScreen.main.scale
        // A large selection becoming small needs fewer source pixels, not a
        // full-resolution bitmap of every page it contains. Quantize to avoid
        // rerasterizing at every pointer sample; normal ink keeps its own scale.
        let selectedZoom = max(hypot(selectionTransform.a, selectionTransform.b),
                               hypot(selectionTransform.c, selectionTransform.d))
        let selectedScale = scale * min(1, pow(2, ceil(log2(max(0.01, selectedZoom)))))
        // One tile of look-ahead lets ordinary pointer updates reuse existing
        // textures. New source areas are loaded only when they enter this region.
        let requested = viewport.applying(transform.inverted())
        let requestedSource = requested.applying(selectionTransform.inverted())
        if scale == loadedScale && selectedScale == loadedSelectedScale &&
            loadedViewport.contains(requested) && loadedSource.contains(requestedSource) { return }
        let visible = requested.insetBy(dx: -512 / scale, dy: -512 / scale)
        let sourceVisible = requestedSource.insetBy(dx: -512 / selectedScale, dy: -512 / selectedScale)
        loadedViewport = visible; loadedSource = sourceVisible; loadedScale = scale; loadedSelectedScale = selectedScale
        let normal = Set(cache.candidates(intersecting: visible)).subtracting(selected)
        let moving = Set(cache.candidates(intersecting: sourceVisible)).intersection(selected)
        let needed = normal.union(moving)
        var keys = Set<NativeInkRasterCache.Key>()
        for index in needed.sorted() {
            let container: CALayer
            if let existing = strokeLayers[index] { container = existing }
            else {
                container = CALayer(); container.anchorPoint = .zero; container.zPosition = CGFloat(index)
                container.allowsGroupOpacity = true
                container.opacity = faded.contains(index) ? (committed ? 0 : 0.35) : 1
                strokeLayers[index] = container; inkLayer.addSublayer(container)
            }
            let rasterScale = selected.contains(index) ? selectedScale : scale
            for tile in rasterCache.tiles(for: index, visible: selected.contains(index) ? sourceVisible : visible, scale: rasterScale) {
                keys.insert(tile.key)
                guard tileLayers[tile.key] == nil else { continue }
                let layer = CALayer(); layer.anchorPoint = .zero; layer.frame = tile.rect
                layer.contents = tile.image; layer.contentsScale = rasterScale
                layer.minificationFilter = .linear; layer.magnificationFilter = .linear
                container.addSublayer(layer); tileLayers[tile.key] = layer
            }
        }
        for key in Array(tileLayers.keys) where !keys.contains(key) { tileLayers.removeValue(forKey: key)?.removeFromSuperlayer() }
        for index in Array(strokeLayers.keys) where !needed.contains(index) { strokeLayers.removeValue(forKey: index)?.removeFromSuperlayer() }
    }
    private func applySelectionTransform() {
        for index in selected { strokeLayers[index]?.setAffineTransform(selectionTransform) }
    }
    func moveSelection(_ value: CGAffineTransform) {
        selectionTransform = value
        CATransaction.begin(); CATransaction.setDisableActions(true)
        // Reuse the same original native pixels throughout movement/resizing.
        // Loading is limited to newly exposed source tiles, never a redraw of ink.
        prepareVisibleInk()
        applySelectionTransform()
        CATransaction.commit()
    }
    func setErased(_ indices: Set<Int>, committed: Bool) {
        let changed = self.committed == committed ? faded.symmetricDifference(indices) : faded.union(indices)
        faded = indices; self.committed = committed
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for index in changed {
            // Native PNG already contains the true per-point opacity and texture.
            strokeLayers[index]?.opacity = indices.contains(index) ? (committed ? 0 : 0.35) : 1
        }
        CATransaction.commit()
    }
    func clear() {
        strokeLayers.values.forEach { $0.removeFromSuperlayer() }
        strokeLayers.removeAll(); tileLayers.removeAll()
        paperLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
        paperLayer.backgroundColor = nil
        loadedViewport = .null; loadedSource = .null; loadedScale = 0; loadedSelectedScale = 0
        cache = nil; rasterCache = nil; selected = []; faded = []; committed = false; selectionTransform = .identity
    }
}

final class StrokeEraserPreviewView: UIView {
    private let scene = InkInteractionScene()
    private let trailLayer = CALayer()
    private var activeTrailLayer: CAShapeLayer?
    private let trail = UIBezierPath()
    private var trailPointCount = 0
    private var trailWidth: CGFloat = 12
    private var transaction: StrokeEraserTransaction?
    private var lastPoint: CGPoint?
    // Kept as computed diagnostic views; never regenerated in pointer handling.
    var normalDrawing: PKDrawing { transaction?.remainingDrawing ?? PKDrawing() }
    var fadedDrawing: PKDrawing { transaction?.erasedDrawing ?? PKDrawing() }

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isOpaque = true; isHidden = true; clipsToBounds = true
        backgroundColor = .secondarySystemBackground
        layer.addSublayer(scene.root)
        scene.root.addSublayer(trailLayer)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func begin(transaction: StrokeEraserTransaction, paper: PaperView, viewport: CGRect, transform: CGAffineTransform) {
        end(); self.transaction = transaction
        trailWidth = transaction.width
        clipTrail(viewport: viewport, transform: transform, page: paper.documentBounds)
        scene.prepare(cache: transaction.geometryCache, paper: paper, viewport: viewport, transform: transform)
        isHidden = false
    }
    func updateViewport(_ transform: CGAffineTransform, paper: PaperView) {
        scene.updateViewport(transform, paper: paper)
        clipTrail(viewport: bounds, transform: transform, page: paper.documentBounds)
    }
    private func clipTrail(viewport: CGRect, transform: CGAffineTransform, page: CGRect) {
        let visible = viewport.applying(transform.inverted()).intersection(page)
        // Rectangular clipping needs no offscreen alpha mask. Bound this layer
        // to the visible document slice, never the height of a stitched PDF.
        CATransaction.begin(); CATransaction.setDisableActions(true)
        trailLayer.mask = nil; trailLayer.anchorPoint = .zero
        trailLayer.bounds = visible.isNull ? .zero : visible
        trailLayer.position = visible.isNull ? .zero : visible.origin
        trailLayer.masksToBounds = true
        CATransaction.commit()
    }
    func setErased(_ indices: Set<Int>, committed: Bool = false) { scene.setErased(indices, committed: committed) }
    func extend(along points: [CGPoint]) {
        CATransaction.begin(); CATransaction.setDisableActions(true)
        for point in points where point.x.isFinite && point.y.isFinite {
            // Freeze completed chunks. Long eraser contacts no longer copy and
            // retessellate their entire growing history on every pointer batch.
            if activeTrailLayer == nil || trailPointCount >= 128 {
                activeTrailLayer?.path = trail.cgPath
                trail.removeAllPoints(); trailPointCount = 0
                let chunk = CAShapeLayer()
                chunk.fillColor = nil; chunk.strokeColor = UIColor.white.cgColor
                chunk.lineCap = .round; chunk.lineJoin = .round; chunk.lineWidth = trailWidth
                trailLayer.addSublayer(chunk); activeTrailLayer = chunk
                if let lastPoint { trail.move(to: lastPoint) }
            }
            if lastPoint == nil { trail.move(to: point); trail.addLine(to: CGPoint(x: point.x + 0.001, y: point.y)) }
            else { trail.addLine(to: point) }
            lastPoint = point; trailPointCount += 1
        }
        activeTrailLayer?.path = trail.cgPath
        CATransaction.commit()
    }
    func clearTrail() {
        trail.removeAllPoints(); lastPoint = nil; activeTrailLayer = nil; trailPointCount = 0
        trailLayer.sublayers?.forEach { $0.removeFromSuperlayer() }
    }
    func end() { isHidden = true; transaction = nil; clearTrail(); scene.clear() }
}

final class InkTransformPreview: UIView {
    private let scene = InkInteractionScene()
    private(set) var selectionTransform = CGAffineTransform.identity
    var geometryBuildCount: Int { scene.geometryBuildCount }
    var rasterizationCount: Int { scene.rasterizationCount }
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isOpaque = true; isHidden = true; clipsToBounds = true
        backgroundColor = .secondarySystemBackground
        layer.addSublayer(scene.root)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func prepare(selection: RectangularInkSelection, paper: PaperView, viewport: CGRect, transform: CGAffineTransform) {
        scene.prepare(cache: selection.geometryCache, selected: selection.indices, paper: paper, viewport: viewport, transform: transform)
        selectionTransform = .identity; isHidden = false
    }
    func updateViewport(_ transform: CGAffineTransform, paper: PaperView) { scene.updateViewport(transform, paper: paper) }
    func moveSelection(_ transform: CGAffineTransform, viewportTransform: CGAffineTransform) {
        selectionTransform = transform
        scene.moveSelection(transform)
    }
    func clear() { scene.clear(); isHidden = true; selectionTransform = .identity }
}
