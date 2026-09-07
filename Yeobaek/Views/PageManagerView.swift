import SwiftUI

struct PageManagerView: View {
    let noteID: UUID
    let selectedPageID: UUID
    var onSelect: (UUID) -> Void
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var deleteTarget: UUID?
    private var note: Notebook? { store.note(noteID) }

    var body: some View {
        NavigationStack {
            List {
                if let note {
                    ForEach(Array(note.pages.enumerated()), id: \.element.id) { index, page in
                        Button {
                            onSelect(page.id)
                            dismiss()
                        } label: {
                            HStack(spacing: 20) {
                                PageThumbnail(note: note, page: page).frame(width: 68, height: 92)
                                VStack(alignment: .leading, spacing: 6) {
                                    Text("\(index + 1)페이지").font(.headline).foregroundStyle(.primary)
                                    Text(page.pdfPageIndex == nil ? page.paper.title : "PDF 페이지").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedPageID == page.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                            }.padding(.vertical, 6)
                        }
                        .contextMenu {
                            Button("복제", systemImage: "plus.square.on.square") { _ = store.duplicatePage(noteID: noteID, pageID: page.id) }
                            Button("삭제", systemImage: "trash", role: .destructive) { deleteTarget = page.id }.disabled(note.pages.count <= 1)
                        }
                        .swipeActions {
                            Button("삭제", role: .destructive) { deleteTarget = page.id }.disabled(note.pages.count <= 1)
                        }
                    }
                    .onMove { source, destination in
                        store.updateNote(noteID) { $0.pages.move(fromOffsets: source, toOffset: destination) }
                    }
                }
            }
            .navigationTitle("페이지")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("완료") { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Menu {
                        ForEach(PaperStyle.allCases) { paper in
                            Button(paper.title) {
                                if let id = store.addPage(noteID: noteID, after: nil, paper: paper) { onSelect(id); dismiss() }
                            }
                        }
                    } label: { Label("페이지 추가", systemImage: "plus") }
                }
            }
            .alert("이 페이지를 삭제할까요?", isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
                Button("취소", role: .cancel) { }
                Button("페이지 삭제", role: .destructive) {
                    if let id = deleteTarget { store.deletePage(noteID: noteID, pageID: id) }
                }
            } message: { Text("페이지의 필기와 삽입한 항목을 복원할 수 없습니다.") }
            .storeErrorAlert()
        }
    }
}

struct PageThumbnail: View {
    let note: Notebook
    let page: NotePage
    @EnvironmentObject private var store: NoteStore
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFit() }
            else if failed { Image(systemName: "exclamationmark.triangle").foregroundStyle(.secondary) }
            else { ProgressView() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.white)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay { RoundedRectangle(cornerRadius: 4).stroke(.black.opacity(0.08), lineWidth: 1) }
        .accessibilityHidden(true)
        .task(id: note.updatedAt) {
            do {
                let drawing = try store.drawing(noteID: note.id, pageID: page.id)
                image = PageRenderer.snapshot(page: page, note: note, drawing: drawing, store: store, width: 160)
            } catch { failed = true }
        }
    }
}
