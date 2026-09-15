import SwiftUI
import UniformTypeIdentifiers

struct NoteRoute: Identifiable { let id: UUID }

struct LibraryView: View {
    @EnvironmentObject private var store: NoteStore
    @State private var selection: LibraryFilter? = .all
    @State private var query = ""
    @State private var sort: NoteSort = .modified
    @State private var creatingNote = false
    @State private var importingPDF = false
    @State private var importing = false
    @State private var pendingPDF: PreparedPDFImport?
    @State private var importedNoteID: UUID?
    @State private var deferredImport: PreparedPDFImport?
    @State private var route: NoteRoute?
    @State private var createdNoteID: UUID?
    @State private var editingNote: Notebook?
    @State private var folderPrompt = false
    @State private var folderTitle = ""
    @State private var editingFolder: NoteFolder?
    @State private var deletingNote: Notebook?
    @State private var deletingFolder: NoteFolder?
    @State private var editingProject: NoteProject?
    @State private var creatingProject = false
    @State private var deletingProject: NoteProject?
    @State private var connectingAI = false

    private var filter: LibraryFilter { selection ?? .all }
    private var title: String {
        switch filter {
        case .all: return "모든 노트"
        case .favorites: return "즐겨찾기"
        case .trash: return "최근 삭제된 항목"
        case .unassigned: return "프로젝트 미지정"
        case .project(let id): return store.project(id)?.title ?? "프로젝트"
        case .folder(let id): return store.library.folders.first { $0.id == id }?.title ?? "폴더"
        }
    }
    private var currentFolderID: UUID? { if case .folder(let id) = filter { return id }; return nil }
    private var currentProjectID: UUID? { if case .project(let id) = filter { return id }; return nil }
    private var notes: [Notebook] { store.library.notes(in: filter, query: query, sort: sort) }

