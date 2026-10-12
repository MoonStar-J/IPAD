import SwiftUI
import UniformTypeIdentifiers

struct NoteRoute: Identifiable { let id: UUID }

struct LibraryView: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    @EnvironmentObject private var store: NoteStore
    @State private var selection: LibraryFilter? = .unassigned
    @State private var query = ""
    @State private var sort: NoteSort = .modified
    @State private var creatingNote = false
    @State private var importingPDF = false
    @StateObject private var pdfImport = PDFImportFlow()
    @State private var importedNoteID: UUID?
    @State private var deferredImportURL: URL?
    @State private var route: NoteRoute?
    @State private var createdNoteID: UUID?
    @State private var editingNote: Notebook?
    @State private var deletingNote: Notebook?
    @State private var emptyingTrash: Set<UUID>?
    @State private var editingProject: NoteProject?
    @State private var creatingProject = false
    @State private var newProjectParentID: UUID?
    @State private var collapsedProjects = Set<UUID>()
    @State private var rootDropTargeted = false
    @State private var projectDropTarget: UUID?
    @State private var deletingProject: NoteProject?
    @State private var showingSettings = false
    @State private var connectingAI = false
    @State private var movingItem: LibraryItem?

    private var filter: LibraryFilter { selection ?? .unassigned }
    private var title: String {
        switch filter {
        case .all: return localized("모든 노트", language: appLanguage)
        case .favorites: return localized("즐겨찾기", language: appLanguage)
        case .trash: return localized("최근 삭제된 항목", language: appLanguage)
        case .unassigned: return localized("홈", language: appLanguage)
        case .project(let id): return store.project(id)?.title ?? localized("프로젝트", language: appLanguage)
        case .folder(let id): return store.library.folders.first { $0.id == id }?.title ?? localized("프로젝트", language: appLanguage)
        }
    }
    private var currentFolderID: UUID? { if case .folder(let id) = filter { return id }; return nil }
    private var currentProjectID: UUID? { if case .project(let id) = filter { return id }; return nil }
    private var notes: [Notebook] { store.library.notes(in: filter, query: query, sort: sort) }

    private var isDirectory: Bool { filter == .unassigned || currentProjectID != nil }
    private var projects: [NoteProject] {
        guard isDirectory else { return [] }
        return store.library.projects.filter {
            $0.parentID == currentProjectID && (query.isEmpty || $0.title.localizedStandardContains(query))
        }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    var body: some View {
        Group {
            if let error = store.loadingError {
                ContentUnavailableView {
                    Label(localized("보관함을 열 수 없습니다", language: appLanguage), systemImage: "externaldrive.badge.exclamationmark")
                } description: { Text(error.text) } actions: { Button(localized("다시 시도", language: appLanguage)) { store.loadLibrary() } }
            } else {
                NavigationSplitView {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            sidebarRow(localized("홈", language: appLanguage), icon: "house", filter: .unassigned)
                                .dropDestination(for: String.self) { values, _ in movePayload(values, to: nil) }
                            sidebarRow(localized("모든 노트", language: appLanguage), icon: "square.grid.2x2", filter: .all)
                            sidebarRow(localized("즐겨찾기", language: appLanguage), icon: "star", filter: .favorites)
                            Text(localized("프로젝트", language: appLanguage)).font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                                .padding(.horizontal, 12).padding(.top, 22).padding(.bottom, 6)
                            Button { selection = .unassigned } label: {
                                Label(localized("최상위 (홈)", language: appLanguage), systemImage: "tray")
                                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                                    .padding(.horizontal, 12).contentShape(Rectangle())
                            }.buttonStyle(.plain)
                                .accessibilityIdentifier("project-root-drop")
                                .background(rootDropTargeted ? Color.accentColor.opacity(0.18) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
                                .dropDestination(for: String.self) { values, _ in movePayload(values, to: nil) } isTargeted: { rootDropTargeted = $0 }
                            ForEach(store.library.projectTree(collapsed: collapsedProjects)) { entry in
                                projectTreeRow(entry)
                            }
                            Button { newProjectParentID = nil; creatingProject = true } label: {
                                Label(localized("새 프로젝트", language: appLanguage), systemImage: "plus").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 12)
                            }.buttonStyle(.plain).accessibilityIdentifier("sidebar-new-project")
                            Button(localized("설정", language: appLanguage), systemImage: "gearshape") { showingSettings = true }.padding(12).accessibilityIdentifier("app-settings")
                            sidebarRow(localized("최근 삭제된 항목", language: appLanguage), icon: "trash", filter: .trash).padding(.top, 22)
                            Button { connectingAI = true } label: {
                                Label(AppBuild.aiConnectionTitle, systemImage: "sparkles").frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).padding(.horizontal, 12)
                            }.buttonStyle(.plain)
                        }.padding(16)
                    }
                    .navigationTitle(AppIdentity.displayName)
                    .safeAreaInset(edge: .bottom) {
                        Label(localized("이 iPad에 저장됨", language: appLanguage), systemImage: "internaldrive")
                            .font(.caption).foregroundStyle(.secondary).padding()
                    }
                    .navigationSplitViewColumnWidth(min: 230, ideal: 260, max: 300)
                } detail: {
                    NavigationStack {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 28) {
                                if isDirectory {
                                    ScrollView(.horizontal, showsIndicators: false) {
                                        HStack {
                                            Button(localized("홈", language: appLanguage), systemImage: "house") { selection = .unassigned }
                                                .accessibilityIdentifier("library-home")
                                                .dropDestination(for: String.self) { values, _ in movePayload(values, to: nil) }
                                            if let id = currentProjectID {
                                                ForEach(store.library.projectPath(id)) { project in
                                                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.secondary)
                                                    Button(project.title) { selection = .project(project.id) }
                                                        .dropDestination(for: String.self) { values, _ in movePayload(values, to: project.id) }
                                                }
                                            }
                                        }.buttonStyle(.bordered).padding(.vertical, 4)
                                    }
                                }
                                HStack {
                                    Text(isDirectory ? localized("프로젝트 %@개 · 노트 %@개", "\(projects.count)", "\(notes.count)", language: appLanguage) : localized("노트 %@개", "\(notes.count)", language: appLanguage)).font(.subheadline).foregroundStyle(.secondary)
                                    Spacer()
                                    Menu {
                                        Picker(localized("노트 정렬", language: appLanguage), selection: $sort) { ForEach(NoteSort.allCases) { Text(localized($0.label, language: appLanguage)).tag($0) } }
                                    } label: { Label(sort.label, systemImage: "arrow.up.arrow.down").font(.subheadline) }
                                }
                                if notes.isEmpty && projects.isEmpty { emptyState.padding(.vertical, 48) }
                                else {
                                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 150, maximum: 210), spacing: 28)], alignment: .leading, spacing: 32) {
                                        ForEach(projects) { project in projectCard(project) }
                                        ForEach(notes) { note in
                                            VStack(alignment: .leading, spacing: 0) {
                                                Button {
                                                    route = NoteRoute(id: note.id)
                                                } label: {
                                                VStack(alignment: .leading, spacing: 12) {
                                                    NoteCover(note: note)
                                                    Text(note.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                                                    HStack(spacing: 4) {
                                                        Text(note.summary == nil ? localized("page.count", "\(note.pages.count)", language: appLanguage) : localized("요약 · ", language: appLanguage) + note.summary!.state.title)
                                                        Text("·")
                                                        Text(note.updatedAt, style: .date)
                                                    }.font(.caption).foregroundStyle(.secondary).lineLimit(1)
                                                }.contentShape(Rectangle())
                                                }
                                                .buttonStyle(.plain)
                                                .disabled(filter == .trash)
                                                .accessibilityLabel(note.title + (note.summary == nil ? localized(", %@페이지", "\(note.pages.count)", language: appLanguage) : localized(", 요약", language: appLanguage)))
                                                if filter == .trash {
                                                    HStack {
                                                        Button(localized("복원", language: appLanguage), systemImage: "arrow.uturn.backward") { store.restore(note.id) }
                                                        Spacer()
                                                        Button(role: .destructive) { deletingNote = note } label: { Image(systemName: "trash") }
                                                            .accessibilityLabel(localized("%@ 영구 삭제", "\(note.title)", language: appLanguage))
                                                    }.font(.subheadline).buttonStyle(.bordered).padding(.top, 12)
                                                }
                                            }
                                            .contextMenu { noteActions(note) }
                                            .onDrag {
                                                guard filter != .trash else { return NSItemProvider() }
                                                return NSItemProvider(object: LibraryItem.note(note.id).id as NSString)
                                            }
                                            .accessibilityIdentifier("note-" + note.id.uuidString)
                                        }
                                    }
                                }
                            }.padding(32).frame(maxWidth: 1300, alignment: .leading).frame(maxWidth: .infinity)
                        }
                        .background(Color(uiColor: .systemGroupedBackground))
                        .navigationTitle(title)
                        .navigationBarTitleDisplayMode(.inline)
                        .searchable(text: $query, prompt: localized("프로젝트·노트 이름 또는 텍스트 검색", language: appLanguage))
                        .toolbar {
                            if filter == .trash {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button(localized("모두 영구 삭제", language: appLanguage), role: .destructive) {
                                        emptyingTrash = Set(store.library.notebooks.filter { $0.deletedAt != nil }.map(\.id))
                                    }
                                    .disabled(!store.library.notebooks.contains { $0.deletedAt != nil })
                                    .accessibilityIdentifier("trash-empty-all")
                                }
                                if !(store.library.pendingAssetDeletions ?? []).isEmpty {
                                    ToolbarItem(placement: .topBarTrailing) {
                                        Button(localized("첨부 정리 다시 시도", language: appLanguage)) { store.finishPermanentDeletion() }
                                    }
                                }
                            }
                            if filter != .trash && route == nil {
                                ToolbarItemGroup(placement: .topBarTrailing) {
                                    if let id = currentProjectID, let project = store.project(id) {
                                        Button { editingProject = project } label: { Label(localized("프로젝트 설정", language: appLanguage), systemImage: "slider.horizontal.3") }
                                    }
                                    Button { newProjectParentID = currentProjectID; creatingProject = true } label: { Label(localized("새 프로젝트", language: appLanguage), systemImage: "folder.badge.plus") }
                                    Button { importingPDF = true } label: { Label(localized("PDF 가져오기", language: appLanguage), systemImage: "square.and.arrow.down") }
                                        .accessibilityIdentifier("library-import-pdf")
                                    Button { creatingNote = true } label: { Label(localized("새로운 노트", language: appLanguage), systemImage: "square.and.pencil") }
                                        .accessibilityIdentifier("library-create-note")
                                        .keyboardShortcut("n", modifiers: .command)
                                }
                            }
                        }
                        .overlay { if pdfImport.preparing { ProgressView(localized("PDF 가져오는 중…", language: appLanguage)).padding(28).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18)) } }
                    }
                }
            }
        }
        .sheet(isPresented: $creatingNote, onDismiss: {
            if let id = createdNoteID { route = NoteRoute(id: id); createdNoteID = nil }
        }) { NotebookForm(folderID: currentFolderID, projectID: currentProjectID, onCreated: { createdNoteID = $0 }) }
        .sheet(isPresented: $creatingProject) { ProjectForm(parentID: newProjectParentID) }
        .sheet(item: $movingItem) { item in moveSheet(item) }
        .sheet(item: $editingProject) { ProjectForm(existing: $0) }
        .sheet(isPresented: $connectingAI) {
            ChatGPTMarginView(conversationID: nil, project: nil)
        }
        .alert(localized("프로젝트를 삭제할까요?", language: appLanguage), isPresented: Binding(get: { deletingProject != nil }, set: { if !$0 { deletingProject = nil } })) {
            Button(localized("취소", language: appLanguage), role: .cancel) { deletingProject = nil }
            Button(localized("프로젝트 삭제", language: appLanguage), role: .destructive) {
                if let project = deletingProject { store.deleteProject(project.id); selection = project.parentID.map(LibraryFilter.project) ?? .unassigned }
                deletingProject = nil
            }
        } message: { Text(localized("하위 프로젝트와 노트는 삭제되지 않고 한 단계 위로 이동합니다.", language: appLanguage)) }
        .sheet(item: $editingNote) { NotebookForm(existing: $0) }
        .fullScreenCover(item: $route, onDismiss: {
            if let url = deferredImportURL { deferredImportURL = nil; prepareImport(url, folderID: nil) }
        }) { route in NavigationStack { EditorView(noteID: route.id) }.environmentObject(store) }
        .sheet(isPresented: $showingSettings) { AppearanceSettings() }
        .sheet(isPresented: $importingPDF, onDismiss: {
            pdfImport.cancel()
            if let id = importedNoteID { importedNoteID = nil; route = NoteRoute(id: id) }
        }) {
            PDFImportSourceView(flow: pdfImport, folderID: currentFolderID, projectID: currentProjectID) { id in
                importedNoteID = id
                importingPDF = false
            }
        }
        .onOpenURL { url in
            guard url.isFileURL, store.flushDrawings(), !importingPDF else { return }
            if route != nil { deferredImportURL = url; route = nil }
            else { prepareImport(url, folderID: nil) }
        }
        .alert(localized("휴지통의 %@개 노트를 모두 영구 삭제할까요?", "\(emptyingTrash?.count ?? 0)", language: appLanguage), isPresented: Binding(get: { emptyingTrash != nil }, set: { if !$0 { emptyingTrash = nil } }), presenting: emptyingTrash) { ids in
            Button(localized("취소", language: appLanguage), role: .cancel) { emptyingTrash = nil }
            Button(localized("모두 영구 삭제", language: appLanguage), role: .destructive) {
                store.permanentlyDelete(ids)
                emptyingTrash = nil
            }
        } message: { _ in Text(localized("검색 결과와 관계없이 휴지통 전체가 대상입니다. 노트와 첨부·AI 대화가 삭제되며 복구할 수 없습니다.", language: appLanguage)) }
        .alert(localized("노트를 영구 삭제할까요?", language: appLanguage), isPresented: Binding(get: { deletingNote != nil }, set: { if !$0 { deletingNote = nil } })) {
            Button(localized("취소", language: appLanguage), role: .cancel) { }
            Button(localized("영구 삭제", language: appLanguage), role: .destructive) { if let note = deletingNote { store.permanentlyDelete(note.id) } }
        } message: { Text(localized("노트와 첨부 파일이 삭제되며 복원할 수 없습니다.", language: appLanguage)) }
        .alert(localized("작업을 완료하지 못했습니다", language: appLanguage), isPresented: Binding(get: { store.errorMessage != nil && route == nil && !importingPDF && !creatingNote && editingNote == nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button(localized("확인", language: appLanguage), role: .cancel) { store.errorMessage = nil }
        } message: { Text(store.errorMessage?.text ?? "") }
    }

    private func projectTreeRow(_ entry: ProjectTreeEntry) -> some View {
        let project = entry.project
        let hasChildren = store.library.projects.contains { $0.parentID == project.id }
        return HStack(spacing: 4) {
            Button { selection = .project(project.id) } label: {
                HStack(spacing: 10) {
                    Circle().fill((project.cover ?? .blue).color).frame(width: 10, height: 10)
                        .accessibilityHidden(true)
                    Text(project.title).foregroundStyle(.primary).lineLimit(1)
                    Spacer(minLength: 2)
                    Text("\(sidebarCount(.project(project.id)))").font(.caption).foregroundStyle(.secondary)
                }.frame(minHeight: 44).contentShape(Rectangle())
            }.buttonStyle(.plain).accessibilityIdentifier("sidebar-project-" + project.id.uuidString)

            if hasChildren {
                Button {
                    if !collapsedProjects.insert(project.id).inserted { collapsedProjects.remove(project.id) }
                } label: {
                    Image(systemName: collapsedProjects.contains(project.id) ? "chevron.right" : "chevron.down")
                        .font(.caption.weight(.semibold)).foregroundStyle(.secondary).frame(width: 44, height: 44).contentShape(Rectangle())
                }.buttonStyle(.plain)
                    .accessibilityLabel(project.title + (collapsedProjects.contains(project.id) ? localized(" 하위 프로젝트 펼치기", language: appLanguage) : localized(" 하위 프로젝트 접기", language: appLanguage)))
                    .accessibilityIdentifier("project-toggle-" + project.id.uuidString)
            }
        }.padding(.leading, CGFloat(min(entry.depth, 8)) * 16 + 12).padding(.trailing, 6)
            .background(projectDropTarget == project.id ? Color.accentColor.opacity(0.18) : filter == .project(project.id) ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
            .contentShape(Rectangle())
            .contextMenu { projectActions(project) }
            .onDrag { NSItemProvider(object: LibraryItem.project(project.id).id as NSString) }
            .dropDestination(for: String.self) { values, _ in movePayload(values, to: project.id) } isTargeted: { targeted in
                if targeted { projectDropTarget = project.id }
                else if projectDropTarget == project.id { projectDropTarget = nil }
            }
    }

    private func movePayload(_ values: [String], to parentID: UUID?) -> Bool {
        guard values.count == 1, let item = LibraryItem(payload: values[0]) else { return false }
        let moved = store.move(item, to: parentID)
        if moved, let parentID { collapsedProjects.subtract(store.library.projectPath(parentID).map(\.id)) }
        return moved
    }

    private func projectCard(_ project: NoteProject) -> some View {
        Button { selection = .project(project.id) } label: {
            VStack(alignment: .leading, spacing: 12) {
                ZStack {
                    Color.clear
                    Image(systemName: "folder.fill").resizable().scaledToFit()
                        .foregroundStyle((project.cover ?? .blue).color).padding(.horizontal, 8)
                        .shadow(color: (project.cover ?? .blue).color.opacity(0.18), radius: 8, y: 5)
                }.aspectRatio(0.78, contentMode: .fit)
                Text(project.title).font(.subheadline.weight(.semibold)).foregroundStyle(.primary).lineLimit(1)
                Text(localized("프로젝트 %@개 · 노트 %@개", "\(store.library.projects.filter { $0.parentID == project.id }.count)", "\(store.library.notebooks.filter { $0.projectID == project.id && $0.deletedAt == nil }.count)", language: appLanguage))
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
            .accessibilityLabel(localized("%@, %@ 프로젝트 폴더", "\(project.title)", "\((project.cover ?? .blue).title)", language: appLanguage))
            .accessibilityIdentifier("project-" + project.id.uuidString)
            .contextMenu { projectActions(project) }
            .draggable(LibraryItem.project(project.id).id)
            .dropDestination(for: String.self) { values, _ in movePayload(values, to: project.id) }
    }

    @ViewBuilder private func projectActions(_ project: NoteProject) -> some View {
        Button(localized("프로젝트 설정", language: appLanguage), systemImage: "slider.horizontal.3") { editingProject = project }
        Button(localized("이동", language: appLanguage), systemImage: "folder") { movingItem = .project(project.id) }
        if project.parentID != nil {
            Button(localized("최상위로 이동", language: appLanguage), systemImage: "arrow.up.to.line") { store.move(.project(project.id), to: nil) }
        }
        Button(localized("하위 프로젝트 만들기", language: appLanguage), systemImage: "folder.badge.plus") {
            newProjectParentID = project.id; creatingProject = true
        }
        Button(localized("프로젝트 삭제", language: appLanguage), systemImage: "trash", role: .destructive) { deletingProject = project }
    }

    private func moveSheet(_ item: LibraryItem) -> some View {
        NavigationStack {
            List {
                Button(localized("최상위 (홈)", language: appLanguage)) { if store.move(item, to: nil) { movingItem = nil } }
                ForEach(store.library.projects.filter { store.library.canMove(item, to: $0.id) }.sorted {
                    projectPath($0.id) < projectPath($1.id)
                }) { project in
                    Button(projectPath(project.id)) {
                        if store.move(item, to: project.id) { movingItem = nil }
                    }
                }
            }.navigationTitle(localized("이동 위치", language: appLanguage))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(localized("취소", language: appLanguage)) { movingItem = nil } } }
        }.storeErrorAlert()
    }

    private func projectPath(_ id: UUID) -> String {
        store.library.projectPath(id).map(\.title).joined(separator: " / ")
    }

    private func sidebarCount(_ filter: LibraryFilter) -> Int {
        let notes = store.library.notebooks.filter { filter.includes($0) }.count
        switch filter {
        case .unassigned: return notes + store.library.projects.filter { $0.parentID == nil }.count
        case .project(let id): return notes + store.library.projects.filter { $0.parentID == id }.count
        default: return notes
        }
    }

    private func sidebarRow(_ title: String, icon: String, filter value: LibraryFilter) -> some View {
        Button { selection = value } label: {
            HStack {
                Label(title, systemImage: icon)
                Spacer()
                Text("\(sidebarCount(value))").foregroundStyle(.secondary).font(.caption)
            }.frame(minHeight: 44).padding(.horizontal, 12).contentShape(Rectangle())
        }.buttonStyle(.plain)
            .background(filter == value ? Color.primary.opacity(0.08) : Color.clear, in: RoundedRectangle(cornerRadius: 12))
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label(query.isEmpty ? (filter == .trash ? localized("휴지통이 비어 있습니다", language: appLanguage) : localized("항목이 없습니다", language: appLanguage)) : localized("검색 결과가 없습니다", language: appLanguage),
                  systemImage: query.isEmpty ? (filter == .trash ? "trash" : "book.closed") : "magnifyingglass")
        } description: {
            Text(query.isEmpty ? (filter == .trash ? localized("삭제한 노트는 이곳에서 복원할 수 있습니다.", language: appLanguage) : localized("프로젝트나 노트를 추가하거나 PDF를 가져올 수 있습니다.", language: appLanguage)) : localized("다른 이름이나 텍스트로 검색해 보세요.", language: appLanguage))
        } actions: {
            if query.isEmpty && filter != .trash { Button(localized("새로운 노트 만들기", language: appLanguage)) { creatingNote = true }.buttonStyle(.borderedProminent).foregroundStyle(Color(uiColor: .systemBackground)) }
        }
    }

    private func prepareImport(_ url: URL, folderID: UUID?) {
        guard !pdfImport.preparing else { return }
        importingPDF = true
        pdfImport.prepare(url, store: store, folderID: folderID, projectID: currentProjectID)
    }

    @ViewBuilder private func noteActions(_ note: Notebook) -> some View {
        if filter == .trash {
            Button(localized("복원", language: appLanguage), systemImage: "arrow.uturn.backward") { store.restore(note.id) }
            Button(localized("영구 삭제", language: appLanguage), systemImage: "trash", role: .destructive) { deletingNote = note }
        } else {
            Button(localized("이름 및 표지 변경", language: appLanguage), systemImage: "pencil") { editingNote = note }
            Button(note.isFavorite ? localized("즐겨찾기 해제", language: appLanguage) : localized("즐겨찾기", language: appLanguage), systemImage: note.isFavorite ? "star.slash" : "star") {
                store.updateNote(note.id) { $0.isFavorite.toggle() }
            }
            Button(localized("이동", language: appLanguage), systemImage: "folder") { movingItem = .note(note.id) }
            Button(localized("복제", language: appLanguage), systemImage: "plus.square.on.square") { _ = store.duplicate(note.id) }
            Button(localized("휴지통으로 이동", language: appLanguage), systemImage: "trash", role: .destructive) { store.trash(note.id) }
        }
    }
}

