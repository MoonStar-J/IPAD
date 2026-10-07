import SwiftUI
import PencilKit

/// Preferences exercise the same DrawingSession as the app, isolated from both
/// the user's installed app and other integration fixture preferences.
@MainActor func checkInkToolPreferences() throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        try PDFIntegrationChecks.check(condition(), "ink tool preferences: " + message)
    }
    let suite = "noteMargin.inkTools.tests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let session = DrawingSession(preferences: defaults)
    try check(session.selectedTool == .pen && session.inkWidth == 3,
              "new preferences retain the original default pen")
    session.inkWidth = 0.35
    session.inkColor = InkPalette.color("164B95")
    session.rulerActive = true
    session.applyTool()
    try check(abs(((session.canvas.tool as? PKInkingTool)?.width ?? 99) - 0.35) < 0.0001,
              "initial fine pen applies its configured width to native ink")
    session.selectTool(.pencil)
    session.inkWidth = 2.1; session.inkColor = InkPalette.color("7A193C"); session.rulerActive = false
    session.applyTool()
    session.selectTool(.marker)
    session.inkWidth = 6.4; session.inkColor = InkPalette.color("E29600"); session.rulerActive = false
    session.applyTool()
    session.selectTool(.pen)
    try check(session.inkWidth == 0.35 && InkPalette.hex(session.inkColor) == "164B95" && session.rulerActive,
              "switching back restores that pen's own width color and ruler")
    session.selectTool(.lasso)
    session.selectTool(.pixelEraser)
    let independentWidth = session.eraserWidthRange.lowerBound + (session.eraserWidthRange.upperBound - session.eraserWidthRange.lowerBound) * 0.37
    session.eraserWidth = independentWidth; session.applyTool()
    try check((session.canvas.tool as? PKEraserTool)?.eraserType == .fixedWidthBitmap,
              "partial mode uses native fixed-width erasing")
    try check(abs(((session.canvas.tool as? PKEraserTool)?.width ?? -1) - session.eraserWidth) < 0.0001,
              "partial eraser's displayed width equals the actual native tool width")
    session.inkWidth = 11
    session.applyTool()
    try check(session.eraserWidth == independentWidth && abs(((session.canvas.tool as? PKEraserTool)?.width ?? -1) - independentWidth) < 0.0001,
              "eraser width is independent of the previous pen width")
    session.finishErasing()
    try check(session.selectedTool == .pen && session.inkWidth == 0.35 && InkPalette.hex(session.inkColor) == "164B95" && session.rulerActive,
              "erasing returns to the exact last ink state even through a selection tool")
    try check(session.lastEraserTool == .pixelEraser && session.lastSelectionTool == .lasso,
              "automatic pen return preserves both option choices")
    session.selectTool(.marker)
    let reopened = DrawingSession(preferences: defaults)
    try check(reopened.selectedTool == .marker && reopened.inkWidth == 6.4 && InkPalette.hex(reopened.inkColor) == "E29600",
              "a new note/session restores the last ink type width and color")
    try check(abs(((reopened.canvas.tool as? PKInkingTool)?.width ?? -1) - 6.4 * 4) < 0.0001,
              "restored marker settings immediately reach the native canvas")
    try check(reopened.lastEraserTool == .pixelEraser && reopened.lastSelectionTool == .lasso && reopened.eraserWidth == independentWidth,
              "new sessions restore eraser mode independent width and selection shape")
    reopened.selectTool(.pencil)
    try check(reopened.inkWidth == 2.1 && InkPalette.hex(reopened.inkColor) == "7A193C" && !reopened.rulerActive,
              "pencil has its own persisted preferences")
    reopened.selectTool(.pen)
    try check(reopened.inkWidth == 0.35 && reopened.rulerActive, "pen settings survive closing and reopening a note")
    for mode in [InkTool.eraser, .pixelEraser] {
        reopened.selectTool(mode)
        reopened.eraserWidth = reopened.eraserWidthRange.upperBound + 500
        reopened.applyTool()
        try check(reopened.eraserWidth == reopened.eraserWidthRange.upperBound,
                  "\(mode.rawValue) width clamps to its supported upper bound")
        if mode == .pixelEraser {
            try check(abs(((reopened.canvas.tool as? PKEraserTool)?.width ?? -1) - reopened.eraserWidth) < 0.0001,
                      "partial width matches native width at the upper bound")
        } else {
            try check(reopened.eraserWidthRange == 4...80 &&
                      (reopened.canvas.tool as? PKEraserTool)?.eraserType == .vector,
                      "whole-stroke width is independent of PencilKit's zero-width vector tool")
            let points = [CGPoint(x: 10, y: 20), CGPoint(x: 20, y: 20), CGPoint(x: 30, y: 20)]
                .enumerated().map { index, point in
                    PKStrokePoint(location: point, timeOffset: Double(index), size: CGSize(width: 2, height: 2),
                                  opacity: 1, force: 1, azimuth: 0, altitude: .pi / 2)
                }
            let drawing = PKDrawing(strokes: [PKStroke(ink: PKInk(.pen, color: .black),
                path: PKStrokePath(controlPoints: points, creationDate: Date(timeIntervalSince1970: 0)))])
            let transaction = StrokeEraserTransaction(drawing: drawing, width: reopened.eraserWidth)
            try check(transaction.width == 80, "whole-stroke transaction preserves the selected document-space width")
            transaction.extend(to: CGPoint(x: 20, y: 0))
            let small = StrokeEraserTransaction(drawing: drawing, width: reopened.eraserWidthRange.lowerBound)
            small.extend(to: CGPoint(x: 20, y: 0))
            try check(transaction.erasedIndices == [0] && small.erasedIndices.isEmpty && drawing.strokes.count == 1,
                      "whole-stroke width changes the erasing footprint while preserving the source drawing")
        }
        reopened.eraserWidth = -.infinity
        reopened.applyTool()
        try check(reopened.eraserWidth.isFinite && reopened.eraserWidthRange.contains(reopened.eraserWidth),
                  "\(mode.rawValue) invalid width recovers to a valid setting")
        if mode == .pixelEraser {
            try check(abs(((reopened.canvas.tool as? PKEraserTool)?.width ?? -1) - reopened.eraserWidth) < 0.0001,
                      "invalid partial width recovers without a UI/native mismatch")
        }
    }
    let keys = Set(defaults.persistentDomain(forName: suite)?.keys.map { $0 } ?? [])
    try check(keys == [DrawingSession.preferencesKey], "only one device-local tool settings namespace is written")
    guard let data = defaults.data(forKey: DrawingSession.preferencesKey),
          var payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          var brushes = payload["brushes"] as? [String: [String: Any]],
          var pen = brushes[InkTool.pen.rawValue] else {
        throw NSError(domain: "missing ink preference fixture data", code: 1)
    }
    payload["lastInk"] = "unknown-future-tool"
    pen["width"] = -500; brushes[InkTool.pen.rawValue] = pen; payload["brushes"] = brushes
    defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: DrawingSession.preferencesKey)
    let repaired = DrawingSession(preferences: defaults)
    try check(repaired.selectedTool == .pen && repaired.inkWidth == 0.1,
              "unrecognized tool and invalid stored width recover independently")
    defaults.set(Data("invalid settings".utf8), forKey: DrawingSession.preferencesKey)
    let recovered = DrawingSession(preferences: defaults)
    try check(recovered.selectedTool == .pen && recovered.inkWidth == 3,
              "malformed settings cannot block opening a note")
}
