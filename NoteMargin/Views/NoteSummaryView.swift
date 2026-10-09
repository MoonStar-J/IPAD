import SwiftUI

@MainActor final class NoteSummaryDraft: ObservableObject {
    enum Step: Equatable { case scope, name, connection, progress(UUID) }
    @Published var step: Step = .scope
    @Published var selected = Set<String>()
    @Published var whole = true
    @Published var title = ""
    @Published var prompt = ""
}

struct NoteSummaryComposer: View {
    let noteID: UUID
    @ObservedObject var service: NoteSummaryService
    @ObservedObject var draft: NoteSummaryDraft
    var selectedRegion: CGRect?
    let selectRegion: () -> Void
    let open: (UUID) -> Void
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var connection = ChatGPTPlanConnection.shared
    private var note: Notebook? { store.note(noteID) }
    private var infinite: Bool { note?.pages.first?.isInfinite == true }
    private var choices: [SummarySource] { note.map(NoteSummaryService.pageChoices) ?? [] }
    private var rangeLabel: String {
        if draft.whole { return "전체 노트" }
        if infinite { return "선택한 사각형 영역" }
        return choices.filter { draft.selected.contains($0.id) }.map(\.label).joined(separator: ", ")
    }
    private var canProceed: Bool { draft.whole || (infinite ? selectedRegion != nil : !draft.selected.isEmpty) }
    private var connected: Bool { connection.state == .ready && connection.selected != nil && connection.models.contains { $0.slug == connection.model } }

    var body: some View {
        Group {
            if draft.step == .connection {
                ChatGPTPlanSettings(onDone: { draft.step = .name })
            } else {
                NavigationStack {
                    Form {
                        if let note {
                            switch draft.step {
                            case .scope:
                                Section {
                                    Picker("요약 범위", selection: $draft.whole) {
                                        Text("전체 요약하기").tag(true)
                                        Text("선택한 부분 요약하기").tag(false)
                                    }.pickerStyle(.inline)
                                }
                                if !draft.whole {
                                    if infinite {
                                        Section {
                                            Button(selectedRegion == nil ? "사각형 영역 선택" : "영역 다시 선택", action: selectRegion)
                                            if let rect = selectedRegion { Text("x: \(Int(rect.minX)), y: \(Int(rect.minY)) · \(Int(rect.width)) × \(Int(rect.height))").font(.caption) }
                                        }
                                    } else {
                                        Section("원래 페이지 순서로 요약합니다") {
                                            PageSelectionRows(note: note, choices: choices, selected: $draft.selected)
                                        }
                                    }
                                }
                                Section { Button("요약하기") { draft.step = .name }.disabled(!canProceed).accessibilityIdentifier("summary-next") }
                            case .name:
                                Section("요약 노트 이름") { TextField("이름", text: $draft.title).accessibilityIdentifier("summary-title") }
                                Section("이번 요약 요청") {
                                    TextField("비워 두면 설정의 기본 요약 프롬프트를 사용합니다", text: $draft.prompt, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("summary-prompt")
                                    NavigationLink("기본 요약 프롬프트 설정") { SummaryPromptSettings() }
                                    Text("이번 요청은 저장된 기본값을 바꾸지 않습니다.").font(.caption)
                                }
                                Section("생성할 요약") {
                                    LabeledContent("범위", value: rangeLabel)
                                    LabeledContent("저장 위치", value: store.summaryLocation(for: note))
                                    Text("생성 당시 자료를 기준으로 저장합니다. 원본 노트는 변경하지 않습니다.").font(.caption)
                                }
                                Section("ChatGPT") {
                                    Text(connection.profiles.first { $0.id == connection.selected }?.title ?? "연결된 계정 없음")
                                    Picker("모델", selection: $connection.model) {
                                        if connection.model.isEmpty { Text("모델 선택 필요").tag("") }
                                        ForEach(connection.models) { Text($0.display_name).tag($0.slug) }
                                    }
                                    if !connection.model.isEmpty && !PlanModelSupport.acceptsImage(connection.model) {
                                        Text("이미지를 읽을 수 있다고 확인된 모델을 선택해 주세요.").foregroundStyle(.red)
                                    }
                                    Button("연결·계정 설정") { draft.step = .connection }
                                    Text("선택 범위의 이미지와 텍스트를 연결된 ChatGPT로 전송합니다. 긴 자료는 여러 요청과 통합으로 나뉘어 사용량이 추가로 소비될 수 있습니다. 앱이 종료되면 작업은 중단됩니다.").font(.caption)
                                }
                                Section {
                                    Button("생성") {
                                        if let id = service.start(sourceID: noteID, title: draft.title, choices: draft.whole ? nil : (infinite ? nil : draft.selected), region: draft.whole ? nil : selectedRegion, prompt: draft.prompt) { draft.step = .progress(id) }
                                    }.disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !connected || !PlanModelSupport.acceptsImage(connection.model) || service.busy || service.unsaved)
                                        .accessibilityIdentifier("summary-create")
                                    Button("범위 다시 선택") { draft.step = .scope }
                                }
                            case .progress(let id):
                                SummaryProgress(noteID: id, service: service)
                                Section { Button("요약 노트 열기") { open(id) }.accessibilityIdentifier("summary-open") }
                            case .connection: EmptyView()
                            }
                        }
                        if let failure = service.failure { Section { Text(failure).foregroundStyle(.red).textSelection(.enabled) } }
                        if service.unsaved { Section { Button("다시 저장") { service.saveAgain() }.disabled(service.busy) } }
                        if let active = service.activeID, draft.step != .progress(active) {
                            Section { Button("진행 중인 요약 보기") { draft.step = .progress(active) } }
                        }
                    }
                    .accessibilityIdentifier("summary-form")
                    .scrollDismissesKeyboard(.interactively)
                    .navigationTitle("노트 요약").navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("닫기") { dismiss() } } }
                }
            }
        }
        .onAppear {
            if draft.title.isEmpty { draft.title = note?.title ?? "" }
            if selectedRegion != nil { draft.whole = false }
        }
        .task { if connection.models.isEmpty { await connection.refreshModels() } }
    }
}

