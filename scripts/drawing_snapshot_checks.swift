import SwiftUI
import PencilKit
import Combine

/// Exercises the app's real delegate -> store -> serial persistence path.
/// Native delegate delivery is replayed explicitly; this is not a physical
/// Pencil latency measurement or a simulation of PencilKit's internal renderer.
@MainActor func checkDrawingSnapshots() async throws -> Int {
    #if DEBUG
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        try PDFIntegrationChecks.check(try condition(), "drawing snapshots: " + message)
        count += 1
    }
    func drawing(points count: Int, force: CGFloat = 0.5, width: CGFloat = 3,
                 y: CGFloat = 120, seed: UInt32 = 17) -> PKDrawing {
        let points = (0..<count).map { index in
            PKStrokePoint(location: CGPoint(x: 40 + CGFloat(index) * 4, y: y + CGFloat(index % 3)),
                          timeOffset: Double(index) / 120,
                          size: CGSize(width: width, height: width), opacity: 1,
                          force: force, azimuth: 0.2, altitude: .pi / 3)
        }
        let stroke = PKStroke(ink: PKInk(.pen, color: .black),
                              path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 120)),
                              transform: .identity, mask: nil, randomSeed: seed)
        return PKDrawing(strokes: [stroke])
    }
    func sameInk(_ lhs: PKDrawing, _ rhs: PKDrawing) -> Bool {
        guard lhs.strokes.count == rhs.strokes.count else { return false }
        func close(_ a: CGFloat, _ b: CGFloat) -> Bool { abs(a - b) < 0.0001 }
        return zip(lhs.strokes, rhs.strokes).allSatisfy { a, b in
            a.ink.inkType == b.ink.inkType && a.ink.color == b.ink.color &&
            a.transform == b.transform && a.randomSeed == b.randomSeed &&
            a.path.count == b.path.count && a.mask?.cgPath == b.mask?.cgPath &&
            zip(a.path, b.path).allSatisfy { x, y in
                close(x.location.x, y.location.x) && close(x.location.y, y.location.y) &&
                close(x.size.width, y.size.width) && close(x.size.height, y.size.height) &&
                close(x.force, y.force) && close(x.opacity, y.opacity) &&
                close(x.azimuth, y.azimuth) && close(x.altitude, y.altitude) &&
                abs(x.timeOffset - y.timeOffset) < 0.0001
            }
        }
    }
    func waitForCompletion(_ ready: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !ready(), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
    }

    try check(Bundle.main.bundleIdentifier == "com.notemargin.integrationcheck", "isolated fixture only")
    let suite = "noteMargin.drawingSnapshots.tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defer { defaults.removePersistentDomain(forName: suite) }
    let store = NoteStore()
    guard let noteID = store.createNote(title: "Drawing snapshot fixture", paper: .plain,
                                       cover: .blue, folderID: nil),
          let pageID = store.note(noteID)?.pages.first?.id else {
        throw NSError(domain: "drawing snapshot fixture", code: 1)
    }
    let session = DrawingSession(preferences: defaults)
    session.load(noteID: noteID, pageID: pageID, store: store)
    let canvas = session.canvas
    // Programmatic fixture assignments must not introduce a second, UIKit-
    // scheduled callback alongside the explicit delegate event being tested.
    canvas.delegate = nil
    defer {
        session.stop()
        if store.flushDrawings() { store.trash(noteID); store.permanentlyDelete(noteID) }
    }
    try check(session.loadError == nil && !store.hasUnsavedChanges, "clean blank note starts with no pending drawing")
    var dirtyPublications: [Bool] = []
    let dirtyObserver = store.$hasUnsavedChanges.sink { dirtyPublications.append($0) }
    defer { dirtyObserver.cancel() }

    session.canvasViewDidBeginUsingTool(canvas)
    DrawingEngineMetrics.reset()
    let samples = (2...25).map { drawing(points: $0) }
    for sample in samples {
        canvas.drawing = sample
        for _ in 0..<5 { session.canvasViewDrawingDidChange(canvas) }
    }
    let activeSource = samples.last!
    try check(DrawingEngineMetrics.drawingCallbacks == 120, "all active native drawing callbacks reach the real delegate")
    try check(DrawingEngineMetrics.snapshotCount == 0, "120 active callbacks do not copy the native drawing")
    try check(store.hasUnsavedChanges, "active unsnapshotted ink marks the document dirty")
    try check(dirtyPublications == [false, true], "active callbacks publish dirty state only once per clean-to-dirty transition")

    let readDuringContact = try store.drawing(noteID: noteID, pageID: pageID)
    try check(sameInk(readDuringContact, activeSource), "explicit drawing read captures the latest in-contact stroke")
    try check(DrawingEngineMetrics.snapshotCount == 1, "explicit active read captures one snapshot")
    _ = try store.drawing(noteID: noteID, pageID: pageID)
    try check(DrawingEngineMetrics.snapshotCount == 1, "repeated read without another native update reuses the pending snapshot")

    let backgroundSource = drawing(points: 28, force: 0.65, width: 3.5)
    canvas.drawing = backgroundSource
    session.canvasViewDrawingDidChange(canvas)
    try check(DrawingEngineMetrics.snapshotCount == 1, "new active update remains deferred after an explicit read")
    try check(store.flushDrawings(), "lifecycle flush succeeds during the active contact")
    try check(DrawingEngineMetrics.snapshotCount == 2, "active flush captures the newer stroke once")
    try check(!store.hasUnsavedChanges, "flush clears only the captured active revision")
    try check(sameInk(try NoteStore().drawing(noteID: noteID, pageID: pageID), backgroundSource),
              "reopening immediately after a mid-contact flush restores the current stroke")

    let liftedSource = drawing(points: 32, force: 0.7, width: 4)
    canvas.drawing = liftedSource
    session.canvasViewDrawingDidChange(canvas)
    let beforeEnd = DrawingEngineMetrics.snapshotCount
    session.canvasViewDidEndUsingTool(canvas)
    try check(DrawingEngineMetrics.snapshotCount == beforeEnd + 1, "tool end captures the latest stroke exactly once")
    try check(sameInk(try store.drawing(noteID: noteID, pageID: pageID), liftedSource),
              "end boundary keeps ink that arrived after the lifecycle flush")
    try check(store.flushDrawings(), "lifted snapshot persists")
    try check(sameInk(try NoteStore().drawing(noteID: noteID, pageID: pageID), liftedSource),
              "lifted stroke survives reopening")

    // PencilKit may deliver final estimated-force data after didEndUsingTool.
    let correctedSource = drawing(points: 32, force: 0.95, width: 4.75)
    canvas.drawing = correctedSource
    let beforeCorrection = DrawingEngineMetrics.snapshotCount
    session.canvasViewDrawingDidChange(canvas)
    try check(DrawingEngineMetrics.snapshotCount == beforeCorrection + 1 && store.hasUnsavedChanges,
              "late native pressure correction takes a fresh committed snapshot")
    try check(sameInk(try store.drawing(noteID: noteID, pageID: pageID), correctedSource),
              "late correction replaces the earlier lifted snapshot")
    try check(store.flushDrawings(), "late native correction persists")
    try check(sameInk(try NoteStore().drawing(noteID: noteID, pageID: pageID), correctedSource),
              "reopened pressure and point widths include the late correction")

    session.canvasViewDidBeginUsingTool(canvas)
    let beforeEmptyContact = DrawingEngineMetrics.snapshotCount
    session.canvasViewDidEndUsingTool(canvas)
    try check(DrawingEngineMetrics.snapshotCount == beforeEmptyContact && !store.hasUnsavedChanges,
              "contact without a drawing update creates no snapshot or dirty state")

    let reloadSource = drawing(points: 21, force: 0.75, y: 190, seed: 27)
    session.canvasViewDidBeginUsingTool(canvas)
    canvas.drawing = reloadSource
    session.canvasViewDrawingDidChange(canvas)
    let beforeReload = DrawingEngineMetrics.snapshotCount
    store.loadLibrary()
    try check(DrawingEngineMetrics.snapshotCount == beforeReload + 1,
              "library reload captures active dirty ink even when the pending snapshot map was empty")
    try check(!store.hasUnsavedChanges && store.loadingError == nil,
              "library reload finishes only after the active snapshot is saved")
    try check(sameInk(try NoteStore().drawing(noteID: noteID, pageID: pageID), reloadSource),
              "library reload does not replace current in-contact ink with the older disk version")
    session.canvasViewDidEndUsingTool(canvas)
    try check(store.flushDrawings(), "contact remains valid after library reload")

    // The autosave's library publication occurs immediately before removing
    // its saved revisions. Inject the next actual callback at that boundary
    // using Combine's synchronous delivery, not timing or a private test hook.
    let oldSource = drawing(points: 12, y: 220, seed: 31)
    let newActiveSource = drawing(points: 19, force: 0.8, y: 260, seed: 32)
    let priorDate = store.note(noteID)!.updatedAt
    var injectedActive = false
    var activeCompletion: AnyCancellable? = store.$library.dropFirst().sink { library in
        guard !injectedActive,
              let date = library.notebooks.first(where: { $0.id == noteID })?.updatedAt,
              date > priorDate else { return }
        injectedActive = true
        session.canvasViewDidBeginUsingTool(canvas)
        canvas.drawing = newActiveSource
        session.canvasViewDrawingDidChange(canvas)
    }
    defer { activeCompletion?.cancel() }
    canvas.drawing = oldSource
    session.canvasViewDrawingDidChange(canvas)
    DrawingEngineMetrics.reset()
    try await waitForCompletion { injectedActive }
    activeCompletion?.cancel(); activeCompletion = nil
    try check(injectedActive, "real background autosave reached its completion boundary")
    try check(DrawingEngineMetrics.drawingCallbacks == 1 && DrawingEngineMetrics.snapshotCount == 0,
              "next contact at an old autosave completion stays unsnapshotted")
    try check(store.hasUnsavedChanges, "old save completion cannot clear newer active dirty ink")
    try check(sameInk(try store.drawing(noteID: noteID, pageID: pageID), newActiveSource),
              "explicit read after old completion obtains the new active stroke")
    session.canvasViewDidEndUsingTool(canvas)
    try check(store.flushDrawings(), "new contact remains flushable after an older autosave completion")
    try check(sameInk(try NoteStore().drawing(noteID: noteID, pageID: pageID), newActiveSource),
              "old completion cannot overwrite the newer active stroke on disk")

    // Also cover a newer already-captured revision, as can happen when a late
    // native correction arrives while an older batch finishes saving.
    let nextOldSource = drawing(points: 15, y: 300, seed: 41)
    let nextCorrection = drawing(points: 15, force: 0.9, width: 5, y: 300, seed: 41)
    let priorCorrectionDate = store.note(noteID)!.updatedAt
    var injectedCorrection = false
    var correctionCompletion: AnyCancellable? = store.$library.dropFirst().sink { library in
        guard !injectedCorrection,
              let date = library.notebooks.first(where: { $0.id == noteID })?.updatedAt,
              date > priorCorrectionDate else { return }
        injectedCorrection = true
        canvas.drawing = nextCorrection
        session.canvasViewDrawingDidChange(canvas)
    }
    defer { correctionCompletion?.cancel() }
    canvas.drawing = nextOldSource
    session.canvasViewDrawingDidChange(canvas)
    DrawingEngineMetrics.reset()
    try await waitForCompletion { injectedCorrection }
    correctionCompletion?.cancel(); correctionCompletion = nil
    try check(injectedCorrection && DrawingEngineMetrics.snapshotCount == 1,
              "late correction captures one newer revision during real save completion")
    try check(store.hasUnsavedChanges, "old saved revision cannot clear newer committed dirty ink")
    try check(sameInk(try store.drawing(noteID: noteID, pageID: pageID), nextCorrection),
              "new committed revision survives old batch removal")
    try check(store.flushDrawings(), "latest correction flush succeeds after the revision race")
    try check(sameInk(try NoteStore().drawing(noteID: noteID, pageID: pageID), nextCorrection),
              "latest correction survives a store reopen after the revision race")
    try check(store.errorMessage == nil, "all snapshot boundaries finish without persistence errors")

    // An unavailable weak canvas/provider must not turn an unresolved dirty
    // page into a successful flush. Use another store so failure is isolated.
    do {
        let unavailableStore = NoteStore()
        guard let unavailableNoteID = unavailableStore.createNote(title: "Unavailable snapshot fixture", paper: .plain,
                                                                  cover: .blue, folderID: nil),
              let unavailablePageID = unavailableStore.note(unavailableNoteID)?.pages.first?.id else {
            throw NSError(domain: "unavailable snapshot fixture", code: 1)
        }
        let recoveredSource = drawing(points: 18, force: 0.85, y: 340, seed: 47)
        defer {
            unavailableStore.beginDrawingInteraction(noteID: unavailableNoteID, pageID: unavailablePageID,
                                                    snapshot: { recoveredSource })
            unavailableStore.endDrawingInteraction(noteID: unavailableNoteID, pageID: unavailablePageID)
            if unavailableStore.flushDrawings() { unavailableStore.trash(unavailableNoteID); unavailableStore.permanentlyDelete(unavailableNoteID) }
        }
        unavailableStore.beginDrawingInteraction(noteID: unavailableNoteID, pageID: unavailablePageID, snapshot: { nil })
        unavailableStore.markActiveDrawingChanged(noteID: unavailableNoteID, pageID: unavailablePageID)
        try check(!unavailableStore.flushDrawings(), "missing active snapshot cannot report a successful save")
        try check(unavailableStore.hasUnsavedChanges && unavailableStore.errorMessage != nil,
                  "unavailable provider preserves dirty state and reports a recoverable save error")
        unavailableStore.beginDrawingInteraction(noteID: unavailableNoteID, pageID: unavailablePageID,
                                                snapshot: { recoveredSource })
        try check(unavailableStore.flushDrawings() && !unavailableStore.hasUnsavedChanges,
                  "restoring the provider makes the same dirty page saveable")
        unavailableStore.endDrawingInteraction(noteID: unavailableNoteID, pageID: unavailablePageID)
        try check(sameInk(try NoteStore().drawing(noteID: unavailableNoteID, pageID: unavailablePageID), recoveredSource),
                  "recovery persists the original editable drawing")
    }

    // A page switch ends the provider's lifetime. It must capture the old page
    // before replacing its PKCanvasView, and reject callbacks from that view.
    guard let nextPageID = store.addPage(noteID: noteID, after: pageID, paper: .plain) else {
        throw NSError(domain: "snapshot page switch fixture", code: 1)
    }
    let switchingSource = drawing(points: 24, force: 0.9, y: 380, seed: 53)
    session.canvasViewDidBeginUsingTool(canvas)
    canvas.drawing = switchingSource
    DrawingEngineMetrics.reset()
    session.canvasViewDrawingDidChange(canvas)
    session.load(noteID: noteID, pageID: nextPageID, store: store)
    session.canvas.delegate = nil
    try check(DrawingEngineMetrics.snapshotCount == 1,
              "loading another page captures the previous active provider exactly once")
    try check(session.canvas !== canvas && session.canvas.drawing.strokes.isEmpty,
              "page switch replaces the native surface without carrying old-page ink")
    try check(sameInk(try NoteStore().drawing(noteID: noteID, pageID: pageID), switchingSource),
              "mid-contact page switch persists the previous page's latest ink")
    let callbacksBeforeOldPage = DrawingEngineMetrics.drawingCallbacks
    session.canvasViewDrawingDidChange(canvas)
    try check(DrawingEngineMetrics.drawingCallbacks == callbacksBeforeOldPage,
              "late callback from the detached page is ignored")
    try check(try store.drawing(noteID: noteID, pageID: nextPageID).strokes.isEmpty,
              "previous page's late callback cannot contaminate the new page")
    return count
    #else
    throw NSError(domain: "Drawing snapshot checks require DEBUG metrics", code: 1)
    #endif
}
