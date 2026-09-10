import SwiftUI
import PencilKit
import PhotosUI

private enum EditorSheet: String, Identifiable {
    case pages, settings, text, objects, share
    var id: String { rawValue }
}

struct EditorView: View {
    let noteID: UUID
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @StateObject private var session = DrawingSession()
    @AppStorage("fingerDrawing") private var fingerDrawing = false
    @State private var selectedPageID: UUID?
    @State private var editingObjects = false
    @State private var selectedElementID: UUID?
    @State private var sheet: EditorSheet?
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var sharingURLs: [URL] = []
    @State private var exporting = false
    @State private var showingDeletePage = false
    @State private var importingPhoto = false
    @State private var showingSwipeHint = true

    private var note: Notebook? { store.note(noteID) }
    private var page: NotePage? { note?.pages.first { $0.id == selectedPageID } ?? note?.pages.first }
    private var pageIndex: Int { note?.pages.firstIndex { $0.id == page?.id } ?? 0 }

    var body: some View {
        Group {
            if let note, let page {
                VStack(spacing: 0) {
                    if editingObjects {
                        HStack {
                            Label("텍스트·사진을 탭해서 선택하고 끌어서 이동하세요", systemImage: "hand.draw")
                                .font(.callout).foregroundStyle(.secondary)
                            Spacer()
                            Button("항목 편집") { sheet = .objects }
                            Button("완료") { editingObjects = false; selectedElementID = nil }.bold()
                        }.padding(.horizontal, 20).padding(.vertical, 12).background(.bar)
                    }
                    AIEditorCanvas(note: note, page: page, session: session, store: store,
                                   fingerDrawing: fingerDrawing, editingObjects: editingObjects,
                                   toolsVisible: sheet == nil && !choosingPhoto,
                                   onTurnPage: { goToPage(pageIndex + $0) },
                                   onSelectElement: { selectedElementID = $0 },
                                   onMoveElement: { id, x, y in
                        store.updatePage(noteID: noteID, pageID: page.id) { page in
                            guard let index = page.elements.firstIndex(where: { $0.id == id }) else { return }
                            page.elements[index].x = x; page.elements[index].y = y
                        }
                    })
                    .overlay {
                        if let error = session.loadError {
                            ContentUnavailableView("필기를 불러올 수 없습니다", systemImage: "exclamationmark.triangle", description: Text(error))
                                .background(.regularMaterial)
                        }
                    }
                    .overlay(alignment: .top) {
                        if showingSwipeHint && note.pages.count > 1 && !page.isContinuousPDF && !editingObjects {
                            Label("세 손가락으로  ← 다음 · 이전 →", systemImage: "hand.draw")
                                .font(.caption).padding(.horizontal, 16).padding(.vertical, 10)
                                .background(.regularMaterial, in: Capsule()).padding(.top, 12)
                                .allowsHitTesting(false)
                        }
                    }
                    HStack(spacing: 18) {
                        Button { goToPage(pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                            .disabled(pageIndex == 0).accessibilityLabel("이전 페이지")
                        Button { sheet = .pages } label: {
                            Text("\(pageIndex + 1) / \(note.pages.count)").monospacedDigit()
                        }.accessibilityLabel("\(note.pages.count)페이지 중 \(pageIndex + 1)페이지, 페이지 관리")
                        Button { goToPage(pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                            .disabled(pageIndex == note.pages.count - 1).accessibilityLabel("다음 페이지")
                        if note.pages.count > 1 && !page.isContinuousPDF {
                            Button { showingSwipeHint.toggle() } label: { Image(systemName: "hand.draw") }
                                .accessibilityLabel("세 손가락 페이지 넘김 안내")
                        }
                        Spacer()
                        Button { store.flushDrawings() } label: {
                            Label(store.hasUnsavedChanges ? "저장 중…" : "저장됨", systemImage: store.hasUnsavedChanges ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                                .foregroundStyle(.secondary)
                        }.accessibilityHint("탭하면 저장을 다시 시도합니다")
                        Button("\(session.zoomPercent)%") { session.fitPage() }.monospacedDigit().accessibilityLabel("용지에 맞게 확대 비율 초기화")
                    }
                    .font(.caption).buttonStyle(.plain).frame(minHeight: 44).padding(.horizontal, 24).background(.bar)
                }
                .navigationTitle(note.title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { editorToolbar(note: note, page: page) }
                .task(id: note.id) {
                    showingSwipeHint = true
                    do { try await Task.sleep(for: .seconds(6)) } catch { return }
                    showingSwipeHint = false
                }
                .onAppear { session.load(noteID: noteID, pageID: page.id, store: store) }
                .onChange(of: page.id) { _, id in
                    selectedElementID = nil
                    session.load(noteID: noteID, pageID: id, store: store)
                }
                .sheet(item: $sheet) { value in
                    switch value {
                    case .pages:
                        PageManagerView(noteID: noteID, selectedPageID: page.id) { selectedPageID = $0 }
                    case .settings: NotebookForm(existing: note)
                    case .text:
                        ElementForm(element: PageElement(kind: .text, width: min(400, page.width - 80), height: min(200, page.height - 80)), page: page) { element in
                            store.updatePage(noteID: noteID, pageID: page.id) { $0.elements.append(element) }
                        }
                    case .objects: ObjectManagerView(noteID: noteID, pageID: page.id, selectedID: selectedElementID)
                    case .share: ShareSheet(urls: sharingURLs)
                    }
                }
                .alert("이 페이지를 삭제할까요?", isPresented: $showingDeletePage) {
                    Button("취소", role: .cancel) { }
                    Button("페이지 삭제", role: .destructive) {
                        store.deletePage(noteID: noteID, pageID: page.id)
                    }
                } message: { Text("페이지의 필기와 삽입한 항목을 복원할 수 없습니다.") }
            } else {
                ContentUnavailableView("노트를 찾을 수 없습니다", systemImage: "book.closed")
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
            }
        }
        .interactiveDismissDisabled(store.hasUnsavedChanges)
        .onDisappear { session.stop() }
        .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item, let pageID = page?.id else { return }
            importingPhoto = true
            Task { @MainActor in
                defer { importingPhoto = false; photoItem = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                    store.addImage(data, noteID: noteID, pageID: pageID)
                } catch { store.errorMessage = "사진을 가져오지 못했습니다. \(error.localizedDescription)" }
            }
        }
        .overlay {
            if exporting || importingPhoto {
                ProgressView(exporting ? "내보내는 중…" : "사진 가져오는 중…")
                    .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .alert("작업을 완료하지 못했습니다", isPresented: Binding(get: { store.errorMessage != nil && sheet == nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("확인", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    @ToolbarContentBuilder private func editorToolbar(note: Notebook, page: NotePage) -> some ToolbarContent {
        ToolbarItem(placement: .topBarLeading) {
            Button { if store.flushDrawings() { session.stop(); dismiss() } } label: { Label("보관함", systemImage: "chevron.left") }
        }
        ToolbarItemGroup(placement: .topBarLeading) {
            Button { session.undo() } label: { Label("실행 취소", systemImage: "arrow.uturn.backward") }
                .disabled(!session.canUndo || editingObjects).keyboardShortcut("z", modifiers: .command)
            Button { session.redo() } label: { Label("다시 실행", systemImage: "arrow.uturn.forward") }
                .disabled(!session.canRedo || editingObjects).keyboardShortcut("z", modifiers: [.command, .shift])
        }
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button { sheet = .pages } label: { Label("페이지", systemImage: "rectangle.stack") }
            Menu {
                Button("텍스트 추가", systemImage: "textformat") { sheet = .text }
                Button("사진 추가", systemImage: "photo") { choosingPhoto = true }
                Divider()
                Button("텍스트·사진 이동", systemImage: "cursorarrow.and.square.on.square.dashed") { editingObjects.toggle() }
                Button("텍스트·사진 편집", systemImage: "slider.horizontal.3") { sheet = .objects }
                Divider()
                Menu("페이지 추가", systemImage: "doc.badge.plus") {
                    ForEach(PaperStyle.allCases) { paper in
                        Button(paper.title) {
                            if let id = store.addPage(noteID: noteID, after: page.id, paper: paper) { selectedPageID = id }
                        }
                    }
                }
            } label: { Label("삽입", systemImage: "plus") }
            Menu {
                Button("노트 전체를 PDF로 공유", systemImage: "doc.richtext") { export(asPDF: true) }
                Button("현재 페이지를 이미지로 공유", systemImage: "photo") { export(asPDF: false) }
            } label: { Label("공유", systemImage: "square.and.arrow.up") }.disabled(exporting)
            Menu {
                Toggle("손가락으로도 필기", isOn: $fingerDrawing)
                Button("화면에 용지 맞추기", systemImage: "arrow.down.right.and.arrow.up.left") { session.fitPage() }
                if page.pdfRegions.isEmpty {
                    Picker("용지 변경", selection: Binding(get: { page.paper }, set: { paper in
                        store.updatePage(noteID: noteID, pageID: page.id) { $0.paper = paper }
                    })) { ForEach(PaperStyle.allCases) { Text($0.title).tag($0) } }
                }
                Divider()
                Button("노트 이름 및 표지", systemImage: "book.closed") { sheet = .settings }
                Button(note.isFavorite ? "즐겨찾기 해제" : "즐겨찾기", systemImage: "star") { store.updateNote(noteID) { $0.isFavorite.toggle() } }
                Button("페이지 복제", systemImage: "plus.square.on.square") {
                    if let id = store.duplicatePage(noteID: noteID, pageID: page.id) { selectedPageID = id }
                }
                Button("페이지 삭제", systemImage: "trash", role: .destructive) { showingDeletePage = true }.disabled(note.pages.count <= 1)
            } label: { Label("더 보기", systemImage: "ellipsis.circle") }
        }
    }

    @discardableResult
    private func goToPage(_ index: Int) -> Bool {
        guard let note, note.pages.indices.contains(index), store.flushDrawings() else { return false }
        selectedPageID = note.pages[index].id
        return true
    }

    private func export(asPDF: Bool) {
        guard store.flushDrawings(), let note, let page else { return }
        exporting = true
        Task { @MainActor in
            await Task.yield()
            defer { exporting = false }
            do {
                let url: URL
                if asPDF { url = try ExportService.exportPDF(note: note, store: store) }
                else { url = try ExportService.exportPNG(note: note, page: page, store: store) }
                sharingURLs = [url]
                sheet = .share
            } catch { store.errorMessage = "내보내지 못했습니다. \(error.localizedDescription)" }
        }
    }
}
