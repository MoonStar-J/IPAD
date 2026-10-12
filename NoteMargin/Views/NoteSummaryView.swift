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
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
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
        if draft.whole { return localized("전체 노트", language: appLanguage) }
        if infinite { return localized("선택한 사각형 영역", language: appLanguage) }
        return choices.filter { draft.selected.contains($0.id) }.map { $0.displayLabel(in: appLanguage) }.joined(separator: ", ")
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
                                    Picker(localized("요약 범위", language: appLanguage), selection: $draft.whole) {
                                        Text(localized("전체 요약하기", language: appLanguage)).tag(true)
                                        Text(localized("선택한 부분 요약하기", language: appLanguage)).tag(false)
                                    }.pickerStyle(.inline)
                                }
                                if !draft.whole {
                                    if infinite {
                                        Section {
                                            Button(selectedRegion == nil ? localized("사각형 영역 선택", language: appLanguage) : localized("영역 다시 선택", language: appLanguage), action: selectRegion)
                                            if let rect = selectedRegion { Text("x: \(Int(rect.minX)), y: \(Int(rect.minY)) · \(Int(rect.width)) × \(Int(rect.height))").font(.caption) }
                                        }
                                    } else {
                                        Section(localized("원래 페이지 순서로 요약합니다", language: appLanguage)) {
                                            PageSelectionRows(note: note, choices: choices, selected: $draft.selected)
                                        }
                                    }
                                }
                                Section { Button(localized("요약하기", language: appLanguage)) { draft.step = .name }.disabled(!canProceed).accessibilityIdentifier("summary-next") }
                            case .name:
                                Section(localized("요약 노트 이름", language: appLanguage)) { TextField(localized("이름", language: appLanguage), text: $draft.title).accessibilityIdentifier("summary-title") }
                                Section(localized("이번 요약 요청", language: appLanguage)) {
                                    TextField(localized("비워 두면 설정의 기본 요약 프롬프트를 사용합니다", language: appLanguage), text: $draft.prompt, axis: .vertical).lineLimit(3...8).accessibilityIdentifier("summary-prompt")
                                    NavigationLink(localized("기본 요약 프롬프트 설정", language: appLanguage)) { SummaryPromptSettings() }
                                    Text(localized("이번 요청은 저장된 기본값을 바꾸지 않습니다.", language: appLanguage)).font(.caption)
                                }
                                Section(localized("생성할 요약", language: appLanguage)) {
                                    LabeledContent(localized("범위", language: appLanguage), value: rangeLabel)
                                    LabeledContent(localized("저장 위치", language: appLanguage), value: store.summaryLocation(for: note))
                                    Text(localized("생성 당시 자료를 기준으로 저장합니다. 원본 노트는 변경하지 않습니다.", language: appLanguage)).font(.caption)
                                }
                                Section("ChatGPT") {
                                    Text(connection.profiles.first { $0.id == connection.selected }?.title(in: appLanguage) ?? localized("연결된 계정 없음", language: appLanguage))
                                    Picker(localized("모델", language: appLanguage), selection: $connection.model) {
                                        if connection.model.isEmpty { Text(localized("모델 선택 필요", language: appLanguage)).tag("") }
                                        ForEach(connection.models) { Text($0.display_name).tag($0.slug) }
                                    }
                                    if !connection.model.isEmpty && !PlanModelSupport.acceptsImage(connection.model) {
                                        Text(localized("이미지를 읽을 수 있다고 확인된 모델을 선택해 주세요.", language: appLanguage)).foregroundStyle(.red)
                                    }
                                    Button(localized("연결·계정 설정", language: appLanguage)) { draft.step = .connection }
                                    Text(localized("선택 범위의 이미지와 텍스트를 연결된 ChatGPT로 전송합니다. 긴 자료는 여러 요청과 통합으로 나뉘어 사용량이 추가로 소비될 수 있습니다. 앱이 종료되면 작업은 중단됩니다.", language: appLanguage)).font(.caption)
                                }
                                Section {
                                    Button(localized("생성", language: appLanguage)) {
                                        if let id = service.start(sourceID: noteID, title: draft.title, choices: draft.whole ? nil : (infinite ? nil : draft.selected), region: draft.whole ? nil : selectedRegion, prompt: draft.prompt) { draft.step = .progress(id) }
                                    }.disabled(draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !connected || !PlanModelSupport.acceptsImage(connection.model) || service.busy || service.unsaved)
                                        .accessibilityIdentifier("summary-create")
                                    Button(localized("범위 다시 선택", language: appLanguage)) { draft.step = .scope }
                                }
                            case .progress(let id):
                                SummaryProgress(noteID: id, service: service)
                                Section { Button(localized("요약 노트 열기", language: appLanguage)) { open(id) }.accessibilityIdentifier("summary-open") }
                            case .connection: EmptyView()
                            }
                        }
                        if let failure = service.failure { Section { Text(failure.text).foregroundStyle(.red).textSelection(.enabled) } }
                        if service.unsaved { Section { Button(localized("다시 저장", language: appLanguage)) { service.saveAgain() }.disabled(service.busy) } }
                        if let active = service.activeID, draft.step != .progress(active) {
                            Section { Button(localized("진행 중인 요약 보기", language: appLanguage)) { draft.step = .progress(active) } }
                        }
                    }
                    .accessibilityIdentifier("summary-form")
                    .scrollDismissesKeyboard(.interactively)
                    .navigationTitle(localized("노트 요약", language: appLanguage)).navigationBarTitleDisplayMode(.inline)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(localized("닫기", language: appLanguage)) { dismiss() } } }
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
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    let noteID: UUID
    @ObservedObject var service: NoteSummaryService
    @EnvironmentObject private var store: NoteStore
    var body: some View {
        Section {
            if service.activeID == noteID {
                ProgressView(service.message.isEmpty ? localized("준비 중", language: appLanguage) : service.message.text)
                Button(localized("취소", language: appLanguage)) { service.cancel() }
                Text(localized("화면을 닫아도 앱이 실행 중인 동안 계속됩니다.", language: appLanguage)).font(.caption)
            } else if let summary = store.note(noteID)?.summary {
                Text(summary.state.running ? localized("미완료 · 중단됨", language: appLanguage) : summary.state.title)
                if summary.state != .completed {
                    Button(localized("이 요약에서 다시 시도", language: appLanguage)) { service.resume(noteID) }.disabled(service.busy || service.unsaved)
                }
            }
        }
    }
}

