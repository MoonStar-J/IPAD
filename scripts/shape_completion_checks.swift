import UIKit
import PencilKit

/// Synthetic lifecycle checks in the isolated integration app, not Pencil latency measurements.
@MainActor @discardableResult func checkShapeCompletion() async throws -> Int {
    var checks = 0
    func check(_ value: @autoclosure () throws -> Bool, _ message: String) throws {
        checks += 1
        if try !value() { throw NSError(domain: "shape completion: " + message, code: 1) }
    }
    func sample(_ i: Int, pending: Bool = false) -> ShapeCompletionSample {
        ShapeCompletionSample(documentPoint: CGPoint(x: 20 + Double(i) * 2, y: 40 + sin(Double(i) * 0.15) * 0.2),
                              timestamp: Double(i) * 0.01, estimationIndex: i, expectingUpdates: pending ? 1 : 0)
    }
    let samples = (0..<60).map { sample($0) }
    var ended = samples.last!; ended.timestamp = 1.4; ended.estimationIndex = 99
    func stroke(offset: CGPoint = .zero) -> PKStroke {
        let points = samples.enumerated().map { i, sample in
            PKStrokePoint(location: sample.documentPoint, timeOffset: sample.timestamp,
                          size: CGSize(width: 2 + Double(i) * 0.03, height: 3 + Double(i) * 0.02),
                          opacity: 0.9 + Double(i) * 0.008, force: 0.2 + Double(i) * 0.01,
                          azimuth: Double(i) * 0.03, altitude: 0.7 + Double(i) * 0.002,
                          secondaryScale: 0.5 + Double(i) * 0.004)
        }
        return PKStroke(ink: PKInk(.pencil, color: .darkGray),
                        path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 1_500)),
                        transform: CGAffineTransform(translationX: offset.x, y: offset.y), randomSeed: 12_345)
    }
    let existing = stroke(offset: CGPoint(x: 300, y: 600))
    let baseline = PKDrawing(strokes: [existing])
    let source = PKDrawing(strokes: [existing, stroke()])
    let originalBytes = source.dataRepresentation()
    let recognized = ShapeRecognizer().recognize(documentPoints: samples.map(\.documentPoint))!
    guard let replacement = ShapeStrokeCompleter.replacement(source: source, baseline: baseline, result: recognized) else {
        throw NSError(domain: "shape completion: an existing-note prefix permits replacement", code: 1)
    }
    try check(source.dataRepresentation() == originalBytes, "canonical original remains unchanged")
    try check(replacement.strokes.count == 2 && InkStrokeAppearance.matches(replacement.strokes[0], existing), "unrelated prefix ink is preserved")
    let original = source.strokes.last!, fitted = replacement.strokes.last!
    try check(fitted.path.count == original.path.count && fitted.randomSeed == original.randomSeed &&
              fitted.transform == original.transform && fitted.ink.inkType == original.ink.inkType,
              "replacement retains original sampling count brush transform and random seed")
    // PKStrokePoint's public constructor re-quantizes packed aspect ratio and
    // azimuth. Use an identity-position reconstruction as the native control,
    // then require the actual fitted output to preserve that control exactly.
    // This distinguishes SDK encoding loss from dropped app pressure/tilt data.
    let identityPoints = original.path.map { point in
        PKStrokePoint(location: point.location, timeOffset: point.timeOffset, size: point.size,
                      opacity: point.opacity, force: point.force, azimuth: point.azimuth,
                      altitude: point.altitude, secondaryScale: point.secondaryScale)
    }
    let identityPath = PKStrokePath(controlPoints: identityPoints, creationDate: original.path.creationDate)
    var attributeDifferences = Array(repeating: 0.0, count: 8)
    for (a, b) in zip(original.path, fitted.path) {
        let differences = [abs(a.size.width - b.size.width), abs(a.size.height - b.size.height),
                           abs(a.force - b.force), abs(a.opacity - b.opacity), abs(a.azimuth - b.azimuth),
                           abs(a.altitude - b.altitude), abs(a.timeOffset - b.timeOffset),
                           abs(a.secondaryScale - b.secondaryScale)]
        for i in differences.indices { attributeDifferences[i] = max(attributeDifferences[i], differences[i]) }
    }
    let attributeNames = ["width", "height", "force", "opacity", "azimuth", "altitude", "time", "secondaryScale"]
    let attributeDiagnostic = zip(attributeNames, attributeDifferences).map { "\($0)=\($1)" }.joined(separator: ",")
    try check(attributeDifferences[1] < 0.005 && attributeDifferences[4] < 0.0001 &&
              [0, 2, 3, 5, 6, 7].allSatisfy { attributeDifferences[$0] == 0 },
              "fixture differences stay within the measured native encoding step: \(attributeDiagnostic)")
    for (index, pair) in zip(identityPath, fitted.path).enumerated() {
        let (a, b) = pair
        try check(a.size == b.size && a.force == b.force && a.opacity == b.opacity &&
                  a.azimuth == b.azimuth && a.altitude == b.altitude && a.timeOffset == b.timeOffset &&
                  a.secondaryScale == b.secondaryScale,
                  "pressure/tilt attributes exactly match the native identity reconstruction; index=\(index)")
    }
    let deepOriginal = stroke(offset: CGPoint(x: 400, y: 70_000))
    let deepSource = PKDrawing(strokes: [existing, deepOriginal])
    let deepResult = ShapeRecognizer().recognize(documentPoints: samples.map { $0.documentPoint.applying(deepOriginal.transform) })!
    let deepCompleted = ShapeStrokeCompleter.replacement(source: deepSource, baseline: baseline, result: deepResult)!
    try check(deepCompleted.strokes.last!.transform == deepOriginal.transform, "deep source retains its transform")
    for (a, b) in zip(fitted.path, deepCompleted.strokes.last!.path) {
        try check(hypot(a.location.x - b.location.x, a.location.y - b.location.y) < 0.01,
                  "document-space fit converts back to source local coordinates")
    }
    let changedPrefix = PKDrawing(strokes: [stroke(offset: CGPoint(x: 301, y: 600)), stroke()])
    try check(ShapeStrokeCompleter.replacement(source: changedPrefix, baseline: baseline, result: recognized) == nil,
              "an edited preceding stroke invalidates the candidate")
    let multiple = PKDrawing(strokes: [existing, stroke(), stroke(offset: CGPoint(x: 1, y: 1))])
    try check(ShapeStrokeCompleter.replacement(source: multiple, baseline: baseline, result: recognized) == nil,
              "multiple appended strokes cannot be mistaken for one held stroke")
    var masked = stroke(); masked.mask = UIBezierPath(rect: CGRect(x: 0, y: 0, width: 500, height: 500))
    try check(ShapeStrokeCompleter.replacement(source: PKDrawing(strokes: [existing, masked]), baseline: baseline, result: recognized) == nil,
              "masked or ruler-edited ink is left intact")

    for zoom in [CGFloat(0.5), 1, 4] {
        for offset in [CGPoint.zero, CGPoint(x: 350, y: 70_000)] {
            let document = CGPoint(x: 750, y: 70_500)
            let viewport = CGPoint(x: document.x * zoom - offset.x, y: document.y * zoom - offset.y)
            let canvasLocation = CGPoint(x: viewport.x + offset.x, y: viewport.y + offset.y)
            try check(ShapeCompletionController.documentPoint(canvasLocation: canvasLocation, zoom: zoom) == document,
                      "touch conversion does not add scroll offset twice at zoom \(zoom)")
        }
    }
    var contact = ShapeCompletionContact(zoom: 1, offset: .zero)
    for i in samples.indices { contact.append(sample(i, pending: i == 8 || i == 30)) }
    contact.append(ended); contact.end(timestamp: ended.timestamp)
    try check(!contact.ready && contact.pending == [8, 30], "all coalesced estimates gate completion after lift")
    contact.updateEstimate(sample(8))
    try check(!contact.ready && contact.pending == [30], "one resolved estimate cannot release the stroke")
    contact.updateEstimate(sample(30))
    try check(contact.ready, "hold and lift complete after every expected estimate is finalized")
    var shortHold = ShapeCompletionContact(zoom: 1, offset: .zero)
    for sample in samples { shortHold.append(sample) }
    shortHold.end(timestamp: 0.8)
    try check(!shortHold.ready, "normal fast handwriting does not trigger completion")
    var longerHold = ShapeCompletionContact(zoom: 1, offset: .zero, holdDuration: 1.2)
    for sample in samples { longerHold.append(sample) }
    longerHold.end(timestamp: 1.4)
    try check(!longerHold.ready && longerHold.holdDuration == 1.2, "internal hold duration is configurable without a UI change")
    var missingIndex = ShapeCompletionContact(zoom: 1, offset: .zero)
    var unknown = sample(0, pending: true); unknown.estimationIndex = nil
    missingIndex.append(unknown)
    for sample in samples.dropFirst() { missingIndex.append(sample) }
    missingIndex.end(timestamp: 2)
    try check(!missingIndex.ready, "untrackable estimates conservatively keep native ink")

    func settle(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() && ProcessInfo.processInfo.systemUptime < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        return predicate()
    }
    // Manual monotonic scheduler: no sleeps are used to cross the hold deadline.
    for nativeFirst in [false, true] {
        let clock = ShapeManualClock()
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 600)); canvas.drawing = baseline
        let owner = UIView(frame: canvas.frame); owner.addSubview(canvas)
        let controller = ShapeCompletionController(scheduler: clock.scheduler)
        controller.attach(to: canvas); controller.isEnabled = true
        var count = 0, previews = 0
        controller.onPreviewForTesting = { _ in previews += 1 }
        controller.onCompletion = { before, original, after, _ in
            count += 1; canvas.drawing = after
            return before == source && original.strokes.count == 2 && after.strokes.count == 2
        }
        if nativeFirst { controller.nativeBegan(previousStrokeCount: 1) }
        controller.inputBegan(sample(0), zoom: 1, offset: .zero)
        if !nativeFirst { controller.nativeBegan(previousStrokeCount: 1) }
        for value in samples.dropFirst() { clock.time = value.timestamp; controller.inputMoved(value) }
        try check(clock.scheduledCount == 1, "normal movement does not allocate a timer per sample")
        clock.advance(to: 1.129)
        await Task.yield()
        try check(previews == 0, "0.55 seconds is measured from the latest pause anchor, not touch down")
        clock.advance(to: 1.131) // No move or lift event after the last sample.
        let shown = await settle { previews == 1 }
        try check(shown && controller.phase == .snapped && canvas.layer.opacity == 1,
                  "native/observer begin order \(nativeFirst): snap is visible before lift without another event")
        try check(canvas.drawing == baseline && count == 0, "held preview never assigns native drawing or registers undo")
        var tail = ended; tail.documentPoint = CGPoint(x: 900, y: 900)
        controller.inputMoved(tail); clock.advance(to: 5)
        try check(previews == 1 && count == 0, "same contact cannot resnap or expose a tail")
        controller.inputEnded(ended)
        canvas.drawing = source
        controller.nativeChanged(drawing: source, revision: 1)
        controller.nativeEnded(drawing: source, revision: 1)
        let completed = await settle { count == 1 }
        try check(completed, "one existing replacement operation after native end")
        controller.nativeFinishedRendering()
        try check(controller.phase == .committing, "render handoff completes at the presentation transaction boundary")
        controller.nativeChanged(drawing: canvas.drawing, revision: 3)
        // PKCanvasView may echo synchronously inside its setter, before the
        // session records the same value for persistence. That is not new ink.
        controller.nativeChanged(drawing: canvas.drawing, revision: 4, isNativeNotification: false)
        if nativeFirst {
            // Begin the next native contact before the previous render handoff.
            // It must not steal/reset the old session or get hidden forever.
            controller.inputBegan(sample(0),zoom:1,offset:.zero)
            controller.nativeBegan(previousStrokeCount:2)
            let next=stroke(offset:CGPoint(x:0,y:100))
            canvas.drawing=PKDrawing(strokes:canvas.drawing.strokes+[next])
            controller.nativeChanged(drawing:canvas.drawing,revision:5)
            controller.inputEnded(ended)
            controller.nativeEnded(drawing:canvas.drawing,revision:5)
            controller.nativeChanged(drawing:canvas.drawing,revision:6)
        }
        controller.nativeFinishedRendering()
        _ = await settle { controller.phase == .finished }
        try check(count == 1 && canvas.layer.opacity == 1 && (controller.phase == .finished || (nativeFirst && controller.phase == .idle)), "one handoff and no double commit")
        try check(canvas.drawing.strokes.count == (nativeFirst ? 3:2), "fast next contact remains native ink, not part of previous shape")
        withExtendedLifetime(owner) {}
    }
    for cancel in ["lift", "move", "tool", "page", "cancel", "inactive"] {
        let clock = ShapeManualClock()
        let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 600)); canvas.drawing = baseline
        let controller = ShapeCompletionController(scheduler: clock.scheduler)
        controller.attach(to: canvas); controller.isEnabled = true
        var previews = 0
        controller.onPreviewForTesting = { _ in previews += 1 }
        controller.inputBegan(sample(0), zoom: 1, offset: .zero); controller.nativeBegan(previousStrokeCount: 1)
        for value in samples.dropFirst() { clock.time = value.timestamp; controller.inputMoved(value) }
        clock.time = 1.1
        switch cancel {
        case "lift": controller.inputEnded(ended)
        case "move": var moved = ended; moved.timestamp = 1.1; moved.documentPoint.x += 30; controller.inputMoved(moved)
        case "tool": controller.isEnabled = false
        case "page": controller.attach(to: PKCanvasView())
        case "inactive": NotificationCenter.default.post(name: UIApplication.willResignActiveNotification, object: nil)
        default: controller.invalidate()
        }
        clock.advance(to: 1.3, includingCancelled: true)
        try? await Task.sleep(for: .milliseconds(15))
        try check(previews == 0, "\(cancel) rejects even an already-enqueued stale timer")
    }
    // Jitter is measured against the pause anchor, not against each preceding sample.
    for zoom in [CGFloat(0.5), 1, 4] {
        var held = ShapeCompletionContact(zoom: zoom, offset: .zero)
        for value in samples { var point = value; point.documentPoint.x /= zoom; point.documentPoint.y /= zoom; held.append(point) }
        let anchorTime = held.lastMovement, last = held.samples.last!
        for i in 1...40 {
            var point = last; point.estimationIndex = 1_000 + i; point.timestamp += Double(i) * 0.01
            point.documentPoint.x += sin(Double(i)) * 0.2 / zoom
            held.append(point)
        }
        try check(held.lastMovement == anchorTime, "micro jitter does not reset the deadline at zoom \(zoom)")
        for i in 1...40 {
            var point = last; point.estimationIndex = 2_000 + i; point.timestamp += 0.5 + Double(i) * 0.01
            point.documentPoint.x += Double(i) * 0.2 / zoom
            held.append(point)
        }
        try check(held.lastMovement > anchorTime + 0.5, "slow cumulative movement resets the anchor at zoom \(zoom)")
    }
    let gate = ShapeCompletionBlockingRecognizer(), clock = ShapeManualClock()
    let staleCanvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 600)); staleCanvas.drawing = baseline
    let staleController = ShapeCompletionController(recognizer: gate, scheduler: clock.scheduler)
    staleController.attach(to: staleCanvas); staleController.isEnabled = true
    var staleCount = 0
    staleController.onPreviewForTesting = { _ in staleCount += 1 }
    staleController.inputBegan(sample(0), zoom: 1, offset: .zero); staleController.nativeBegan(previousStrokeCount: 1)
    for value in samples.dropFirst() { clock.time = value.timestamp; staleController.inputMoved(value) }
    clock.advance(to: 1.3)
    let started = await settle { gate.started }
    staleController.invalidate(); gate.release()
    try check(started, "fitting actually began before invalidation")
    try? await Task.sleep(for: .milliseconds(20))
    try check(staleCount == 0 && staleCanvas.drawing == baseline, "stale worker cannot overwrite later input")

    // All existing fitted primitives cross the timer boundary while contact stays down.
    for kind in [ShapeKind.line, .circle, .ellipse, .triangle, .rectangle] {
        for zoom in [CGFloat(0.5), 2] {
            let clock = ShapeManualClock()
            let canvas = PKCanvasView(frame: CGRect(x: 0, y: 0, width: 500, height: 600))
            canvas.minimumZoomScale = 0.1; canvas.maximumZoomScale = 5; canvas.zoomScale = zoom
            let owner = UIView(frame: canvas.frame); owner.addSubview(canvas)
            let controller = ShapeCompletionController(scheduler: clock.scheduler)
            controller.attach(to: canvas); controller.isEnabled = true
            var points: [CGPoint] = []
            for i in 0...120 {
                let t = Double(i) / 120, angle = t * 2 * Double.pi
                switch kind {
                case .line: points.append(CGPoint(x: 100 + 180 * t, y: 150 + 0.2 * sin(t * 10)))
                case .circle: points.append(CGPoint(x: 180 + 65 * cos(angle), y: 200 + 65 * sin(angle)))
                case .ellipse: points.append(CGPoint(x: 180 + 95 * cos(angle), y: 200 + 50 * sin(angle)))
                case .triangle:
                    let vertices = [CGPoint(x: 80,y: 280),CGPoint(x: 170,y: 110),CGPoint(x: 300,y: 280),CGPoint(x: 80,y: 280)]
                    let edge = min(2, i / 40), f = Double(i - edge * 40) / 40
                    let a = vertices[edge], b = vertices[edge + 1]
                    points.append(CGPoint(x: a.x + (b.x-a.x)*f, y: a.y+(b.y-a.y)*f))
                case .rectangle:
                    let corners = [CGPoint(x: 80,y: 120),CGPoint(x: 280,y: 120),CGPoint(x: 280,y: 280),CGPoint(x: 80,y: 280),CGPoint(x: 80,y: 120)]
                    let edge = min(3, i / 30), f = Double(i - edge * 30) / 30
                    let a = corners[edge], b = corners[edge + 1]
                    points.append(CGPoint(x: a.x + (b.x-a.x)*f, y: a.y+(b.y-a.y)*f))
                }
            }
            var previews = 0
            controller.onPreviewForTesting = { drawing in if drawing.strokes.count == 1 { previews += 1 } }
            for (index, point) in points.enumerated() {
                let value = ShapeCompletionSample(documentPoint: point, timestamp: Double(index) * 0.01, estimationIndex: nil, expectingUpdates: 0)
                clock.time = value.timestamp
                if index == 0 { controller.inputBegan(value, zoom: canvas.zoomScale, offset: canvas.contentOffset); controller.nativeBegan(previousStrokeCount: 0) }
                else { controller.inputMoved(value) }
            }
            clock.advance(to: 1.8)
            let shown = await settle { previews == 1 }
            try check(shown && controller.phase == .snapped, "\(kind) visibly snaps without move/lift at zoom \(zoom), actual=\(canvas.zoomScale), offset=\(canvas.contentOffset), phase=\(controller.phase)")
            try check(canvas.drawing.strokes.isEmpty && canvas.layer.opacity == 1, "preview replaces native ink without modifying drawing")
            if kind == .triangle || kind == .rectangle {
                var final: PKDrawing?
                controller.onCompletion = { _,_,completed, _ in final=completed; canvas.drawing=completed; return true }
                let nativePoints=points.enumerated().map { i,p in
                    PKStrokePoint(location:p,timeOffset:Double(i)*0.01,size:CGSize(width:3,height:3),opacity:1,force:1,azimuth:0,altitude:.pi/2)
                }
                let native=PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.blue),path:PKStrokePath(controlPoints:nativePoints,creationDate:Date()))])
                controller.inputEnded(ShapeCompletionSample(documentPoint:points.last!,timestamp:1.9,estimationIndex:nil,expectingUpdates:0))
                canvas.drawing=native; controller.nativeChanged(drawing:native,revision:1); controller.nativeEnded(drawing:native,revision:1)
                let committed=await settle { final != nil }
                try check(committed && final?.strokes.count == 1,"\(kind) commits exactly one fitted stroke")
                controller.nativeChanged(drawing: canvas.drawing, revision: 2)
                controller.nativeFinishedRendering()
                _ = await settle { controller.phase == .finished }
                let reopened=try PKDrawing(data:final!.dataRepresentation())
                let fit=ShapeRecognizer().recognize(documentPoints:points)!
                for corner in fit.fittedPoints.dropFirst().dropLast() {
                    let count=reopened.strokes[0].path.filter { hypot($0.location.x-corner.x,$0.location.y-corner.y)<0.01 }.count
                    try check(count>=3,"\(kind) native path keeps repeated corner controls after serialization")
                }
                let rect=CGRect(x:40,y:70,width:300,height:260)
                let image=reopened.image(from:rect,scale:2)
                if zoom==2 { try image.pngData()!.write(to:PDFIntegrationChecks.directory.appendingPathComponent("shape-native-\(kind.rawValue).png")) }
                try check(reopened.strokes[0].ink.color == native.strokes[0].ink.color,"\(kind) preserves native pen color")
            }
            controller.invalidate()
            try check(canvas.layer.opacity == 1, "cancellation restores native visibility")
            withExtendedLifetime(owner) {}
        }
    }

    // Render the actual CanvasHostView (including its paper child), not an
    // independently assembled demo. Compare background pixels across the exact
    // preview visibility transition and native-render handoff.
    for style in ["ruled", "grid", "colored-pdf", "image"] {
        let fixtureStore = NoteStore()
        let id: UUID
        if style == "colored-pdf" {
            let data = UIGraphicsPDFRenderer(bounds: CGRect(x:0,y:0,width:768,height:1024)).pdfData { output in
                output.beginPage()
                UIColor(red:0.96,green:0.85,blue:0.55,alpha:1).setFill()
                output.fill(CGRect(x:0,y:0,width:768,height:1024))
                ("PDF background" as NSString).draw(at:CGPoint(x:80,y:600),withAttributes:[.font:UIFont.systemFont(ofSize:40),.foregroundColor:UIColor.blue])
            }
            let url = PDFIntegrationChecks.directory.appendingPathComponent("shape-paper.pdf")
            try data.write(to:url)
            id = fixtureStore.importPDF(fixtureStore.preparePDF(url, folderID:nil)!,layout:.paged)!
        } else {
            id = fixtureStore.createNote(title:"Shape paper regression",paper:style == "grid" ? .grid : .ruled,cover:.blue,folderID:nil)!
            if style == "image" {
                let image = UIGraphicsImageRenderer(size:CGSize(width:300,height:180)).image { output in
                    UIColor.cyan.setFill(); output.fill(CGRect(x:0,y:0,width:300,height:180))
                    UIColor.magenta.setFill(); output.fill(CGRect(x:30,y:30,width:90,height:90))
                }
                fixtureStore.addImage(image.pngData()!,noteID:id,pageID:fixtureStore.note(id)!.pages[0].id)
            }
        }
        let note = fixtureStore.note(id)!, page=note.pages[0], clock=ShapeManualClock()
        let session=DrawingSession(preferences: .standard, shapeHoldScheduler:clock.scheduler)
        let host=CanvasHostView(session:session); session.host=host
        host.frame=CGRect(x:0,y:0,width:820,height:1000)
        session.load(noteID:id,pageID:page.id,store:fixtureStore)
        host.configure(note:note,page:page,store:fixtureStore,fingerDrawing:false,editingObjects:false,toolsVisible:false,
                       onSelect:{_ in},onMove:{_,_,_ in},onTurnPage:{_ in false})
        host.layoutIfNeeded()
        defer { session.stop(); fixtureStore.permanentlyDelete(id) }
        for factor in [CGFloat(0.5),1,2] {
            session.canvas.zoomScale=host.bounds.width / page.width * factor
            host.canvasDidZoom()
            let canvas=session.canvas, controller=session.shapeCompletionForTesting
            canvas.drawing=PKDrawing()
            controller.invalidate(); controller.attach(to:canvas); controller.isEnabled=true
            controller.nativeChanged(drawing:canvas.drawing,revision:1)
            func render() -> UIImage {
                let format=UIGraphicsImageRendererFormat(); format.scale=1
                return UIGraphicsImageRenderer(size:host.bounds.size,format:format).image { host.layer.render(in:$0.cgContext) }
            }
            // Allow the fixture's programmatic zoom/refinement to settle before
            // starting a contact. Real input calls this same drawing-active gate.
            try? await Task.sleep(for: .milliseconds(250))
            host.setDrawingActive(true)
            CATransaction.flush()
            let before=render(), renders=host.backgroundRasterizationCount
            let transform=host.documentToViewport
            let visible=host.bounds.applying(transform.inverted())
            let start=CGPoint(x:visible.midX-80,y:visible.midY), end=CGPoint(x:visible.midX+80,y:visible.midY)
            var contactPoints=[PKStrokePoint]()
            for i in 0...40 {
                let t=Double(i)/40, p=CGPoint(x:start.x+(end.x-start.x)*t,y:start.y)
                let sample=ShapeCompletionSample(documentPoint:p,timestamp:t,estimationIndex:nil,expectingUpdates:0)
                clock.time=t
                if i==0 { controller.inputBegan(sample,zoom:canvas.zoomScale,offset:canvas.contentOffset); controller.nativeBegan(previousStrokeCount:0) }
                else { controller.inputMoved(sample) }
                contactPoints.append(PKStrokePoint(location:p,timeOffset:t,size:CGSize(width:3,height:3),opacity:1,force:1,azimuth:0,altitude:.pi/2))
            }
            clock.advance(to:1.56)
            let shown=await settle { controller.phase == .snapped }
            try check(shown,"actual host \(style) snaps at zoom \(factor)")
            let during=render()
            // Follow the same active contact through zero length and a rotated
            // endpoint. Inspect real composed pixels, not only fitted geometry.
            controller.inputMoved(ShapeCompletionSample(documentPoint:start,timestamp:1.57,estimationIndex:nil,expectingUpdates:0))
            let editedEnd=CGPoint(x:start.x,y:start.y+100)
            controller.inputMoved(ShapeCompletionSample(documentPoint:editedEnd,timestamp:1.58,estimationIndex:nil,expectingUpdates:0))
            let edited=render()
            var editedPixels=0
            for step in 1...9 {
                let p=CGPoint(x:start.x,y:start.y+Double(step)*10).applying(transform)
                guard host.bounds.insetBy(dx:2,dy:2).contains(p) else { continue }
                for dx in [-1.0,0,1] {
                    let a=PDFIntegrationChecks.color(before,y:p.y,x:p.x+dx),b=PDFIntegrationChecks.color(edited,y:p.y,x:p.x+dx)
                    if zip(a.prefix(3),b.prefix(3)).map({abs(Int($0)-Int($1))}).reduce(0,+)>30 { editedPixels += 1 }
                }
            }
            try check(editedPixels>1 && controller.phase == .snapped && canvas.drawing.strokes.isEmpty,"\(style) same-contact endpoint preview follows pointer through zero length at zoom \(factor)")
            try check(host.backgroundRasterizationCount==renders,"snap shares \(style) tile images without re-rendering the page")
            let native=PKDrawing(strokes:[PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:contactPoints,creationDate:Date()))])
            controller.onCompletion = { _,_,drawing, _ in canvas.drawing=drawing; return true }
            controller.inputEnded(ShapeCompletionSample(documentPoint:end,timestamp:1.6,estimationIndex:nil,expectingUpdates:0))
            canvas.drawing=native; controller.nativeChanged(drawing:native,revision:2); controller.nativeEnded(drawing:native,revision:2)
            let committed=await settle { controller.phase == .committing }
            try check(committed,"\(style) one native commit")
            controller.nativeChanged(drawing:canvas.drawing,revision:3)
            controller.nativeFinishedRendering()
            _ = await settle { controller.phase == .finished }
            let after=render()
            try check(controller.phase == .finished && canvas.layer.opacity==1,"\(style) cleanup after render handoff")
            func pixels(_ image: UIImage) -> [UInt8] {
                var bytes=[UInt8](repeating:0,count:820*1000*4)
                bytes.withUnsafeMutableBytes { memory in
                    let context=CGContext(data:memory.baseAddress,width:820,height:1000,bitsPerComponent:8,bytesPerRow:820*4,
                                          space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue)!
                    context.draw(image.cgImage!,in:CGRect(x:0,y:0,width:820,height:1000))
                }
                return bytes
            }
            let beforePixels=pixels(before), duringPixels=pixels(during), afterPixels=pixels(after)
            var compared=0, mismatch=0, nonBlank=0, totalDelta=0
            var differences=[String]()
            for y in stride(from:20,to:980,by:7) where abs(CGFloat(y)-host.bounds.midY)>20 {
                for x in stride(from:20,to:800,by:7) {
                    let index=(y*820+x)*4
                    let a=Array(beforePixels[index..<index+3]), b=Array(duringPixels[index..<index+3]), c=Array(afterPixels[index..<index+3])
                    compared += 1
                    let delta = zip(a,b).map { abs(Int($0)-Int($1)) } + zip(a,c).map { abs(Int($0)-Int($1)) }
                    totalDelta += delta.reduce(0,+)
                    // Permit the small text-edge sampling/compositing differences
                    // observed in the native render fixture; bound both isolated
                    // edge differences and the whole-image mean (0.1/255).
                    if delta.contains(where:{$0>24}) { mismatch += 1; if differences.count<30 { differences.append("\(x),\(y): \(a) -> \(b) -> \(c)") } }
                    if a[0]<245 || a[1]<245 || a[2]<245 { nonBlank += 1 }
                }
            }
            for (name,image) in [("before",before),("held",during),("after",after)] {
                try image.pngData()!.write(to:PDFIntegrationChecks.directory.appendingPathComponent("shape-\(style)-\(factor)-\(name).png"))
            }
            try differences.joined(separator:"\n").write(to:PDFIntegrationChecks.directory.appendingPathComponent("shape-\(style)-\(factor)-differences.txt"),atomically:true,encoding:.utf8)
            try check(compared>10_000 && nonBlank>50 && mismatch==0 && Double(totalDelta)/Double(compared*6)<0.1,"\(style) background/rules/PDF pixels before/held/after at \(factor): \(mismatch)/\(compared) differ; mean channel delta=\(Double(totalDelta)/Double(compared*6))")
            controller.invalidate()
            host.setDrawingActive(false)
        }
    }

    // The actual app operation, with the same responder-chain undo manager that
    // an editor supplies. Only a disposable test note in the fixture app is used.
    try check(Bundle.main.bundleIdentifier == "com.notemargin.integrationcheck", "persistence fixture is isolated from the user's app")
    let store = NoteStore()
    guard let noteID = store.createNote(title: "Shape completion persistence fixture", paper: .plain, cover: .blue, folderID: nil),
          let note = store.note(noteID), let page = note.pages.first else {
        throw NSError(domain: "shape completion: could not create isolated persistence fixture", code: 1)
    }
    let suite = "NoteMargin.ShapeCompletionChecks.\(UUID())"
    let preferences = UserDefaults(suiteName: suite)!
    defer {
        preferences.removePersistentDomain(forName: suite)
        if store.flushDrawings() { store.permanentlyDelete(noteID) }
    }
    store.queueDrawing(source, noteID: noteID, pageID: page.id)
    try check(store.flushDrawings(), "original freehand drawing reaches the actual repository")
    let actualClock = ShapeManualClock()
    let session = DrawingSession(preferences: preferences, shapeHoldScheduler: actualClock.scheduler)
    session.load(noteID: noteID, pageID: page.id, store: store)
    let owner = ShapeCompletionUndoController()
    owner.view.addSubview(session.canvas)
    session.canvas.frame = CGRect(x: 0, y: 0, width: 820, height: 1_000)
    defer { session.stop(); withExtendedLifetime(owner) {} }
    func sameInk(_ a: PKDrawing, _ b: PKDrawing) -> Bool {
        let lhs = a.strokes, rhs = b.strokes
        return lhs.count == rhs.count && zip(lhs, rhs).allSatisfy { InkStrokeAppearance.matches($0, $1) }
    }
    func nativeArchive(_ drawing: PKDrawing) throws -> PKDrawing {
        try PKDrawing(data: drawing.dataRepresentation())
    }
    func archiveDiagnostic(_ a: PKDrawing, _ b: PKDrawing) -> String {
        guard a.strokes.count == b.strokes.count else { return "count=\(a.strokes.count)/\(b.strokes.count)" }
        return zip(a.strokes, b.strokes).enumerated().map { index, pair in
            let (x, y) = pair
            var pointDifference = 0.0
            for (p, q) in zip(x.path, y.path) {
                pointDifference = max(pointDifference, abs(p.location.x - q.location.x), abs(p.location.y - q.location.y),
                                      abs(p.size.width - q.size.width), abs(p.size.height - q.size.height),
                                      abs(p.force - q.force), abs(p.opacity - q.opacity), abs(p.azimuth - q.azimuth),
                                      abs(p.altitude - q.altitude), abs(p.timeOffset - q.timeOffset), abs(p.secondaryScale - q.secondaryScale))
            }
            return "stroke\(index):pointMax=\(pointDifference),count=\(x.path.count)/\(y.path.count),color=\(x.ink.color.isEqual(y.ink.color)),transform=\(x.transform == y.transform),bounds=\(x.renderBounds == y.renderBounds),seed=\(x.randomSeed == y.randomSeed),date=\(x.path.creationDate == y.path.creationDate),ranges=\(x.maskedPathRanges == y.maskedPathRanges),version=\(x.requiredContentVersion == y.requiredContentVersion)"
        }.joined(separator: ";")
    }
    let loadedOriginal = session.canvas.drawing
    let loadedOriginalBytes = loadedOriginal.dataRepresentation()
    let loadedBaseline = PKDrawing(strokes: Array(loadedOriginal.strokes.dropLast()))
    guard let completedShape = ShapeStrokeCompleter.replacement(source: loadedOriginal, baseline: loadedBaseline, result: recognized),
          let undo = session.canvas.undoManager else {
        throw NSError(domain: "shape completion: missing actual commit/undo fixture", code: 1)
    }
    let sourceArchiveControl = try nativeArchive(source)
    try check(sameInk(loadedOriginal, sourceArchiveControl),
              "drawing session matches an independent native archive round trip: \(archiveDiagnostic(loadedOriginal, sourceArchiveControl))")
    undo.removeAllActions(); undo.groupsByEvent = false
    undo.beginUndoGrouping()
    session.commitDrawing(completedShape, action: "도형 완성")
    undo.endUndoGrouping()
    let completedBytes = session.canvas.drawing.dataRepresentation()
    try check(undo.canUndo && sameInk(session.canvas.drawing, completedShape), "actual commitDrawing installs one undoable completed shape")
    session.undo()
    try check(sameInk(session.canvas.drawing, loadedOriginal) && session.canvas.drawing.dataRepresentation() == loadedOriginalBytes,
              "one actual undo restores the complete original bytes including pressure and tilt")
    try check(store.flushDrawings(), "undo is persisted through the existing queue")
    let undoneStore = NoteStore()
    try check(sameInk(try undoneStore.drawing(noteID: noteID, pageID: page.id), try nativeArchive(loadedOriginal)),
              "repository reopen after undo contains the original freehand drawing")
    session.redo()
    try check(sameInk(session.canvas.drawing, completedShape) && session.canvas.drawing.dataRepresentation() == completedBytes,
              "one actual redo restores the completed shape bytes")
    try check(store.flushDrawings(), "redone shape is persisted through the existing queue")
    let reopenedStore = NoteStore()
    let reopenedDrawing = try reopenedStore.drawing(noteID: noteID, pageID: page.id)
    let completedArchiveControl = try nativeArchive(completedShape)
    try check(sameInk(reopenedDrawing, completedArchiveControl), "repository reopen restores the fitted geometry and original brush attributes")
    try check(InkStrokeAppearance.matches(reopenedDrawing.strokes[0], completedArchiveControl.strokes[0]), "unrelated original note content survives commit undo redo and reopen")
    // Drive the production DrawingSession callbacks, including its real shape
    // replacement/Undo path, while native source data arrives after lift.
    session.canvas.drawing = baseline; session.canvasViewDrawingDidChange(session.canvas)
    undo.removeAllActions()
    let heldController = session.shapeCompletionForTesting
    var visibleSnaps = 0
    heldController.onPreviewForTesting = { _ in visibleSnaps += 1 }
    heldController.inputBegan(sample(0), zoom: session.canvas.zoomScale, offset: session.canvas.contentOffset)
    session.canvasViewDidBeginUsingTool(session.canvas)
    for i in samples.indices.dropFirst() { actualClock.time = samples[i].timestamp; heldController.inputMoved(sample(i, pending: i == 30)) }
    actualClock.advance(to: 1.3)
    let heldShown = await settle { visibleSnaps == 1 }
    try check(heldShown && session.canvas.layer.opacity == 1, "actual session preview appears before native commit, even with pending estimates")
    var tailStroke = source.strokes.last!
    let nativePoints = Array(tailStroke.path) + [
        PKStrokePoint(location: CGPoint(x: 500,y: 500),timeOffset: 1.6,size: CGSize(width: 3,height: 3),opacity: 1,force: 1,azimuth: 0,altitude: 1),
        PKStrokePoint(location: CGPoint(x: 600,y: 500),timeOffset: 1.7,size: CGSize(width: 3,height: 3),opacity: 1,force: 1,azimuth: 0,altitude: 1)]
    tailStroke.path = PKStrokePath(controlPoints: nativePoints, creationDate: tailStroke.path.creationDate)
    let nativeWithTail = PKDrawing(strokes: [existing, tailStroke])
    var tailEvent = ended; tailEvent.timestamp = 1.7; tailEvent.documentPoint = CGPoint(x: 600,y: 500)
    heldController.inputMoved(tailEvent); heldController.inputEnded(tailEvent)
    undo.beginUndoGrouping()
    session.canvas.drawing = nativeWithTail
    session.canvasViewDrawingDidChange(session.canvas); session.canvasViewDidEndUsingTool(session.canvas)
    try? await Task.sleep(for: .milliseconds(10))
    try check(heldController.phase == .committing || heldController.phase == .finished, "native end commits without waiting for an undocumented estimate/drawing sequence")
    heldController.inputEstimated(sample(30))
    try? await Task.sleep(for: .milliseconds(10))
    try check(heldController.phase == .committing || heldController.phase == .finished, "late estimate preserves the single committed operation")
    session.canvasViewDrawingDidChange(session.canvas)
    let heldCommitted = await settle { heldController.phase == .committing || heldController.phase == .finished }
    undo.endUndoGrouping()
    try check(heldCommitted && visibleSnaps == 1, "late native revision cannot duplicate the shape commit")
    let heldFinal = session.canvas.drawing
    let finalPoints = Array(heldFinal.strokes.last!.path)
    try check(heldFinal.strokes.count == 2 && finalPoints.first!.location == samples.first!.documentPoint &&
              hypot(finalPoints.last!.location.x-600,finalPoints.last!.location.y-500)<0.001,
              "line starts at actual original input and finishes at last actual endpoint, with no freehand tail")
    for point in finalPoints {
        let a=samples.first!.documentPoint, b=tailEvent.documentPoint
        try check(abs((point.location.x-a.x)*(b.y-a.y)-(point.location.y-a.y)*(b.x-a.x))<0.1,"all final points lie on edited straight segment")
    }
    session.canvasViewDrawingDidChange(session.canvas)
    session.canvasViewDidFinishRendering(session.canvas)
    try check(session.canvas.layer.opacity == 1, "native render callback reveals completed native ink")
    // Re-delivery of a native original cannot reinsert it or create another Undo.
    session.canvas.drawing = nativeWithTail; session.canvasViewDrawingDidChange(session.canvas)
    try check(sameInk(session.canvas.drawing, heldFinal), "late native original is repaired without a second shape operation")
    session.undo()
    try check(session.canvas.drawing.strokes.count == 2 && session.canvas.drawing.strokes.last!.path.count == samples.count,
              "one Undo restores freehand before snap, excluding the suppressed tail")
    session.redo()
    try check(sameInk(session.canvas.drawing, heldFinal), "one Redo restores held shape")
    try check(store.flushDrawings(), "held shape saved through existing persistence")
    let heldReopened = NoteStore()
    try check(sameInk(try heldReopened.drawing(noteID: noteID, pageID: page.id), try nativeArchive(heldFinal)),
              "held shape survives reopening")

    print("PASS: \(checks) shape completion lifecycle/attribute checks (synthetic UIKit/PencilKit fixtures)")
    return checks
}

