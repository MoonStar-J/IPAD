import UIKit
import PencilKit

@MainActor func checkEditorViewport(_ store: NoteStore) throws {
    func check(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        try PDFIntegrationChecks.check(condition(), "editor viewport: " + message)
    }
    let note = try PDFIntegrationChecks.pageSwapFixture(store)
    let session = DrawingSession()
    let host = CanvasHostView(session: session)
    session.host = host
    host.frame = CGRect(x: 0, y: 0, width: 820, height: 1_000)
    session.load(noteID: note.id, pageID: note.pages[0].id, store: store)
    defer { session.stop() }
    let source = session.canvas.drawing.dataRepresentation()
    // UIScrollView aligns its settled contentOffset to display pixels.
    let pixelTolerance = 1 / max(1, UIScreen.main.scale) + 0.001
    func configure(_ page: NotePage) {
        host.configure(note: note, page: page, store: store, fingerDrawing: false,
                       editingObjects: false, toolsVisible: true, onSelect: { _ in },
                       onMove: { _, _, _ in }, onTurnPage: { _ in false })
        host.layoutIfNeeded()
    }
    configure(note.pages[0])
    try check(!session.canvas.bouncesZoom, "minimum-scale pinch has no elastic zoom rebound")
    let fit = session.canvas.zoomScale
    session.canvas.zoomScale = fit * 2
    session.canvas.contentOffset = CGPoint(x: 700, y: 900)
    for step in 0...60 {
        let scale = fit * (2 - 1.5 * CGFloat(step) / 60)
        session.canvas.setZoomScale(scale, animated: false)
        host.canvasDidZoom()
        let displayed = CGRect(x: 0, y: 0, width: note.pages[0].width, height: note.pages[0].height)
            .applying(host.documentToViewport)
        try "step=\(step) requested=\(scale) actual=\(session.canvas.zoomScale) canvas=\(session.canvas.bounds) host=\(host.bounds) inset=\(session.canvas.contentInset) offset=\(session.canvas.contentOffset) page=\(displayed)".write(to: PDFIntegrationChecks.directory.appendingPathComponent("viewport-centering.txt"), atomically: true, encoding: .utf8)
        if displayed.width + 48 <= host.bounds.width {
            try check(abs(displayed.midX - host.bounds.midX) <= pixelTolerance, "fitting horizontal axis is centered during each zoom callback")
        }
        if displayed.height + 48 <= host.bounds.height {
            try check(abs(displayed.midY - host.bounds.midY) <= pixelTolerance, "fitting vertical axis is centered during each zoom callback")
        }
        try check(host.backgroundViewportTransform == host.documentToViewport, "paper and native ink share every intermediate zoom position")
    }
    let settled = host.documentToViewport
    for _ in 0..<20 { host.setNeedsLayout(); host.layoutIfNeeded(); host.canvasDidZoom() }
    try check(host.documentToViewport == settled, "minimum overview does not drift during repeated layout and zoom callbacks")
    try check(abs(session.canvas.zoomScale - fit * 0.5) < 0.001, "half-fit overview remains available")

    // A stitched PDF can keep scrolling vertically while the horizontal axis
    // fits. Never center the long document's entire height or allow a stale
    // offset beyond the bottom of its scaled content.
    var longPage = note.pages[0]
    longPage.id = UUID(); longPage.height = 80_000; longPage.pdfSegments = []
    configure(longPage)
    let longFit = session.canvas.zoomScale
    session.canvas.zoomScale = longFit * 0.5
    session.canvas.contentOffset = CGPoint(x: 5_000, y: 90_000)
    host.canvasDidZoom()
    let transform = host.documentToViewport
    try check(abs(longPage.width * transform.a / 2 + transform.tx - host.bounds.midX) <= pixelTolerance,
              "long PDF stays horizontally centered at minimum zoom")
    let maxOffset = longPage.height * session.canvas.zoomScale - host.bounds.height + session.canvas.contentInset.bottom
    try check(abs(session.canvas.contentOffset.y - maxOffset) <= pixelTolerance, "long PDF clamps stale bottom offset without a spring-back")
    try check(session.canvas.drawing.dataRepresentation() == source, "viewport updates never mutate ink source")
}