private struct SummaryProgress: View {
    let noteID: UUID
    @ObservedObject var service: NoteSummaryService
    @EnvironmentObject private var store: NoteStore
    var body: some View {
        Section {
            if service.activeID == noteID {
                ProgressView(service.message.isEmpty ? "준비 중" : service.message)
                Button("취소") { service.cancel() }
                Text("화면을 닫아도 앱이 실행 중인 동안 계속됩니다.").font(.caption)
            } else if let summary = store.note(noteID)?.summary {
                Text(summary.state.running ? "미완료 · 중단됨" : summary.state.title)
                if summary.state != .completed {
                    Button("이 요약에서 다시 시도") { service.resume(noteID) }.disabled(service.busy || service.unsaved)
                }
            }
        }
    }
}

struct SummaryReaderView: View {
    let noteID: UUID
    @ObservedObject var service: NoteSummaryService
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var bodyText = ""
    @State private var sources: [SummarySource] = []
    @State private var error: String?
    private enum Sheet: String, Identifiable { case share, settings, connection; var id: String { rawValue } }
    @State private var sheet: Sheet?
    @State private var urls: [URL] = []
    private var note: Notebook? { store.note(noteID) }
    var body: some View {
        Group {
            if let note, let summary = note.summary {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(note.title).font(.largeTitle.bold())
                        Text("\(summary.sourceTitle) · \(summary.createdAt.formatted()) 생성 당시 자료").font(.caption).foregroundStyle(.secondary)
                        Text(summary.model).font(.caption).foregroundStyle(.secondary)
                        if service.activeID == noteID {
                            ProgressView(service.message)
                            Button("취소") { service.cancel() }
                        } else if summary.state != .completed {
                            Text(summary.state.running ? "미완료 · 중단됨" : summary.state.title).foregroundStyle(.orange)
                            Button("이 요약에서 다시 시도") { service.resume(noteID); reload(); if let failure = service.failure { error = failure } }.disabled(service.busy || service.unsaved)
                            Button("ChatGPT 연결·모델 확인") { sheet = .connection }
                        }
                        if service.unsaved && service.retainedID == noteID { Button("받은 결과 다시 저장") { service.saveAgain(); reload() }.disabled(service.busy) }
                        if let error = error ?? (service.retainedID == noteID || service.activeID == noteID ? service.failure : nil) {
                            Text(error).foregroundStyle(.red).textSelection(.enabled)
                        }
                        MathAnswerView(text: bodyText).accessibilityIdentifier("summary-body")
                        DisclosureGroup("생성 당시 출처 \(sources.count)개") {
                            ForEach(sources) { source in Text("[\(source.id)] \(source.label)").font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }.padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
                }
                .navigationTitle("요약").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button("보관함") { dismiss() }.accessibilityIdentifier("editor-library-back") }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button("원문 복사", systemImage: "doc.on.doc") { UIPasteboard.general.string = bodyText }
                        Button("공유", systemImage: "square.and.arrow.up") {
                            do { urls = [try ExportService.exportMarkdown(note: note, store: store)]; sheet = .share }
                            catch { self.error = error.localizedDescription }
                        }
                        Button("설정", systemImage: "ellipsis.circle") { sheet = .settings }
                    }
                }
                .sheet(item: $sheet) { value in
                    switch value {
                    case .share: ShareSheet(urls: urls)
                    case .settings: NotebookForm(existing: note)
                    case .connection: SummaryConnectionView()
                    }
                }
            } else { ContentUnavailableView("요약 노트를 찾을 수 없습니다", systemImage: "doc.text") }
        }
        .task { reload() }
        .onChange(of: note?.updatedAt) { _, _ in reload() }
        .onChange(of: service.activeID) { _, _ in reload() }
        .onChange(of: service.unsaved) { _, _ in reload() }
    }
    private func reload() {
        do {
            let work = try service.checkpoint(noteID)
            sources = work.sources; error = work.failure
            if service.retainedID == noteID || service.activeID == noteID { bodyText = work.markdown }
            else if let summary = note?.summary {
                let data = try store.summaryAsset(noteID, name: summary.bodyAsset)
                guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
                bodyText = text
            }
        } catch { self.error = "저장된 요약을 읽지 못했습니다. " + error.localizedDescription }
    }
}