struct SummaryReaderView: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    let noteID: UUID
    @ObservedObject var service: NoteSummaryService
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var bodyText = ""
    @State private var displayBody = ""
    @State private var sources: [SummarySource] = []
    @State private var error: AppMessage?
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
                        Text(localized("%@ · %@ 생성 당시 자료", "\(summary.sourceTitle)", "\(summary.createdAt.formatted(.dateTime.locale(appLanguage.locale)))", language: appLanguage)).font(.caption).foregroundStyle(.secondary)
                        Text(summary.model).font(.caption).foregroundStyle(.secondary)
                        if service.activeID == noteID {
                            ProgressView(service.message.text)
                            Button(localized("취소", language: appLanguage)) { service.cancel() }
                        } else if summary.state != .completed {
                            Text(summary.state.running ? localized("미완료 · 중단됨", language: appLanguage) : summary.state.title).foregroundStyle(.orange)
                            Button(localized("이 요약에서 다시 시도", language: appLanguage)) { service.resume(noteID); reload(); if let failure = service.failure { error = failure } }.disabled(service.busy || service.unsaved)
                            Button(localized("ChatGPT 연결·모델 확인", language: appLanguage)) { sheet = .connection }
                        }
                        if service.unsaved && service.retainedID == noteID { Button(localized("받은 결과 다시 저장", language: appLanguage)) { service.saveAgain(); reload() }.disabled(service.busy) }
                        if let error = error ?? (service.retainedID == noteID || service.activeID == noteID ? service.failure : nil) {
                            Text(error.text).foregroundStyle(.red).textSelection(.enabled)
                        }
                        MathAnswerView(text: displayBody).accessibilityIdentifier("summary-body")
                        DisclosureGroup(localized("생성 당시 출처 %@개", "\(sources.count)", language: appLanguage)) {
                            ForEach(sources) { source in Text("[\(source.id)] \(source.displayLabel(in: appLanguage))").font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                        }
                    }.padding(24).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity)
                }
                .navigationTitle(localized("요약", language: appLanguage)).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(localized("보관함", language: appLanguage)) { dismiss() }.accessibilityIdentifier("editor-library-back") }
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        Button(localized("원문 복사", language: appLanguage), systemImage: "doc.on.doc") { UIPasteboard.general.string = bodyText }
                        Button(localized("공유", language: appLanguage), systemImage: "square.and.arrow.up") {
                            do { urls = [try ExportService.exportMarkdown(note: note, store: store)]; sheet = .share }
                            catch { self.error = AppMessage(error) }
                        }
                        Button(localized("설정", language: appLanguage), systemImage: "ellipsis.circle") { sheet = .settings }
                    }
                }
                .sheet(item: $sheet) { value in
                    switch value {
                    case .share: ShareSheet(urls: urls)
                    case .settings: NotebookForm(existing: note)
                    case .connection: SummaryConnectionView()
                    }
                }
            } else { ContentUnavailableView(localized("요약 노트를 찾을 수 없습니다", language: appLanguage), systemImage: "doc.text") }
        }
        .task { reload() }
        .onChange(of: note?.updatedAt) { _, _ in reload() }
        .onChange(of: service.activeID) { _, _ in reload() }
        .onChange(of: service.unsaved) { _, _ in reload() }
        .onChange(of: appLanguage) { _, _ in reload() }
    }
    private func reload() {
        do {
            let work = try service.checkpoint(noteID)
            sources = work.sources; error = work.failure.map { AppMessage($0) }
            if service.retainedID == noteID || service.activeID == noteID { bodyText = work.markdown }
            else if let summary = note?.summary {
                let data = try store.summaryAsset(noteID, name: summary.bodyAsset)
                guard let text = String(data: data, encoding: .utf8) else { throw CocoaError(.fileReadCorruptFile) }
                bodyText = text
            }
            displayBody = work.final == nil ? work.displayMarkdown : bodyText
        } catch { self.error = AppMessage("저장된 요약을 읽지 못했습니다. %@", error: error) }
    }
}

