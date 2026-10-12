import SwiftUI

struct PageManagerView: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
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
                                    Text(localized("%@페이지", "\(index + 1)", language: appLanguage)).font(.headline).foregroundStyle(.primary)
                                    Text(page.isContinuousPDF ? localized("PDF %@페이지 연결됨", "\(page.pdfRegions.count)", language: appLanguage) : (page.pdfRegions.isEmpty ? page.paper.title : localized("PDF 페이지", language: appLanguage))).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if selectedPageID == page.id { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                            }.padding(.vertical, 6)
                        }
                        .contextMenu {
                            Button(localized("복제", language: appLanguage), systemImage: "plus.square.on.square") { _ = store.duplicatePage(noteID: noteID, pageID: page.id) }
                            Button(localized("삭제", language: appLanguage), systemImage: "trash", role: .destructive) { deleteTarget = page.id }.disabled(note.pages.count <= 1)
                        }
                        .swipeActions {
                            Button(localized("삭제", language: appLanguage), role: .destructive) { deleteTarget = page.id }.disabled(note.pages.count <= 1)
                        }
                    }
                    .onMove { source, destination in
                        store.updateNote(noteID) { $0.pages.move(fromOffsets: source, toOffset: destination) }
                    }
                }
            }
            .navigationTitle(localized("페이지", language: appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(localized("완료", language: appLanguage)) { dismiss() } }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    EditButton()
                    Menu {
                        ForEach(PaperStyle.allCases) { paper in
                            Button(localized(paper.title, language: appLanguage)) {
                                if let id = store.addPage(noteID: noteID, after: nil, paper: paper) { onSelect(id); dismiss() }
                            }
                        }
                    } label: { Label(localized("페이지 추가", language: appLanguage), systemImage: "plus") }
                }
            }
            .alert(localized("이 페이지를 삭제할까요?", language: appLanguage), isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } })) {
                Button(localized("취소", language: appLanguage), role: .cancel) { }
                Button(localized("페이지 삭제", language: appLanguage), role: .destructive) {
                    if let id = deleteTarget { store.deletePage(noteID: noteID, pageID: id) }
                }
            } message: { Text(localized("페이지의 필기와 삽입한 항목을 복원할 수 없습니다.", language: appLanguage)) }
            .storeErrorAlert()
        }
    }
}

struct PageThumbnail: View {
    let note: Notebook
    let page: NotePage
    var region: CGRect? = nil
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
                let width = region?.width ?? CGFloat(page.width)
                let height = region?.height ?? CGFloat(page.height)
                image = PageRenderer.snapshot(page: page, note: note, drawing: drawing, store: store, width: min(160, 2048 * width / max(width, height)), rect: region)
            } catch { failed = true }
        }
    }
}