    var body: some View {
        Group {
            if let error = store.loadingError {
                ContentUnavailableView {
                    Label("보관함을 열 수 없습니다", systemImage: "externaldrive.badge.exclamationmark")
                } description: { Text(error) } actions: { Button("다시 시도") { store.loadLibrary() } }
            } else {
                NavigationSplitView {
                    List(selection: $selection) {
                        Section {
                            sidebarRow("모든 노트", icon: "square.grid.2x2", filter: .all)
                            sidebarRow("즐겨찾기", icon: "star", filter: .favorites)
                        }
                        Section("프로젝트") {
                            ForEach(store.library.projects) { project in
                                sidebarRow(project.title, icon: "square.stack.3d.up", filter: .project(project.id))
                                    .contextMenu {
                                        Button("프로젝트 · 에이전트 설정", systemImage: "slider.horizontal.3") { editingProject = project }
                                        Button("프로젝트 삭제", systemImage: "trash", role: .destructive) { deletingProject = project }
                                    }
                            }
                            sidebarRow("프로젝트 미지정", icon: "tray", filter: .unassigned)
                            Button { creatingProject = true } label: { Label("새 프로젝트", systemImage: "plus") }
                        }
                        Section("폴더") {
                            ForEach(store.library.folders) { folder in
                                sidebarRow(folder.title, icon: "folder", filter: .folder(folder.id))
                                    .contextMenu {
                                        Button("이름 변경", systemImage: "pencil") {
                                            editingFolder = folder; folderTitle = folder.title; folderPrompt = true
                                        }
                                        Button("폴더 삭제", systemImage: "trash", role: .destructive) { deletingFolder = folder }
                                    }
                            }
                            Button { editingFolder = nil; folderTitle = ""; folderPrompt = true } label: {
                                Label("새로운 폴더", systemImage: "folder.badge.plus")
                            }
                        }
                        Section { sidebarRow("최근 삭제된 항목", icon: "trash", filter: .trash) }
                        Section { Button { connectingAI = true } label: { Label(AppBuild.aiConnectionTitle, systemImage: "sparkles") } }
                    }
                    .navigationTitle(AppIdentity.displayName)
                    .safeAreaInset(edge: .bottom) {
                        Label("이 iPad에 저장됨", systemImage: "internaldrive")
                            .font(.caption).foregroundStyle(.secondary).padding()
                    }
                    .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 300)
                } detail: {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 28) {
                                if filter != .trash && query.isEmpty {
                                    VStack(alignment: .leading, spacing: 8) {
                                        Text(currentProjectID == nil ? "생각이 머무는 곳." : title).font(.system(.largeTitle, design: .serif))
                                        Text("가볍게 펼치고, 자유롭게 기록하세요.").font(.subheadline).foregroundStyle(.secondary)
                                    }.padding(.top, 12)
                                }
                                HStack {
                                    Text("\(notes.count)개의 노트").font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Menu {
                                        Picker("정렬", selection: $sort) { ForEach(NoteSort.allCases) { Text($0.label).tag($0) } }
                                    } label: { Label(sort.label, systemImage: "arrow.up.arrow.down").font(.subheadline) }
                                }
                                if notes.isEmpty { emptyState.padding(.vertical, 48) }
                                else {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 28)], alignment: .leading, spacing: 32) {
                                        ForEach(notes) { note in
                                            VStack(alignment: .leading, spacing: 0) {
                                                Button {
                                                    route = NoteRoute(id: note.id)
                                                } label: {
                                                VStack(alignment: .leading, spacing: 12) {
                                                    NoteCover(note: note)
                                                    Text(note.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                                    HStack(spacing: 4) {
                                                        Text("\(note.pages.count)페이지")
                                                        Text("·")
                                                        Text(note.updatedAt, style: .date)
                                                    }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                                }.contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                                .disabled(filter == .trash)
                                                .accessibilityLabel("\(note.title), \(note.pages.count)페이지")
                                                if filter == .trash {
                                                    HStack {
                                                        Button("복원", systemImage: "arrow.uturn.backward") { store.restore(note.id) }
                                                        Spacer()
                                                        Button(role: .destructive) { deletingNote = note } label: { Image(systemName: "trash") }
                                                            .accessibilityLabel("\(note.title) 영구 삭제")
                                                    }.font(.subheadline).buttonStyle(.bordered).padding(.top, 12)
                                                }
                                            }
                                            .contextMenu { noteActions(note) }
                                        }
                                    }
                                }
                            }.padding(32).frame(maxWidth: 1300, alignment: .leading).frame(maxWidth: .infinity)
                        }
                        .background(Color(uiColor: .systemGroupedBackground))
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                        .searchable(text: $query, prompt: "노트 이름 또는 입력한 텍스트 검색")
                        .toolbar {
                            if filter != .trash {
                                ToolbarItemGroup(placement: .topBarTrailing) {
                                    if let id = currentProjectID, let project = store.project(id) {
                                        Button { editingProject = project } label: { Label("프로젝트 설정", systemImage: "slider.horizontal.3") }
                                    }
                                    Button { importingPDF = true } label: { Label("PDF 가져오기", systemImage: "square.and.arrow.down") }
                                    Button { creatingNote = true } label: { Label("새로운 노트", systemImage: "square.and.pencil") }
                                        .keyboardShortcut("n", modifiers: .command)
                                }
                            }
                        }
                        .overlay { if importing { ProgressView("PDF 가져오는 중…").padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } }
                    }
                }
            }
        }
        .sheet(isPresented: $creatingNote, onDismiss: {
            if let id = createdNoteID { route = NoteRoute(id: id); createdNoteID = nil }
        }) { NotebookForm(folderID: currentFolderID, projectID: currentProjectID, onCreated: { createdNoteID = $0 }) }
        .sheet(isPresented: $creatingProject) { ProjectForm() }
        .sheet(item: $editingProject) { ProjectForm(existing: $0) }
        .sheet(isPresented: $connectingAI) {
            #if PERSONAL_CHATGPT
            PersonalChatGPTView(conversationID: nil, project: nil)
            #else
            AIConnectionSettingsView()
            #endif
        }
        .alert("프로젝트를 삭제할까요?", isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } })) {
            Button("취소", role: .cancel) { deletingProject = nil }
            Button("프로젝트 삭제", role: .destructive) {
                if let project = deletingProject { store.deleteProject(project.id); selection = .unassigned }
                deletingProject = nil
            }
        } message: { Text("노트는 삭제되지 않고 ‘프로젝트 미지정’으로 이동합니다.") }
        .sheet(item: $editingNote) { NotebookForm(existing: $0) }
        .sheet(item: $pendingPDF, onDismiss: {
            if let id = importedNoteID { route = NoteRoute(id: id); importedNoteID = nil }
        }) { prepared in
            PDFImportChoiceView(title: prepared.title, pageCount: prepared.pages.count) { layout in
                importedNoteID = store.importPDF(prepared, layout: layout)
                pendingPDF = nil
            }
        }
        .fullScreenCover(item: $route, onDismiss: {
            if let prepared = deferredImport { deferredImport = nil; presentImport(prepared) }
        }) { route in NavigationStack { EditorView(noteID: route.id) }.environmentObject(store) }
        .fileImporter(isPresented: $importingPDF, allowedContentTypes: [.pdf]) { result in
            switch result {
            case .success(let url):
                prepareImport(url, folderID: currentFolderID)
            case .failure(let error): store.errorMessage = error.localizedDescription
            }
        }
        .onOpenURL { url in
            guard store.flushDrawings(), !importing, pendingPDF == nil else { return }
            prepareImport(url, folderID: nil)
        }
        .alert(editingFolder == nil ? "새로운 폴더" : "폴더 이름 변경", isPresented: $folderPrompt) {
            TextField("폴더 이름", text: $folderTitle)
            Button("취소", role: .cancel) { }
            Button("저장") {
                if let editingFolder { store.renameFolder(editingFolder.id, title: folderTitle) }
                else { store.createFolder(folderTitle) }
            }.disabled(folderTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .alert("노트를 영구 삭제할까요?", isPresented: Binding(get: { deletingNote != nil }, set: { if !$0 { deletingNote = nil } })) {
            Button("취소", role: .cancel) { }
            Button("영구 삭제", role: .destructive) { if let note = deletingNote { store.permanentlyDelete(note.id) } }
        } message: { Text("노트와 첨부 파일이 삭제되며 복원할 수 없습니다.") }
        .alert("폴더를 삭제할까요?", isPresented: Binding(get: { deletingFolder != nil }, set: { if !$0 { deletingFolder = nil } })) {
            Button("취소", role: .cancel) { }
            Button("폴더 삭제", role: .destructive) {
                if let folder = deletingFolder {
                    store.deleteFolder(folder.id)
                    if filter == .folder(folder.id) { selection = .all }
                }
            }
        } message: { Text("폴더 안의 노트는 ‘모든 노트’에 유지됩니다.") }
        .alert("작업을 완료하지 못했습니다", isPresented: Binding(get: { store.errorMessage != nil && route == nil && !creatingNote && editingNote == nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("확인", role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
    }

    private func sidebarRow(_ title: String, icon: String, filter: LibraryFilter) -> some View {
        HStack {
            Label(title, systemImage: icon)
            Spacer()
            Text("\(store.library.notebooks.filter { filter.includes($0) }.count)").foregroundStyle(.tertiary).font(.caption)
        }.tag(filter)
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(query.isEmpty ? (filter == .trash ? "휴지통이 비어 있습니다" : "첫 페이지를 펼쳐보세요") : "검색 결과가 없습니다",
                  systemImage: query.isEmpty ? (filter == .trash ? "trash" : "book.closed") : "magnifyingglass")
        } description: {
            Text(query.isEmpty ? (filter == .trash ? "삭제한 노트는 이곳에서 복원할 수 있습니다." : "새 노트를 만들거나 PDF를 가져와 기록을 시작하세요.") : "다른 이름이나 텍스트로 검색해 보세요.")
        } actions: {
            if query.isEmpty && filter != .trash { Button("새로운 노트 만들기") { creatingNote = true }.buttonStyle(.borderedProminent) }
        }
    }

    private func prepareImport(_ url: URL, folderID: UUID?) {
        guard !importing else { return }
        importing = true
        let projectID = currentProjectID
        Task { @MainActor in
            await Task.yield()
            defer { importing = false }
            guard var prepared = store.preparePDF(url, folderID: folderID) else { return }
            prepared.projectID = projectID
            if route != nil { deferredImport = prepared; route = nil }
            else { presentImport(prepared) }
        }
    }

    private func presentImport(_ prepared: PreparedPDFImport) {
        if prepared.pages.count > 1 { pendingPDF = prepared }
        else if let id = store.importPDF(prepared, layout: .paged) { route = NoteRoute(id: id) }
    }

    @ViewBuilder private func noteActions(_ note: Notebook) -> some View {
        if filter == .trash {
            Button("복원", systemImage: "arrow.uturn.backward") { store.restore(note.id) }
            Button("영구 삭제", systemImage: "trash", role: .destructive) { deletingNote = note }
        } else {
            Button("이름 및 표지 변경", systemImage: "pencil") { editingNote = note }
            Button(note.isFavorite ? "즐겨찾기 해제" : "즐겨찾기", systemImage: note.isFavorite ? "star.slash" : "star") {
                store.updateNote(note.id) { $0.isFavorite.toggle() }
            }
            Menu("프로젝트로 이동", systemImage: "square.stack.3d.up") {
                Button("프로젝트 미지정") { store.assignProject(noteID: note.id, projectID: nil) }
                ForEach(store.library.projects) { project in
                    Button(project.title) { store.assignProject(noteID: note.id, projectID: project.id) }
                }
            }
            Menu("폴더로 이동", systemImage: "folder") {
                Button("폴더 없음") { store.updateNote(note.id) { $0.folderID = nil } }
                ForEach(store.library.folders) { folder in Button(folder.title) { store.updateNote(note.id) { $0.folderID = folder.id } } }
            }
            Button("복제", systemImage: "plus.square.on.square") { _ = store.duplicate(note.id) }
            Button("휴지통으로 이동", systemImage: "trash", role: .destructive) { store.trash(note.id) }
        }
    }
}

private struct PDFImportChoiceView: View {
    let title: String
    let pageCount: Int
    let onChoose: (PDFImportLayout) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 24) {
                Text("\(title) · \(pageCount)페이지").font(.subheadline).foregroundStyle(.secondary)
                Text("어떻게 펼칠까요?").font(.title2.bold())
                ForEach(PDFImportLayout.allCases) { layout in
                    Button { onChoose(layout) } label: {
                        HStack(spacing: 18) {
                            Image(systemName: layout == .continuous ? "scroll" : "rectangle.stack")
                                .font(.title).frame(width: 40)
                            VStack(alignment: .leading, spacing: 8) {
                                Text(layout.title).font(.headline)
                                Text(layout == .continuous
                                     ? "모든 페이지를 세로로 연결합니다. 스크롤하며 경계 너머까지 필기할 수 있어요."
                                     : "원래 페이지를 유지합니다. 세 손가락으로 좌우로 쓸어 페이지를 넘겨요.")
                                    .font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption)
                        }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 18))
                    }.buttonStyle(.plain)
                }
                Spacer(minLength: 0)
            }.padding(24).background(Color(uiColor: .systemGroupedBackground))
                .navigationTitle("PDF 가져오기").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } } }
        }.presentationDetents([.large])
    }
}

struct ProjectForm: View {
    var existing: NoteProject?
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var instructions = ""
    var body: some View {
        NavigationStack {
            Form {
                Section("프로젝트") { TextField("예: 선형대수 · 1학기", text: $title) }
                Section {
                    TextEditor(text: $instructions).frame(minHeight: 180)
                } header: { Text("프로젝트 에이전트 지침") } footer: {
                    Text("예: 대학 1학년 수준으로 설명하고, 답보다 풀이 과정을 먼저 알려줘. 이 지침은 이 프로젝트의 대화에만 적용됩니다.")
                }
            }
            .navigationTitle(existing == nil ? "새 프로젝트" : "프로젝트 설정")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("저장") {
                        if let existing {
                            if store.updateProject(existing.id, title: title, agentInstructions: instructions) { dismiss() }
                        } else if store.createProject(title: title, agentInstructions: instructions) != nil { dismiss() }
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
            .onAppear { title = existing?.title ?? ""; instructions = existing?.agentInstructions ?? "" }
        }.storeErrorAlert()
    }
}
