import Foundation
import Combine

@MainActor
final class AppPreferences: ObservableObject {
    @Published var autoUpgrade: Bool { didSet { defaults.set(autoUpgrade, forKey: "autoUpgrade") } }
    @Published var animatedArtwork: Bool { didSet { defaults.set(animatedArtwork, forKey: "animatedArtwork") } }
    @Published var respectLowPower: Bool { didSet { defaults.set(respectLowPower, forKey: "respectLowPower") } }
    @Published var preferLossless: Bool { didSet { defaults.set(preferLossless, forKey: "preferLossless") } }
    @Published var networkPlayback: Bool { didSet { defaults.set(networkPlayback, forKey: "networkPlayback") } }
    private let defaults: UserDefaults
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoUpgrade = defaults.object(forKey: "autoUpgrade") as? Bool ?? true
        animatedArtwork = defaults.object(forKey: "animatedArtwork") as? Bool ?? true
        respectLowPower = defaults.object(forKey: "respectLowPower") as? Bool ?? true
        preferLossless = defaults.object(forKey: "preferLossless") as? Bool ?? true
        networkPlayback = defaults.object(forKey: "networkPlayback") as? Bool ?? true
    }
}
