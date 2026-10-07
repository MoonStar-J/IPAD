import SwiftUI
import PencilKit
import CryptoKit

/// Small device-local tool preferences; no note, drawing, or account data.
private struct InkToolPreferences: Codable {
    struct Brush: Codable {
        var width: Double
        var red: Double
        var green: Double
        var blue: Double
        var alpha: Double
        var ruler: Bool

        init(width: Double = 3, color: Color = .black, ruler: Bool = false) {
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            UIColor(color).resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).getRed(&r, green: &g, blue: &b, alpha: &a)
            self.width = width; red = Double(r); green = Double(g); blue = Double(b); alpha = Double(a); self.ruler = ruler
        }
        var color: Color {
            Color(.sRGB, red: min(1, max(0, red)), green: min(1, max(0, green)),
                  blue: min(1, max(0, blue)), opacity: min(1, max(0, alpha)))
        }
    }
    var brushes: [String: Brush] = [:]
    var lastInk = InkTool.pen.rawValue
    var lastSelection = InkTool.rectangle.rawValue
    var lastEraser = InkTool.eraser.rawValue
    var eraserWidth: Double = 12
}

@MainActor
final class DrawingSession: NSObject, ObservableObject, PKCanvasViewDelegate {
    private(set) var canvas = PagingCanvasView()
    @Published var selectedTool: InkTool = .pen
    @Published private(set) var lastSelectionTool: InkTool = .rectangle
    @Published private(set) var lastEraserTool: InkTool = .eraser
    @Published var inkColor = Color.black { didSet { rememberInkSettings() } }
    @Published var inkWidth: Double = 3 { didSet { rememberInkSettings() } }
    @Published var rulerActive = false { didSet { rememberInkSettings() } }
    @Published var eraserWidth: Double = 12 { didSet { rememberEraserSettings() } }
    static let preferencesKey = "noteMargin.inkTools.preferences.v1"
    var eraserWidthRange: ClosedRange<Double> {
        Self.eraserWidthRange(for: selectedTool.isEraser ? selectedTool : lastEraserTool)
    }
    private static func eraserWidthRange(for tool: InkTool) -> ClosedRange<Double> {
        // PencilKit's vector eraser reports 0...0 and ignores requested widths.
        // Whole-stroke hit testing is ours, so its width is in document points.
        if tool != .pixelEraser { return 4...80 }
        let native = PKEraserTool.EraserType.fixedWidthBitmap.validWidthRange
        let lower = max(0.1, Double(native.lowerBound))
        return lower...max(lower, native.upperBound.isFinite ? Double(native.upperBound) : 64)
    }
    private let preferences: UserDefaults
    private var savedTools = InkToolPreferences()
    private var restoringToolSettings = true
    private var nativeToolActive = false
    private var nativeDrawingDirty = false
    private(set) var drawingRevision: UInt64 = 0
    private var committedDrawing = PKDrawing()
    private var committedDocumentDrawing = PKDrawing()
    private(set) var canvasOrigin = CGPoint.zero
    private let infiniteUndo = UndoManager()
    private var pendingInfiniteUndo: PKDrawing?
    var undoManager: UndoManager? { canvas.usesDocumentUndo ? infiniteUndo : canvas.undoManager }
    var drawing: PKDrawing {
        let native = canvas.drawing
        return native == committedDrawing ? committedDocumentDrawing : documentDrawing(native)
    }
    private func documentDrawing(_ native: PKDrawing) -> PKDrawing {
        canvasOrigin == .zero ? native : native.transformed(using: CGAffineTransform(translationX: -canvasOrigin.x, y: -canvasOrigin.y))
    }
    private func nativeDrawing(_ document: PKDrawing) -> PKDrawing {
        canvasOrigin == .zero ? document : document.transformed(using: CGAffineTransform(translationX: canvasOrigin.x, y: canvasOrigin.y))
    }
    private func documentShape(_ result: ShapeRecognitionResult) -> ShapeRecognitionResult {
        ShapeRecognitionResult(kind: result.kind, confidence: result.confidence, normalizedError: result.normalizedError,
            fittedPoints: result.fittedPoints.map { CGPoint(x: $0.x-canvasOrigin.x,y: $0.y-canvasOrigin.y) })
    }
    /// Only on scroll-range expansion, never during a contact. PencilKit keeps
    /// positive input coordinates; persisted paths and all app tools stay logical.
    func setCanvasOrigin(_ origin: CGPoint) {
        guard origin != canvasOrigin, !nativeToolActive else { return }
        let document = drawing
        shapeCompletion.invalidate(preservingSelection: host?.hasAutomaticShapeSelection == true)
        canvasOrigin = origin
        loading = true
        canvas.drawing = nativeDrawing(document)
        loading = false
        committedDrawing = canvas.drawing; committedDocumentDrawing = document
        shapeCompletion.nativeChanged(drawing: committedDrawing, revision: drawingRevision)
    }
    private var committedStrokeCount = 0
    private var committingShape = false
    private let shapeHoldScheduler: ShapeHoldScheduler?
    private lazy var shapeCompletion: ShapeCompletionController = {
        let controller = ShapeCompletionController(scheduler: shapeHoldScheduler)
        #if DEBUG
        controller.acceptsTestTouches = ProcessInfo.processInfo.arguments.contains("--pencil-test-touch")
        #endif
        controller.onCompletion = { [weak self] source, original, completed, result in
            guard let self, !self.nativeToolActive, self.loadError == nil,
                  self.canvas.drawing == source else { return false }
            self.committingShape = true
            var shapes = self.inkShapes
            if let stroke = self.documentDrawing(completed).strokes.last {
                shapes.removeAll { $0.strokeID == InkStrokeID(stroke) }
                shapes.append(InkShape(strokeID: InkStrokeID(stroke), kind: result.kind.rawValue,
                    points: self.documentShape(result).fittedPoints, fingerprint: Self.fingerprint(stroke)))
            }
            let accepted = self.replaceDrawing(self.documentDrawing(completed), on: self.canvas, action: "도형 보정", undoOriginal: self.documentDrawing(original), shapes: shapes)
            self.committingShape = false
            return accepted
        }
        controller.onClosedShapePreview = { [weak self] result in if let self { self.host?.showAutomaticShape(self.documentShape(result)) } }
        controller.onClosedShapeReady = { [weak self] result, ids in if let self { self.host?.activateAutomaticShape(self.documentShape(result), ids: ids) } }
        controller.onPreviewCancelled = { [weak self] in self?.host?.cancelAutomaticShape() }
        controller.shouldObserveContact = { [weak self] in self?.host?.hasAutomaticShapeSelection != true }
        controller.onRepair = { [weak self] source, completed in
            guard let self, !self.nativeToolActive, self.canvas.drawing == source else { return }
            // A late native estimate belongs to the same operation, not a new Undo.
            var shapes = self.inkShapes
            for stroke in self.documentDrawing(completed).strokes {
                if let i = shapes.firstIndex(where: { $0.strokeID == InkStrokeID(stroke) }) {
                    shapes[i].fingerprint = Self.fingerprint(stroke)
                }
            }
            if let noteID = self.noteID, let pageID = self.pageID {
                self.store?.updatePage(noteID: noteID, pageID: pageID) { $0.inkShapes = shapes }
            }
            self.canvas.drawing = completed
            self.processDrawingChange(self.canvas, isNativeNotification: false)
        }
        return controller
    }()
    #if DEBUG
    var shapeCompletionForTesting: ShapeCompletionController { shapeCompletion }
    #endif
    @Published var selectedStrokeCount = 0
    @Published var selectionActionRect: CGRect?
    @Published var selectionIsGrouped = false
    struct SelectedInkExport: Identifiable {
        let id = UUID()
        let urls: [URL]
    }
    @Published var selectedInkExport: SelectedInkExport?
    static var copiedInk: PKDrawing?
    private static var lastCopiedStrokeDate = Date.distantPast
    private var lastInk: (tool: InkTool, color: Color, width: Double, ruler: Bool) = (.pen, .black, 3, false)

