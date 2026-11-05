import SwiftUI

@main
@MainActor
struct ChaiMusicApp: App {
    @StateObject private var store: LibraryStore
    @StateObject private var player: PlayerController
    @StateObject private var sources: SourceManager
    @StateObject private var preferences: AppPreferences
    @StateObject private var lyrics: LyricsService
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let library = LibraryStore()
        let sourceManager = SourceManager(root: library.root)
        let options = AppPreferences()
        _store = StateObject(wrappedValue: library)
        _sources = StateObject(wrappedValue: sourceManager)
        _preferences = StateObject(wrappedValue: options)
        _lyrics = StateObject(wrappedValue: LyricsService(sources: sourceManager))
        _player = StateObject(wrappedValue: PlayerController(store: library, sources: sourceManager, preferences: options))
    }

    var body: some Scene {
        WindowGroup {
            AppShell().environmentObject(store).environmentObject(player)
                .environmentObject(sources).environmentObject(preferences).environmentObject(lyrics)
                .preferredColorScheme(.dark).tint(Tea.gold)
                .onChange(of: scenePhase) { _, phase in
                    if phase != .active { player.persist(); store.save() }
                }
        }
    }
}
