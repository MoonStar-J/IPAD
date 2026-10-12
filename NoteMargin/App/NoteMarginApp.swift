import SwiftUI

@main
struct NoteMarginApp: App {
    @AppStorage("app.appearance") private var appearance: AppAppearance = .system
    @AppStorage(AppLanguage.key) private var language: AppLanguage = .korean
    @StateObject private var store = NoteStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .environment(\.locale, language.locale)
                .tint(.accentColor)
                .preferredColorScheme(appearance.colorScheme)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { store.flushDrawings() }
                    if phase == .background {
                        ChatGPTPlanConnection.shared.cancelSignIn()
                        MarginAIStore.shared.cancelPlanRequests()
                    }
                }
        }
    }
}