    private func rememberInkSettings() {
        guard !restoringToolSettings, selectedTool.isInk else { return }
        let width = inkWidth.isFinite ? min(12, max(0.1, inkWidth)) : 3
        if width != inkWidth {
            restoringToolSettings = true; inkWidth = width; restoringToolSettings = false
        }
        savedTools.brushes[selectedTool.rawValue] = .init(width: width, color: inkColor, ruler: rulerActive)
        savedTools.lastInk = selectedTool.rawValue
        lastInk = (selectedTool, inkColor, width, rulerActive)
        persistToolSettings()
    }
    private func rememberEraserSettings() {
        guard !restoringToolSettings else { return }
        let requested = eraserWidth.isFinite ? eraserWidth : 12
        let width = min(eraserWidthRange.upperBound, max(eraserWidthRange.lowerBound, requested))
        if eraserWidth != width {
            restoringToolSettings = true; eraserWidth = width; restoringToolSettings = false
        }
        savedTools.eraserWidth = width
        persistToolSettings()
    }
    private func persistToolSettings() {
        guard !restoringToolSettings, let data = try? JSONEncoder().encode(savedTools) else { return }
        preferences.set(data, forKey: Self.preferencesKey)
    }
    private func restoreBrush(_ tool: InkTool) {
        let brush = savedTools.brushes[tool.rawValue] ?? .init()
        inkWidth = brush.width.isFinite ? min(12, max(0.1, brush.width)) : 3
        inkColor = brush.color; rulerActive = brush.ruler
    }
    func selectTool(_ tool: InkTool) {
        rememberInkSettings()
        host?.cancelStrokeErasing()
        host?.clearInkSelection()
        restoringToolSettings = true
        selectedTool = tool
        if tool.isInk { restoreBrush(tool) }
        if tool.isSelection { lastSelectionTool = tool; savedTools.lastSelection = tool.rawValue }
        if tool.isEraser { lastEraserTool = tool; savedTools.lastEraser = tool.rawValue }
        restoringToolSettings = false
        rememberInkSettings()
        if tool.isEraser { rememberEraserSettings() }
        persistToolSettings()
        applyTool()
    }
    func applyTool(preservingEraserPreview: Bool = false) {
        shapeCompletion.invalidate()
        shapeCompletion.isEnabled = selectedTool.isInk && !rulerActive
        if !preservingEraserPreview { host?.cancelStrokeErasing() }
        switch selectedTool {
        case .pen:
            // PencilKit clamps the classic pressure pen to ~0.88pt (OS dependent).
            // Its native monoline ink supports finer values without post-stroke
            // rescaling, which would visibly change ink after lifting the Pencil.
            let type: PKInkingTool.InkType = inkWidth < PKInkingTool.InkType.pen.validWidthRange.lowerBound ? .monoline : .pen
            canvas.tool = PKInkingTool(type, color: UIColor(inkColor), width: inkWidth)
        case .pencil: canvas.tool = PKInkingTool(.pencil, color: UIColor(inkColor), width: inkWidth)
        case .marker: canvas.tool = PKInkingTool(.marker, color: UIColor(inkColor), width: inkWidth * 4)
        case .eraser: canvas.tool = PKEraserTool(.vector)
        case .pixelEraser: canvas.tool = PKEraserTool(.fixedWidthBitmap, width: eraserWidth)
        // Both selection shapes use the same host-owned editable selection.
        case .lasso, .rectangle: canvas.tool = PKInkingTool(.pen, color: UIColor(inkColor), width: inkWidth)
        }
        canvas.isRulerActive = rulerActive && selectedTool.isInk
        host?.schedulePreviewWarmup()
    }
    func finishErasing() {
        guard selectedTool == .eraser || selectedTool == .pixelEraser else { return }
        let previous = lastInk
        restoringToolSettings = true
        selectedTool = previous.tool; inkColor = previous.color
        inkWidth = previous.width; rulerActive = previous.ruler
        restoringToolSettings = false
        rememberInkSettings()
        // The vector preview stays until PencilKit has rendered committed ink.
        applyTool(preservingEraserPreview: true)
    }
    func canvasViewDidBeginUsingTool(_ canvasView: PKCanvasView) {
        guard canvasView === canvas, let noteID, let pageID else { return }
        if canvas.usesDocumentUndo { pendingInfiniteUndo = drawing }
        nativeToolActive = true
        nativeDrawingDirty = false
        shapeCompletion.nativeBegan(previousStrokeCount: committedStrokeCount)
        host?.setDrawingActive(true)
        store?.beginDrawingInteraction(noteID: noteID, pageID: pageID, snapshot: { [weak self, weak canvasView] in
            guard let self, let canvasView else { return nil }
            return DrawingEngineMetrics.snapshot { self.documentDrawing(canvasView.drawing) }
        })
    }
    func canvasViewDidEndUsingTool(_ canvasView: PKCanvasView) {
        guard canvasView === canvas else { return }
        // Capture once at the commit boundary. PencilKit owns active/coalesced/
        // predicted input and incremental rendering throughout the contact.
        if nativeDrawingDirty { captureCommittedDrawing(canvasView) }
        nativeToolActive = false
        nativeDrawingDirty = false
        registerInfiniteStrokeUndo()
        host?.setDrawingActive(false)
        if let noteID, let pageID { store?.endDrawingInteraction(noteID: noteID, pageID: pageID) }
        shapeCompletion.nativeEnded(drawing: committedDrawing, revision: drawingRevision)
        refreshUndo()
        guard selectedTool == .pixelEraser else { return }
        DispatchQueue.main.async { [weak self, weak canvasView] in
            guard let self, canvasView === self.canvas, self.selectedTool == .pixelEraser else { return }
            self.finishErasing()
        }
    }
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var zoomPercent = 100
    @Published var loadError: String?
    weak var host: CanvasHostView?
    private weak var store: NoteStore?
    private var noteID: UUID?
    private var pageID: UUID?
    private var loading = false
    private var undoRefreshPending = false
    private var toolsAreVisible = false
    private var undoObservers: [NSObjectProtocol] = []

