import UIKit
import PencilKit

/// Value snapshots of actual/coalesced touches only. Predicted Pencil input is
/// owned exclusively by PencilKit and never enters recognition or persistence.
struct ShapeCompletionSample: Sendable {
    var documentPoint: CGPoint
    var timestamp: TimeInterval
    var estimationIndex: Int?
    var expectingUpdates: UInt
    var force: CGFloat = 1
    var altitude: CGFloat = .pi / 2
    var azimuth: CGFloat = 0
}

/// Kept outside UIGestureRecognizer so reset/ended does not discard pressure or
/// location estimates that UIKit will finalize after Pencil lift.
struct ShapeCompletionContact: Sendable {
    private(set) var samples: [ShapeCompletionSample] = []
    private(set) var pending = Set<Int>()
    private var indices: [Int: Int] = [:]
    private(set) var ambiguous = false
    private(set) var ended = false
    private var anchor = CGPoint.zero
    private(set) var lastMovement: TimeInterval = 0
    private var endTime: TimeInterval = 0
    private var anchorIndex = 0
    var recognitionSamples: [ShapeCompletionSample] { Array(samples.prefix(anchorIndex + 1)) }
    private var minimum = CGPoint.zero, maximum = CGPoint.zero
    let zoom: CGFloat
    let offset: CGPoint
    let holdDuration: TimeInterval

    init(zoom: CGFloat, offset: CGPoint, holdDuration: TimeInterval = 0.55) {
        self.zoom = zoom; self.offset = offset
        self.holdDuration = holdDuration.isFinite ? max(0.55, holdDuration) : 0.55
    }
    mutating func append(_ sample: ShapeCompletionSample) {
        guard !ended, sample.documentPoint.x.isFinite, sample.documentPoint.y.isFinite,
              sample.timestamp.isFinite, samples.count < 100_000 else { ambiguous = true; return }
        if let index = sample.estimationIndex, let existing = indices[index] {
            guard samples[existing].timestamp == sample.timestamp else { ambiguous = true; return }
            samples[existing] = sample; updatePending(sample); return
        }
        if let last = samples.last, sample.timestamp <= last.timestamp { updatePending(sample); return }
        if samples.isEmpty {
            anchor = sample.documentPoint; minimum = anchor; maximum = anchor; lastMovement = sample.timestamp
        } else if hypot(sample.documentPoint.x - anchor.x, sample.documentPoint.y - anchor.y) * zoom > 2.5 {
            anchor = sample.documentPoint; lastMovement = sample.timestamp; anchorIndex = samples.count
        }
        minimum.x = min(minimum.x, sample.documentPoint.x); minimum.y = min(minimum.y, sample.documentPoint.y)
        maximum.x = max(maximum.x, sample.documentPoint.x); maximum.y = max(maximum.y, sample.documentPoint.y)
        if let index = sample.estimationIndex { indices[index] = samples.count }
        samples.append(sample); updatePending(sample)
    }
    mutating func updateEstimate(_ sample: ShapeCompletionSample) {
        guard let key = sample.estimationIndex, let index = indices[key],
              samples[index].timestamp == sample.timestamp else { return }
        samples[index] = sample; updatePending(sample)
    }
    private mutating func updatePending(_ sample: ShapeCompletionSample) {
        if let index = sample.estimationIndex {
            if sample.expectingUpdates == 0 { pending.remove(index) } else { pending.insert(index) }
        } else if sample.expectingUpdates != 0 { ambiguous = true }
    }
    mutating func end(timestamp: TimeInterval) { ended = true; endTime = timestamp }
    var hasMeaningfulStroke: Bool {
        !ambiguous && samples.count >= 12 && hypot(maximum.x - minimum.x, maximum.y - minimum.y) * zoom >= 36
    }
    var ready: Bool {
        !ambiguous && ended && pending.isEmpty && samples.count >= 12 &&
        endTime - lastMovement >= holdDuration && hypot(maximum.x - minimum.x, maximum.y - minimum.y) * zoom >= 36
    }
}

/// A single cancellable monotonic deadline, independent of touch-move events and
/// UIKit's tracking run-loop mode. Tests inject the same boundary with a manual clock.
@MainActor
struct ShapeHoldScheduler {
    var now: () -> TimeInterval
    var schedule: (TimeInterval, @escaping @MainActor () -> Void) -> (() -> Void)
    static var live: Self {
        Self(now: { ProcessInfo.processInfo.systemUptime }, schedule: { delay, fire in
            let task = Task { @MainActor in
                do { try await Task.sleep(for: .seconds(max(0, delay))) } catch { return }
                guard !Task.isCancelled else { return }
                fire()
            }
            return { task.cancel() }
        })
    }
}

