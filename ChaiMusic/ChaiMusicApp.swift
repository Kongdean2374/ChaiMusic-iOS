import SwiftUI

@main
@MainActor
struct ChaiMusicApp: App {
    @StateObject private var store: LibraryStore
    @StateObject private var player: PlayerController
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = LibraryStore()
        _store = StateObject(wrappedValue: library)
        _player = StateObject(wrappedValue: PlayerController(store: library))
    }

    var body: some Scene {
        WindowGroup {
            AppShell()
                .environmentObject(store)
                .environmentObject(player)
                .preferredColorScheme(.dark)
                .tint(Tea.gold)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { player.persist(); store.save() }
                }
        }
    }
}
