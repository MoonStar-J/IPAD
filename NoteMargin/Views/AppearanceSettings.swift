import SwiftUI

enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var title: String { switch self { case .system: return localized("시스템"); case .light: return localized("라이트"); case .dark: return localized("다크") } }
    var colorScheme: ColorScheme? { switch self { case .system: return nil; case .light: return .light; case .dark: return .dark } }
}

struct AppearancePicker: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    @AppStorage("app.appearance") private var appearance: AppAppearance = .system
    var body: some View {
        Picker(localized("화면 모드", language: appLanguage), selection: $appearance) {
            ForEach(AppAppearance.allCases) { Text(localized($0.title, language: appLanguage)).tag($0) }
        }
    }
}

struct LanguagePicker: View {
    @AppStorage(AppLanguage.key) private var language: AppLanguage = .korean
    var body: some View {
        Picker(localized("언어", language: language), selection: $language) {
            ForEach(AppLanguage.allCases) { Text($0.title).tag($0) }
        }.accessibilityIdentifier("app-language")
    }
}

struct AppearanceSettings: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    @AppStorage("app.appearance") private var appearance: AppAppearance = .system
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Section(localized("언어", language: appLanguage)) { LanguagePicker() }
                Section(localized("화면", language: appLanguage)) { AppearancePicker() }
                Section("AI") {
                    NavigationLink(localized("기본 요약 프롬프트", language: appLanguage)) { SummaryPromptSettings() }
                    NavigationLink(localized("AI 질문 프리셋", language: appLanguage)) { AIQuestionPresetSettings() }
                }
            }
                .navigationTitle(localized("설정", language: appLanguage)).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button(localized("완료", language: appLanguage)) { dismiss() } } }
        }.presentationDetents([.large]).preferredColorScheme(appearance.colorScheme)
    }
}

struct SummaryPromptSettings: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    @AppStorage(SummaryPrompt.defaultKey) private var prompt = ""
    var body: some View {
        Form {
            Section(localized("기본 요약 프롬프트", language: appLanguage)) {
                TextEditor(text: $prompt).frame(minHeight: 240).accessibilityIdentifier("default-summary-prompt")
                Text(localized("자동 저장됩니다. 공백이면 내장 기본값을 사용합니다. 출처·수식 형식·자료 안전 규칙은 항상 적용합니다.", language: appLanguage)).font(.caption)
                Button(localized("기본값 복원", language: appLanguage)) { prompt = "" }
            }
            Section(localized("내장 기본값", language: appLanguage)) { Text(localized(SummaryPrompt.defaultStyle, language: appLanguage)).font(.callout) }
        }.navigationTitle(localized("기본 요약 프롬프트", language: appLanguage)).navigationBarTitleDisplayMode(.inline)
    }
}

struct AIQuestionPresetSettings: View {
    @AppStorage(AppLanguage.key) private var appLanguage: AppLanguage = .korean
    @AppStorage(AIQuestionPreferences.key) private var data = Data()
    @State private var presets: [AIQuestionPreset] = []
    @State private var loaded = false
    @State private var error: AppMessage?
    var body: some View {
        List {
            Section {
                ForEach($presets) { $preset in
                    NavigationLink(preset.name.isEmpty ? localized("이름 없는 프리셋", language: appLanguage) : preset.displayName(in: appLanguage)) {
                        Form {
                            TextField(localized("표시 이름", language: appLanguage), text: Binding(get: { preset.displayName(in: appLanguage) }, set: { preset.name = $0 })).accessibilityIdentifier("preset-name")
                            Section(localized("기본 질문", language: appLanguage)) { TextEditor(text: Binding(get: { preset.displayQuestion(in: appLanguage) }, set: { preset.question = $0 })).frame(minHeight: 120).accessibilityIdentifier("preset-question") }
                            Section(localized("응답 지침", language: appLanguage)) { TextEditor(text: Binding(get: { preset.displayInstructions(in: appLanguage) }, set: { preset.instructions = $0 })).frame(minHeight: 180).accessibilityIdentifier("preset-instructions") }
                            Text(localized("자동 저장됩니다. 직접 작성한 질문에도 이 응답 지침을 적용합니다. 이미 보낸 요청은 바뀌지 않습니다.", language: appLanguage)).font(.caption)
                        }.navigationTitle(localized("프리셋 편집", language: appLanguage)).navigationBarTitleDisplayMode(.inline)
                    }
                }.onDelete { presets.remove(atOffsets: $0) }
            }
            if loaded {
                Section {
                    Button(localized("프리셋 추가", language: appLanguage)) { presets.append(.init(id: UUID().uuidString, name: localized("새 프리셋", language: appLanguage), question: "", instructions: "")) }
                    Button(localized("기본 항목 복원", language: appLanguage)) { presets = AIQuestionPreferences.restore(presets) }
                    Text(localized("기본 항목을 복원해도 직접 추가한 프리셋은 유지됩니다. 삭제는 항목을 왼쪽으로 밀어 주세요.", language: appLanguage)).font(.caption)
                }
            }
            if let error { Section { Text(error.text).foregroundStyle(.red) } }
        }.navigationTitle(localized("AI 질문 프리셋", language: appLanguage)).navigationBarTitleDisplayMode(.inline)
            .task {
                do { presets = try AIQuestionPreferences.decode(data); loaded = true }
                catch { self.error = AppMessage("저장된 프리셋을 읽지 못했습니다. 기존 설정을 보존했습니다.") }
            }
            .onChange(of: presets) { _, value in
                guard loaded else { return }
                do { data = try JSONEncoder().encode(value) }
                catch { self.error = AppMessage(error) }
            }
    }
}
