import SwiftUI

/// The AI UI floats over the existing viewport. Opening a chat does not resize
/// the PencilKit document or replace its drawing, zoom or scroll position.
struct AIEditorCanvas: View {
    let note: Notebook
    let page: NotePage
    @ObservedObject var session: DrawingSession
    @ObservedObject var store: NoteStore
    let fingerDrawing: Bool
    let editingObjects: Bool
    let toolsVisible: Bool
    let onTurnPage: (Int) -> Bool
    let onSelectElement: (UUID?) -> Void
    let onMoveElement: (UUID, Double, Double) -> Void
    var editorControlsInset: CGFloat = 0
    var toolObstacles: [CGRect] = []
    var onOverlayVisibilityChange: (Bool) -> Void = { _ in }
    var summarySelection: Binding<Bool> = .constant(false)
    var onSummaryRegion: (CGRect) -> Void = { _ in }
    @ObservedObject private var ai = MarginAIStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selecting = false
    @State private var selection: CGRect?
    @State private var transform = CGAffineTransform.identity
    @State private var activeChatID: UUID?
    @State private var showingHistory = false
    @State private var sourceFocus: (pageID: UUID, rect: CGRect)?
    @State private var captureTarget: UUID?
    @State private var choosingTarget = false
    private var noteHistory: [MarginConversation] { ai.conversations.filter { $0.noteID == note.id } }
    private var noteChats: [MarginConversation] { ai.conversations.filter { $0.belongs(to: note) } }

    private var overlayActive: Bool { selecting || summarySelection.wrappedValue || activeChatID != nil || showingHistory || choosingTarget }

    private var pageChats: [MarginConversation] { ai.conversations.filter { $0.noteID == note.id && $0.pageID == page.id } }