@MainActor
final class ShapeCompletionController {
    enum Phase { case idle, tracking, recognizing, snapped, committing, finished }
    private(set) var phase: Phase = .idle
    var isEnabled = false {
        didSet {
            if !isEnabled { invalidate() }
            observer.isEnabled = isEnabled
        }
    }
    // Native source, freehand before the snap (for undo), completed drawing.
    var onCompletion: ((PKDrawing, PKDrawing, PKDrawing, ShapeRecognitionResult) -> Bool)?
    var onRepair: ((PKDrawing, PKDrawing) -> Void)?
    var onClosedShapePreview: ((ShapeRecognitionResult) -> Void)?
    var onClosedShapeReady: ((ShapeRecognitionResult, Set<InkStrokeID>) -> Void)?
    var onPreviewCancelled: (() -> Void)?
    var shouldObserveContact: (() -> Bool)?
    private weak var canvas: PKCanvasView?
    private let observer = ShapeCompletionGestureRecognizer()
    private let recognizer: any ShapeRecognizing
    private let holdDuration: TimeInterval
    private let clock: ShapeHoldScheduler
    private var contact: ShapeCompletionContact?
    private var baseline: PKDrawing?
    private var latestDrawing: PKDrawing?
    private var previousStrokeCount: Int?
    private var nativeActive = false, nativeDidEnd = false
    private var revision: UInt64 = 0, epoch: UInt64 = 0, request: UInt64 = 0
    private var work: Task<Void, Never>?
    private var cancelDeadline: (() -> Void)?
    private var eventClockOffset: TimeInterval = 0
    private var gateScheduled = false
    private var result: ShapeRecognitionResult?
    private var cutoff: TimeInterval = 0
    private var preview: ShapeHeldPreview?
    private var lineTemplate: PKStroke?
    private var handoffScheduled = false
    private var renderedCommit: PKDrawing?
    private var committed: PKDrawing?
    private var receipt: Receipt?
    private var applicationObserver: NSObjectProtocol?
    private struct Receipt {
        let baseline: PKDrawing
        let original: PKStroke
        let result: ShapeRecognitionResult
        let cutoff: TimeInterval
        var completed: PKDrawing
    }
    #if DEBUG
    // Only disposable integration fixtures opt in: production still observes Pencil only.
    private var renderCallbacks = 0
    var handoffDiagnostics: String {
        "phase=\(phase) rev=\(revision) renders=\(renderCallbacks) scheduled=\(handoffScheduled) active=\(nativeActive) same=\(canvas?.drawing == committed) viewport=\(contact.flatMap { c in canvas.map { viewportMatches(c,$0) } } ?? false)"
    }
    var acceptsTestTouches = false
    var onPreviewForTesting: ((PKDrawing) -> Void)?
    #endif