struct ProjectForm: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    var existing: NoteProject?
    var parentID: UUID?
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var instructions = ""
    @State private var cover: CoverColor = .blue
    @State private var selectedParentID: UUID?
    init(existing: NoteProject? = nil, parentID: UUID? = nil) {
        self.existing = existing
        self.parentID = parentID
        _title = State(initialValue: existing?.title ?? "")
        _instructions = State(initialValue: existing?.agentInstructions ?? "")
        _cover = State(initialValue: existing?.cover ?? .blue)
        _selectedParentID = State(initialValue: existing == nil ? parentID : existing?.parentID)
    }
    var body: some View {
        NavigationStack {
            Form {
                Section(localized("프로젝트", language: appLanguage)) { TextField(localized("프로젝트 이름", language: appLanguage), text: $title) }
                Section(localized("폴더 색상", language: appLanguage)) {
                    HStack(spacing: 20) {
                        ForEach(CoverColor.allCases) { value in
                            Button { cover = value } label: {
                                Circle().fill(value.color).frame(width: 38, height: 38)
                                    .overlay { if value == cover { Image(systemName: "checkmark").foregroundStyle(.white).bold() } }
                                    .frame(minWidth: 44, minHeight: 44)
                            }.buttonStyle(.plain).accessibilityLabel(localized(value.title, language: appLanguage))
                                .accessibilityAddTraits(value == cover ? .isSelected : [])
                                .accessibilityIdentifier("project-color-" + value.rawValue)
                        }
                    }.frame(maxWidth: .infinity)
                }
                Section(localized("위치", language: appLanguage)) {
                    Picker(localized("상위 프로젝트", language: appLanguage), selection: $selectedParentID) {
                        Text(localized("최상위 (홈)", language: appLanguage)).tag(UUID?.none)
                        ForEach(store.library.projectTree().filter { entry in
                            existing.map { store.library.canMove(.project($0.id), to: entry.id) } ?? true
                        }) { entry in
                            Text(store.library.projectPath(entry.id).map(\.title).joined(separator: " / "))
                                .tag(Optional(entry.id))
                        }
                    }.pickerStyle(.menu).accessibilityIdentifier("project-parent-picker")
                }
                Section {
                    TextEditor(text: $instructions).frame(minHeight: 180)
                } header: { Text(localized("프로젝트 에이전트 지침", language: appLanguage)) } footer: {
                    Text(localized("예: 대학 1학년 수준으로 설명하고, 답보다 풀이 과정을 먼저 알려줘. 이 지침은 이 프로젝트의 대화에만 적용됩니다.", language: appLanguage))
                }
            }
            .navigationTitle(existing == nil ? localized("새 프로젝트", language: appLanguage) : localized("프로젝트 설정", language: appLanguage))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button(localized("취소", language: appLanguage)) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(localized("저장", language: appLanguage)) {
                        if let existing {
                            if store.updateProject(existing.id, title: title, agentInstructions: instructions, parentID: selectedParentID, cover: cover) { dismiss() }
                        } else if store.createProject(title: title, agentInstructions: instructions, parentID: selectedParentID, cover: cover) != nil { dismiss() }
                    }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }

        }.storeErrorAlert()
    }
}
