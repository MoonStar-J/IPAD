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

final class CanvasHostView: UIView {
    let session: DrawingSession
    private var canvas: PagingCanvasView { session.canvas }
    private let paper = PaperView()
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
        // Selection must stay above the new render surface.
        layer.addSublayer(selectionLayer)
        canvas.panGestureRecognizer.require(toFail: objectPan)
        for swipe in pageSwipes {
            canvas.panGestureRecognizer.require(toFail: swipe)
            canvas.drawingGestureRecognizer.require(toFail: swipe)
        }
        canvas.accessibilityLabel = "필기 용지"
        canvas.accessibilityIdentifier = "notebook-canvas"
        canvas.accessibilityHint = "Apple Pencil로 필기합니다. 손가락으로 화면을 확대하거나 이동할 수 있습니다."
    }

    func replaceCanvas(_ previous: PKCanvasView) {
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
        if canvas.frame != bounds { canvas.frame = bounds }
        if paper.frame != bounds { paper.frame = bounds }
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
        updateSelection()
    }

    func canvasDidScroll() { updateVisiblePaper() }
    func canvasDidZoom() {
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