    init(recognizer: any ShapeRecognizing = ShapeRecognizer(), holdDuration: TimeInterval = 0.55,
         scheduler: ShapeHoldScheduler? = nil) {
        self.recognizer = recognizer; self.holdDuration = holdDuration; self.clock = scheduler ?? .live
        observer.owner = self
        observer.cancelsTouchesInView = false
        observer.delaysTouchesBegan = false; observer.delaysTouchesEnded = false
        observer.requiresExclusiveTouchType = false; observer.isEnabled = false
        applicationObserver = NotificationCenter.default.addObserver(forName: UIApplication.willResignActiveNotification,
                                                                      object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.invalidate() }
        }
    }
    deinit { work?.cancel(); if let applicationObserver { NotificationCenter.default.removeObserver(applicationObserver) } }

    func attach(to canvas: PKCanvasView) {
        guard self.canvas !== canvas else { return }
        invalidate(); self.canvas?.removeGestureRecognizer(observer); self.canvas = canvas
        latestDrawing = canvas.drawing
        canvas.addGestureRecognizer(observer); observer.isEnabled = isEnabled
    }
    func invalidate(preservingSelection: Bool = false) {
        epoch &+= 1; request &+= 1; cancelDeadline?(); cancelDeadline = nil
        work?.cancel(); work = nil
        contact = nil; baseline = nil; previousStrokeCount = nil
        result = nil; committed = nil; receipt = nil
        nativeActive = false; nativeDidEnd = false; phase = .idle
        // Cancellation keeps PencilKit's original, as before. Never cancel its
        // drawing recognizer or assign drawing while a native contact is active.
        clearPreview()
        if !preservingSelection { onPreviewCancelled?() }
    }
    func nativeBegan(previousStrokeCount: Int) {
        guard isEnabled else { return }
        // A new contact is also a presentation boundary: the installed shape
        // must no longer obscure subsequent native input.
        if phase == .committing {
            // A new real contact must never remain behind the previous preview.
            // The committed drawing is already installed; keep only its repair receipt.
            clearPreview(); contact = nil; result = nil; phase = .finished
        }
        self.previousStrokeCount = previousStrokeCount
        baseline = latestDrawing
        nativeActive = true; nativeDidEnd = false
    }
    func nativeChanged(drawing: PKDrawing, revision: UInt64, isNativeNotification: Bool = true) {
        latestDrawing = drawing; self.revision = revision
        trace("drawing-changed")
        if !nativeActive, repairLateNativeDrawing(drawing) { return }
        if phase == .committing {
            if let committed, drawing != committed {
                // A fast next contact may already have committed. Its native
                // render includes our unchanged prefix: follow that content,
                // without refitting or adding the next stroke to shape identity.
                let prior = committed.strokes, strokes = drawing.strokes
                if strokes.count >= prior.count && zip(prior,strokes).allSatisfy({ InkStrokeAppearance.matches($0,$1) }) {
                    self.committed = drawing
                }
                renderedCommit = nil
            }
        }
        scheduleGate()
    }
    func nativeEnded(drawing: PKDrawing, revision: UInt64) {
        trace("native-ended")
        if phase == .committing {
            nativeChanged(drawing: drawing, revision: revision, isNativeNotification: false)
            return
        }
        latestDrawing = drawing; self.revision = revision
        nativeActive = false; nativeDidEnd = true; scheduleGate()
    }
    func inputBegan(_ sample: ShapeCompletionSample, zoom: CGFloat, offset: CGPoint) {
        guard isEnabled, shouldObserveContact?() != false else { return }
        // UIKit may deliver the observation before or after nativeBegan.
        if phase == .committing { clearPreview(); phase = .finished }
        if phase == .snapped {
            // Do not let an interrupted native finalization obscure the next
            // contact. As with tool/page cancellation, preserve native ink.
            invalidate()
        }
        epoch &+= 1; request &+= 1; work?.cancel(); work = nil
        cancelDeadline?(); cancelDeadline = nil
        result = nil; committed = nil
        if !nativeActive { baseline = nil; previousStrokeCount = nil; nativeDidEnd = false }
        contact = ShapeCompletionContact(zoom: zoom, offset: offset, holdDuration: holdDuration)
        eventClockOffset = clock.now() - sample.timestamp
        contact?.append(sample); phase = .tracking
        armDeadline()
    }
    func inputMoved(_ sample: ShapeCompletionSample) {
        if phase == .snapped {
            updateLineEndpoint(sample.documentPoint)
            return
        }
        guard phase == .tracking || phase == .recognizing else { return }
        let oldAnchorTime = contact?.lastMovement
        contact?.append(sample)
        if oldAnchorTime != contact?.lastMovement {
            request &+= 1; work?.cancel(); work = nil; phase = .tracking
            armDeadline()
        }
    }
    func inputEnded(_ sample: ShapeCompletionSample) {
        trace("touch-ended")
        if phase == .tracking || phase == .recognizing {
            // Lifting before a visible snap must never cause a delayed snap.
            let previousReceipt = receipt
            invalidate(); receipt = previousReceipt
            return
        }
        guard phase == .snapped else { return }
        updateLineEndpoint(sample.documentPoint)
        contact?.end(timestamp: sample.timestamp)
        cancelDeadline?(); cancelDeadline = nil; scheduleGate()
    }
    func inputEstimated(_ sample: ShapeCompletionSample) {
        trace("estimated")
        contact?.updateEstimate(sample)
        scheduleGate()
    }
    private func armDeadline() {
        guard let contact, !contact.ended else { return }
        let anchorTime = contact.lastMovement, token = epoch
        // Movement only updates the anchor. Keep the one pending wakeup and
        // re-arm it there if necessary, rather than allocating/cancelling a task
        // for every 2.5 screen points of ordinary handwriting.
        guard cancelDeadline == nil else { return }
        let deadline = eventClockOffset + anchorTime + contact.holdDuration
        cancelDeadline = clock.schedule(max(0, deadline - clock.now())) { [weak self] in
            guard let self, self.epoch == token else { return }
            self.cancelDeadline = nil
            guard let current = self.contact, !current.ended, self.phase == .tracking else { return }
            if self.clock.now() + 0.000001 < self.eventClockOffset + current.lastMovement + current.holdDuration {
                self.armDeadline(); return
            }
            self.recognizeHeldContact()
        }
    }
    private func recognizeHeldContact() {
        guard phase == .tracking, isEnabled, nativeActive, let contact, !contact.ended,
              contact.hasMeaningfulStroke, let canvas, let tool = canvas.tool as? PKInkingTool,
              let baseline, let previousStrokeCount, viewportMatches(contact, canvas),
              clock.now() - eventClockOffset - contact.lastMovement >= contact.holdDuration - 0.000001 else { return }
        phase = .recognizing
        let token = epoch; request &+= 1; let attempt = request
        let samples = contact.recognitionSamples
        let points = samples.map(\.documentPoint)
        let recognizer = self.recognizer
        // A held PKCanvasView may contain only committed strokes (verified by
        // the real-touch probe). Do not read/guess drawing.strokes.last here.
        let provisional = Self.provisionalStroke(samples, tool: tool)
        // The provisional source is ours, so fitting needs only this stroke.
        let source = PKDrawing(strokes: [provisional])
        let viewport = CGRect(x: canvas.bounds.minX / contact.zoom, y: canvas.bounds.minY / contact.zoom,
                              width: canvas.bounds.width / contact.zoom, height: canvas.bounds.height / contact.zoom)
        let scale = contact.zoom * (canvas.window?.screen.scale ?? UIScreen.main.scale)
        // Recognition excludes stationary jitter; Undo retains every real
        // sample received before the visible snap, excluding later editing.
        let frozenCutoff = (contact.samples.last?.timestamp ?? 0) - (contact.samples.first?.timestamp ?? 0)
        let computation = Task.detached(priority: .userInitiated) { () -> (ShapeRecognitionResult, PKDrawing)? in
            guard !Task.isCancelled, baseline.strokes.count == previousStrokeCount,
                  let recognized = recognizer.recognize(documentPoints: points) else { return nil }
            let result = recognized.kind == .line ? ShapeRecognitionResult(kind: .line, confidence: recognized.confidence,
                normalizedError: recognized.normalizedError, fittedPoints: [points.first!, points.last!]) : recognized
            guard let fitted = ShapeStrokeCompleter.replacement(source: source, baseline: PKDrawing(), result: result),
                  !Task.isCancelled, viewport.width > 0, viewport.height > 0 else { return nil }
            return (result, PKDrawing(strokes: baseline.strokes + fitted.strokes))
        }
        work = Task { [weak self, weak canvas] in
            let output = await withTaskCancellationHandler(operation: { await computation.value },
                                                          onCancel: { computation.cancel() })
            guard let self, self.epoch == token, self.request == attempt else { return }
            self.work = nil
            guard let (result, fitted) = output, let canvas, self.canvas === canvas,
                  let container = canvas.superview,
                  self.phase == .recognizing, self.nativeActive, self.isEnabled,
                  self.contact?.ended == false, self.viewportMatches(contact, canvas) else {
                if self.phase == .recognizing { self.phase = .tracking }
                return
            }
            // Pure fitting runs off-thread. PKDrawing rasterization shares the
            // native canvas renderer and the main-actor interaction raster cache.
            var image: UIImage!, backgroundInk: UIImage!
            DrawingEngineMetrics.measure(.shapeRaster) {
                UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
                    image = PKDrawing(strokes: [fitted.strokes[previousStrokeCount]]).image(from: viewport, scale: scale)
                    backgroundInk = baseline.image(from: viewport, scale: scale)
                }
            }
            // Keep PencilKit visible/renderable underneath an opaque composition
            // of the EXISTING cached paper, committed ink and current shape. No
            // private native layers, parent opacity changes, or white ink cover.
            let preview = ShapeHeldPreview(frame: canvas.frame)
            preview.backgroundColor = container.backgroundColor?.resolvedColor(with: container.traitCollection)
            (container as? CanvasHostView)?.copyShapePreviewBackground(to: preview.layer)
            preview.install(backgroundInk: backgroundInk, shape: image)
            CATransaction.begin(); CATransaction.setDisableActions(true)
            container.insertSubview(preview, aboveSubview: canvas)
            CATransaction.commit()
            self.preview = preview; self.result = result; self.cutoff = frozenCutoff; self.phase = .snapped
            self.lineTemplate = Self.provisionalStroke([contact.samples.first!, contact.samples.last!], tool: tool)
            if result.kind != .line { self.onClosedShapePreview?(result) }
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--shape-diagnostics") {
                print("Shape session=\(token) preview=success kind=\(result.kind.rawValue) paper=\(container is CanvasHostView)")
            }
            self.onPreviewForTesting?(fitted)
            #endif
        }
    }
    private func updateLineEndpoint(_ point: CGPoint) {
        guard phase == .snapped, let result, result.kind == .line,
              let endpoint = ShapeEditMath.lineEndpoint(pointer: point), let start = result.fittedPoints.first,
              var stroke = lineTemplate, let canvas, let preview else { return }
        self.result = ShapeRecognitionResult(kind: .line, confidence: result.confidence,
            normalizedError: result.normalizedError, fittedPoints: [start, endpoint])
        let points = Array(stroke.path)
        guard points.count == 2 else { return }
        stroke.path = PKStrokePath(controlPoints: [ShapeStrokeCompleter.relocate(points[0], to: start, time: 0),
            ShapeStrokeCompleter.relocate(points[1], to: endpoint, time: points[1].timeOffset)], creationDate: stroke.path.creationDate)
        // Only the two-point object is rasterized; cached paper and all other ink
        // are retained. No refit, input-history scan, drawing assignment or Undo.
        preview.showShape(PKDrawing(strokes: [stroke]), canvas: canvas)
    }

    private func viewportMatches(_ contact: ShapeCompletionContact, _ canvas: PKCanvasView) -> Bool {
        !canvas.isZooming && !canvas.isDragging && canvas.zoomScale == contact.zoom && canvas.contentOffset == contact.offset
    }
    private static func provisionalStroke(_ samples: [ShapeCompletionSample], tool: PKInkingTool) -> PKStroke {
        let start = samples.first?.timestamp ?? 0
        let points = samples.map {
            PKStrokePoint(location: $0.documentPoint, timeOffset: $0.timestamp - start,
                          size: CGSize(width: tool.width, height: tool.width), opacity: 1,
                          force: $0.force, azimuth: $0.azimuth, altitude: $0.altitude)
        }
        return PKStroke(ink: tool.ink, path: PKStrokePath(controlPoints: points, creationDate: Date()))
    }
    fileprivate func sample(_ touch: UITouch) -> ShapeCompletionSample? {
        guard let canvas, let contact, viewportMatches(contact, canvas) else { return nil }
        return Self.sample(touch, canvas: canvas)
    }
    fileprivate func began(_ touch: UITouch) {
        guard let canvas, isEnabled, !canvas.isZooming, !canvas.isDragging,
              let sample = Self.sample(touch, canvas: canvas) else { return }
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--shape-diagnostics") {
            print("Shape input policy=\(canvas.drawingPolicy.rawValue) drawingEnabled=\(canvas.drawingGestureRecognizer.isEnabled) panTouches=\(canvas.panGestureRecognizer.minimumNumberOfTouches) offset=\(canvas.contentOffset)")
        }
        #endif
        inputBegan(sample, zoom: canvas.zoomScale, offset: canvas.contentOffset)
    }
    private static func sample(_ touch: UITouch, canvas: PKCanvasView) -> ShapeCompletionSample? {
        guard canvas.zoomScale.isFinite, canvas.zoomScale > 0 else { return nil }
        return ShapeCompletionSample(documentPoint: documentPoint(canvasLocation: touch.location(in: canvas), zoom: canvas.zoomScale),
                                     timestamp: touch.timestamp, estimationIndex: touch.estimationUpdateIndex?.intValue,
                                     expectingUpdates: UInt(bitPattern: touch.estimatedPropertiesExpectingUpdates.rawValue),
                                     force: touch.force, altitude: touch.altitudeAngle, azimuth: touch.azimuthAngle(in: canvas))
    }
    static func documentPoint(canvasLocation: CGPoint, zoom: CGFloat) -> CGPoint {
        CGPoint(x: canvasLocation.x / zoom, y: canvasLocation.y / zoom)
    }
    private func scheduleGate() {
        guard !gateScheduled else { return }
        gateScheduled = true
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.gateScheduled = false; self.finalizeIfReady()
        }
    }
    private func finalizeIfReady() {
        guard phase == .snapped, nativeDidEnd, !nativeActive, let contact, contact.ended,
              !contact.ambiguous,
              let canvas, let source = latestDrawing, canvas.drawing == source,
              let baseline, let result,
              let pair = ShapeStrokeCompleter.heldReplacement(source: source, baseline: baseline, result: result, cutoff: cutoff) else { return }
        // Lift is a commit boundary, not a promise about estimate callback order.
        // Use the current native attributes; repair later estimates by stroke identity.
        // Waiting for another revision after the last estimate can wait forever.
        preview?.showShape(PKDrawing(strokes: [pair.completed.strokes[baseline.strokes.count]]), canvas: canvas)
        phase = .committing; committed = pair.completed
        handoffScheduled = false
        receipt = Receipt(baseline: baseline, original: source.strokes.last!, result: result, cutoff: cutoff, completed: pair.completed)
        let accepted = onCompletion?(source, pair.original, pair.completed, result) == true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--shape-diagnostics") {
            print("Shape session=\(epoch) commit=\(accepted) kind=\(result.kind.rawValue)")
        }
        #endif
        if !accepted { invalidate() }
        else if result.kind != .line {
            // The old contact has ended and the model is installed. Arm our
            // existing selection for the NEXT contact now, while the same shape
            // preview stays visible until native presentation is ready.
            let ids = Set(pair.completed.strokes.dropFirst(baseline.strokes.count).map(InkStrokeID.init))
            onClosedShapeReady?(result, ids)
        }
    }
    // Only a matching native stroke from this contact may be repaired, never an
    // unrelated page/edit. Repair is not a second shape operation or undo item.
    private func repairLateNativeDrawing(_ drawing: PKDrawing) -> Bool {
        guard let receipt, let canvas, phase != .snapped, phase != .recognizing, phase != .tracking else { return false }
        let index = receipt.baseline.strokes.count, strokes = drawing.strokes
        guard strokes.count > index, let expected = receipt.completed.strokes.last,
              !InkStrokeAppearance.matches(strokes[index], expected),
              strokes[index].path.creationDate == receipt.original.path.creationDate,
              strokes[index].randomSeed == receipt.original.randomSeed,
              let pair = ShapeStrokeCompleter.heldReplacement(source: PKDrawing(strokes: Array(strokes.prefix(index + 1))),
                  baseline: receipt.baseline, result: receipt.result, cutoff: receipt.cutoff) else { return false }
        let fixed = PKDrawing(strokes: pair.completed.strokes + strokes.dropFirst(index + 1))
        guard canvas.drawing == drawing else { return false }
        self.receipt?.completed = pair.completed; committed = fixed; latestDrawing = fixed
        onRepair?(drawing, fixed)
        return true
    }
    func nativeFinishedRendering() {
        trace("rendered")
        #if DEBUG
        if phase == .committing { renderCallbacks += 1 }
        #endif
        guard phase == .committing, let committed, let canvas,
              canvas.drawing == committed,
              let contact, viewportMatches(contact, canvas), !nativeActive else { return }
        renderedCommit = committed
        schedulePresentationHandoff()
    }
    private func schedulePresentationHandoff() {
        guard phase == .committing, !handoffScheduled, let committed, renderedCommit == committed,
              let canvas, canvas.drawing == committed, let contact, viewportMatches(contact,canvas),
              !nativeActive else { return }
        // didFinishRendering acknowledges native presentation. A drawing setter
        // is not documented to emit a separate drawingDidChange echo.
        let token = epoch, handoffRevision = revision
        handoffScheduled = true
        // The delegate says the matching native ink is rendered; wait for that
        // Core Animation transaction to present, not an arbitrary millisecond delay.
        CATransaction.begin()
        CATransaction.setCompletionBlock { [weak self, weak canvas] in
            MainActor.assumeIsolated {
                guard let self, let canvas, self.canvas === canvas, self.epoch == token else { return }
                self.handoffScheduled = false
                guard self.phase == .committing, self.revision == handoffRevision, canvas.drawing == committed,
                      !self.nativeActive, self.viewportMatches(contact, canvas) else {
                    // A newer genuine render callback may have arrived while
                    // this transaction was pending. Drain that recorded content,
                    // never invent a render acknowledgement or poll each frame.
                    self.schedulePresentationHandoff(); return
                }
                self.phase = .finished
                self.clearPreview(); self.contact = nil; self.result = nil
            }
        }
        CATransaction.commit()
    }
    private func trace(_ event: String) {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--shape-diagnostics") {
            print("Shape event=\(event) session=\(epoch) phase=\(phase) revision=\(revision) active=\(nativeActive) pending=\(contact?.pending.count ?? 0)")
        }
        #endif
    }
    private func clearPreview() {
        handoffScheduled = false; renderedCommit = nil; lineTemplate = nil
        guard preview != nil else { return }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        preview?.removeFromSuperview(); preview = nil
        CATransaction.commit()
    }

}

