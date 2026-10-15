import SwiftUI
import UniformTypeIdentifiers

@MainActor
final class PDFImportFlow: ObservableObject {
    enum Stage { case sources, reading, selection, options, result }
    @Published private(set) var stage: Stage = .sources
    @Published var files: [PreparedPDFImport] = []
    @Published private(set) var failures: [AppMessage] = []
    @Published private(set) var created: [UUID] = []
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var preparing: Bool { if case .reading = stage { return true }; return false }

    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        stage = created.isEmpty ? .sources : .result
        files = []
    }
    func reset() { cancel(); created = []; failures = []; stage = .sources }
    func prepare(_ urls: [URL], store: NoteStore, folderID: UUID?, projectID: UUID?) {
        start(store: store, folderID: folderID, projectID: projectID) {
            var selection = PDFImportSelection()
            for url in urls {
                try Task.checkCancellation()
                do { selection.files.append(try await PDFImportReader.read(url)) }
                catch is CancellationError { throw CancellationError() }
                catch { selection.failures.append(AppMessage("%@ · %@", url.lastPathComponent, AppMessage(error).text)) }
            }
            return selection
        }
    }
    func start(store: NoteStore, folderID: UUID?, projectID: UUID?, read: @escaping () async throws -> PDFImportSelection) {
        guard !preparing else { return }
        let token = UUID(); generation = token; stage = .reading
        task = Task { @MainActor [weak self] in
            do {
                let selection = try await read()
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                self.failures += selection.failures
                for contents in selection.files {
                    await Task.yield()
                    try Task.checkCancellation()
                    if var prepared = store.preparePDF(contents, folderID: folderID) {
                        prepared.projectID = projectID
                        self.files.append(prepared)
                    } else {
                        self.failures.append(AppMessage("%@ · %@", contents.title, store.errorMessage?.text ?? localized("가져오지 못했습니다")))
                        store.errorMessage = nil
                    }
                }
                self.stage = .selection
            } catch is CancellationError {
                if self?.generation == token { self?.stage = .selection }
            } catch {
                if self?.generation == token { self?.failures.append(AppMessage(error)); self?.stage = .selection }
            }
            if self?.generation == token { self?.task = nil }
        }
    }
    func chooseOptions() { guard !files.isEmpty, !preparing else { return }; stage = .options }
    func editSelection() { guard !preparing else { return }; stage = .selection }
    func create(layout: PDFImportLayout, separate: Bool, title: String, store: NoteStore, completion: @escaping (UUID) -> Void) {
        guard case .options = stage, !files.isEmpty else { return }
        let token = UUID(); generation = token; stage = .reading; created = []
        let groups = separate ? files.map { [$0] } : [files]
        task = Task { @MainActor [weak self] in
            for group in groups {
                await Task.yield()
                guard let self, !Task.isCancelled, self.generation == token else { return }
                let result = await store.importPDFs(group, title: separate ? group[0].title : title, layout: layout)
                guard !Task.isCancelled, self.generation == token else { return }
                if let id = result {
                    self.created.append(id)
                } else {
                    self.failures.append(AppMessage("%@ · %@", group.map(\.title).joined(separator: ", "), store.errorMessage?.text ?? localized("가져오지 못했습니다")))
                    store.errorMessage = nil
                }
            }
            guard let self, self.generation == token else { return }
            self.files = []; self.task = nil; self.stage = .result
            if self.created.count == 1 && self.failures.isEmpty { completion(self.created[0]) }
        }
    }
}