private struct SummaryConnectionView: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    @ObservedObject private var connection = ChatGPTPlanConnection.shared
    var body: some View {
        VStack {
            Picker(localized("모델", language: appLanguage), selection: $connection.model) { ForEach(connection.models) { Text($0.display_name).tag($0.slug) } }.padding()
            ChatGPTPlanSettings()
        }.task { if connection.models.isEmpty { await connection.refreshModels() } }
    }
}

struct PageSelectionRows: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    let note: Notebook
    let choices: [SummarySource]
    @Binding var selected: Set<String>
    var body: some View {
        HStack {
            Button(localized("전체 선택", language: appLanguage)) { selected = Set(choices.map(\.id)) }
            Spacer()
            Button(localized("선택 해제", language: appLanguage)) { selected.removeAll() }
        }.buttonStyle(.borderless)
        ForEach(choices) { choice in
            if let page = note.pages.first(where: { $0.id == choice.pageID }) {
                Button {
                    if !selected.insert(choice.id).inserted { selected.remove(choice.id) }
                } label: {
                    HStack(spacing: 20) {
                        PageThumbnail(note: note, page: page, region: choice.rect).frame(width: 68, height: 92)
                        Text(choice.displayLabel(in: appLanguage)).foregroundStyle(.primary)
                        Spacer()
                        Image(systemName: selected.contains(choice.id) ? "checkmark.circle.fill" : "circle")
                    }
                }.accessibilityLabel(choice.displayLabel(in: appLanguage) + (selected.contains(choice.id) ? localized(", 선택됨", language: appLanguage) : localized(", 선택 안 됨", language: appLanguage)))
            }
        }
    }
}

struct PDFExportSelection: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    let note: Notebook
    let choices: [SummarySource]
    let exporting: Bool
    let progress: AppMessage
    @Binding var error: AppMessage?
    let cancel: () -> Void
    let export: (Set<String>) -> Void
    @State private var selected = Set<String>()
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                if exporting { Section { ProgressView(progress.text); Button(localized("내보내기 취소", language: appLanguage), action: cancel) } }
                Section(localized("원래 문서 순서로 내보냅니다", language: appLanguage)) { PageSelectionRows(note: note, choices: choices, selected: $selected).disabled(exporting) }
            }
                .navigationTitle(localized("선택 PDF 내보내기", language: appLanguage)).navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button(localized("취소", language: appLanguage)) { dismiss() }.disabled(exporting) }
                    ToolbarItem(placement: .confirmationAction) { Button(localized("내보내기", language: appLanguage)) { export(selected) }.disabled(selected.isEmpty || exporting) }
                }
        }.interactiveDismissDisabled(exporting)
            .alert(localized("내보내지 못했습니다", language: appLanguage), isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button(localized("확인", language: appLanguage), role: .cancel) { error = nil }
            } message: { Text(error?.text ?? "") }
    }
}