/// Observes real Pencil samples without preventing, delaying, cancelling, or
/// replacing PencilKit's own native drawing recognizer/rendering.
@MainActor
final class ShapeCompletionGestureRecognizer: UIGestureRecognizer {
    weak var owner: ShapeCompletionController?
    private weak var pencil: UITouch?
    private func accepts(_ touch: UITouch) -> Bool {
        guard owner?.shouldObserveContact?() != false else { return false }
        #if DEBUG
        if owner?.acceptsTestTouches == true { return true }
        #endif
        return touch.type == .pencil
    }
    override func canPrevent(_ preventedGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func canBePrevented(by preventingGestureRecognizer: UIGestureRecognizer) -> Bool { false }
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        if owner?.shouldObserveContact?() == false {
            for touch in touches { ignore(touch, for: event) }
            state = .failed; return
        }
        guard pencil == nil, touches.count == 1, let touch = touches.first, accepts(touch) else {
            owner?.invalidate()
            for touch in touches { ignore(touch, for: event) }
            return
        }
        pencil = touch
        let coalesced = event.coalescedTouches(for: touch) ?? [touch]
        owner?.began(coalesced.first ?? touch)
        // Track any coalesced real samples accompanying the initial contact.
        for sample in coalesced {
            if let value = owner?.sample(sample) { owner?.inputMoved(value) }
        }
        state = .began
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let pencil, touches.contains(pencil) else { return }
        let actual = event.coalescedTouches(for: pencil) ?? [pencil]
        // Endpoint editing only needs the newest actual point in this delivery.
        // Ordinary handwriting still observes all coalesced samples unchanged.
        let delivered = owner?.phase == .snapped ? [actual.last ?? pencil] : actual
        for sample in delivered {
            guard let value = owner?.sample(sample) else { owner?.invalidate(); return }
            owner?.inputMoved(value)
        }
        state = .changed
    }
    override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let pencil, touches.contains(pencil) else { return }
        for sample in event.coalescedTouches(for: pencil) ?? [] {
            if let value = owner?.sample(sample) { owner?.inputMoved(value) }
        }
        if let sample = owner?.sample(pencil) { owner?.inputEnded(sample) } else { owner?.invalidate() }
        state = .ended
    }
    override func touchesEstimatedPropertiesUpdated(_ touches: Set<UITouch>) {
        // Intentionally independent of `pencil`: UIKit may reset this recognizer
        // before the last force/location/tilt estimates arrive.
        for touch in touches {
            if let sample = owner?.sample(touch) { owner?.inputEstimated(sample) }
        }
    }
    override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent) {
        guard let pencil, touches.contains(pencil) else { return }
        owner?.invalidate(); state = .cancelled
    }
    override func reset() { super.reset(); pencil = nil }
}

