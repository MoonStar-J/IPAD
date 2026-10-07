import SwiftUI
import PencilKit

@MainActor private final class InkGroupCheckController: UIViewController {
    let history = UndoManager()
    override var undoManager: UndoManager? { history }
}

@MainActor func checkInkGroups(store: NoteStore) throws {
    var count = 0
    func check(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
        try PDFIntegrationChecks.check(try condition(), "ink groups: " + message)
        count += 1
    }
    func identity(_ stroke: PKStroke) -> InkStrokeID {
        InkStrokeID(creationDate: stroke.path.creationDate, randomSeed: stroke.randomSeed)
    }
    func stroke(y: CGFloat, seed: UInt32) -> PKStroke {
        let points = (0..<8).map { index in
            PKStrokePoint(location: CGPoint(x: 80 + CGFloat(index) * 12, y: y), timeOffset: Double(index) * 0.02,
                          size: CGSize(width: 4, height: 4), opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
        }
        return PKStroke(ink: PKInk(.pen, color: .black),
                        path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 100)),
                        transform: .identity, mask: nil, randomSeed: seed)
    }
    func makeSession(store: NoteStore, note: Notebook) -> (DrawingSession, CanvasHostView, InkGroupCheckController) {
        let session = DrawingSession()
        let host = CanvasHostView(session: session)
        session.host = host
        let controller = InkGroupCheckController()
        controller.view.addSubview(host)
        host.frame = CGRect(x: 0, y: 0, width: 820, height: 1000)
        session.load(noteID: note.id, pageID: note.pages[0].id, store: store)
        session.selectTool(.rectangle)
        host.configure(note: note, page: note.pages[0], store: store, fingerDrawing: true,
                       editingObjects: false, toolsVisible: true, onSelect: { _ in }, onMove: { _, _, _ in }, onTurnPage: { _ in false })
        host.layoutIfNeeded()
        controller.history.groupsByEvent = false
        return (session, host, controller)
    }

    try check(Bundle.main.bundleIdentifier == "com.notemargin.integrationcheck", "isolated fixture only")
    var encodedPage = try JSONSerialization.jsonObject(with: JSONEncoder().encode(NotePage())) as! [String: Any]
    encodedPage.removeValue(forKey: "inkGroups")
    let legacyPage = try JSONDecoder().decode(NotePage.self, from: JSONSerialization.data(withJSONObject: encodedPage))
    try check(legacyPage.inkGroups == nil, "legacy page without group field decodes")
    guard let noteID = store.createNote(title: "Ink group fixture", paper: .plain, cover: .blue, folderID: nil),
          let note = store.note(noteID) else { throw NSError(domain: "ink groups fixture", code: 1) }
    let pageID = note.pages[0].id
    defer { if store.flushDrawings() { store.permanentlyDelete(noteID) } }
    let original = PKDrawing(strokes: [stroke(y: 100, seed: 11), stroke(y: 200, seed: 22), stroke(y: 400, seed: 33)])
    let originalIDs = original.strokes.map(identity)
    store.queueDrawing(original, noteID: noteID, pageID: pageID)
    try check(store.flushDrawings(), "seed ink persisted")
    let (session, host, controller) = makeSession(store: store, note: note)
    defer { session.stop(); withExtendedLifetime(controller) {} }
    guard let undo = session.canvas.undoManager else { throw NSError(domain: "ink groups undo manager", code: 1) }
    undo.groupsByEvent = false
    let savedOriginal = session.canvas.drawing.dataRepresentation()
    let legacyClones = PKDrawing(strokes: [original.strokes[2], original.strokes[2]])
    try check(session.expandedSelectionIndices(in: legacyClones, indices: [0]) == [0], "ungrouped legacy duplicate identifiers do not expand raw selection")
    let pairRect = CGRect(x: 60, y: 80, width: 140, height: 140)
    host.selectInk(in: pairRect)
    try check(host.selectedInkIndices == [0, 1], "fixture selects two strokes")
    undo.beginUndoGrouping(); session.groupSelectedInk(); undo.endUndoGrouping()
    let group = store.note(noteID)?.pages[0].inkGroups?.first
    try check(group?.strokeIDs == Array(originalIDs.prefix(2)) && session.selectionIsGrouped, "group records public stroke identifiers and updates action state")
    try check(session.canvas.drawing.dataRepresentation() == savedOriginal, "grouping does not rewrite or flatten original drawing")
    try check(session.expandedSelectionIndices(in: session.canvas.drawing, indices: [0]) == [0, 1], "one group member expands to the pair")
    try check(session.expandedSelectionIndices(in: session.canvas.drawing, indices: [2]) == [2], "unrelated stroke is excluded")
    try check(session.expandedSelectionIndices(in: legacyClones, indices: [0]) == [0], "unrelated groups do not expand legacy clone identifiers")

    session.undo()
    try check(store.note(noteID)?.pages[0].inkGroups == nil, "group undo removes only metadata")
    try check(session.canvas.drawing.dataRepresentation() == savedOriginal, "group undo leaves ink intact")
    session.redo()
    try check(store.note(noteID)?.pages[0].inkGroups?.first == group, "group redo restores exact group record")

    let reopened = NoteStore()
    let restoredNote = reopened.note(noteID)!
    try check(restoredNote.pages[0].inkGroups?.first == group, "groups survive store reopen")
    let (restored, restoredHost, restoredController) = makeSession(store: reopened, note: restoredNote)
    defer { restored.stop(); withExtendedLifetime(restoredController) {} }
    guard let restoredUndo = restored.canvas.undoManager else { throw NSError(domain: "ink groups reopened undo manager", code: 1) }
    restoredUndo.groupsByEvent = false
    let memberBox = CGRect(x: 60, y: 80, width: 140, height: 40)
    restoredHost.selectInk(in: memberBox)
    try check(restoredHost.selectedInkIndices == [0, 1], "box selection expands saved group after session reopen")
    restoredHost.clearInkSelection()
    restoredHost.selectInk(in: CGPath(ellipseIn: memberBox, transform: nil))
    try check(restoredHost.selectedInkIndices == [0, 1], "freeform selection expands saved group after session reopen")
    restoredUndo.beginUndoGrouping()
    restoredHost.transformSelectedInk(CGAffineTransform(translationX: 35, y: 45), action: "필기 이동")
    restoredUndo.endUndoGrouping()
    let moved = restored.canvas.drawing
    try check(moved.strokes.map(identity) == originalIDs, "move preserves group identities")
    try check(moved.strokes[2].transform == original.strokes[2].transform, "group move preserves unrelated ink")
    try check(restored.expandedSelectionIndices(in: moved, indices: [1]) == [0, 1], "group still expands after move")

    var maskedMember = moved.strokes[0]
    maskedMember.mask = UIBezierPath(rect: CGRect(x: 70, y: 90, width: 60, height: 20))
    let masked = PKDrawing(strokes: [maskedMember, moved.strokes[1], moved.strokes[2]])
    try check(restored.expandedSelectionIndices(in: masked, indices: [0]) == [0, 1], "pixel mask changes preserve membership")
    let erasedMember = PKDrawing(strokes: [moved.strokes[1], moved.strokes[2]])
    try check(restored.expandedSelectionIndices(in: erasedMember, indices: [0]) == [0], "stale erased member does not select unrelated ink")

    let selected = PKDrawing(strokes: Array(moved.strokes.prefix(2)))
    let copy = DrawingSession.reidentifiedInk(selected)
    var copyDatesChanged = true
    var copyAppearancePreserved = true
    for (a, b) in zip(copy.strokes, selected.strokes) {
        copyDatesChanged = copyDatesChanged && a.path.creationDate != b.path.creationDate && a.randomSeed == b.randomSeed
        let sameTransform = a.transform == b.transform
        let sameMask = a.mask?.cgPath == b.mask?.cgPath
        let sameInk = a.ink.inkType == b.ink.inkType && a.ink.color == b.ink.color
        var samePoints = a.path.count == b.path.count
        if samePoints {
            for index in 0..<a.path.count {
                let left = a.path[index], right = b.path[index]
                if left.location != right.location || left.size != right.size || left.timeOffset != right.timeOffset { samePoints = false }
            }
        }
        if !sameTransform || !sameMask || !sameInk || !samePoints { copyAppearancePreserved = false }
    }
    try check(copyDatesChanged, "copied paths get new dates but keep texture seeds")
    try check(try PKDrawing(data: copy.dataRepresentation()).strokes.map(identity) == copy.strokes.map(identity), "fresh copy identifiers survive drawing serialization")
    try check(copyAppearancePreserved, "copy keeps editable geometry, masks, widths, timing and ink appearance")
    let together = PKDrawing(strokes: moved.strokes + copy.strokes)
    try check(restored.expandedSelectionIndices(in: together, indices: [3]) == [3], "new copy does not accidentally join original group")

    restoredUndo.beginUndoGrouping(); restored.ungroupSelectedInk(); restoredUndo.endUndoGrouping()
    try check(reopened.note(noteID)?.pages[0].inkGroups == nil && !restored.selectionIsGrouped, "ungroup persists and updates action state")
    restored.undo()
    try check(reopened.note(noteID)?.pages[0].inkGroups?.first == group, "ungroup undo restores exact metadata")
    restored.redo()
    try check(reopened.note(noteID)?.pages[0].inkGroups == nil, "ungroup redo removes metadata")
    try check(restored.canvas.drawing == moved, "metadata undo and redo never change drawing")

    restoredHost.selectInk(in: moved.strokes[0].renderBounds.union(moved.strokes[1].renderBounds).insetBy(dx: -5, dy: -5))
    let beforeExport = restored.canvas.drawing.dataRepresentation()
    restored.saveSelectedInk()
    guard let exported = restored.selectedInkExport else { throw NSError(domain: "ink groups missing export", code: 1) }
    defer { if let directory = exported.urls.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: directory) } }
    try check(exported.urls.count == 2, "share exports contain editable drawing and image")
    guard let editableURL = exported.urls.first(where: { $0.pathExtension == "drawing" }),
          let imageURL = exported.urls.first(where: { $0.pathExtension == "png" }) else { throw NSError(domain: "ink groups export types", code: 1) }
    let editable = try PKDrawing(data: Data(contentsOf: editableURL))
    let image = UIImage(contentsOfFile: imageURL.path)
    try check(editable.strokes.count == 2 && editable.strokes.map(identity) == Array(originalIDs.prefix(2)), "editable export decodes and preserves selected stroke source identities")
    try check(image?.cgImage != nil && max(image!.size.width, image!.size.height) <= 2048, "PNG export decodes within bounded raster size")
    try check(restored.canvas.drawing.dataRepresentation() == beforeExport, "export leaves original ink unchanged")
    try check(NoteStore().note(noteID)?.pages[0].inkGroups == nil, "ungroup survives another store reopen")
    restored.selectedInkExport = nil

    // Old versions duplicated dates/seeds verbatim. Grouping two strokes must
    // not pull in an unselected third copy that shares the first stroke's ID.
    do {
        guard let legacyID = reopened.createNote(title: "Legacy group collision fixture", paper: .plain, cover: .blue, folderID: nil),
              let legacyNote = reopened.note(legacyID) else { throw NSError(domain: "legacy group fixture", code: 1) }
        let legacyPageID = legacyNote.pages[0].id
        defer { if reopened.flushDrawings() { reopened.permanentlyDelete(legacyID) } }
        var unrelatedCopy = original.strokes[0]
        unrelatedCopy.transform = CGAffineTransform(translationX: 0, y: 300)
        let legacyDrawing = PKDrawing(strokes: [original.strokes[0], original.strokes[1], unrelatedCopy])
        reopened.queueDrawing(legacyDrawing, noteID: legacyID, pageID: legacyPageID)
        try check(reopened.flushDrawings(), "legacy copied IDs seeded")
        let (legacySession, legacyHost, legacyController) = makeSession(store: reopened, note: legacyNote)
        defer { legacySession.stop(); withExtendedLifetime(legacyController) {} }
        guard let legacyUndo = legacySession.canvas.undoManager,
              let drawingFile = reopened.assetURL(noteID: legacyID, name: "\(legacyPageID).drawing") else { throw NSError(domain: "legacy group undo/file", code: 1) }
        legacyUndo.groupsByEvent = false
        legacyUndo.removeAllActions()
        let beforeRepair = legacySession.canvas.drawing.dataRepresentation()
        let diskBeforeRepair = try Data(contentsOf: drawingFile)
        legacyHost.selectInk(in: pairRect)
        try check(legacyHost.selectedInkIndices == [0, 1], "legacy raw selection excludes translated duplicate")

        // Make the second half of the paired write fail: drawing replacement
        // succeeds first, then the library path rejects atomic replacement.
        let libraryFile = drawingFile.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("library.json")
        let backup = libraryFile.appendingPathExtension("ink-group-fixture-backup")
        try FileManager.default.moveItem(at: libraryFile, to: backup)
        var libraryRestored = false
        defer {
            if !libraryRestored {
                try? FileManager.default.removeItem(at: libraryFile)
                try? FileManager.default.moveItem(at: backup, to: libraryFile)
                _ = reopened.flushDrawings()
            }
        }
        try FileManager.default.createDirectory(at: libraryFile, withIntermediateDirectories: false)
        legacyUndo.beginUndoGrouping(); legacySession.groupSelectedInk(); legacyUndo.endUndoGrouping()
        try check(legacySession.canvas.drawing.dataRepresentation() == beforeRepair, "failed identity repair leaves displayed original unchanged")
        try check(try Data(contentsOf: drawingFile) == diskBeforeRepair, "metadata failure rolls drawing bytes back")
        try check(reopened.note(legacyID)?.pages[0].inkGroups == nil, "failed repair creates no group metadata")
        // Foundation retains even an explicitly opened/closed empty undo group.
        // Compare with that control, then consume the test-created empty group;
        // a real registered paired operation would create a redo operation.
        let emptyControl = UndoManager()
        emptyControl.groupsByEvent = false
        emptyControl.beginUndoGrouping(); emptyControl.endUndoGrouping()
        try check(legacyUndo.canUndo == emptyControl.canUndo, "failed repair has the same undo state as an empty test group")
        if legacyUndo.canUndo { legacyUndo.undo() }
        try check(!legacyUndo.canUndo && !legacyUndo.canRedo, "failed repair registers no undoable or redoable work")
        try check(legacySession.canvas.drawing.dataRepresentation() == beforeRepair && reopened.note(legacyID)?.pages[0].inkGroups == nil, "consuming empty test group leaves originals intact")
        try check(reopened.hasUnsavedChanges && reopened.errorMessage != nil, "failed paired write retains original for retry with visible error")
        try FileManager.default.removeItem(at: libraryFile)
        try FileManager.default.moveItem(at: backup, to: libraryFile)
        libraryRestored = true
        try check(reopened.flushDrawings(), "failed repair original can be safely flushed again")
        reopened.errorMessage = nil

        legacyUndo.beginUndoGrouping(); legacySession.groupSelectedInk(); legacyUndo.endUndoGrouping()
        let repaired = legacySession.canvas.drawing
        try check(identity(repaired.strokes[0]) != identity(legacyDrawing.strokes[0]), "only colliding selected stroke receives a fresh identity")
        try check(identity(repaired.strokes[1]) == identity(legacyDrawing.strokes[1]) && identity(repaired.strokes[2]) == identity(legacyDrawing.strokes[2]), "noncolliding and unselected original identities remain unchanged")
        try check(repaired.strokes[0].randomSeed == legacyDrawing.strokes[0].randomSeed && repaired.strokes[0].transform == legacyDrawing.strokes[0].transform, "legacy repair preserves seed and geometry")
        try check(legacySession.expandedSelectionIndices(in: repaired, indices: [0]) == [0, 1], "repaired group expands to exactly selected pair")
        try check(legacySession.expandedSelectionIndices(in: repaired, indices: [2]) == [2], "unselected legacy copy never joins repaired group")
        try check(legacyHost.selectedInkIndices == [0, 1], "selection restored after successful identity repair")
        legacySession.undo()
        try check(legacySession.canvas.drawing.dataRepresentation() == beforeRepair && reopened.note(legacyID)?.pages[0].inkGroups == nil, "one undo restores both exact drawing bytes and group metadata")
        try check(!legacyUndo.canUndo, "paired grouping occupies a single undo operation")
        legacySession.redo()
        try check(legacySession.canvas.drawing == repaired && reopened.note(legacyID)?.pages[0].inkGroups?.count == 1, "one redo restores repaired drawing and group together")
        let legacyReopened = NoteStore()
        let persistedRepair = try legacyReopened.drawing(noteID: legacyID, pageID: legacyPageID)
        try check(persistedRepair.strokes.map(identity) == repaired.strokes.map(identity), "repaired identities survive reopening")
    }
    print("PASS: \(count) ink grouping/export checks (metadata/box/lasso/identity/undo/redo/reopen/editable/PNG)")
}