    override convenience init() {
        #if DEBUG
        if let id = ProcessInfo.processInfo.environment["NOTEMARGIN_UI_FIXTURE"], UUID(uuidString: id) != nil {
            self.init(preferences: UserDefaults(suiteName: "NoteMargin.UITests." + id)!)
            return
        }
        #endif
        self.init(preferences: .standard)
    }

    init(preferences: UserDefaults, shapeHoldScheduler: ShapeHoldScheduler? = nil) {
        self.preferences = preferences
        self.shapeHoldScheduler = shapeHoldScheduler
        super.init()
        if let data = preferences.data(forKey: Self.preferencesKey),
           let stored = try? JSONDecoder().decode(InkToolPreferences.self, from: data) { savedTools = stored }
        let restoredInk = InkTool(rawValue: savedTools.lastInk) ?? .pen
        selectedTool = restoredInk.isInk ? restoredInk : .pen
        let restoredSelection = InkTool(rawValue: savedTools.lastSelection) ?? .rectangle
        lastSelectionTool = restoredSelection.isSelection ? restoredSelection : .rectangle
        let restoredEraser = InkTool(rawValue: savedTools.lastEraser) ?? .eraser
        lastEraserTool = restoredEraser.isEraser ? restoredEraser : .eraser
        restoreBrush(selectedTool)
        let restoredWidth = savedTools.eraserWidth.isFinite ? savedTools.eraserWidth : 12
        eraserWidth = min(eraserWidthRange.upperBound, max(eraserWidthRange.lowerBound, restoredWidth))
        lastInk = (selectedTool, inkColor, inkWidth, rulerActive)
        restoringToolSettings = false
        configureCanvas(canvas)
        applyTool()
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshUndo() }
            })
        }
    }

    deinit { for observer in undoObservers { NotificationCenter.default.removeObserver(observer) } }

    private func configureCanvas(_ canvas: PagingCanvasView) {
        shapeCompletion.attach(to: canvas)
        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = true
        canvas.overrideUserInterfaceStyle = .light
        if #available(iOS 26.0, *) { canvas.pencilKitResponderState.toolPickerVisibility = .inactive }
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.drawingPolicy = .pencilOnly
    }

    func load(noteID: UUID, pageID: UUID, store: NoteStore) {
        guard self.noteID != noteID || self.pageID != pageID else { return }
        host?.saveViewport()
        shapeCompletion.invalidate()
        nativeToolActive = false
        host?.setDrawingActive(false)
        host?.cancelStrokeErasing()
        if let previousNote = self.noteID, let previousPage = self.pageID {
            self.store?.endDrawingInteraction(noteID: previousNote, pageID: previousPage)
            if self.store !== store { self.store?.flushDrawings() }
        }
        store.flushDrawings()
        self.store = store
        self.noteID = noteID
        self.pageID = pageID
        loading = true
        loadError = nil
        let previous = canvas
        let selectedTool = previous.tool
        canvasOrigin = .zero; infiniteUndo.removeAllActions(); pendingInfiniteUndo = nil
        let replacement = PagingCanvasView()
        replacement.usesDocumentUndo = store.note(noteID)?.pages.first(where: { $0.id == pageID })?.isInfinite == true
        configureCanvas(replacement)
        // An empty drawing can leave old PencilKit render tiles alive on a reused
        // view. Give each page its own render surface, without changing ink coordinates.
        previous.delegate = nil
        if previous.isFirstResponder { previous.resignFirstResponder() }
        toolsAreVisible = false
        canvas = replacement
        // Reopening can replace the canvas after SwiftUI's configuration pass.
        // Keep its input policy until the next pass, including infinite viewports.
        replacement.drawingPolicy = previous.drawingPolicy
        replacement.panGestureRecognizer.minimumNumberOfTouches = previous.panGestureRecognizer.minimumNumberOfTouches
        replacement.tool = selectedTool
        replacement.isRulerActive = previous.isRulerActive
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
        committedDrawing = canvas.drawing
        committedDocumentDrawing = documentDrawing(committedDrawing)
        committedStrokeCount = committedDrawing.strokes.count
        shapeCompletion.nativeChanged(drawing: committedDrawing, revision: drawingRevision)
        loading = false
        refreshUndo()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        processDrawingChange(canvasView, isNativeNotification: true)
    }
    private func processDrawingChange(_ canvasView: PKCanvasView, isNativeNotification: Bool) {
        guard canvasView === canvas, !loading, loadError == nil, let noteID, let pageID else { return }
        DrawingEngineMetrics.drawingChanged()
        drawingRevision &+= 1
        if nativeToolActive {
            nativeDrawingDirty = true
            store?.markActiveDrawingChanged(noteID: noteID, pageID: pageID)
            return
        }
        // Includes PencilKit's late estimated-pressure updates after lift.
        let drawing = captureCommittedDrawing(canvasView)
        shapeCompletion.nativeChanged(drawing: committedDrawing, revision: drawingRevision, isNativeNotification: isNativeNotification)
        registerInfiniteStrokeUndo()
        host?.cancelEraserIfDrawingChanged(drawing)
        host?.validateInkSelection(drawing)
        // Undo groups close at the end of the current event.
        if !undoRefreshPending {
            undoRefreshPending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.undoRefreshPending = false
                self.refreshUndo()
            }
        }
    }

    @discardableResult private func captureCommittedDrawing(_ canvasView: PKCanvasView) -> PKDrawing {
        let drawing = DrawingEngineMetrics.snapshot { canvasView.drawing }
        // Echoes of an assigned native drawing reuse its logical snapshot.
        // Transforming the same PKDrawing twice creates distinct archive IDs.
        if drawing != committedDrawing { committedDocumentDrawing = documentDrawing(drawing) }
        committedDrawing = drawing
        committedStrokeCount = drawing.strokes.count
        if let noteID, let pageID { store?.queueDrawing(committedDocumentDrawing, noteID: noteID, pageID: pageID) }
        return committedDocumentDrawing
    }
    private func registerInfiniteStrokeUndo() {
        guard !nativeToolActive, let original = pendingInfiniteUndo, original != committedDocumentDrawing else { return }
        pendingInfiniteUndo = nil
        let ownsGroup = infiniteUndo.groupingLevel == 0 && !infiniteUndo.isUndoing && !infiniteUndo.isRedoing
        if ownsGroup { infiniteUndo.beginUndoGrouping() }
        defer { if ownsGroup { infiniteUndo.endUndoGrouping() } }
        infiniteUndo.registerUndo(withTarget: self) { session in
            session.commitDrawing(original, action: "필기")
        }
        infiniteUndo.setActionName("필기")
    }

    @discardableResult
    func commitStrokeErasing(_ drawing: PKDrawing) -> Bool {
        commitDrawing(drawing, action: "획 지우기")
    }

    @discardableResult
    func commitDrawing(_ drawing: PKDrawing, action: String, shapes: [InkShape]? = nil) -> Bool {
        guard loadError == nil else { return false }
        return replaceDrawing(drawing, on: canvas, action: action, shapes: shapes)
    }

    @discardableResult
    private func replaceDrawing(_ drawing: PKDrawing, on target: PagingCanvasView, action: String, undoOriginal: PKDrawing? = nil, shapes: [InkShape]? = nil) -> Bool {
        guard target === canvas else { return false }
        if !committingShape { shapeCompletion.invalidate() }
        let ownsGroup = canvas.usesDocumentUndo && undoManager?.groupingLevel == 0 && undoManager?.isUndoing == false && undoManager?.isRedoing == false
        if ownsGroup { undoManager?.beginUndoGrouping() }
        defer { if ownsGroup { undoManager?.endUndoGrouping() } }
        let previous = undoOriginal ?? self.drawing
        let previousShapes = inkShapes
        if let shapes, let noteID, let pageID {
            guard store?.updatePage(noteID: noteID, pageID: pageID, { $0.inkShapes = shapes.isEmpty ? nil : shapes }) == true else { return false }
        }
        undoManager?.registerUndo(withTarget: target) { [weak self] target in
            self?.replaceDrawing(previous, on: target, action: action, shapes: previousShapes)
        }
        undoManager?.setActionName(action)
        loading = true
        target.drawing = nativeDrawing(drawing)
        committedDrawing = target.drawing
        committedDocumentDrawing = drawing
        loading = false
        processDrawingChange(target, isNativeNotification: false)
        return true
    }

    var inkShapes: [InkShape] {
        guard let noteID, let pageID else { return [] }
        return store?.note(noteID)?.pages.first(where: { $0.id == pageID })?.inkShapes ?? []
    }
    static func fingerprint(_ stroke: PKStroke) -> Data {
        // A new PKDrawing has a random archive identity. Hash geometry instead
        // so the same native stroke still matches after loading from disk.
        var bytes = Data()
        func append(_ value: Double) {
            // PencilKit archives transforms as Float32. Hash the archived
            // precision, so fractional drags survive save/reopen unchanged.
            var bits = Double(Float(value)).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { bytes.append(contentsOf: $0) }
        }
        let t = stroke.transform
        for value in [t.a, t.b, t.c, t.d, t.tx, t.ty] { append(Double(value)) }
        for point in stroke.path {
            append(Double(point.location.x)); append(Double(point.location.y))
        }
        return Data(SHA256.hash(data: bytes))
    }
    func shape(for stroke: PKStroke) -> ShapeRecognitionResult? {
        guard stroke.mask == nil,
              let saved = inkShapes.first(where: { $0.strokeID == InkStrokeID(stroke) }),
              saved.fingerprint == Self.fingerprint(stroke), let kind = ShapeKind(rawValue: saved.kind) else { return nil }
        return ShapeRecognitionResult(kind: kind, confidence: 1, normalizedError: 0, fittedPoints: saved.points)
    }
    func transformedShapes(drawing: PKDrawing, indices: Set<Int>, transform: CGAffineTransform) -> [InkShape] {
        let strokes = drawing.strokes
        var shapes = inkShapes
        for i in indices where strokes.indices.contains(i) {
            let stroke = strokes[i]
            guard let index = shapes.firstIndex(where: { $0.strokeID == InkStrokeID(stroke) }) else { continue }
            shapes[index].points = shapes[index].points.map { $0.applying(transform) }
            shapes[index].fingerprint = Self.fingerprint(stroke)
        }
        return shapes
    }

    private var inkGroups: [InkGroup] {
        guard let noteID, let pageID else { return [] }
        return store?.note(noteID)?.pages.first(where: { $0.id == pageID })?.inkGroups ?? []
    }

    private static func strokeID(_ stroke: PKStroke) -> InkStrokeID {
        InkStrokeID(creationDate: stroke.path.creationDate, randomSeed: stroke.randomSeed)
    }

    func expandedSelectionIndices(in drawing: PKDrawing, indices: Set<Int>) -> Set<Int> {
        let strokes = drawing.strokes
        let identifiers = strokes.map(Self.strokeID)
        let originalIndices = Set(indices.filter { strokes.indices.contains($0) })
        var selected = Set(originalIndices.map { identifiers[$0] })
        var groupedIdentifiers: Set<InkStrokeID> = []
        // Normally groups are disjoint. Fixed-point expansion also handles older
        // or merged metadata with overlapping groups without dropping members.
        var changed = true
        while changed {
            changed = false
            for group in inkGroups where !selected.isDisjoint(with: group.strokeIDs) {
                let before = selected.count
                groupedIdentifiers.formUnion(group.strokeIDs)
                selected.formUnion(group.strokeIDs)
                if selected.count != before { changed = true }
            }
        }
        // Legacy pasted copies may share identifiers. Without a matching group,
        // preserve the exact hit-test indices rather than selecting those copies.
        return originalIndices.union(identifiers.indices.filter { groupedIdentifiers.contains(identifiers[$0]) })
    }

    func updateSelectionActions(rect: CGRect?, selectedDrawing: PKDrawing?) {
        if selectionActionRect != rect { selectionActionRect = rect }
        let identifiers = Set((selectedDrawing?.strokes ?? []).map(Self.strokeID))
        let grouped = inkGroups.contains { !identifiers.isDisjoint(with: $0.strokeIDs) }
        if selectionIsGrouped != grouped { selectionIsGrouped = grouped }
    }

    func groupSelectedInk() {
        guard loadError == nil, let host, let store, let noteID, let pageID else { return }
        let drawing = self.drawing
        let indices = expandedSelectionIndices(in: drawing, indices: host.selectedInkIndices)
        guard indices.count >= 2 else { return }
        let strokes = drawing.strokes
        let identifiers = indices.sorted().map { Self.strokeID(strokes[$0]) }
        let selected = Set(identifiers)
        var groups = inkGroups.filter { selected.isDisjoint(with: $0.strokeIDs) }
        let unselected = Set(strokes.indices.filter { !indices.contains($0) }.map { Self.strokeID(strokes[$0]) })
        let colliding = indices.filter { unselected.contains(Self.strokeID(strokes[$0])) }
        if !colliding.isEmpty {
            // Earlier app versions pasted identical public stroke identifiers.
            // Repair only the selected copies; unrelated strokes keep all bytes.
            var repaired = strokes
            for index in colliding.sorted() {
                repaired[index] = Self.reidentifiedInk(PKDrawing(strokes: [strokes[index]])).strokes[0]
            }
            groups.append(InkGroup(strokeIDs: indices.sorted().map { Self.strokeID(repaired[$0]) }))
            replaceGroupedSelection(PKDrawing(strokes: repaired), groups: groups, selectedIndices: indices, action: "필기 그룹화")
            return
        }
        groups.append(InkGroup(strokeIDs: identifiers))
        if store.setInkGroups(noteID: noteID, pageID: pageID, groups: groups, undoManager: undoManager, action: "필기 그룹화") {
            updateSelectionActions(rect: selectionActionRect, selectedDrawing: host.selectedInkDrawing)
            refreshUndo()
        }
    }

    private func replaceGroupedSelection(_ drawing: PKDrawing, groups: [InkGroup], selectedIndices: Set<Int>, action: String) {
        guard loadError == nil, let store, let noteID, let pageID else { return }
        let target = canvas
        let previous = self.drawing, previousGroups = inkGroups
        guard store.setInkGroupsAndDrawing(noteID: noteID, pageID: pageID, drawing: drawing, groups: groups) else { return }
        undoManager?.registerUndo(withTarget: target) { [weak self] target in
            guard let self, self.canvas === target else { return }
            self.replaceGroupedSelection(previous, groups: previousGroups, selectedIndices: selectedIndices, action: action)
        }
        undoManager?.setActionName(action)
        host?.clearInkSelection()
        // Persistence already succeeded. Suppress the synchronous drawing-change
        // callback; any late PencilKit callback still follows the normal path.
        loading = true
        target.drawing = nativeDrawing(drawing)
        committedDrawing = target.drawing
        committedDocumentDrawing = drawing
        loading = false
        host?.restoreInkSelection(indices: selectedIndices)
        updateSelectionActions(rect: selectionActionRect, selectedDrawing: host?.selectedInkDrawing)
        refreshUndo()
    }

    func ungroupSelectedInk() {
        guard loadError == nil, let host, let drawing = host.selectedInkDrawing,
              let store, let noteID, let pageID else { return }
        let selected = Set(drawing.strokes.map(Self.strokeID))
        let groups = inkGroups.filter { selected.isDisjoint(with: $0.strokeIDs) }
        if store.setInkGroups(noteID: noteID, pageID: pageID, groups: groups, undoManager: undoManager, action: "필기 그룹 해제") {
            updateSelectionActions(rect: selectionActionRect, selectedDrawing: drawing)
            refreshUndo()
        }
    }

    /// A pasted copy gets a new path date, while keeping the random seed that
    /// controls its rendered pencil texture. No existing stroke is rewritten.
    static func reidentifiedInk(_ drawing: PKDrawing) -> PKDrawing {
        PKDrawing(strokes: drawing.strokes.map { stroke in
            let date = max(Date(), max(lastCopiedStrokeDate, stroke.path.creationDate).addingTimeInterval(0.000001))
            lastCopiedStrokeDate = date
            let path = PKStrokePath(controlPoints: (0..<stroke.path.count).map { stroke.path[$0] }, creationDate: date)
            return PKStroke(ink: stroke.ink, path: path, transform: stroke.transform, mask: stroke.mask, randomSeed: stroke.randomSeed)
        })
    }

    func saveSelectedInk() {
        guard loadError == nil, let drawing = host?.selectedInkDrawing, !drawing.strokes.isEmpty else { return }
        let bounds = drawing.bounds.insetBy(dx: -8, dy: -8)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("NoteMargin-Ink-\(UUID().uuidString)", isDirectory: true)
        do {
            guard store?.flushDrawings() == true else { return }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let editable = directory.appendingPathComponent("선택한 필기.drawing")
            let imageURL = directory.appendingPathComponent("선택한 필기.png")
            let normalized = drawing.transformed(using: CGAffineTransform(translationX: -bounds.minX, y: -bounds.minY))
            try normalized.dataRepresentation().write(to: editable, options: .atomic)
            // Bound raster memory even when the selection spans a very long PDF.
            // The .drawing export retains the full editable source resolution.
            let scale = min(2, 2048 / max(bounds.width, bounds.height))
            let size = CGSize(width: max(1, ceil(bounds.width * scale)), height: max(1, ceil(bounds.height * scale)))
            let format = UIGraphicsImageRendererFormat()
            format.scale = 1; format.opaque = true
            var png: Data?
            UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                let ink = drawing.image(from: bounds, scale: scale)
                png = UIGraphicsImageRenderer(size: size, format: format).image { context in
                    UIColor.white.setFill(); context.fill(CGRect(origin: .zero, size: size))
                    ink.draw(in: CGRect(origin: .zero, size: size))
                }.pngData()
            }
            guard let png else { throw CocoaError(.fileWriteUnknown) }
            try png.write(to: imageURL, options: .atomic)
            selectedInkExport = SelectedInkExport(urls: [editable, imageURL])
        } catch {
            try? FileManager.default.removeItem(at: directory)
            store?.errorMessage = "선택한 필기를 저장할 수 없습니다. \(error.localizedDescription)"
        }
    }

    func canvasViewDidFinishRendering(_ canvasView: PKCanvasView) {
        guard canvasView === canvas else { return }
        shapeCompletion.nativeFinishedRendering()
        host?.finishEraserRendering()
        host?.finishInkRendering()
    }

    func scrollViewDidScroll(_ scrollView: UIScrollView) {
        if scrollView === canvas { host?.canvasDidScroll() }
    }
    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
        if scrollView === canvas { shapeCompletion.invalidate() }
    }
    func scrollViewWillBeginZooming(_ scrollView: UIScrollView, with view: UIView?) {
        if scrollView === canvas { shapeCompletion.invalidate() }
    }
    func scrollViewDidZoom(_ scrollView: UIScrollView) {
        if scrollView === canvas { host?.canvasDidZoom() }
    }

    func refreshUndo() {
        let undo = undoManager?.canUndo ?? false
        let redo = undoManager?.canRedo ?? false
        if canUndo != undo { canUndo = undo }
        if canRedo != redo { canRedo = redo }
    }
    func undo() { shapeCompletion.invalidate(); host?.clearInkSelection(); host?.cancelStrokeErasing(); undoManager?.undo(); refreshUndo() }
    func redo() { shapeCompletion.invalidate(); host?.clearInkSelection(); host?.cancelStrokeErasing(); undoManager?.redo(); refreshUndo() }
    func fitPage() { host?.fitPage(animated: true) }

    func setToolsVisible(_ visible: Bool) {
        // Keep the responder stable while saving live ink. The app owns the tool UI.
        let shouldShow = visible && canvas.window != nil
        if toolsAreVisible != shouldShow {
            toolsAreVisible = shouldShow
        }
        if shouldShow && !canvas.isFirstResponder { canvas.becomeFirstResponder() }
        else if !shouldShow && canvas.isFirstResponder { canvas.resignFirstResponder() }
    }

    func saveViewport(_ viewport: CanvasViewport) {
        guard let noteID, let pageID else { return }
        if store?.note(noteID)?.pages.first(where: { $0.id == pageID })?.viewport != viewport {
            store?.updatePage(noteID: noteID, pageID: pageID) { $0.viewport = viewport }
        }
    }
    func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
        if !decelerate { host?.canvasDidScroll(); host?.saveViewport() }
    }
    func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
        host?.canvasDidScroll(); host?.saveViewport()
    }
    func scrollViewDidEndZooming(_ scrollView: UIScrollView, with view: UIView?, atScale scale: CGFloat) {
        host?.canvasDidScroll(); host?.saveViewport()
    }
    func stop() {
        host?.saveViewport()
        shapeCompletion.invalidate()
        nativeToolActive = false
        host?.cancelStrokeErasing()
        host?.setDrawingActive(false)
        if let noteID, let pageID { store?.endDrawingInteraction(noteID: noteID, pageID: pageID) }
        store?.flushDrawings(); setToolsVisible(false)
    }
}

