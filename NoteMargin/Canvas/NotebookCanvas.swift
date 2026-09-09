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

final class CanvasHostView: UIView, UIScrollViewDelegate {
    let session: DrawingSession
    private let scroll = UIScrollView()
    private let sheet = UIView()
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
        scroll.delegate = self
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.contentInsetAdjustmentBehavior = .never
        scroll.panGestureRecognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
        addSubview(scroll)
        scroll.addSubview(sheet)
        sheet.backgroundColor = .white
        sheet.layer.shadowColor = UIColor.black.cgColor
        sheet.layer.shadowOpacity = 0.12
        sheet.layer.shadowRadius = 12
        sheet.layer.shadowOffset = CGSize(width: 0, height: 4)
        paper.isOpaque = true
        paper.isUserInteractionEnabled = false
        sheet.addSubview(paper)
        sheet.addSubview(session.canvas)
        selectionLayer.strokeColor = UIColor.systemBlue.cgColor
        selectionLayer.fillColor = UIColor.systemBlue.withAlphaComponent(0.07).cgColor
        selectionLayer.lineWidth = 2
        selectionLayer.lineDashPattern = [6, 4]
        sheet.layer.addSublayer(selectionLayer)
        objectPan = UIPanGestureRecognizer(target: self, action: #selector(moveObject(_:)))
        objectPan.maximumNumberOfTouches = 1
        objectTap = UITapGestureRecognizer(target: self, action: #selector(selectObject(_:)))
        sheet.addGestureRecognizer(objectPan)
        sheet.addGestureRecognizer(objectTap)
        scroll.panGestureRecognizer.require(toFail: objectPan)
        for direction: UISwipeGestureRecognizer.Direction in [.left, .right] {
            let swipe = UISwipeGestureRecognizer(target: self, action: #selector(turnPage(_:)))
            swipe.direction = direction
            swipe.numberOfTouchesRequired = 3
            swipe.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            addGestureRecognizer(swipe)
            scroll.panGestureRecognizer.require(toFail: swipe)
            session.canvas.drawingGestureRecognizer.require(toFail: swipe)
            pageSwipes.append(swipe)
        }
        isAccessibilityElement = false
        session.canvas.accessibilityLabel = "필기 용지"
        session.canvas.accessibilityHint = "Apple Pencil로 필기합니다. 손가락으로 화면을 확대하거나 이동할 수 있습니다."
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
        pageSwipes.forEach { $0.isEnabled = canTurn }
        session.canvas.pageTurningEnabled = canTurn
        if pageChanged {
            scroll.zoomScale = 1
            sheet.frame = CGRect(x: 0, y: 0, width: page.width, height: page.height)
            session.canvas.frame = sheet.bounds
            session.canvas.contentSize = sheet.bounds.size
            scroll.contentSize = sheet.bounds.size
            selectedID = nil
            needsFit = true
        }
        if contentChanged {
            paper.render = { [weak store] context in
                guard let store else { return }
                PageRenderer.drawBackground(page: page, note: note, store: store, context: context)
            }
        }
        session.canvas.drawingPolicy = fingerDrawing ? .anyInput : .pencilOnly
        session.canvas.isUserInteractionEnabled = !editingObjects && session.loadError == nil
        objectPan.isEnabled = editingObjects
        objectTap.isEnabled = editingObjects
        scroll.panGestureRecognizer.minimumNumberOfTouches = (fingerDrawing || editingObjects) ? 2 : 1
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
        scroll.frame = bounds
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
        scroll.minimumZoomScale = fit
        scroll.maximumZoomScale = max(4, fit * 6)
        let changes = {
            self.scroll.setZoomScale(fit, animated: false)
            self.centerSheet()
            self.scroll.setContentOffset(CGPoint(x: -self.scroll.contentInset.left, y: -self.scroll.contentInset.top), animated: false)
        }
        if animated { UIView.animate(withDuration: 0.25, animations: changes) }
        else { changes() }
    }

    private func centerSheet() {
        let horizontal = max(24, (scroll.bounds.width - sheet.frame.width) / 2)
        let vertical = max(24, (scroll.bounds.height - 80 - sheet.frame.height) / 2)
        scroll.contentInset = UIEdgeInsets(top: vertical, left: horizontal, bottom: vertical + 80, right: horizontal)
    }

    @objc private func turnPage(_ gesture: UISwipeGestureRecognizer) {
        guard gesture.state == .ended, onTurnPage?(gesture.direction == .left ? 1 : -1) == true else { return }
        if !UIAccessibility.isReduceMotionEnabled {
            let transition = CATransition()
            transition.type = .fade
            transition.duration = 0.18
            sheet.layer.add(transition, forKey: "pageTurn")
        }
    }

    // Keep the PDF backing bitmap bounded to the visible area even for a very long sheet.
    private func updateVisiblePaper() {
        guard currentPage != nil, scroll.bounds.width > 0 else { return }
        let visible = sheet.convert(scroll.bounds, from: scroll).intersection(sheet.bounds)
        guard !visible.isNull, !visible.isEmpty else { return }
        paper.frame = visible
        paper.pageOrigin = visible.origin
        paper.setNeedsDisplay()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) { updateVisiblePaper() }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { sheet }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        centerSheet()
        updateVisiblePaper()
        let value = Int((scrollView.zoomScale / max(scrollView.minimumZoomScale, 0.01) * 100).rounded())
        DispatchQueue.main.async { [weak session] in if session?.zoomPercent != value { session?.zoomPercent = value } }
    }

    private func element(at point: CGPoint) -> PageElement? {
        currentPage?.elements.reversed().first {
            CGRect(x: $0.x, y: $0.y, width: $0.width, height: $0.height).contains(point)
        }
    }

    @objc private func selectObject(_ gesture: UITapGestureRecognizer) {
        selectedID = element(at: gesture.location(in: sheet))?.id
        updateSelection()
        onSelect?(selectedID)
    }

    @objc private func moveObject(_ gesture: UIPanGestureRecognizer) {
        guard var page = currentPage else { return }
        if gesture.state == .began {
            guard let element = element(at: gesture.location(in: sheet)) else { selectedID = nil; updateSelection(); return }
            selectedID = element.id
            dragOrigin = CGPoint(x: element.x, y: element.y)
            onSelect?(selectedID)
        }
        guard let id = selectedID, let index = page.elements.firstIndex(where: { $0.id == id }) else { return }
        let delta = gesture.translation(in: sheet)
        let x = min(max(0, dragOrigin.x + delta.x), max(0, page.width - page.elements[index].width))
        let y = min(max(0, dragOrigin.y + delta.y), max(0, page.height - page.elements[index].height))
        page.elements[index].x = x
        page.elements[index].y = y
        // Commit once at the end; show the destination outline while dragging.
        selectionLayer.path = UIBezierPath(rect: CGRect(x: x, y: y, width: page.elements[index].width, height: page.elements[index].height)).cgPath
        if gesture.state == .ended { onMove?(id, x, y) }
        if gesture.state == .cancelled { updateSelection() }
    }

    private func updateSelection() {
        guard let element = currentPage?.elements.first(where: { $0.id == selectedID }) else { selectionLayer.path = nil; return }
        selectionLayer.path = UIBezierPath(rect: CGRect(x: element.x, y: element.y, width: element.width, height: element.height)).cgPath
    }
}
