import SwiftUI
import PencilKit

@MainActor
final class DrawingSession: NSObject, ObservableObject, PKCanvasViewDelegate {
    let canvas = PagingCanvasView()
    let toolPicker = PKToolPicker()
    @Published var canUndo = false
    @Published var canRedo = false
    @Published var zoomPercent = 100
    @Published var loadError: String?
    weak var host: CanvasHostView?
    private weak var store: NoteStore?
    private var noteID: UUID?
    private var pageID: UUID?
    private var loading = false
    private var undoObservers: [NSObjectProtocol] = []

    override init() {
        super.init()
        canvas.delegate = self
        canvas.backgroundColor = .clear
        canvas.isOpaque = false
        canvas.isScrollEnabled = false
        canvas.overrideUserInterfaceStyle = .light
        canvas.tool = PKInkingTool(.pen, color: .black, width: 3)
        canvas.drawingPolicy = .pencilOnly
        toolPicker.addObserver(canvas)
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange, .NSUndoManagerDidCloseUndoGroup] {
            undoObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.refreshUndo() }
            })
        }
    }

    deinit { for observer in undoObservers { NotificationCenter.default.removeObserver(observer) } }

    func load(noteID: UUID, pageID: UUID, store: NoteStore) {
        guard self.noteID != noteID || self.pageID != pageID else { return }
        store.flushDrawings()
        self.store = store
        self.noteID = noteID
        self.pageID = pageID
        loading = true
        loadError = nil
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
        loading = false
        refreshUndo()
    }

    func canvasViewDrawingDidChange(_ canvasView: PKCanvasView) {
        guard !loading, loadError == nil, let noteID, let pageID else { return }
        store?.queueDrawing(canvasView.drawing, noteID: noteID, pageID: pageID)
        // Undo groups close at the end of the current event.
        DispatchQueue.main.async { [weak self] in self?.refreshUndo() }
    }

    func refreshUndo() {
        canUndo = canvas.undoManager?.canUndo ?? false
        canRedo = canvas.undoManager?.canRedo ?? false
    }
    func undo() { canvas.undoManager?.undo(); refreshUndo() }
    func redo() { canvas.undoManager?.redo(); refreshUndo() }
    func fitPage() { host?.fitPage(animated: true) }

    func setToolsVisible(_ visible: Bool) {
        toolPicker.setVisible(visible, forFirstResponder: canvas)
        if visible && canvas.window != nil { canvas.becomeFirstResponder() }
        else if !visible { canvas.resignFirstResponder() }
    }

    func stop() { store?.flushDrawings(); setToolsVisible(false) }
}

final class PagingCanvasView: PKCanvasView {
    var pageTurningEnabled = false
    // The canvas owns three-finger paging; toolbar undo/redo remain available.
    override var editingInteractionConfiguration: UIEditingInteractionConfiguration {
        pageTurningEnabled ? .none : .default
    }
}