@MainActor private final class ShapeCompletionUndoController: UIViewController {
    let history = UndoManager()
    override var undoManager: UndoManager? { history }
}

private final class ShapeCompletionBlockingRecognizer: ShapeRecognizing, @unchecked Sendable {
    private let condition = NSCondition()
    private var didStart = false, released = false
    var started: Bool { condition.lock(); defer { condition.unlock() }; return didStart }
    func release() { condition.lock(); released = true; condition.broadcast(); condition.unlock() }
    func recognize(documentPoints: [CGPoint]) -> ShapeRecognitionResult? {
        condition.lock(); didStart = true; condition.broadcast()
        while !released { condition.wait() }
        condition.unlock()
        return ShapeRecognizer().recognize(documentPoints: documentPoints)
    }
}

@MainActor private final class ShapeManualClock {
    var time: TimeInterval = 0
    private(set) var scheduledCount = 0
    private struct Job { let deadline: TimeInterval; let action: @MainActor () -> Void; var cancelled = false }
    private var jobs: [UUID: Job] = [:]
    var scheduler: ShapeHoldScheduler {
        ShapeHoldScheduler(now: { self.time }, schedule: { delay, action in
            self.scheduledCount += 1
            let id = UUID(); self.jobs[id] = Job(deadline: self.time + delay, action: action)
            return { self.jobs[id]?.cancelled = true }
        })
    }
    func advance(to time: TimeInterval, includingCancelled: Bool = false) {
        self.time = time
        let due = jobs.filter { $0.value.deadline <= time }
        for (id, job) in due {
            jobs.removeValue(forKey: id)
            if !job.cancelled || includingCancelled { job.action() }
        }
    }
}

