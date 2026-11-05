// swift-tools-version: 5.9
import PackageDescription
import Foundation

// Core 與 SQLite 使用同一模組，讓 Linux/macOS 驗證不需要匯入 iOS UI。
let databaseSources = ["Services/LibraryDatabase.swift", "Services/BackupService.swift"]
let serviceFiles = (try? FileManager.default.contentsOfDirectory(atPath: "ChaiMusic/Services")) ?? []
let ignoredServices = serviceFiles.map { "Services/\($0)" }.filter { !databaseSources.contains($0) }
let package = Package(
    name: "ChaiMusicCore",
    platforms: [.macOS(.v13)],
    products: [.library(name: "ChaiMusicCore", targets: ["ChaiMusicCore"])],
    targets: [
        .systemLibrary(name: "CSQLite", path: "Sources/CSQLite", pkgConfig: "sqlite3", providers: [.apt(["libsqlite3-dev"]), .brew(["sqlite3"])]),
        .target(name: "ChaiMusicCore", dependencies: ["CSQLite"], path: "ChaiMusic",
                exclude: ["Views", "Resources", "ChaiMusicApp.swift"] + ignoredServices,
                sources: ["Core"] + databaseSources),
        .testTarget(name: "ChaiMusicCoreTests", dependencies: ["ChaiMusicCore"], path: "Tests/ChaiMusicCoreTests")
    ],
    swiftLanguageVersions: [.v5]
)
