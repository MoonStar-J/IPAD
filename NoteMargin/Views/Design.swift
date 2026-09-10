import SwiftUI

extension CoverColor {
    var color: Color {
        switch self {
        case .blue: return Color(red: 0.31, green: 0.45, blue: 0.64)
        case .sage: return Color(red: 0.43, green: 0.55, blue: 0.47)
        case .sand: return Color(red: 0.69, green: 0.57, blue: 0.41)
        case .rose: return Color(red: 0.65, green: 0.44, blue: 0.46)
        case .graphite: return Color(red: 0.34, green: 0.37, blue: 0.41)
        }
    }
}

struct NoteCover: View {
    let note: Notebook
    var body: some View {
        ZStack(alignment: .leading) {
            RoundedRectangle(cornerRadius: 12).fill(note.cover.color.gradient)
            Rectangle().fill(.black.opacity(0.09)).frame(width: 14).padding(.leading, 10)
            VStack(alignment: .leading, spacing: 12) {
                Image(systemName: note.pdfAssetName == nil ? "book.closed" : "doc.richtext")
                    .font(.title2.weight(.light)).opacity(0.85)
                Spacer()
                Text(note.title).font(.system(.title3, design: .serif).weight(.medium)).lineLimit(3)
                Text(note.pdfAssetName == nil ? "NOTEBOOK" : "PDF NOTEBOOK")
                    .font(.system(size: 9, weight: .semibold, design: .rounded)).tracking(2).opacity(0.7)
            }
            .foregroundStyle(.white).padding(24).padding(.leading, 10)
        }
        .aspectRatio(0.78, contentMode: .fit)
        .overlay(alignment: .topTrailing) {
            if note.isFavorite {
                Image(systemName: "star.fill").font(.caption).foregroundStyle(.white.opacity(0.9)).padding(14)
            }
        }
        .shadow(color: note.cover.color.opacity(0.15), radius: 8, x: 0, y: 5)
        .accessibilityHidden(true)
    }
}

struct NotebookForm: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var store: NoteStore
    var existing: Notebook?
    var folderID: UUID?
    var projectID: UUID?
    var onCreated: (UUID) -> Void = { _ in }
    @State private var title = ""
    @State private var paper: PaperStyle = .ruled
    @State private var cover: CoverColor = .blue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        NoteCover(note: Notebook(title: title.trimmedOrUntitled, cover: cover))
                            .frame(width: 138).padding(.vertical, 10)
                        Spacer()
                    }.listRowBackground(Color.clear)
                }
                Section("노트 이름") { TextField("제목 없는 노트", text: $title).submitLabel(.done) }
                Section("표지 색상") {
                    HStack(spacing: 20) {
                        ForEach(CoverColor.allCases) { value in
                            Button { cover = value } label: {
                                Circle().fill(value.color).frame(width: 38, height: 38)
                                    .overlay { if value == cover { Image(systemName: "checkmark").foregroundStyle(.white).bold() } }
                                    .frame(minWidth: 44, minHeight: 44)
                            }.buttonStyle(.plain).accessibilityLabel(value.title)
                                .accessibilityAddTraits(value == cover ? .isSelected : [])
                        }
                    }.frame(maxWidth: .infinity)
                }
                if existing == nil {
                    Section("첫 페이지 용지") {
                        Picker("용지", selection: $paper) {
                            ForEach(PaperStyle.allCases) { Text($0.title).tag($0) }
                        }.pickerStyle(.segmented)
                    }
                }
            }
            .navigationTitle(existing == nil ? "새로운 노트" : "노트 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(existing == nil ? "만들기" : "완료") {
                        if let existing {
                            if store.updateNote(existing.id, { $0.title = title.trimmedOrUntitled; $0.cover = cover }) { dismiss() }
                        } else if let id = store.createNote(title: title, paper: paper, cover: cover, folderID: folderID, projectID: projectID) {
                            dismiss()
                            onCreated(id)
                        }
                    }.bold()
                }
            }
            .onAppear { if let existing { title = existing.title; cover = existing.cover } }
        }
        .presentationDetents([.large])
        .storeErrorAlert()
    }
}

struct StoreErrorAlert: ViewModifier {
    @EnvironmentObject private var store: NoteStore
    func body(content: Content) -> some View {
        content.alert("작업을 완료하지 못했습니다", isPresented: Binding(
            get: { store.errorMessage != nil },
            set: { if !$0 { store.errorMessage = nil } }
        )) {
            Button("확인", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }
}

extension View {
    func storeErrorAlert() -> some View { modifier(StoreErrorAlert()) }
}