    var body: some View {
        GeometryReader { geometry in
            NotebookCanvas(note: note, page: page, session: session, store: store,
                           fingerDrawing: fingerDrawing, editingObjects: editingObjects,
                           toolsVisible: toolsVisible && activeChatID == nil && !selecting && !summarySelection.wrappedValue && !showingHistory,
                           onTurnPage: onTurnPage, onSelectElement: onSelectElement, onMoveElement: onMoveElement,
                           selectingRegion: selecting || summarySelection.wrappedValue, onRegionChange: { selection = $0 },
                           onViewportChange: { next, _ in
                               if !pageChats.isEmpty && transform != next { transform = next }
                               if let focus = sourceFocus, focus.pageID == page.id {
                                   sourceFocus = nil
                                   session.canvas.zoom(to: focus.rect.offsetBy(dx: session.canvasOrigin.x,dy: session.canvasOrigin.y), animated: true)
                               }
                           })
            .overlay {
                if toolsVisible && activeChatID == nil && !selecting && !summarySelection.wrappedValue && !showingHistory && !editingObjects && session.loadError == nil {
                    DockedDrawingTools(session: session, obstacles: toolObstacles)
                }
            }
            .overlay {
                if !selecting && !summarySelection.wrappedValue && !editingObjects {
                    ForEach(Array(pageChats.filter { $0.belongs(to: note) }.enumerated()), id: \.element.id) { index, chat in
                        let anchor = CGPoint(x: chat.rect.midX, y: chat.rect.midY).applying(transform)
                        if anchor.y >= 60 && anchor.y <= geometry.size.height - 24 {
                            Button { toggle(chat.id) } label: {
                                ZStack(alignment: .bottomTrailing) {
                                    Circle().fill(activeChatID == chat.id ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
                                    Image(systemName: ai.sending.contains(chat.id) ? "ellipsis" : "sparkles")
                                        .foregroundStyle(activeChatID == chat.id ? Color(uiColor: .systemBackground) : Color.accentColor)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    Text("\(index + 1)").font(.system(size: 9, weight: .bold)).padding(3)
                                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: Circle()).offset(x: 2, y: 2)
                                }.frame(width: 40, height: 40).shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            }
                            .buttonStyle(.plain).toolObstacle().position(x: geometry.size.width - 25, y: anchor.y)
                            .accessibilityLabel("여백 대화 \(index + 1): \(chat.title)")
                            .accessibilityIdentifier("ai-margin-pin-\(index)")
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if !editingObjects {
                    if selecting || summarySelection.wrappedValue {
                        VStack(alignment: .leading, spacing: 8) {
                            Text(summarySelection.wrappedValue ? "모서리를 끌어 요약할 영역을 조절하세요" : "모서리를 끌어 질문할 영역을 조절하세요").font(.caption).foregroundStyle(.primary)
                            HStack {
                                Button("취소") { selecting = false; summarySelection.wrappedValue = false; selection = nil }.foregroundStyle(.primary)
                                Button(summarySelection.wrappedValue ? "이 영역 요약" : (captureTarget == nil ? "이 영역으로 질문" : "현재 문제에 추가")) { if summarySelection.wrappedValue { if let selection { summarySelection.wrappedValue = false; onSummaryRegion(selection) } } else if captureTarget != nil || noteChats.isEmpty { capture() } else { choosingTarget = true } }.buttonStyle(.borderedProminent).foregroundStyle(Color(uiColor: .systemBackground))
                                    .disabled(selection == nil).accessibilityIdentifier("ai-region-confirm")
                                    .popover(isPresented: $choosingTarget) { captureDestinationPicker }
                            }
                        }.padding(12)
                            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(12)
                    } else {
                        HStack(spacing: 10) {
                            Button {
                                session.host?.cancelStrokeErasing()
                                activeChatID = nil; captureTarget = nil; selection = nil; selecting = true
                            } label: { Label("질문", systemImage: "sparkles").font(.subheadline.weight(.medium)) }
                                .accessibilityIdentifier("ai-question-start").disabled(session.loadError != nil)
                            if !noteHistory.isEmpty {
                                Divider().frame(height: 18)
                                Button { showingHistory = true } label: { Image(systemName: "bubble.left.and.bubble.right") }
                                    .accessibilityLabel("이 노트의 문제별 AI 대화 목록")
                                    .popover(isPresented: $showingHistory) {
                                        List(noteHistory) { chat in
                                            Button { showingHistory = false; activeChatID = chat.id } label: {
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text(chat.title).lineLimit(2).foregroundStyle(.primary)
                                                    Text(chat.belongs(to: note) ? chat.projectTitle : "이전 프로젝트 · \(chat.projectTitle)")
                                                        .font(.caption).foregroundStyle(.secondary)
                                                }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 6)
                                            }.buttonStyle(.plain)
                                                .listRowBackground(Color(uiColor: .secondarySystemGroupedBackground))
                                        }.scrollContentBackground(.hidden)
                                            .background(Color(uiColor: .systemGroupedBackground))
                                            .presentationBackground(Color(uiColor: .systemGroupedBackground))
                                            .frame(minWidth: 280, idealWidth: 320, minHeight: 200, idealHeight: 340)
                                    }
                            }
                        }.padding(.horizontal, 14).padding(.vertical, 10)
                            .foregroundStyle(.primary)
                            .background(.regularMaterial, in: Capsule()).toolObstacle().padding(12)
                            .padding(.top, overlayActive ? 0 : editorControlsInset)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if let id = activeChatID, !selecting, !editingObjects {
                    ChatGPTMarginView(conversationID: id, project: note.projectID.flatMap { store.project($0) }, onClose: { activeChatID = nil }, onSave: { text in
                        let source = selection ?? ai.conversation(id)?.rect
                        let element = PageElement(kind: .text, text: text, x: page.isInfinite ? Double(source?.minX ?? 24) : 24, y: page.isInfinite ? Double(source?.maxY ?? 100) : max(24, min(page.height - 200, selection?.maxY ?? 100)), width: min(600, page.width - 48), height: 180, fontSize: 18)
                        store.setAIElement(noteID: note.id, pageID: page.id, element: element, present: true, undoManager: session.undoManager)
                        session.refreshUndo()
                    }, onAttach: {
                        session.host?.cancelStrokeErasing()
                        captureTarget = id; activeChatID = nil; selection = nil; selecting = true
                    }, onSource: {
                        if let chat = ai.conversation(id) {
                            activeChatID = nil
                            let rect = chat.rect.insetBy(dx: -24, dy: -24)
                            if let target = note.pages.firstIndex(where: { $0.id == chat.pageID }), let current = note.pages.firstIndex(where: { $0.id == page.id }), target != current {
                                sourceFocus = (chat.pageID, rect)
                                if !onTurnPage(target - current) { sourceFocus = nil }
                            } else { session.canvas.zoom(to: rect, animated: true) }
                        }
                    })
                        .id(id)
                        .frame(width: max(180, min(620, geometry.size.width - 72)), height: max(180, geometry.size.height - 68))
                        .padding(.trailing, 54).padding(.top, 54)
                }
            }
        }
        .onAppear { ai.load(noteID: note.id) }
        .onChange(of: pageChats.map(\.id)) { _, _ in
            if let viewport = session.host?.documentToViewport { transform = viewport }
        }
        .onChange(of: overlayActive, initial: true) { _, active in onOverlayVisibilityChange(active) }
        .onDisappear {
            ai.flushDrafts(noteID: note.id)
            onOverlayVisibilityChange(false)
        }
        .onChange(of: scenePhase) { _, phase in if phase != .active { ai.flushDrafts(noteID: note.id) } }
        .onChange(of: page.id) { _, _ in selecting = false; selection = nil; activeChatID = nil; showingHistory = false; choosingTarget = false }
        .onChange(of: editingObjects) { _, editing in if editing { selecting = false; activeChatID = nil } }
        .onChange(of: note.projectID) { _, _ in selecting = false; activeChatID = nil }
        .alert("AI 대화를 처리하지 못했습니다", isPresented: Binding(get: { ai.errorMessage != nil }, set: { if !$0 { ai.errorMessage = nil } })) {
            Button("확인", role: .cancel) { ai.errorMessage = nil }
        } message: { Text(ai.errorMessage ?? "") }
    }

    private var captureDestinationPicker: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("대화 선택").font(.headline).foregroundStyle(.primary)
                Spacer()
                Button { choosingTarget = false } label: {
                    Image(systemName: "xmark").font(.subheadline.weight(.semibold))
                        .foregroundStyle(.secondary).frame(width: 36, height: 36)
                        .background(Color(uiColor: .tertiarySystemFill), in: Circle())
                }.buttonStyle(.plain).accessibilityLabel("대화 선택 닫기")
            }.padding(.horizontal, 16).padding(.top, 12).padding(.bottom, 8)
            Text("선택한 영역을 새 대화 또는 기존 대화에 추가합니다.")
                .font(.subheadline).foregroundStyle(.secondary)
                .padding(.horizontal, 16).padding(.bottom, 16)
            ScrollView {
                VStack(spacing: 8) {
                    Button {
                        choosingTarget = false; captureTarget = nil; capture()
                    } label: {
                        captureDestinationRow(title: "새 문제", detail: "새 대화 시작", symbol: "plus.bubble")
                    }
                    .buttonStyle(.plain).accessibilityLabel("새 문제")
                    .accessibilityIdentifier("ai-capture-new-conversation")
                    ForEach(noteChats) { chat in
                        let sending = ai.sending.contains(chat.id)
                        Button {
                            choosingTarget = false; captureTarget = chat.id; capture()
                        } label: {
                            captureDestinationRow(title: chat.title,
                                                  detail: sending ? "답변 생성 중" : "현재 문제에 추가",
                                                  symbol: sending ? "ellipsis.bubble" : "bubble.left.and.bubble.right")
                        }
                        .buttonStyle(.plain).disabled(sending)
                        .accessibilityLabel("현재 문제에 추가: " + String(chat.title.prefix(48)))
                        .accessibilityIdentifier("ai-capture-existing-" + chat.id.uuidString)
                    }
                }.padding(.horizontal, 12).padding(.bottom, 12)
            }
        }
        .frame(width: 340, height: min(460, CGFloat(noteChats.count + 1) * 88 + 118))
        .background(Color(uiColor: .systemGroupedBackground))
        .presentationBackground(Color(uiColor: .systemGroupedBackground))
        .presentationCompactAdaptation(.popover)
        .accessibilityIdentifier("ai-capture-destination-picker")
    }

    private func captureDestinationRow(title: String, detail: String, symbol: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: symbol).font(.title3).foregroundStyle(.primary).frame(width: 28)
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.body.weight(.medium)).foregroundStyle(.primary).lineLimit(2)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }.frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        }
        .padding(14).frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .contentShape(RoundedRectangle(cornerRadius: 12))
    }

    private func toggle(_ id: UUID) { activeChatID = activeChatID == id ? nil : id }
    private func capture() {
        guard let selection, store.flushDrawings(), session.loadError == nil else { return }
        do {
            let region = try RegionContextService.capture(note: note, page: page, drawing: session.drawing, store: store, rect: selection)
            if let target = captureTarget {
                if ai.addCapture(region, to: target, note: note) { selecting = false; activeChatID = target; captureTarget = nil }
            } else if let id = ai.create(note: note, project: note.projectID.flatMap { store.project($0) }, region: region) {
                selecting = false; activeChatID = id
            }
        } catch { ai.errorMessage = "선택 영역을 준비하지 못했습니다. \(error.localizedDescription)" }
    }
}