@MainActor @discardableResult func checkShapeDirectEditing() async throws -> Int {
    var count=0
    func check(_ condition: Bool, _ message: String) throws {
        count += 1
        if !condition { throw NSError(domain:"shape direct editing: "+message,code:1) }
    }
    func settle(_ predicate: @escaping @MainActor () -> Bool) async -> Bool {
        let deadline=ProcessInfo.processInfo.systemUptime+3
        while !predicate() && ProcessInfo.processInfo.systemUptime<deadline { try? await Task.sleep(for:.milliseconds(2)) }
        return predicate()
    }
    for kind in [ShapeKind.circle,.ellipse,.triangle,.rectangle] {
        let store=NoteStore(),clock=ShapeManualClock()
        let id=store.createNote(title:"Direct shape fixture",paper:.ruled,cover:.blue,folderID:nil)!
        let note=store.note(id)!,page=note.pages[0]
        let session=DrawingSession(preferences:.standard,shapeHoldScheduler:clock.scheduler)
        let host=CanvasHostView(session:session);session.host=host
        let vc=ShapeCompletionUndoController();vc.view=host
        let window=UIWindow(frame:CGRect(x:0,y:0,width:820,height:1000));window.rootViewController=vc;window.isHidden=false
        session.load(noteID:id,pageID:page.id,store:store)
        host.configure(note:note,page:page,store:store,fingerDrawing:false,editingObjects:false,toolsVisible:true,onSelect:{_ in},onMove:{_,_,_ in},onTurnPage:{_ in false})
        host.layoutIfNeeded()
        try? await Task.sleep(for:.milliseconds(100))
        defer { session.stop();window.isHidden=true;store.permanentlyDelete(id) }
        let selectedTool=session.selectedTool,controller=session.shapeCompletionForTesting
        var points=[CGPoint]()
        let vertices = kind == .triangle ? [CGPoint(x:-80,y:65),CGPoint(x:-45,y:-70),CGPoint(x:100,y:65),CGPoint(x:-80,y:65)] :
            [CGPoint(x:-90,y:-55),CGPoint(x:90,y:-55),CGPoint(x:90,y:55),CGPoint(x:-90,y:55),CGPoint(x:-90,y:-55)]
        for i in 0...120 {
            let t=Double(i)/120, p:CGPoint
            if kind == .circle || kind == .ellipse {
                p=CGPoint(x:(kind == .circle ? 70:100)*cos(t*2*Double.pi),y:(kind == .circle ? 70:50)*sin(t*2*Double.pi))
            } else {
                let n=vertices.count-1,edge=min(n-1,Int(t*Double(n))),f=t*Double(n)-Double(edge),a=vertices[edge],b=vertices[edge+1]
                p=CGPoint(x:a.x+(b.x-a.x)*f,y:a.y+(b.y-a.y)*f)
            }
            let rotated=ShapeEditMath.rotate(p,angle:0.37)
            points.append(CGPoint(x:rotated.x+300,y:rotated.y+330))
        }
        // Native source is deliberately given two unrelated prefix strokes.
        func ink(_ p:[CGPoint],date:Double)->PKStroke {
            PKStroke(ink:PKInk(.pen,color:.blue),path:PKStrokePath(controlPoints:p.enumerated().map { i,p in
                PKStrokePoint(location:p,timeOffset:Double(i)*0.01,size:CGSize(width:3,height:3),opacity:1,force:1,azimuth:0,altitude:.pi/2)
            },creationDate:Date(timeIntervalSince1970:date)))
        }
        let prefix=[ink([CGPoint(x:20,y:30),CGPoint(x:60,y:30)],date:10),ink([CGPoint(x:20,y:60),CGPoint(x:60,y:60)],date:20)]
        session.canvas.drawing=PKDrawing(strokes:prefix);session.canvasViewDrawingDidChange(session.canvas)
        vc.history.removeAllActions()
        for (i,p) in points.enumerated() {
            let sample=ShapeCompletionSample(documentPoint:p,timestamp:Double(i)*0.01,estimationIndex:nil,expectingUpdates:0)
            clock.time=sample.timestamp
            if i==0 { controller.inputBegan(sample,zoom:session.canvas.zoomScale,offset:session.canvas.contentOffset);session.canvasViewDidBeginUsingTool(session.canvas) }
            else { controller.inputMoved(sample) }
        }
        clock.advance(to:1.8)
        let shown=await settle { controller.phase == .snapped }
        try check(shown && host.automaticShapeFrame != nil && !host.hasAutomaticShapeSelection,"\(kind) displays selection immediately but does not reinterpret held contact")
        let frozen=host.automaticShapeFrame
        controller.inputMoved(ShapeCompletionSample(documentPoint:CGPoint(x:600,y:800),timestamp:1.85,estimationIndex:nil,expectingUpdates:0))
        try check(host.automaticShapeFrame == frozen,"\(kind) held shape is fixed")
        // A SwiftUI reconfiguration must not discard or hide the held preview.
        host.configure(note:note,page:page,store:store,fingerDrawing:false,editingObjects:false,toolsVisible:true,onSelect:{_ in},onMove:{_,_,_ in},onTurnPage:{_ in false})
        try check(host.subviews.contains{$0.accessibilityIdentifier=="shape-held-preview"} && session.canvas.layer.opacity==1,"\(kind) reconfiguration preserves visible preview and native rendering")
        controller.inputEnded(ShapeCompletionSample(documentPoint:points.last!,timestamp:1.9,estimationIndex:nil,expectingUpdates:0))
        session.canvas.drawing=PKDrawing(strokes:prefix+[ink(points,date:30)])
        session.canvasViewDrawingDidChange(session.canvas);session.canvasViewDidEndUsingTool(session.canvas)
        let committed=await settle { controller.phase == .committing || controller.phase == .finished }
        try check(committed,"\(kind) commits after native contact ends")
        try check(host.hasAutomaticShapeSelection,"\(kind) next contact can edit before presentation cleanup completes")
        session.canvasViewDrawingDidChange(session.canvas);session.canvasViewDidFinishRendering(session.canvas)
        let ready=await settle { host.hasAutomaticShapeSelection }
        try check(ready && host.selectedInkIndices == [2] && session.selectedTool==selectedTool,"\(kind) automatically selects stable stroke ID without changing pen")
        while vc.history.groupingLevel>0 { vc.history.endUndoGrouping() }
        vc.history.removeAllActions(); vc.history.groupsByEvent=false
        let initial=session.canvas.drawing, initialFrame=host.automaticShapeFrame!
        let start=CGPoint(x:initialFrame.center.x+9,y:initialFrame.center.y-7),delta=CGPoint(x:45,y:27)
        host.beginInkTransform(at:start)
        for i in 1...30 {
            host.updateInkDrag(to:CGPoint(x:start.x+delta.x*CGFloat(i)/30,y:start.y+delta.y*CGFloat(i)/30))
        }
        try check(abs(host.liveInkTransform.tx-delta.x)<0.001 && abs(host.liveInkTransform.ty-delta.y)<0.001 && host.liveSelectionTransform==host.liveInkTransform,"\(kind) original + total delta; outline and ink match")
        vc.history.beginUndoGrouping();host.transformSelectedInk(host.liveSelectionTransform,action:"필기 이동");vc.history.endUndoGrouping()
        let moved=session.canvas.drawing
        try check(moved.strokes.count==3 && zip(moved.strokes.prefix(2),prefix).allSatisfy{InkStrokeAppearance.matches($0,$1)},"\(kind) unrelated strokes retained")
        try check(InkStrokeID(moved.strokes[2])==InkStrokeID(initial.strokes[2]),"\(kind) transform preserves identity")
        let movedFrame=host.automaticShapeFrame!,corner=movedFrame.corners[2]
        let grab=CGPoint(x:corner.x+3,y:corner.y-4)
        host.beginInkTransform(at:grab)
        let resize=ShapeResizeDrag(frame:movedFrame,corner:2,pointer:grab)
        let desired=CGPoint(x:resize.anchor.x+(corner.x-resize.anchor.x)*1.5+3,y:resize.anchor.y+(corner.y-resize.anchor.y)*1.5-4)
        host.updateInkDrag(to:desired)
        let transform=host.liveSelectionTransform
        try check(abs(transform.a-1.5)<0.001 && transform.a==transform.d,"\(kind) rotated corner uses common scale with grab offset")
        vc.history.beginUndoGrouping();host.transformSelectedInk(transform,action:"필기 크기 조절");vc.history.endUndoGrouping()
        let resized=session.canvas.drawing, shapeFrame=host.automaticShapeFrame!
        try check(abs(shapeFrame.width/shapeFrame.height-initialFrame.width/initialFrame.height)<0.0001,"\(kind) shape ratio preserved")
        let ids=Set(resized.strokes.map(InkStrokeID.init))
        try check(ids.count==3 && ids.contains(InkStrokeID(initial.strokes[2])),"\(kind) no duplicate object")
        // Preserve native archival round-trip semantics, including scaled width.
        try check(store.flushDrawings(),"\(kind) flush edited geometry")
        let reopen=try NoteStore().drawing(noteID:id,pageID:page.id), control=try PKDrawing(data:resized.dataRepresentation())
        try check(zip(reopen.strokes,control.strokes).allSatisfy{InkStrokeAppearance.matches($0,$1)},"\(kind) reopen matches native transformed archive")
        session.undo()
        try check(session.canvas.drawing==moved,"\(kind) resize is one Undo")
        session.redo()
        try check(session.canvas.drawing==resized,"\(kind) resize is one Redo")
        // Hit-testing uses newly transformed geometry, not the old location/index.
        let selected=RectangularInkSelection(drawing:resized,rect:resized.strokes[2].renderBounds)
        try check(selected.indices.contains(2),"\(kind) selection index reflects committed transform")
        host.activateAutomaticShape(ShapeRecognitionResult(kind:kind,confidence:1,normalizedError:0,fittedPoints:points),ids:[InkStrokeID(resized.strokes[2])])
        host.handleInkSelectionTap(at:CGPoint(x:700,y:950))
        try check(!host.hasAutomaticShapeSelection && host.selectedInkDrawing==nil && session.selectedTool==selectedTool,"\(kind) outside tap restores normal pen")
    }
    // A line collapsed exactly onto its start remains finite and serializable.
    let p=[PKStrokePoint(location:CGPoint(x:10,y:20),timeOffset:0,size:CGSize(width:3,height:3),opacity:1,force:1,azimuth:0,altitude:1),
           PKStrokePoint(location:CGPoint(x:90,y:40),timeOffset:1,size:CGSize(width:3,height:3),opacity:1,force:1,azimuth:0,altitude:1)]
    let stroke=PKStroke(ink:PKInk(.pen,color:.black),path:PKStrokePath(controlPoints:p,creationDate:Date()))
    let zero=ShapeRecognitionResult(kind:.line,confidence:1,normalizedError:0,fittedPoints:[p[0].location,p[0].location])
    let collapsed=ShapeStrokeCompleter.replacement(source:PKDrawing(strokes:[stroke]),baseline:PKDrawing(),result:zero)
    try check(collapsed != nil,"zero-length line commits safely")
    let reopened=try PKDrawing(data:collapsed!.dataRepresentation())
    try check(reopened.strokes.count==1 && reopened.strokes[0].path.allSatisfy{$0.location.x.isFinite && $0.location.y.isFinite},"zero-length line archive contains no NaN")
    print("PASS: \(count) direct shape editing checks (injected contacts, real host/selection/Undo/store)")
    return count
}
