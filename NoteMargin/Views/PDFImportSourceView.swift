import SwiftUI
import UniformTypeIdentifiers

/// The library owns this operation. Presenting/dismissing the system picker
/// cannot cancel a cloud read or lose its prepared bytes.
@MainActor
final class PDFImportFlow: ObservableObject {
    enum Stage { case sources, reading, options(PreparedPDFImport), failed(String) }
    @Published private(set) var stage: Stage = .sources
    private var task: Task<Void, Never>?
    private var generation = UUID()
    var preparing: Bool { if case .reading = stage { return true }; return false }

    func cancel() { generation = UUID(); task?.cancel(); task = nil; stage = .sources }
    func prepare(_ url: URL, store: NoteStore, folderID: UUID?, projectID: UUID?) {
        start(store: store, folderID: folderID, projectID: projectID) { try await PDFImportReader.read(url) }
    }
    func start(store: NoteStore, folderID: UUID?, projectID: UUID?, read: @escaping () async throws -> PDFImportContents) {
        guard !preparing else { return }
        let token = UUID(); generation = token; stage = .reading
        task = Task { @MainActor [weak self] in
            do {
                let contents = try await read()
                try Task.checkCancellation()
                guard let self, self.generation == token else { return }
                guard var prepared = store.preparePDF(data: contents.data, title: contents.title, folderID: folderID) else {
                    self.stage = .failed(store.errorMessage ?? "PDF를 열 수 없습니다. 암호가 해제된 PDF를 선택해 주세요.")
                    store.errorMessage = nil; self.task = nil; return
                }
                prepared.projectID = projectID
                self.stage = .options(prepared)
            } catch is CancellationError {
                if self?.generation == token { self?.stage = .sources }
            } catch {
                if self?.generation == token { self?.stage = .failed(error.localizedDescription) }
            }
            if self?.generation == token { self?.task = nil }
        }
    }
    func create(layout: PDFImportLayout, store: NoteStore) -> UUID? {
        guard case .options(let prepared) = stage else { return nil }
        // Consume once. Repeated button/delegate deliveries cannot create twice.
        stage = .reading
        if let id = store.importPDF(prepared, layout: layout) { stage = .sources; return id }
        stage = .options(prepared)
        return nil
    }
}

struct PDFImportSourceView: View {
    @ObservedObject var flow: PDFImportFlow
    let folderID: UUID?
    let projectID: UUID?
    let onImported: (UUID) -> Void
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingPicker = false

    var body: some View {
        NavigationStack {
            Group {
                switch flow.stage {
                case .options(let prepared):
                    List {
                        Section {
                            Text(prepared.title).font(.headline)
                            Text("\(prepared.pages.count)페이지").foregroundStyle(.secondary)
                        }
                        Section("페이지 배치") {
                            ForEach(prepared.pages.count > 1 ? PDFImportLayout.allCases : [.paged]) { layout in
                                Button {
                                    if let id = flow.create(layout: layout, store: store) { onImported(id) }
                                } label: {
                                    Label(layout.title, systemImage: layout == .continuous ? "scroll" : "rectangle.stack")
                                        .padding(.vertical, 12)
                                }.accessibilityIdentifier("pdf-layout-" + layout.rawValue)
                            }
                        }
                    }.accessibilityIdentifier("pdf-import-options")
                case .reading:
                    VStack(spacing: 20) {
                        ProgressView("PDF를 준비하는 중…")
                        Button("취소") { flow.cancel() }
                    }
                case .sources, .failed:
                    List {
                        if case .failed(let message) = flow.stage {
                            Section { Text(message).foregroundStyle(.red) } header: { Text("가져오지 못했습니다") }
                        }
                        Section {
                            Button { showingPicker = true } label: { Label("파일에서 선택", systemImage: "folder") }
                                .accessibilityIdentifier("pdf-import-files")
                        } footer: { Text("내 iPad, iCloud Drive와 파일 앱의 저장 공간에서 PDF를 가져옵니다.") }
                        Section("Google Drive") {
                            GoogleDriveImportButton { contents in
                                flow.start(store: store, folderID: folderID, projectID: projectID, read: contents)
                            }
                        }
                    }
                }
            }
            .navigationTitle("PDF 가져오기").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) {
                Button("닫기") { flow.cancel(); dismiss() }
            } }
            .sheet(isPresented: $showingPicker) {
                PDFDocumentPicker { url in
                    showingPicker = false
                    if let url { flow.prepare(url, store: store, folderID: folderID, projectID: projectID) }
                }
            }
        }.presentationDetents([.large]).interactiveDismissDisabled(flow.preparing)
    }
}

struct PDFDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--pdf-import-fixture") {
            let directory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("Import Fixtures", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("Import Regression.pdf")
            let renderer = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 595, height: 842))
            try? renderer.pdfData { pdf in
                for page in 1...2 { pdf.beginPage(); ("Import test \(page)" as NSString).draw(at: CGPoint(x: 40, y: 40), withAttributes: nil) }
            }.write(to: file, options: .atomic)
            picker.directoryURL = directory
        }
        #endif
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        private var delivered = false
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
        private func finish(_ url: URL?) { guard !delivered else { return }; delivered = true; onPick(url) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(nil) }
    }
}