private struct SummaryConnectionView: View {
    @ObservedObject private var connection = ChatGPTPlanConnection.shared
    var body: some View {
        VStack {
            Picker("모델", selection: $connection.model) { ForEach(connection.models) { Text($0.display_name).tag($0.slug) } }.padding()
            ChatGPTPlanSettings()
        }.task { if connection.models.isEmpty { await connection.refreshModels() } }
    }
}

struct PageSelectionRows: View {
    let note: Notebook
    let choices: [SummarySource]
    @Binding var selected: Set<String>
    var body: some View {
        HStack {
            Button("전체 선택") { selected = Set(choices.map(\.id)) }
            Spacer()
            Button("선택 해제") { selected.removeAll() }
        }.buttonStyle(.borderless)
        ForEach(choices) { choice in
            if let page = note.pages.first(where: { $0.id == choice.pageID }) {
                Button {
                    if !selected.insert(choice.id).inserted { selected.remove(choice.id) }
                } label: {
                    HStack(spacing: 20) {
                        PageThumbnail(note: note, page: page, region: choice.rect).frame(width: 68, height: 92)
                        Text(choice.label).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: selected.contains(choice.id) ? "checkmark.circle.fill" : "circle")
                    }
                }.accessibilityLabel(choice.label + (selected.contains(choice.id) ? ", 선택됨" : ", 선택 안 됨"))
            }
        }
    }
}

struct PDFExportSelection: View {
    let note: Notebook
    let choices: [SummarySource]
    let exporting: Bool
    let progress: String
    @Binding var error: String?
    let cancel: () -> Void
    let export: (Set<String>) -> Void
    @State private var selected = Set<String>()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if exporting { Section { ProgressView(progress); Button("내보내기 취소", action: cancel) } }
                Section("원래 문서 순서로 내보냅니다") { PageSelectionRows(note: note, choices: choices, selected: $selected).disabled(exporting) }
            }
                .navigationTitle("선택 PDF 내보내기").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("취소") { dismiss() }.disabled(exporting) }
                    ToolbarItem(placement: .confirmationAction) { Button("내보내기") { export(selected) }.disabled(selected.isEmpty || exporting) }
                }
        }.interactiveDismissDisabled(exporting)
            .alert("내보내지 못했습니다", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("확인", role: .cancel) { error = nil }
            } message: { Text(error ?? "") }
    }
}
