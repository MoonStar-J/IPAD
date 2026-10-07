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
            Form { Section("화면") { AppearancePicker() } }
                .navigationTitle("설정").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("완료") { dismiss() } } }
        }.presentationDetents([.medium]).preferredColorScheme(appearance.colorScheme)
    }
}
