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
    @ObservedObject private var ai = MarginAIStore.shared
    @Environment(\.scenePhase) private var scenePhase
    @State private var selecting = false
    @State private var selection: CGRect?
    @State private var transform = CGAffineTransform.identity
    @State private var activeChatID: UUID?
    @State private var showingHistory = false

    private var pageChats: [MarginConversation] { ai.conversations.filter { $0.noteID == note.id && $0.pageID == page.id } }

    var body: some View {
        GeometryReader { geometry in
            NotebookCanvas(note: note, page: page, session: session, store: store,
                           fingerDrawing: fingerDrawing, editingObjects: editingObjects,
                           toolsVisible: toolsVisible && activeChatID == nil && !selecting && !showingHistory,
                           onTurnPage: onTurnPage, onSelectElement: onSelectElement, onMoveElement: onMoveElement,
                           selectingRegion: selecting, onRegionChange: { selection = $0 },
                           onViewportChange: { transform = $0; _ = $1 })
            .overlay {
                if !selecting && !editingObjects {
                    ForEach(Array(pageChats.filter { $0.belongs(to: note) }.enumerated()), id: \.element.id) { index, chat in
                        let anchor = CGPoint(x: chat.rect.midX, y: chat.rect.midY).applying(transform)
                        if anchor.y >= 60 && anchor.y <= geometry.size.height - 24 {
                            Button { toggle(chat.id) } label: {
                                ZStack(alignment: .bottomTrailing) {
                                    Circle().fill(activeChatID == chat.id ? Color.accentColor : Color(uiColor: .secondarySystemBackground))
                                    Image(systemName: ai.sending.contains(chat.id) ? "ellipsis" : "sparkles")
                                        .foregroundStyle(activeChatID == chat.id ? Color.white : Color.accentColor)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                    Text("\(index + 1)").font(.system(size: 9, weight: .bold)).padding(3)
                                        .background(.regularMaterial, in: Circle()).offset(x: 2, y: 2)
                                }.frame(width: 40, height: 40).shadow(color: .black.opacity(0.12), radius: 3, y: 1)
                            }
                            .buttonStyle(.plain).position(x: geometry.size.width - 25, y: anchor.y)
                            .accessibilityLabel("여백 대화 \(index + 1): \(chat.title)")
                            .accessibilityIdentifier("ai-margin-pin-\(index)")
                        }
                    }
                }
            }
            .overlay(alignment: .topLeading) {
                if !editingObjects {
                    if selecting {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("모서리를 끌어 질문할 영역을 조절하세요").font(.caption)
                            HStack {
                                Button("취소") { selecting = false; selection = nil }
                                Button("이 영역으로 질문") { capture() }.buttonStyle(.borderedProminent)
                                    .disabled(selection == nil).accessibilityIdentifier("ai-region-confirm")
                            }
                        }.padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)).padding(12)
                    } else {
                        HStack(spacing: 10) {
                            Button {
                                session.host?.cancelStrokeErasing()
                                activeChatID = nil; selection = nil; selecting = true
                            } label: { Label("질문", systemImage: "sparkles").font(.subheadline.weight(.medium)) }
                                .accessibilityIdentifier("ai-question-start").disabled(session.loadError != nil)
                            if !pageChats.isEmpty {
                                Divider().frame(height: 18)
                                Button { showingHistory = true } label: { Image(systemName: "bubble.left.and.bubble.right") }
                                    .accessibilityLabel("이 페이지의 AI 대화 목록")
                                    .popover(isPresented: $showingHistory) {
                                        List(pageChats) { chat in
                                            Button { showingHistory = false; activeChatID = chat.id } label: {
                                                VStack(alignment: .leading, spacing: 5) {
                                                    Text(chat.title).lineLimit(2)
                                                    Text(chat.belongs(to: note) ? chat.projectTitle : "이전 프로젝트 · \(chat.projectTitle)")
                                                        .font(.caption).foregroundStyle(.secondary)
                                                }
                                            }
                                        }.frame(minWidth: 280, idealWidth: 320, minHeight: 200, idealHeight: 340)
                                    }
                            }
                        }.padding(.horizontal, 14).padding(.vertical, 10)
                            .background(.regularMaterial, in: Capsule()).padding(12)
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                if let id = activeChatID, !selecting, !editingObjects {
                    MarginChatView(conversationID: id, note: note, project: note.projectID.flatMap { store.project($0) }, onClose: { activeChatID = nil })
                        .id(id)
                        .frame(width: max(180, min(410, geometry.size.width - 72)), height: max(180, min(650, geometry.size.height - 68)))
                        .padding(.trailing, 54).padding(.top, 54)
                }
            }
        }
        .onAppear { ai.load(noteID: note.id) }
        .onDisappear { ai.flushDrafts(noteID: note.id) }
        .onChange(of: scenePhase) { _, phase in if phase != .active { ai.flushDrafts(noteID: note.id) } }
        .onChange(of: page.id) { _, _ in selecting = false; selection = nil; activeChatID = nil }
        .onChange(of: editingObjects) { _, editing in if editing { selecting = false; activeChatID = nil } }
        .onChange(of: note.projectID) { _, _ in selecting = false; activeChatID = nil }
        .alert("AI 대화를 처리하지 못했습니다", isPresented: Binding(get: { ai.errorMessage != nil }, set: { if !$0 { ai.errorMessage = nil } })) {
            Button("확인", role: .cancel) { ai.errorMessage = nil }
        } message: { Text(ai.errorMessage ?? "") }
    }

    private func toggle(_ id: UUID) { activeChatID = activeChatID == id ? nil : id }
    private func capture() {
        guard let selection, store.flushDrawings(), session.loadError == nil else { return }
        do {
            let region = try RegionContextService.capture(note: note, page: page, drawing: session.canvas.drawing, store: store, rect: selection)
            if let id = ai.create(note: note, project: note.projectID.flatMap { store.project($0) }, region: region) {
                selecting = false; activeChatID = id
            }
        } catch { ai.errorMessage = "선택 영역을 준비하지 못했습니다. \(error.localizedDescription)" }
    }
}