enum ShapeStrokeCompleter {
    /// Freeze the native freehand prefix at the visible snap. A later movement
    /// in the same contact cannot create a tail in the stored stroke or in Undo.
    static func heldReplacement(source: PKDrawing, baseline: PKDrawing, result: ShapeRecognitionResult,
                                cutoff: TimeInterval) -> (original: PKDrawing, completed: PKDrawing)? {
        guard cutoff.isFinite, cutoff >= 0, source.strokes.count == baseline.strokes.count + 1,
              var stroke = source.strokes.last else { return nil }
        let originalPoints = Array(stroke.path)
        let points = originalPoints.filter { $0.timeOffset <= cutoff + 0.000001 }
        guard points.count >= 2 else { return nil }
        if points.count != originalPoints.count {
            stroke.path = PKStrokePath(controlPoints: points, creationDate: stroke.path.creationDate)
        }
        let original = PKDrawing(strokes: Array(source.strokes.dropLast()) + [stroke])
        guard let completed = replacement(source: original, baseline: baseline, result: result) else { return nil }
        return (original, completed)
    }
    /// Preserve the original point attributes and stroke identity/ink/seed. Only
    /// point positions change; a few repeated corner points keep boxes sharp in
    /// PencilKit's B-spline. No unrelated stroke is reconstructed.
    static func replacement(source: PKDrawing, baseline: PKDrawing, result: ShapeRecognitionResult) -> PKDrawing? {
        let strokes = source.strokes
        let prior = baseline.strokes
        guard strokes.count == prior.count + 1,
              zip(strokes.dropLast(), prior).allSatisfy({ InkStrokeAppearance.matches($0, $1) }),
              let original = strokes.last, original.mask == nil, original.path.count >= 2,
              result.fittedPoints.count >= 2, result.fittedPoints.count <= 65 else { return nil }
        let transform = original.transform
        let determinant = transform.a * transform.d - transform.b * transform.c
        guard determinant.isFinite, abs(determinant) > 1e-9 else { return nil }
        let inverse = transform.inverted(), originals = Array(original.path)
        let locations = originals.map { $0.location.applying(transform) }
        let originalDistances = cumulative(locations), fittedDistances = cumulative(result.fittedPoints)
        guard let sourceLength = originalDistances.last, sourceLength > 0,
              let fittedLength = fittedDistances.last, fittedLength.isFinite, fittedLength >= 0 else { return nil }
        let fractions = originalDistances.map { $0 / sourceLength }
        var cornerFractions: [CGFloat] = []
        if result.kind == .rectangle || result.kind == .triangle {
            cornerFractions = fittedDistances.dropFirst().dropLast().map { $0 / fittedLength }
        }
        var mapped = [PKStrokePoint](); mapped.reserveCapacity(originals.count + cornerFractions.count * 3)
        var cornerIndex = 0, fittedIndex = 1
        func point(at fraction: CGFloat) -> CGPoint {
            let distance = fraction * fittedLength
            while fittedIndex < fittedDistances.count - 1 && fittedDistances[fittedIndex] < distance { fittedIndex += 1 }
            let low = fittedDistances[fittedIndex - 1], high = fittedDistances[fittedIndex]
            let t = high > low ? (distance - low) / (high - low) : 0
            let a = result.fittedPoints[fittedIndex - 1], b = result.fittedPoints[fittedIndex]
            return CGPoint(x: a.x + (b.x - a.x) * t, y: a.y + (b.y - a.y) * t).applying(inverse)
        }
        for i in originals.indices {
            while cornerIndex < cornerFractions.count && cornerFractions[cornerIndex] <= fractions[i] {
                let fraction = cornerFractions[cornerIndex], location = point(at: fraction)
                let lower = max(0, i - 1), denominator = fractions[i] - fractions[lower]
                let t = denominator > 0 ? (fraction - fractions[lower]) / denominator : 0
                let time = originals[lower].timeOffset + Double(t) * (originals[i].timeOffset - originals[lower].timeOffset)
                for _ in 0..<3 { mapped.append(relocate(originals[i], to: location, time: time)) }
                cornerIndex += 1
            }
            mapped.append(relocate(originals[i], to: point(at: fractions[i]), time: originals[i].timeOffset))
        }
        var replacement = original
        replacement.path = PKStrokePath(controlPoints: mapped, creationDate: original.path.creationDate)
        var completed = strokes; completed[completed.count - 1] = replacement
        return PKDrawing(strokes: completed)
    }
    private static func cumulative(_ points: [CGPoint]) -> [CGFloat] {
        var values: [CGFloat] = [0]; values.reserveCapacity(points.count)
        for (a, b) in zip(points, points.dropFirst()) { values.append(values.last! + hypot(b.x - a.x, b.y - a.y)) }
        return values
    }
    static func relocate(_ source: PKStrokePoint, to location: CGPoint, time: TimeInterval) -> PKStrokePoint {
        if #available(iOS 27.0, *) {
            return PKStrokePoint(location: location, timeOffset: time, size: source.size, opacity: source.opacity,
                                 force: source.force, azimuth: source.azimuth, altitude: source.altitude,
                                 secondaryScale: source.secondaryScale, threshold: source.threshold, lateralJitter: source.lateralJitter)
        }
        if #available(iOS 26.0, *) {
            return PKStrokePoint(location: location, timeOffset: time, size: source.size, opacity: source.opacity,
                                 force: source.force, azimuth: source.azimuth, altitude: source.altitude,
                                 secondaryScale: source.secondaryScale, threshold: source.threshold)
        }
        return PKStrokePoint(location: location, timeOffset: time, size: source.size, opacity: source.opacity,
                             force: source.force, azimuth: source.azimuth, altitude: source.altitude, secondaryScale: source.secondaryScale)
    }
}