final class PagingCanvasView: PKCanvasView {
    #if DEBUG
    var editingDiagnostics: (() -> String)?
    override var accessibilityValue: String? {
        get { editingDiagnostics?() ?? super.accessibilityValue }
        set { super.accessibilityValue = newValue }
    }
    #endif
    // Native Undo snapshots use display coordinates. Infinite documents register
    // logical snapshots in DrawingSession so range rebasing cannot corrupt Undo.
    var usesDocumentUndo = false
    override var undoManager: UndoManager? { usesDocumentUndo ? nil : super.undoManager }
    var pageTurningEnabled = false
    // The canvas owns three-finger paging; toolbar undo/redo remain available.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        (pageTurningEnabled || usesDocumentUndo) ? .none : .default
    }
}

/// A document-coordinate vector approximation used only for hit testing.
/// Display uses native PencilKit textures, never this approximation. The editable PencilKit stroke is never replaced by this path.
struct InkStrokeGeometry {
    let path: CGPath
    let color: CGColor
    let opacity: Float
    let bounds: CGRect

    init(stroke: PKStroke) {
        let outline = CGMutablePath()
        let source = stroke.path
        var length: CGFloat = 0
        if source.count > 1 {
            for index in 1..<source.count {
                length += hypot(source[index].location.x - source[index - 1].location.x,
                                source[index].location.y - source[index - 1].location.y)
            }
        }
        // Interpolate PencilKit's B-spline once. A very long stroke has a bounded
        // sample count; ordinary handwriting retains sub-point detail.
        let step = max(0.5, length / 8192)
        var previous: PKStrokePoint?
        var opacitySum: CGFloat = 0
        var opacityCount: CGFloat = 0
        func append(_ point: PKStrokePoint) {
            guard point.location.x.isFinite, point.location.y.isFinite,
                  point.size.width.isFinite, point.size.height.isFinite,
                  point.opacity.isFinite, point.azimuth.isFinite,
                  point.opacity > 0, point.size.width > 0, point.size.height > 0 else {
                previous = nil
                return
            }
            let rx = point.size.width / 2, ry = point.size.height / 2
            // The ellipse and bridge use the same winding. Opposite windings
            // would punch alternating holes where densely sampled nibs overlap.
            let c = cos(point.azimuth), s = sin(point.azimuth)
            func at(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
                CGPoint(x: point.location.x + c * x - s * y,
                        y: point.location.y + s * x + c * y)
            }
            let k: CGFloat = 0.5522847498307936
            outline.move(to: at(rx, 0))
            outline.addCurve(to: at(0, ry), control1: at(rx, k * ry), control2: at(k * rx, ry))
            outline.addCurve(to: at(-rx, 0), control1: at(-k * rx, ry), control2: at(-rx, k * ry))
            outline.addCurve(to: at(0, -ry), control1: at(-rx, -k * ry), control2: at(-k * rx, -ry))
            outline.addCurve(to: at(rx, 0), control1: at(k * rx, -ry), control2: at(rx, -k * ry))
            outline.closeSubpath()
            if let previous {
                let dx = point.location.x - previous.location.x
                let dy = point.location.y - previous.location.y
                let distance = hypot(dx, dy)
                if distance > 0.00001 {
                    let normal = CGPoint(x: -dy / distance, y: dx / distance)
                    func offset(_ sample: PKStrokePoint) -> CGPoint {
                        let c = cos(sample.azimuth), s = sin(sample.azimuth)
                        let nx = normal.x * c + normal.y * s
                        let ny = -normal.x * s + normal.y * c
                        let rx = sample.size.width / 2, ry = sample.size.height / 2
                        let divisor = max(0.00001, hypot(rx * nx, ry * ny))
                        let x = rx * rx * nx / divisor, y = ry * ry * ny / divisor
                        return CGPoint(x: c * x - s * y, y: s * x + c * y)
                    }
                    let a = offset(previous), b = offset(point)
                    outline.move(to: CGPoint(x: previous.location.x + a.x, y: previous.location.y + a.y))
                    outline.addLine(to: CGPoint(x: previous.location.x - a.x, y: previous.location.y - a.y))
                    outline.addLine(to: CGPoint(x: point.location.x - b.x, y: point.location.y - b.y))
                    outline.addLine(to: CGPoint(x: point.location.x + b.x, y: point.location.y + b.y))
                    outline.closeSubpath()
                }
            }
            previous = point
            opacitySum += min(1, point.opacity)
            opacityCount += 1
        }
        if source.count == 1 { append(source[0]) }
        else if !source.isEmpty {
            for point in source.interpolatedPoints(by: .distance(step)) { append(point) }
            if previous?.location != source[source.count - 1].location { append(source[source.count - 1]) }
        }
        var local: CGPath = outline
        if let mask = stroke.mask {
            // PKStroke.mask is explicitly pre-transform in the public SDK.
            let clipping = mask.cgPath.normalized(using: mask.usesEvenOddFillRule ? .evenOdd : .winding)
            local = local.intersection(clipping)
        }
        var transform = stroke.transform
        path = local.copy(using: &transform) ?? CGMutablePath()
        bounds = path.boundingBoxOfPath
        color = stroke.ink.color.resolvedColor(with: UITraitCollection(userInterfaceStyle: .light)).cgColor
        opacity = opacityCount > 0 ? Float(opacitySum / opacityCount) : 0
    }
}

