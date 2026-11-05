// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Core 與 SQLite 使用同一模組，讓 Linux/macOS 驗證不需要匯入 iOS UI。
let databaseSources = ["Services/LibraryDatabase.swift", "Services/BackupService.swift"]
let serviceFiles = (try? FileManager.default.contentsOfDirectory(atPath: "ChaiMusic/Services")) ?? []
let ignoredServices = serviceFiles.map { "Services/\($0)" }.filter { !databaseSources.contains($0) }
// Linux 使用系統套件；Apple 平台只匯入 SDK 的 SQLite3，避免 pkg-config 帶入 Homebrew 標頭。
#if os(Linux)
let sqliteTargets: [Target] = [
    .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"])])
]
let sqliteDependencies: [Target.Dependency] = ["CSQLite"]
#else
let sqliteTargets: [Target] = []
let sqliteDependencies: [Target.Dependency] = []
#endif

let package = Package(
    name: "ChaiMusicCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ChaiMusicCore", targets: ["ChaiMusicCore"])],
    targets: sqliteTargets + [
        .target(name: "ChaiMusicCore", dependencies: sqliteDependencies, path: "ChaiMusic",
                exclude: ["Views", "Resources", "ChaiMusicApp.swift"] + ignoredServices,
                sources: ["Core"] + databaseSources),
        .testTarget(name: "ChaiMusicCoreTests", dependencies: ["ChaiMusicCore"], path: "Tests/ChaiMusicCoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
