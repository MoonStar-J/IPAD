import SwiftUI

@main
struct YeobaekApp: App {
    @StateObject private var store = NoteStore()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            LibraryView()
                .environmentObject(store)
                .tint(.accentColor)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { store.flushDrawings() }
                }
        }
    }
}