/// Both freeform and box selections share the same editable whole-stroke model.
struct RectangularInkSelection {
    let original: PKDrawing
    let indices: Set<Int>
    let geometryCache: InkGeometryCache
    init(drawing: PKDrawing, rect: CGRect, geometryCache: InkGeometryCache? = nil) {
        original = drawing
        if let geometryCache, geometryCache.drawing == drawing { self.geometryCache = geometryCache }
        else { self.geometryCache = InkGeometryCache(drawing: drawing) }
        indices = self.geometryCache.indices(intersecting: rect)
    }
    init(drawing: PKDrawing, path: CGPath, geometryCache: InkGeometryCache? = nil) {
        original = drawing
        if let geometryCache, geometryCache.drawing == drawing { self.geometryCache = geometryCache }
        else { self.geometryCache = InkGeometryCache(drawing: drawing) }
        indices = self.geometryCache.indices(intersecting: path)
    }
    init(drawing: PKDrawing, indices: Set<Int>, geometryCache: InkGeometryCache? = nil) {
        original = drawing
        self.indices = indices.intersection(Set(drawing.strokes.indices))
        if let geometryCache, geometryCache.drawing == drawing { self.geometryCache = geometryCache }
        else { self.geometryCache = InkGeometryCache(drawing: drawing) }
    }
    var drawing: PKDrawing { PKDrawing(strokes: original.strokes.enumerated().compactMap { indices.contains($0.offset) ? $0.element : nil }) }
    var bounds: CGRect { drawing.bounds }
    var removing: PKDrawing { PKDrawing(strokes: original.strokes.enumerated().compactMap { indices.contains($0.offset) ? nil : $0.element }) }
    func transformed(_ transform: CGAffineTransform) -> PKDrawing {
        var strokes = original.strokes
        let changed = drawing.transformed(using: transform).strokes
        for (index, stroke) in zip(indices.sorted(), changed) { strokes[index] = stroke }
        return PKDrawing(strokes: strokes)
    }
}