/// One composition owns replacement visibility until the native render handoff.
/// Paper/committed-ink images never change during endpoint editing.
@MainActor
private final class ShapeHeldPreview: UIView {
    private let shape = UIImageView()
    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false; isOpaque = true; clipsToBounds = true
        accessibilityIdentifier = "shape-held-preview"
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    func install(backgroundInk: UIImage, shape image: UIImage) {
        let background = UIImageView(image: backgroundInk)
        background.frame = bounds; addSubview(background)
        shape.frame = bounds; shape.image = image; addSubview(shape)
    }
    func showShape(_ drawing: PKDrawing, canvas: PKCanvasView) {
        let zoom = canvas.zoomScale
        let viewport = CGRect(x: canvas.bounds.minX/zoom, y: canvas.bounds.minY/zoom,
                              width: canvas.bounds.width/zoom, height: canvas.bounds.height/zoom)
        let crop = drawing.bounds.insetBy(dx: -2/zoom, dy: -2/zoom).intersection(viewport)
        guard !crop.isNull, crop.width > 0, crop.height > 0 else { shape.image = nil; return }
        var image: UIImage?
        UITraitCollection(userInterfaceStyle: .light).performAsCurrent {
            image = drawing.image(from: crop, scale: zoom * (canvas.window?.screen.scale ?? UIScreen.main.scale))
        }
        CATransaction.begin(); CATransaction.setDisableActions(true)
        shape.image = image
        shape.frame = CGRect(x: (crop.minX-viewport.minX)*zoom, y: (crop.minY-viewport.minY)*zoom,
                             width: crop.width*zoom, height: crop.height*zoom)
        CATransaction.commit()
    }
}

extension InkStrokeID {
    init(_ stroke: PKStroke) { self.init(creationDate: stroke.path.creationDate, randomSeed: stroke.randomSeed) }
}
