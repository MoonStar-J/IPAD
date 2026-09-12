import SwiftUI

struct AIConnectionSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var connection: AIConnectionStore
    @State private var provider: AIProvider = .openAI
    @State private var model = ""
    @State private var key = ""
    @State private var errorMessage: String?
    @State private var saved = false

    private var hasKey: Bool { connection.configuredProviders.contains(provider) }
    private var hasUnsavedSettings: Bool {
        !key.isEmpty || provider != connection.selectedProvider || model != connection.model
    }

    @MainActor init(connection: AIConnectionStore? = nil) {
        self.connection = connection ?? .shared
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("AI 서비스", selection: $provider) {
                        ForEach(AIProvider.allCases) { Text($0.title).tag($0) }
                    }.accessibilityIdentifier("ai-provider")
                    LabeledContent("연결 상태", value: hasKey ? "API 키 저장됨" : "연결 필요")
                } header: { Text("앱 전체 AI 연결") } footer: {
                    Text("한 번 연결하면 모든 프로젝트에서 사용할 수 있습니다. 프로젝트마다 학습 지침과 대화는 따로 관리됩니다.")
                }
                Section {
                    SecureField(hasKey ? "새 키를 입력하면 교체됩니다" : "API 키 입력", text: $key)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done)
                        .privacySensitive().accessibilityIdentifier("ai-api-key")
                    Link(destination: provider.keyManagementURL) {
                        Label("\(provider.title)에서 API 키 만들기", systemImage: "arrow.up.right.square")
                    }
                } header: { Text("내 API 키") } footer: {
                    Text("키는 이 iPad의 키체인에 저장됩니다. 질문을 보내면 선택 영역과 해당 대화가 선택한 AI 서비스로 전송됩니다. API 사용료는 해당 계정에 별도로 청구될 수 있습니다.")
                }
                Section {
                    TextField(provider.defaultModel, text: $model)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done)
                        .accessibilityLabel("AI 모델").accessibilityIdentifier("ai-model")
                    Button("기본 모델 사용") { model = provider.defaultModel }
                } header: { Text("모델") } footer: {
                    Text("PDF와 필기를 읽을 수 있는 이미지 입력 지원 모델을 사용해 주세요.")
                }
                Section {
                    Button("연결 설정 저장") { _ = save() }
                        .disabled(model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!hasKey && key.isEmpty))
                        .accessibilityIdentifier("save-ai-connection")
                    if hasKey {
                        Button("\(provider.title) 연결 해제", role: .destructive) {
                            do { try connection.removeAPIKey(for: provider); key = ""; saved = false }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }
                    if saved { Label("설정을 저장했습니다", systemImage: "checkmark.circle.fill").foregroundStyle(.green) }
                }
            }
            .navigationTitle("AI 연결").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("취소") { dismiss() }.accessibilityIdentifier("cancel-ai-connection")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("완료", action: complete).accessibilityIdentifier("complete-ai-connection")
                }
            }
            .onSubmit(complete)
            .onAppear { provider = connection.selectedProvider; model = connection.model }
            .onChange(of: provider) { _, next in
                key = ""; saved = false
                model = connection.savedModel(for: next)
            }
            .onChange(of: model) { _, _ in saved = false }
            .onChange(of: key) { _, newValue in if !newValue.isEmpty { saved = false } }
            .alert("연결 설정을 저장하지 못했습니다", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
                Button("확인", role: .cancel) { errorMessage = nil }
            } message: { Text(errorMessage ?? "") }
        }
        .presentationDetents([.large])
    }

    private func complete() {
        if !hasUnsavedSettings || save() { dismiss() }
    }

    private func save() -> Bool {
        do {
            let normalizedModel = try AIClient.normalizedModel(model, provider: provider)
            if !key.isEmpty { try connection.saveAPIKey(key, for: provider) }
            else if try connection.apiKey(for: provider) == nil { throw AIConnectionError.emptyKey }
            connection.selectedProvider = provider
            connection.model = normalizedModel
            key = ""
            saved = true
            return true
        } catch { errorMessage = error.localizedDescription; return false }
    }
}
