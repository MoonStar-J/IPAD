import SwiftUI
import PencilKit
import PhotosUI

private enum EditorSheet: String, Identifiable {
    case pages, settings, text, objects, share, summary, exportSelection
    var id: String { rawValue }
}

struct EditorView: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    let noteID: UUID
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var session = DrawingSession()
    @AppStorage("fingerDrawing") private var fingerDrawing = false
    @State private var toolObstacles: [CGRect] = []
    @State private var selectedPageID: UUID?
    @State private var editingObjects = false
    @State private var selectedElementID: UUID?
    @State private var sheet: EditorSheet?
    @State private var photoItem: PhotosPickerItem?
    @State private var choosingPhoto = false
    @State private var sharingURLs: [URL] = []
    @State private var exporting = false
    @State private var exportTask: Task<Void, Never>?
    @State private var exportProgress = AppMessage("준비 중…")
    @State private var exportChoices: [SummarySource] = []
    @State private var showingDeletePage = false
    @State private var importingPhoto = false
    @State private var showingSwipeHint = true
    @State private var aiOverlayActive = false
    @StateObject private var summaryDraft = NoteSummaryDraft()
    @State private var selectingSummary = false
    @State private var summaryRegion: CGRect?
    @State private var pendingSummaryID: UUID?
    @State private var openedSummary: NoteRoute?

    private var note: Notebook? { store.note(noteID) }
    private var page: NotePage? { note?.pages.first { $0.id == selectedPageID } ?? note?.pages.first }
    private var pageIndex: Int { note?.pages.firstIndex { $0.id == page?.id } ?? 0 }

    var body: some View {
        Group {
            if note?.summary != nil {
                SummaryReaderView(noteID: noteID, service: store.summaries)
            } else if let note, let page {
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
                }, editorControlsInset: 64, toolObstacles: toolObstacles,
                   onOverlayVisibilityChange: { aiOverlayActive = $0 },
                   summarySelection: $selectingSummary, onSummaryRegion: { rect in
                    summaryRegion = rect; sheet = .summary
                })
                .overlay {
                    if let error = session.loadError {
                        ContentUnavailableView(localized("필기를 불러올 수 없습니다", language: appLanguage), systemImage: "exclamationmark.triangle", description: Text(error.text))
                            .background(.regularMaterial)
                    }
                }
                .overlay(alignment: .top) {
                    if !aiOverlayActive && showingSwipeHint && note.pages.count > 1 && !page.isContinuousPDF && !editingObjects {
                        Label(localized("세 손가락으로  ← 다음 · 이전 →", language: appLanguage), systemImage: "hand.draw")
                            .font(.caption).padding(.horizontal, 16).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule()).padding(.vertical, 64)
                            .allowsHitTesting(false)
                    }
                }
                .overlay(alignment: .top) {
                    if !aiOverlayActive {
                        VStack(spacing: 8) {
                            editorHeader(note: note, page: page)
                            if editingObjects {
                                HStack(spacing: 12) {
                                    Text(localized("텍스트·사진을 선택해 이동", language: appLanguage)).font(.caption).foregroundStyle(.secondary)
                                    Button(localized("항목 편집", language: appLanguage)) { sheet = .objects }
                                    Button(localized("완료", language: appLanguage)) { editingObjects = false; selectedElementID = nil }.bold()
                                }
                                .font(.subheadline).padding(.horizontal, 14).frame(minHeight: 44)
                                .modifier(EditorFloatingSurface()).toolObstacle()
                            }
                        }
                        .padding(.horizontal, 12).padding(.top, 12)
                    }
                }
                .overlay(alignment: .bottomLeading) {
                    if !aiOverlayActive {
                        pageControls(note: note, page: page)
                            .padding(.horizontal, 12).padding(.bottom, 12)
                    }
                }
                .overlayPreferenceValue(ToolObstacleKey.self) { anchors in
                    GeometryReader { geometry in
                        let frames = anchors.map { geometry[$0] }
                        Color.clear.onAppear { toolObstacles = frames }
                            .onChange(of: frames) { _, value in if toolObstacles != value { toolObstacles = value } }
                    }.allowsHitTesting(false)
                }
                .toolbar(.hidden, for: .navigationBar)
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
                .allowsHitTesting(!exporting)
                .sheet(item: $sheet, onDismiss: {
                    if let id = pendingSummaryID { pendingSummaryID = nil; openedSummary = NoteRoute(id: id) }
                }) { value in
                    switch value {
                    case .pages:
                        PageManagerView(noteID: noteID, selectedPageID: page.id) { selectedPageID = $0 }
                    case .settings: NotebookForm(existing: note)
                    case .text:
                        let center = page.isInfinite ? session.host?.visibleDocumentCenter : nil
                        ElementForm(element: PageElement(kind: .text, x: center.map { Double($0.x)-200 } ?? 40, y: center.map { Double($0.y)-100 } ?? 40, width: min(400, page.width - 80), height: min(200, page.height - 80)), page: page) { element in
                            store.updatePage(noteID: noteID, pageID: page.id) { $0.elements.append(element) }
                        }
                    case .objects: ObjectManagerView(noteID: noteID, pageID: page.id, selectedID: selectedElementID)
                    case .share: ShareSheet(urls: sharingURLs)
                    case .exportSelection:
                        PDFExportSelection(note: note, choices: exportChoices, exporting: exporting, progress: exportProgress, error: $store.errorMessage, cancel: { exportTask?.cancel() }) { export(asPDF: true, selection: $0) }
                    case .summary:
                        NoteSummaryComposer(noteID: noteID, service: store.summaries, draft: summaryDraft, selectedRegion: summaryRegion, selectRegion: {
                            sheet = nil; editingObjects = false; selectedElementID = nil
                            session.host?.cancelStrokeErasing(); selectingSummary = true
                        }, open: { id in pendingSummaryID = id; sheet = nil })
                    }
                }
                .alert(localized("이 페이지를 삭제할까요?", language: appLanguage), isPresented: $showingDeletePage) {
                    Button(localized("취소", language: appLanguage), role: .cancel) { }
                    Button(localized("페이지 삭제", language: appLanguage), role: .destructive) {
                        store.deletePage(noteID: noteID, pageID: page.id)
                    }
                } message: { Text(localized("페이지의 필기와 삽입한 항목을 복원할 수 없습니다.", language: appLanguage)) }
            } else {
                ContentUnavailableView {
                    Label(localized("노트를 찾을 수 없습니다", language: appLanguage), systemImage: "book.closed")
                } actions: { Button(localized("닫기", language: appLanguage)) { dismiss() } }
            }
        }
        .toolbar(note?.summary == nil ? .hidden : .visible, for: .navigationBar)
        .fullScreenCover(item: $openedSummary) { route in
            NavigationStack { SummaryReaderView(noteID: route.id, service: store.summaries) }.environmentObject(store)
        }
        .background(Color(uiColor: .secondarySystemBackground))
        .interactiveDismissDisabled(store.hasUnsavedChanges)
        .onDisappear { exportTask?.cancel(); session.stop() }
        .onChange(of: scenePhase) { _, phase in if phase != .active { session.host?.saveViewport() } }
        .photosPicker(isPresented: $choosingPhoto, selection: $photoItem, matching: .images)
        .onChange(of: photoItem) { _, item in
            guard let item, let pageID = page?.id else { return }
            let center = session.host?.visibleDocumentCenter
            importingPhoto = true
            Task { @MainActor in
                defer { importingPhoto = false; photoItem = nil }
                do {
                    guard let data = try await item.loadTransferable(type: Data.self) else { throw CocoaError(.fileReadCorruptFile) }
                    store.addImage(data, noteID: noteID, pageID: pageID, center: center)
                } catch { store.errorMessage = AppMessage("사진을 가져오지 못했습니다. %@", error: error) }
            }
        }
        .overlay {
            if exporting || importingPhoto {
                VStack(spacing: 16) {
                    ProgressView(exporting ? exportProgress.text : localized("사진 가져오는 중…", language: appLanguage))
                    if exporting { Button(localized("내보내기 취소", language: appLanguage)) { exportTask?.cancel() } }
                }
                    .padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
            }
        }
        .alert(localized("작업을 완료하지 못했습니다", language: appLanguage), isPresented: Binding(get: { store.errorMessage != nil && sheet == nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(localized("확인", language: appLanguage), role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage?.text ?? "") }
    }

    private func editorHeader(note: Notebook, page: NotePage) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                HStack(spacing: 0) {
                    backButton
                    Text(note.title).font(.subheadline.weight(.medium)).lineLimit(1)
                        .frame(maxWidth: 180, alignment: .leading).padding(.trailing, 14)
                        .accessibilityIdentifier("editor-note-title")
                }.modifier(EditorFloatingSurface()).toolObstacle()
                Spacer(minLength: 10)
                HStack(spacing: 0) { editorActionButtons(note: note, page: page) }
                    .modifier(EditorFloatingSurface()).toolObstacle()
            }
            HStack {
                backButton.modifier(EditorFloatingSurface()).toolObstacle()
                Spacer()
                Text(note.title).font(.subheadline.weight(.medium)).lineLimit(1)
                Spacer()
                Menu { editorActionButtons(note: note, page: page) } label: {
                    Label(localized("노트 도구", language: appLanguage), systemImage: "ellipsis")
                }.modifier(EditorFloatingSurface()).toolObstacle()
            }
        }
        .labelStyle(.iconOnly).buttonStyle(EditorControlButtonStyle())
        .foregroundStyle(.primary)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor-floating-header")
    }

    private var backButton: some View {
        Button { if store.flushDrawings() { session.stop(); dismiss() } } label: {
            Label(localized("보관함", language: appLanguage), systemImage: "chevron.left")
        }.accessibilityIdentifier("editor-library-back")
    }

    private func pageControls(note: Notebook, page: NotePage) -> some View {
        HStack(spacing: 0) {
            if !page.isInfinite { Button { goToPage(pageIndex - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(pageIndex == 0).accessibilityLabel(localized("이전 페이지", language: appLanguage))
            Button { sheet = .pages } label: {
                Text("\(pageIndex + 1) / \(note.pages.count)").monospacedDigit().fixedSize()
            }.accessibilityLabel(localized("%@페이지 중 %@페이지, 페이지 관리", "\(note.pages.count)", "\(pageIndex + 1)", language: appLanguage))
            Button { goToPage(pageIndex + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(pageIndex == note.pages.count - 1).accessibilityLabel(localized("다음 페이지", language: appLanguage))
            Divider().frame(height: 18).padding(.horizontal, 6) }
            else { Text(localized("무한 캔버스", language: appLanguage)).padding(.horizontal, 8) }
            Button("\(session.zoomPercent)%") { session.fitPage() }
                .monospacedDigit().accessibilityLabel(localized("용지에 맞게 확대 비율 초기화", language: appLanguage))
                .accessibilityValue("\(session.zoomPercent)%").accessibilityIdentifier("editor-zoom")
        }
        .font(.caption).buttonStyle(EditorControlButtonStyle()).foregroundStyle(.primary)
        .padding(.horizontal, 4).modifier(EditorFloatingSurface()).toolObstacle()
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("editor-page-controls")
    }

    @ViewBuilder private func editorActionButtons(note: Notebook, page: NotePage) -> some View {
        Button { session.undo() } label: { Label(localized("실행 취소", language: appLanguage), systemImage: "arrow.uturn.backward") }
            .disabled(!session.canUndo || editingObjects).keyboardShortcut("z", modifiers: .command)
        Button { session.redo() } label: { Label(localized("다시 실행", language: appLanguage), systemImage: "arrow.uturn.forward") }
            .disabled(!session.canRedo || editingObjects).keyboardShortcut("z", modifiers: [.command, .shift])
        if !page.isInfinite { Button { sheet = .pages } label: { Label(localized("페이지", language: appLanguage), systemImage: "rectangle.stack") } }
        Menu {
            Button(localized("텍스트 추가", language: appLanguage), systemImage: "textformat") { sheet = .text }
            Button(localized("사진 추가", language: appLanguage), systemImage: "photo") { choosingPhoto = true }
            Divider()
            Button(localized("텍스트·사진 이동", language: appLanguage), systemImage: "cursorarrow.and.square.on.square.dashed") { editingObjects.toggle() }
            Button(localized("텍스트·사진 편집", language: appLanguage), systemImage: "slider.horizontal.3") { sheet = .objects }
            Divider()
            if !page.isInfinite { Menu(localized("페이지 추가", language: appLanguage), systemImage: "doc.badge.plus") {
                ForEach(PaperStyle.allCases) { paper in
                    Button(localized(paper.title, language: appLanguage)) {
                        if let id = store.addPage(noteID: noteID, after: page.id, paper: paper) { selectedPageID = id }
                    }
                }
            } }
        } label: { Label(localized("삽입", language: appLanguage), systemImage: "plus") }
        Menu {
            Button(localized("노트 전체를 PDF로 공유", language: appLanguage), systemImage: "doc.richtext") { export(asPDF: true) }
            Button(localized("선택한 페이지를 PDF로 내보내기", language: appLanguage), systemImage: "doc.on.doc") {
                guard store.flushDrawings() else { return }
                do { exportChoices = try ExportService.pageChoices(note: note, store: store); sheet = .exportSelection }
                catch { store.errorMessage = AppMessage(error) }
            }
            Button(localized("현재 페이지를 이미지로 공유", language: appLanguage), systemImage: "photo") { export(asPDF: false) }
        } label: { Label(localized("공유", language: appLanguage), systemImage: "square.and.arrow.up") }.disabled(exporting)
        Button { if store.flushDrawings() { sheet = .summary } } label: { Label(localized("요약", language: appLanguage), systemImage: "text.alignleft") }
            .accessibilityIdentifier("editor-summary")
        Menu {
            AppearancePicker()
            LanguagePicker()
            Toggle(localized("손가락으로도 필기", language: appLanguage), isOn: $fingerDrawing)
            if note.pages.count > 1 && !page.isContinuousPDF {
                Button(localized("세 손가락 페이지 넘김 안내", language: appLanguage), systemImage: "hand.draw") { showingSwipeHint.toggle() }
            }
            Button(localized("지금 저장", language: appLanguage), systemImage: "square.and.arrow.down") { store.flushDrawings() }
                .accessibilityIdentifier("note-save-now")
            Button(page.isInfinite ? localized("필기 위치로 돌아가기", language: appLanguage) : localized("화면에 용지 맞추기", language: appLanguage), systemImage: "arrow.down.right.and.arrow.up.left") { session.fitPage() }
            if page.pdfRegions.isEmpty {
                Picker(localized("용지 변경", language: appLanguage), selection: Binding(get: { page.paper }, set: { paper in
                    store.updatePage(noteID: noteID, pageID: page.id) { $0.paper = paper }
                })) { ForEach(PaperStyle.allCases) { Text(localized($0.title, language: appLanguage)).tag($0) } }
            }
            Divider()
            Button(localized("노트 이름 및 표지", language: appLanguage), systemImage: "book.closed") { sheet = .settings }
            Button(note.isFavorite ? localized("즐겨찾기 해제", language: appLanguage) : localized("즐겨찾기", language: appLanguage), systemImage: "star") { store.updateNote(noteID) { $0.isFavorite.toggle() } }
            Button(localized("페이지 복제", language: appLanguage), systemImage: "plus.square.on.square") {
                if let id = store.duplicatePage(noteID: noteID, pageID: page.id) { selectedPageID = id }
            }
            Button(localized("페이지 삭제", language: appLanguage), systemImage: "trash", role: .destructive) { showingDeletePage = true }.disabled(note.pages.count <= 1)
        } label: { Label(localized("더 보기", language: appLanguage), systemImage: "ellipsis.circle") }
    }

    @discardableResult
    private func goToPage(_ index: Int) -> Bool {
        guard let note, note.pages.indices.contains(index), store.flushDrawings() else { return false }
        selectedPageID = note.pages[index].id
        return true
    }

    private func export(asPDF: Bool, selection: Set<String>? = nil) {
        guard store.flushDrawings(), let note, let page else { return }
        exporting = true; exportProgress = AppMessage("준비 중…")
        exportTask = Task { @MainActor in
            await Task.yield()
            defer { exporting = false; exportTask = nil }
            do {
                let url: URL
                if asPDF { url = try await ExportService.exportPDF(note: note, store: store, selection: selection) { done, total in exportProgress = AppMessage("내보내는 중 · %@ / %@페이지", "\(done)", "\(total)") } }
                else { url = try ExportService.exportPNG(note: note, page: page, store: store) }
                sharingURLs = [url]
                sheet = .share
            } catch is CancellationError {
            } catch { store.errorMessage = AppMessage("내보내지 못했습니다. %@", error: error) }
        }
    }
}

private struct EditorFloatingSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.primary.opacity(0.10), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.06), radius: 4, y: 2)
    }
}

private struct EditorControlButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(minWidth: 44, minHeight: 44)
            .background(configuration.isPressed ? Color.primary.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .opacity(isEnabled ? 1 : 0.35)
    }
}
