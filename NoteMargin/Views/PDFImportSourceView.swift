import SwiftUI
import UniformTypeIdentifiers

struct PDFImportSourceView: View {
    let folderID: UUID?
    let projectID: UUID?
    let onPrepared: (PreparedPDFImport) -> Void
    @EnvironmentObject private var store: NoteStore
    @Environment(\.dismiss) private var dismiss
    @State private var showingPicker = false
    @State private var pickedURL: URL?
    @State private var preparing = false
    @State private var importTask: Task<Void, Never>?
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button { showingPicker = true } label: {
                        Label("파일에서 선택", systemImage: "folder")
                            .foregroundStyle(.primary)
                    }.accessibilityIdentifier("pdf-import-files")
                } footer: { Text("내 iPad, iCloud Drive와 파일 앱에 연결한 저장 공간에서 PDF를 가져옵니다.") }

                Section {
                    Button { showingPicker = true } label: {
                        Label("Google Drive에서 선택", systemImage: "cloud")
                            .foregroundStyle(.primary)
                    }.accessibilityIdentifier("pdf-import-google-drive")
                    Text("선택 화면의 ‘둘러보기’ 또는 사이드바에서 Google Drive를 선택하세요.")
                        .font(.subheadline).foregroundStyle(.secondary)
                } header: { Text("Google Drive") } footer: {
                    Text("클라우드 파일은 다운로드가 끝난 뒤 가져옵니다. 인터넷 연결과 Drive의 파일 접근 권한이 필요합니다.")
                }

                Section("Google Drive가 보이지 않나요?") {
                    instruction("1", "Google Drive 앱을 설치하고 사용할 Google 계정으로 로그인하세요.")
                    instruction("2", "파일 앱에서 ‘둘러보기’ → ‘…’ → ‘편집’을 열고 위치 목록의 Google Drive를 켜세요.")
                    instruction("3", "이 화면으로 돌아와 ‘Google Drive에서 선택’을 누르세요.")
                    Link("파일 앱에 클라우드 저장 공간 연결하기", destination: URL(string: "https://support.apple.com/ko-kr/102238")!)
                        .font(.subheadline)
                }
            }
            .disabled(preparing)
            .overlay {
                if preparing {
                    VStack(spacing: 16) {
                        ProgressView("PDF를 준비하는 중…")
                        Button("취소") { importTask?.cancel() }
                    }.padding(24).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
                }
            }
            .navigationTitle("PDF 가져오기").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("닫기") { importTask?.cancel(); dismiss() }.disabled(preparing)
                }
            }
            .sheet(isPresented: $showingPicker, onDismiss: {
                if let url = pickedURL { pickedURL = nil; prepare(url) }
            }) {
                PDFDocumentPicker { url in
                    pickedURL = url
                    showingPicker = false
                }
            }
            .alert("PDF를 가져오지 못했습니다", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("확인", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
            .onDisappear { importTask?.cancel() }
        }.presentationDetents([.large]).interactiveDismissDisabled(preparing)
    }

    private func instruction(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.weight(.semibold)).frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.12), in: Circle())
            Text(text).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }.padding(.vertical, 3)
    }

    private func prepare(_ url: URL) {
        guard !preparing else { return }
        preparing = true
        importTask = Task { @MainActor in
            defer { preparing = false; importTask = nil }
            do {
                let contents = try await PDFImportReader.read(url)
                try Task.checkCancellation()
                guard var prepared = store.preparePDF(data: contents.data, title: contents.title, folderID: folderID) else {
                    errorMessage = store.errorMessage ?? "PDF를 열 수 없습니다. 암호가 해제된 PDF를 선택해 주세요."
                    store.errorMessage = nil
                    return
                }
                prepared.projectID = projectID
                onPrepared(prepared)
            } catch is CancellationError {
                // The selection and library stay unchanged when cancelled.
            } catch {
                errorMessage = "파일을 읽지 못했습니다. 인터넷 연결과 Drive 앱의 로그인 상태를 확인한 뒤 다시 선택해 주세요.\n\n\(error.localizedDescription)"
            }
        }
    }
}

private struct PDFDocumentPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.pdf], asCopy: true)
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) { }
    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void
        init(onPick: @escaping (URL?) -> Void) { self.onPick = onPick }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onPick(urls.first) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onPick(nil) }
    }
}