struct PDFImportSourceView: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    @ObservedObject var flow: PDFImportFlow
    let folderID: UUID?
    let projectID: UUID?
    let onImported: (UUID) -> Void
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingPicker = false
    @State private var layout: PDFImportLayout = .paged
    @State private var separate = false
    @State private var title = ""

    var body: some View {
        NavigationStack {
            Group {
                switch flow.stage {
                case .options:
                    Form {
                        Section(localized("노트 이름", language: appLanguage)) {
                            if separate {
                                ForEach($flow.files) { $file in TextField(localized("노트 이름", language: appLanguage), text: $file.title) }
                            } else { TextField(localized("노트 이름", language: appLanguage), text: $title) }
                        }
                        Section(localized("페이지 구성", language: appLanguage)) {
                            Picker(localized("페이지 구성", language: appLanguage), selection: $layout) {
                                Text(localized("페이지별", language: appLanguage)).tag(PDFImportLayout.paged)
                                Text(localized("이어붙이기", language: appLanguage)).tag(PDFImportLayout.continuous)
                            }.pickerStyle(.segmented).accessibilityIdentifier("pdf-page-layout")
                        }
                        Section(localized("노트 구성", language: appLanguage)) {
                            Picker(localized("노트 구성", language: appLanguage), selection: $separate) {
                                Text(localized("모든 파일을 하나의 노트로", language: appLanguage)).tag(false)
                                Text(localized("파일별로 별도 노트", language: appLanguage)).tag(true)
                            }.pickerStyle(.inline).labelsHidden()
                        }
                        Button(localized("파일 순서 변경", language: appLanguage)) { flow.editSelection() }
                        Button(localized("만들기", language: appLanguage)) {
                            flow.create(layout: layout, separate: separate, title: title, store: store, completion: onImported)
                        }.accessibilityIdentifier("pdf-import-create")
                    }.accessibilityIdentifier("pdf-import-options")
                case .reading:
                    VStack(spacing: 20) {
                        ProgressView(localized("PDF를 준비하는 중…", language: appLanguage))
                        Button(localized("취소", language: appLanguage)) { flow.cancel() }
                    }
                case .result:
                    List {
                        Section(localized("생성된 노트", language: appLanguage)) {
                            ForEach(flow.created, id: \.self) { id in
                                Button(store.note(id)?.title ?? localized("노트", language: appLanguage)) { onImported(id) }
                            }
                        }
                        failureRows
                        Button(localized("다시 가져오기", language: appLanguage)) { flow.reset() }
                    }
                case .sources, .selection:
                    List {
                        if !flow.files.isEmpty {
                            Section(localized("파일 순서", language: appLanguage)) {
                                ForEach(flow.files) { file in
                                    HStack {
                                        Text(file.title)
                                        Spacer()
                                        Text(localized("page.count", "\(file.pages.count)", language: appLanguage)).foregroundStyle(.secondary)
                                    }
                                }.onMove { flow.files.move(fromOffsets: $0, toOffset: $1) }
                                    .onDelete { flow.files.remove(atOffsets: $0) }
                            }
                            Button(localized("불러오기", language: appLanguage)) {
                                if title.isEmpty { title = flow.files.first?.title ?? "" }
                                flow.chooseOptions()
                            }.accessibilityIdentifier("pdf-import-confirm-selection")
                        }
                        failureRows
                        Section {
                            Button { showingPicker = true } label: { Label(localized("파일에서 선택", language: appLanguage), systemImage: "folder") }
                                .accessibilityIdentifier("pdf-import-files")
                        } footer: { Text(localized("내 iPad, iCloud Drive와 파일 앱의 저장 공간에서 PDF를 가져옵니다.", language: appLanguage)) }
                        Section("Google Drive") {
                            GoogleDriveImportButton { read in flow.start(store: store, folderID: folderID, projectID: projectID, read: read) }
                        }
                    }.toolbar { if !flow.files.isEmpty { ToolbarItem(placement: .topBarTrailing) { EditButton() } } }
                }
            }
            .navigationTitle(localized("PDF 가져오기", language: appLanguage)).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button(localized("닫기", language: appLanguage)) { flow.reset(); dismiss() }.disabled(flow.preparing)
            } }
            .sheet(isPresented: $showingPicker) {
                PDFDocumentPicker { urls in
                    showingPicker = false
                    if !urls.isEmpty { flow.prepare(urls, store: store, folderID: folderID, projectID: projectID) }
                }
            }
        }.presentationDetents([.large]).interactiveDismissDisabled(flow.preparing)
    }
    @ViewBuilder private var failureRows: some View {
        if !flow.failures.isEmpty {
            Section(localized("가져오지 못했습니다", language: appLanguage)) {
                ForEach(Array(flow.failures.enumerated()), id: \.offset) { _, error in Text(error.text).foregroundStyle(.red) }
            }
        }
    }
}

struct PDFDocumentPicker: UIViewControllerRepresentable {
    let onPick: ([URL]) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.shouldShowFileExtensions = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--pdf-import-fixture") {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Import Fixtures", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            for name in ["Import Regression", "Second Regression"] {
                let file = directory.appendingPathComponent(name).appendingPathExtension("pdf")
                let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
                try? renderer.pdfData { pdf in
                    for page in 1...2 { pdf.beginPage(); ("\(name) \(page)" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: nil) }
                }.write(to: file, options: .atomic)
            }
            picker.directoryURL = directory
        }
        #endif
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        private var delivered = false
        init(onPick: @escaping ([URL]) -> Void) { self.onPick = onPick }
        private func finish(_ urls: [URL]) { guard !delivered else { return }; delivered = true; onPick(urls) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish([]) }
    }
}
