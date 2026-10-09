import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return "시스템"; case .light: return "라이트"; case .dark: return "다크" } }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}

struct AppearancePicker: View {
    @AppStorage("app.appearance") private var appearance: AppAppearance = .system
    var body: some View {
        Picker("화면 모드", selection: $appearance) {
            ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
        }
    }
}

struct AppearanceSettings: View {
    @AppStorage("app.appearance") private var appearance: AppAppearance = .system
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section("화면") { AppearancePicker() }
                Section("AI") {
                    NavigationLink("기본 요약 프롬프트") { SummaryPromptSettings() }
                    NavigationLink("AI 질문 프리셋") { AIQuestionPresetSettings() }
                }
            }
                .navigationTitle("설정").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }.presentationDetents([.large]).preferredColorScheme(appearance.colorScheme)
    }
}

struct SummaryPromptSettings: View {
    @AppStorage(SummaryPrompt.defaultKey) private var prompt = ""
    var body: some View {
        Form {
            Section("기본 요약 프롬프트") {
                TextEditor(text: $prompt).frame(minHeight: 240).accessibilityIdentifier("default-summary-prompt")
                Text("자동 저장됩니다. 공백이면 내장 기본값을 사용합니다. 출처·수식 형식·자료 안전 규칙은 항상 적용합니다.").font(.caption)
                Button("기본값 복원") { prompt = "" }
            }
            Section("내장 기본값") { Text(SummaryPrompt.defaultStyle).font(.callout) }
        }.navigationTitle("기본 요약 프롬프트").navigationBarTitleDisplayMode(.inline)
    }
}

struct AIQuestionPresetSettings: View {
    @AppStorage(AIQuestionPreferences.key) private var data = Data()
    @State private var presets: [AIQuestionPreset] = []
    @State private var loaded = false
    @State private var error: String?
    var body: some View {
        List {
            Section {
                ForEach($presets) { $preset in
                    NavigationLink(preset.name.isEmpty ? "이름 없는 프리셋" : preset.name) {
                        Form {
                            TextField("표시 이름", text: $preset.name).accessibilityIdentifier("preset-name")
                            Section("기본 질문") { TextEditor(text: $preset.question).frame(minHeight: 120).accessibilityIdentifier("preset-question") }
                            Section("응답 지침") { TextEditor(text: $preset.instructions).frame(minHeight: 180).accessibilityIdentifier("preset-instructions") }
                            Text("자동 저장됩니다. 직접 작성한 질문에도 이 응답 지침을 적용합니다. 이미 보낸 요청은 바뀌지 않습니다.").font(.caption)
                        }.navigationTitle("프리셋 편집").navigationBarTitleDisplayMode(.inline)
                    }
                }.onDelete { presets.remove(atOffsets: $0) }
            }
            if loaded {
                Section {
                    Button("프리셋 추가") { presets.append(.init(id: UUID().uuidString, name: "새 프리셋", question: "", instructions: "")) }
                    Button("기본 항목 복원") { presets = AIQuestionPreferences.restore(presets) }
                    Text("기본 항목을 복원해도 직접 추가한 프리셋은 유지됩니다. 삭제는 항목을 왼쪽으로 밀어 주세요.").font(.caption)
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.navigationTitle("AI 질문 프리셋").navigationBarTitleDisplayMode(.inline)
            .task {
                do { presets = try AIQuestionPreferences.decode(data); loaded = true }
                catch { self.error = "저장된 프리셋을 읽지 못했습니다. 기존 설정을 보존했습니다." }
            }
            .onChange(of: presets) { _, value in
                guard loaded else { return }
                do { data = try JSONEncoder().encode(value) }
                catch { self.error = error.localizedDescription }
            }
    }
}
